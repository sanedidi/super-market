package variants

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/variants/naming"
)

// Группы, которые собирает автонормализация каталога (пакет catalognorm):
// Super Market сам разобрал товары на линейку, вкус и вес и сразу
// подтверждает группу (source = auto) — без очереди супер-админа. Откат
// автонормализации расформировывает такие группы.

// AutoItem — товар группы с разобранными весом и вкусом.
type AutoItem struct {
	ProductID string `json:"product_id"`
	Weight    string `json:"weight"`
	WeightUz  string `json:"weight_uz"`
	Flavor    string `json:"flavor"`
	FlavorUz  string `json:"flavor_uz"`
}

// AutoGroup — новая группа общего каталога.
type AutoGroup struct {
	Name       string     `json:"name"`
	NameUz     string     `json:"name_uz"`
	BrandID    string     `json:"brand_id"`
	CategoryID string     `json:"category_id"`
	Items      []AutoItem `json:"items"`
}

// FindConfirmed — подтверждённая группа общего каталога той же марки и
// категории с тем же названием линейки (без учёта регистра и знаков).
func (s *Service) FindConfirmed(ctx context.Context, brandID, categoryID, name string) (string, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT id::text, name FROM variant_groups
		WHERE network_id IS NULL AND status = 'confirmed' AND brand_id = $1 AND category_id = $2`, brandID, categoryID)
	if err != nil {
		return "", err
	}
	type g struct{ id, name string }
	gs, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (g, error) {
		var x g
		return x, r.Scan(&x.id, &x.name)
	})
	if err != nil {
		return "", err
	}
	want := naming.Fold(name)
	for _, x := range gs {
		if naming.Fold(x.name) == want {
			return x.id, nil
		}
	}
	return "", nil
}

// freeItems — товары, которые можно взять в группу: общего каталога, активные,
// не в группе и не в предложении или отклонённом предложении; пары «вес+вкус»
// не повторяются (и с уже стоящими в группе groupID).
func freeItems(ctx context.Context, tx pgx.Tx, groupID string, items []AutoItem) ([]AutoItem, error) {
	ids := make([]string, len(items))
	for i, it := range items {
		ids[i] = it.ProductID
	}
	rows, err := tx.Query(ctx, `
		SELECT p.id::text FROM products p
		WHERE p.id = ANY ($1::uuid[]) AND p.network_id IS NULL AND p.is_active AND p.variant_group_id IS NULL
		  AND NOT EXISTS (SELECT 1 FROM variant_group_items i JOIN variant_groups g ON g.id = i.group_id
		                  WHERE i.product_id = p.id AND g.status IN ('proposed', 'rejected'))`, ids)
	if err != nil {
		return nil, err
	}
	free, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, err
	}
	ok := map[string]bool{}
	for _, id := range free {
		ok[id] = true
	}
	seen := map[string]bool{}
	if groupID != "" {
		rows, err := tx.Query(ctx, `SELECT weight, flavor FROM variant_group_items WHERE group_id = $1 AND included`, groupID)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var w, f string
			if err := rows.Scan(&w, &f); err != nil {
				rows.Close()
				return nil, err
			}
			seen[naming.Fold(w)+"|"+naming.Fold(f)] = true
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return nil, err
		}
	}
	var out []AutoItem
	for _, it := range items {
		k := naming.Fold(it.Weight) + "|" + naming.Fold(it.Flavor)
		if !ok[it.ProductID] || seen[k] || k == "|" {
			continue
		}
		seen[k] = true
		ok[it.ProductID] = false
		out = append(out, it)
	}
	return out, nil
}

func insertItems(ctx context.Context, tx pgx.Tx, groupID string, items []AutoItem) error {
	for _, it := range items {
		w := clip(strings.TrimSpace(it.Weight), maxWeight)
		wuz := clip(strings.TrimSpace(it.WeightUz), maxWeight)
		if wuz == "" {
			wuz = naming.WeightUz(w)
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO variant_group_items (group_id, product_id, weight, weight_uz, weight_sort, flavor, flavor_uz, included, sort)
			VALUES ($1, $2, $3, $4, $5, $6, $7, true, (SELECT COALESCE(max(sort), 0) + 1 FROM variant_group_items WHERE group_id = $1))
			ON CONFLICT DO NOTHING`,
			groupID, it.ProductID, w, wuz, naming.WeightSort(w),
			clip(naming.Capitalize(strings.TrimSpace(it.Flavor)), maxFlavor), clip(naming.Capitalize(strings.TrimSpace(it.FlavorUz)), maxFlavor)); err != nil {
			return err
		}
	}
	return nil
}

// AutoCreate — новая подтверждённая группа. Меньше двух свободных товаров —
// группы нет (id пустой). Возвращает товары, которые вошли в группу.
func (s *Service) AutoCreate(ctx context.Context, g AutoGroup) (string, []AutoItem, error) {
	name := clip(strings.TrimSpace(g.Name), 120)
	if name == "" {
		return "", nil, nil
	}
	var id string
	var used []AutoItem
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		items, err := freeItems(ctx, tx, "", g.Items)
		if err != nil {
			return err
		}
		if len(items) < 2 {
			return nil
		}
		var weights, flavors []string
		for _, it := range items {
			weights, flavors = append(weights, it.Weight), append(flavors, it.Flavor)
		}
		wl, wlUz, fl, flUz := naming.Labels(weights, flavors)
		if wl == "" && fl == "" {
			return nil
		}
		if err := tx.QueryRow(ctx, `
			INSERT INTO variant_groups (name, name_uz, brand_id, category_id, source, confidence, status, decided_at,
			                            weight_label, weight_label_uz, flavor_label, flavor_label_uz)
			VALUES ($1, $2, $3, $4, 'auto', 'high', 'confirmed', now(), $5, $6, $7, $8) RETURNING id`,
			name, clip(strings.TrimSpace(g.NameUz), 120), g.BrandID, g.CategoryID, wl, wlUz, fl, flUz).Scan(&id); err != nil {
			return err
		}
		if err := insertItems(ctx, tx, id, items); err != nil {
			return err
		}
		if err := validate(ctx, tx, id); err != nil {
			// Не сошлось (например, одинаковые вес и вкус после обрезки) — группы нет.
			id = ""
			return errSkip
		}
		used = items
		return apply(ctx, tx, id, true)
	})
	if errors.Is(err, errSkip) {
		return "", nil, nil
	}
	if err != nil {
		return "", nil, err
	}
	return id, used, nil
}

var errSkip = errors.New("skip")

// AutoJoin — добавить товары в подтверждённую группу. Возвращает вошедшие.
func (s *Service) AutoJoin(ctx context.Context, groupID string, items []AutoItem) ([]AutoItem, error) {
	var used []AutoItem
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		status, err := lockGroup(ctx, tx, groupID)
		if err != nil {
			return err
		}
		if status != StatusConfirmed {
			return errSkip
		}
		add, err := freeItems(ctx, tx, groupID, items)
		if err != nil {
			return err
		}
		if len(add) == 0 {
			return errSkip
		}
		if err := insertItems(ctx, tx, groupID, add); err != nil {
			return err
		}
		if err := validate(ctx, tx, groupID); err != nil {
			return errSkip
		}
		used = add
		return apply(ctx, tx, groupID, true)
	})
	if errors.Is(err, errSkip) {
		return nil, nil
	}
	return used, err
}

// AutoUndo — откат: товары productIDs выходят из группы; если группу собрала
// автонормализация (create) — группа удаляется целиком.
func (s *Service) AutoUndo(ctx context.Context, groupID string, productIDs []string, wholeGroup bool) error {
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var status string
		err := tx.QueryRow(ctx, `SELECT status FROM variant_groups WHERE id = $1 AND network_id IS NULL FOR UPDATE`, groupID).Scan(&status)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil // группу уже расформировали
		}
		if err != nil {
			return err
		}
		if wholeGroup {
			if _, err := tx.Exec(ctx, `
				UPDATE products SET variant_group_id = NULL, variant_weight = '', variant_weight_uz = '', variant_weight_sort = 0,
				       variant_flavor = '', variant_flavor_uz = '', variant_sort = 0
				WHERE variant_group_id = $1`, groupID); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `DELETE FROM variant_groups WHERE id = $1 AND source = 'auto'`, groupID)
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM variant_group_items WHERE group_id = $1 AND product_id = ANY ($2::uuid[])`, groupID, productIDs); err != nil {
			return err
		}
		return apply(ctx, tx, groupID, true)
	})
}
