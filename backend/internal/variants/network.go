package variants

import (
	"context"
	"errors"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/ai"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/variants/naming"
)

// Вариации своих товаров магазина (Figma «Панель магазина · Вариации своих
// товаров», В1–В2): вкладка «Вариации» в «Товарах» и в «Начале работы».
// Магазин собирает и подтверждает группы своих товаров сам — они касаются
// только его сети. Свой товар может войти в подтверждённую группу общего
// каталога (группа сети с base_group_id): название, переключатели и
// вес/вкус товаров общего каталога магазин не меняет. Товары общего
// каталога между собой группирует только супер-админ.

func errOnlyBase() error {
	return apperr.Validation("название и переключатели группы общего каталога меняет супер-админ").
		Uz("umumiy katalog guruhining nomi va almashtirgichlarini super-admin oʻzgartiradi")
}

// NetList — группы своих товаров сети: вкладка и поиск.
func (s *Service) NetList(ctx context.Context, pr *identity.Principal, f ListFilter) (GroupList, error) {
	out := GroupList{Items: []Group{}, Counts: map[string]int{StatusProposed: 0, StatusConfirmed: 0, StatusRejected: 0}}
	if f.Status == "" {
		f.Status = StatusProposed
	}
	if _, ok := out.Counts[f.Status]; !ok {
		return out, apperr.Validation("status: proposed, confirmed или rejected").Uz("status: proposed, confirmed yoki rejected")
	}
	q := strings.TrimSpace(f.Query)
	rows, err := s.pool.Query(ctx, `SELECT g.status, count(*)::int FROM variant_groups g
		WHERE g.network_id = $2 AND `+groupMatch(1)+` GROUP BY g.status`, q, pr.NetworkID)
	if err != nil {
		return out, err
	}
	var st string
	var n int
	if _, err := pgx.ForEachRow(rows, []any{&st, &n}, func() error {
		out.Counts[st] = n
		return nil
	}); err != nil {
		return out, err
	}
	out.Total = out.Counts[f.Status]
	order := `g.created_at DESC, g.name`
	if f.Status != StatusProposed {
		order = `g.decided_at DESC NULLS LAST, g.name`
	}
	rows, err = s.pool.Query(ctx, groupSelect+` WHERE g.network_id = $5 AND g.status = $1 AND `+groupMatch(2)+
		` ORDER BY `+order+` LIMIT $3 OFFSET $4`, f.Status, q, f.Page.Limit, f.Page.Offset, pr.NetworkID)
	if err != nil {
		return out, err
	}
	if out.Items, err = pgx.CollectRows(rows, scanGroup); err != nil {
		return out, err
	}
	if err := s.loadItems(ctx, s.pool, out.Items); err != nil {
		return out, err
	}
	err = s.loadBase(ctx, s.pool, out.Items, pr.NetworkID)
	return out, err
}

// loadBase — у группы, свои товары которой входят в группу общего каталога,
// сверху — товары той группы (общий каталог и уже вошедшие свои товары сети)
// для сверки: их магазин не меняет.
func (s *Service) loadBase(ctx context.Context, q db.Querier, groups []Group, networkID string) error {
	for i := range groups {
		g := &groups[i]
		if g.BaseGroupID == nil {
			continue
		}
		rows, err := q.Query(ctx, `
			SELECT p.id, loc(p.name, p.name_uz), p.images[1],
			       COALESCE((SELECT min(b.barcode) FROM product_barcodes b WHERE b.product_id = p.id), ''),
			       p.variant_weight, p.variant_weight_uz, p.variant_flavor, p.variant_flavor_uz, p.network_id IS NOT NULL
			FROM products p
			WHERE p.variant_group_id = $1 AND p.is_active AND (p.network_id IS NULL OR p.network_id = $2)
			  AND NOT EXISTS (SELECT 1 FROM variant_group_items i WHERE i.group_id = $3 AND i.product_id = p.id)
			ORDER BY p.variant_weight_sort, p.variant_weight, p.variant_sort, p.name`, *g.BaseGroupID, networkID, g.ID)
		if err != nil {
			return err
		}
		base, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Item, error) {
			it := Item{Included: true, Locked: true}
			err := r.Scan(&it.ProductID, &it.Name, &it.Image, &it.Barcode, &it.Weight, &it.WeightUz, &it.Flavor, &it.FlavorUz, &it.Own)
			return it, err
		})
		if err != nil {
			return err
		}
		g.Items = append(base, g.Items...)
	}
	return nil
}

func (s *Service) netGet(ctx context.Context, q db.Querier, networkID, id string) (Group, error) {
	g, err := s.get(ctx, q, id)
	if err != nil {
		return g, err
	}
	if g.NetworkID == nil || *g.NetworkID != networkID {
		return Group{}, errNoGroup()
	}
	gs := []Group{g}
	err = s.loadBase(ctx, q, gs, networkID)
	return gs[0], err
}

// NetGet — одна группа своих товаров сети.
func (s *Service) NetGet(ctx context.Context, pr *identity.Principal, id string) (Group, error) {
	return s.netGet(ctx, s.pool, pr.NetworkID, id)
}

// lockNet — блокирует группу сети: статус и группа общего каталога.
func lockNet(ctx context.Context, tx pgx.Tx, id, networkID string) (string, *string, error) {
	var status string
	var base *string
	err := tx.QueryRow(ctx, `SELECT status, base_group_id FROM variant_groups WHERE id = $1 AND network_id = $2 FOR UPDATE`,
		id, networkID).Scan(&status, &base)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil, errNoGroup()
	}
	return status, base, err
}

// netTx — правка группы сети в транзакции; у подтверждённой группы
// изменения сразу уходят в товары.
func (s *Service) netTx(ctx context.Context, pr *identity.Principal, id string, fn func(tx pgx.Tx, status string, base *string) error) (Group, error) {
	if err := pr.Require(identity.PermCatalogManage); err != nil {
		return Group{}, err
	}
	var out Group
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		status, base, err := lockNet(ctx, tx, id, pr.NetworkID)
		if err != nil {
			return err
		}
		if err := fn(tx, status, base); err != nil {
			return err
		}
		out, err = s.netGet(ctx, tx, pr.NetworkID, id)
		return err
	})
	return out, err
}

// NetUpdate — название, переключатели и вес/вкус своих товаров.
func (s *Service) NetUpdate(ctx context.Context, pr *identity.Principal, id string, in UpdateInput) (Group, error) {
	return s.netTx(ctx, pr, id, func(tx pgx.Tx, status string, base *string) error {
		if base != nil && (in.Name != nil || in.NameUz != nil || in.WeightLabel != nil || in.WeightLabelUz != nil ||
			in.FlavorLabel != nil || in.FlavorLabelUz != nil) {
			return errOnlyBase()
		}
		if err := edit(ctx, tx, id, in); err != nil {
			return err
		}
		if status != StatusConfirmed {
			return nil
		}
		if err := validateNet(ctx, tx, id, base, pr.NetworkID); err != nil {
			return err
		}
		return applyNet(ctx, tx, id, base, pr.NetworkID)
	})
}

// NetAddItem — «Добавить свой товар в группу».
func (s *Service) NetAddItem(ctx context.Context, pr *identity.Principal, id, productID string) (Group, error) {
	return s.netTx(ctx, pr, id, func(tx pgx.Tx, status string, base *string) error {
		var name string
		if err := tx.QueryRow(ctx, `SELECT name FROM variant_groups WHERE id = COALESCE($2::uuid, $1::uuid)`, id, base).Scan(&name); err != nil {
			return err
		}
		net := pr.NetworkID
		if err := addItem(ctx, tx, id, name, productID, &net); err != nil {
			return err
		}
		if status != StatusConfirmed {
			return nil
		}
		if err := validateNet(ctx, tx, id, base, pr.NetworkID); err != nil {
			return err
		}
		return applyNet(ctx, tx, id, base, pr.NetworkID)
	})
}

// NetSplit — «Разбить группу» (только своя группа, не вход в группу общего каталога).
func (s *Service) NetSplit(ctx context.Context, pr *identity.Principal, id string, in SplitInput) (SplitResult, error) {
	var out SplitResult
	_, err := s.netTx(ctx, pr, id, func(tx pgx.Tx, status string, base *string) error {
		if base != nil {
			return apperr.Validation("группу общего каталога не разбить — снимите галочку у лишних товаров").
				Uz("umumiy katalog guruhini boʻlib boʻlmaydi — ortiqcha mahsulotlardan belgini olib tashlang")
		}
		var err error
		out, err = s.split(ctx, tx, id, status, in)
		return err
	})
	return out, err
}

// NetConfirm — магазин подтвердил группу своих товаров.
func (s *Service) NetConfirm(ctx context.Context, pr *identity.Principal, id string) (Group, error) {
	return s.netTx(ctx, pr, id, func(tx pgx.Tx, _ string, base *string) error {
		if err := validateNet(ctx, tx, id, base, pr.NetworkID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE variant_groups SET status = 'confirmed', decided_at = now() WHERE id = $1`, id); err != nil {
			return err
		}
		return applyNet(ctx, tx, id, base, pr.NetworkID)
	})
}

// NetReject — отклонить предложение или расформировать группу: свои товары
// снова живут отдельно, Super Market их больше не предлагает.
func (s *Service) NetReject(ctx context.Context, pr *identity.Principal, id string) (Group, error) {
	return s.netTx(ctx, pr, id, func(tx pgx.Tx, _ string, base *string) error {
		if _, err := tx.Exec(ctx, `UPDATE variant_groups SET status = 'rejected', decided_at = now() WHERE id = $1`, id); err != nil {
			return err
		}
		return unsetNet(ctx, tx, id, base, pr.NetworkID, false)
	})
}

// unsetNet — свои товары группы сети больше не в группе (onlyExcluded —
// только снятые галочкой).
func unsetNet(ctx context.Context, tx pgx.Tx, id string, base *string, networkID string, onlyExcluded bool) error {
	target := id
	if base != nil {
		target = *base
	}
	_, err := tx.Exec(ctx, `
		UPDATE products SET variant_group_id = NULL, variant_weight = '', variant_weight_uz = '', variant_weight_sort = 0,
		       variant_flavor = '', variant_flavor_uz = '', variant_sort = 0
		WHERE variant_group_id = $2 AND network_id = $3
		  AND id IN (SELECT product_id FROM variant_group_items WHERE group_id = $1 AND (NOT $4 OR NOT included))`,
		id, target, networkID, onlyExcluded)
	return err
}

// validateNet — группу сети можно подтвердить. Своя группа — как у
// супер-админа; вход в группу общего каталога — хотя бы один свой товар, и
// значения переключателей не повторяют товары той группы.
func validateNet(ctx context.Context, tx pgx.Tx, id string, base *string, networkID string) error {
	if base == nil {
		return validate(ctx, tx, id)
	}
	var baseStatus string
	if err := tx.QueryRow(ctx, `SELECT status FROM variant_groups WHERE id = $1`, *base).Scan(&baseStatus); err != nil {
		return err
	}
	if baseStatus != StatusConfirmed {
		return apperr.Conflict("base_not_confirmed", "группа общего каталога больше не подтверждена").
			Uz("umumiy katalog guruhi endi tasdiqlanmagan")
	}
	type row struct{ name, weight, flavor string }
	scan := func(sql string, args ...any) ([]row, []string, error) {
		rows, err := tx.Query(ctx, sql, args...)
		if err != nil {
			return nil, nil, err
		}
		defer rows.Close()
		var out []row
		var busy []string
		for rows.Next() {
			var r row
			var other *string
			if err := rows.Scan(&r.name, &r.weight, &r.flavor, &other); err != nil {
				return nil, nil, err
			}
			out = append(out, r)
			if other != nil {
				busy = append(busy, r.name+" — «"+*other+"»")
			}
		}
		return out, busy, rows.Err()
	}
	own, busy, err := scan(`
		SELECT p.name, CASE WHEN bg.weight_label = '' THEN '' ELSE i.weight END,
		       CASE WHEN bg.flavor_label = '' THEN '' ELSE i.flavor END,
		       (SELECT og.name FROM variant_groups og WHERE og.id = p.variant_group_id AND og.id <> bg.id)
		FROM variant_group_items i JOIN products p ON p.id = i.product_id JOIN variant_groups bg ON bg.id = $2
		WHERE i.group_id = $1 AND i.included`, id, *base)
	if err != nil {
		return err
	}
	if len(own) == 0 {
		return apperr.Validation("отметьте хотя бы один свой товар").Uz("kamida bitta oʻz mahsulotingizni belgilang")
	}
	if len(busy) > 0 {
		return apperr.Conflict("in_other_group", "товары уже в другой группе: "+strings.Join(busy, "; ")).
			Uz("mahsulotlar boshqa guruhda: " + strings.Join(busy, "; ")).
			WithDetails(map[string]any{"products": busy})
	}
	others, _, err := scan(`
		SELECT p.name, CASE WHEN bg.weight_label = '' THEN '' ELSE p.variant_weight END,
		       CASE WHEN bg.flavor_label = '' THEN '' ELSE p.variant_flavor END, NULL::text
		FROM products p JOIN variant_groups bg ON bg.id = p.variant_group_id
		WHERE p.variant_group_id = $2 AND p.is_active AND (p.network_id IS NULL OR p.network_id = $3)
		  AND NOT EXISTS (SELECT 1 FROM variant_group_items i WHERE i.group_id = $1 AND i.product_id = p.id)`, id, *base, networkID)
	if err != nil {
		return err
	}
	seen := map[string]string{}
	for _, r := range append(others, own...) {
		k := naming.Fold(r.weight) + "|" + naming.Fold(r.flavor)
		if prev, ok := seen[k]; ok {
			return apperr.Validation("у товаров «" + prev + "» и «" + r.name + "» одинаковые значения переключателей — поправьте или снимите свой").
				Uz("«" + prev + "» va «" + r.name + "» mahsulotlarining variant qiymatlari bir xil — tuzating yoki oʻzingiznikini olib tashlang")
		}
		seen[k] = r.name
	}
	return nil
}

// applyNet — состав подтверждённой группы сети в свои товары. Вход в группу
// общего каталога пишет в товары её id; свои товары идут после товаров
// общего каталога того же веса.
func applyNet(ctx context.Context, tx pgx.Tx, id string, base *string, networkID string) error {
	if base == nil {
		return apply(ctx, tx, id, false)
	}
	if err := unsetNet(ctx, tx, id, base, networkID, true); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `
		WITH v AS (
			SELECT i.product_id, i.sort,
			       CASE WHEN bg.weight_label = '' THEN '' ELSE i.weight END AS weight,
			       CASE WHEN bg.weight_label = '' THEN '' ELSE i.weight_uz END AS weight_uz,
			       CASE WHEN bg.weight_label = '' THEN 0 ELSE i.weight_sort END AS weight_sort,
			       CASE WHEN bg.flavor_label = '' THEN '' ELSE i.flavor END AS flavor,
			       CASE WHEN bg.flavor_label = '' THEN '' ELSE i.flavor_uz END AS flavor_uz
			FROM variant_group_items i JOIN variant_groups bg ON bg.id = $2
			WHERE i.group_id = $1 AND i.included
		)
		UPDATE products p SET variant_group_id = $2, variant_weight = v.weight, variant_weight_uz = v.weight_uz,
		       variant_weight_sort = v.weight_sort, variant_flavor = v.flavor, variant_flavor_uz = v.flavor_uz,
		       variant_sort = 1000 + v.sort
		FROM v
		WHERE p.id = v.product_id AND p.network_id = $3
		  AND (p.variant_group_id IS DISTINCT FROM $2 OR p.variant_weight <> v.weight OR p.variant_weight_uz <> v.weight_uz
		       OR p.variant_flavor <> v.flavor OR p.variant_flavor_uz <> v.flavor_uz OR p.variant_sort <> 1000 + v.sort
		       OR p.variant_weight_sort <> v.weight_sort)`, id, *base, networkID)
	return err
}

// ---------------------------------------------------------- «Найти новые группы»

// SuggestNetwork — группы среди своих товаров сети, которые ещё не в группе и
// не были в отклонённом предложении. Пачка «бренд + подкатегория» идёт к ИИ
// (без него — разбор названий) вместе с товарами подтверждённых групп общего
// каталога той же марки и категории: свой товар может войти в такую группу.
func (s *Service) SuggestNetwork(ctx context.Context, networkID string) (SuggestResult, error) {
	var out SuggestResult
	rows, err := s.pool.Query(ctx, `
		SELECT p.brand_id, b.name, p.category_id, c.name,
		       array_agg(p.id::text ORDER BY p.name), array_agg(p.name ORDER BY p.name)
		FROM products p
		JOIN brands b ON b.id = p.brand_id
		JOIN categories c ON c.id = p.category_id
		WHERE p.network_id = $1 AND p.is_active AND p.variant_group_id IS NULL
		  AND NOT EXISTS (
			SELECT 1 FROM variant_group_items i JOIN variant_groups g ON g.id = i.group_id
			WHERE i.product_id = p.id AND g.status IN ('proposed', 'rejected'))
		GROUP BY p.brand_id, b.name, p.category_id, c.name
		ORDER BY count(*) DESC, b.name
		LIMIT $2`, networkID, maxBuckets+1)
	if err != nil {
		return out, err
	}
	buckets, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (bucket, error) {
		b := bucket{network: &networkID, base: map[string]string{}}
		err := r.Scan(&b.brandID, &b.brand, &b.categoryID, &b.catNm, &b.ids, &b.names)
		return b, err
	})
	if err != nil {
		return out, err
	}
	if len(buckets) > maxBuckets {
		buckets, out.More = buckets[:maxBuckets], true
	}
	conn, err := s.ai.Conn(ctx)
	useAI := err == nil
	if err != nil && !errors.Is(err, ai.ErrNotConfigured) {
		return out, err
	}
	out.AI = useAI
	start := time.Now()
	for _, b := range buckets {
		if useAI && time.Since(start) > SuggestBudget {
			out.More = true
			break
		}
		if len(b.ids) > maxBucketProduct {
			b.ids, b.names = b.ids[:maxBucketProduct], b.names[:maxBucketProduct]
			out.More = true
		}
		own := map[string]bool{}
		for _, id := range b.ids {
			own[id] = true
		}
		// Товары подтверждённых групп общего каталога той же марки и категории.
		rows, err := s.pool.Query(ctx, `
			SELECT p.id::text, p.name, p.variant_group_id::text
			FROM products p JOIN variant_groups g ON g.id = p.variant_group_id
			WHERE g.status = 'confirmed' AND g.network_id IS NULL AND p.network_id IS NULL AND p.is_active
			  AND p.brand_id = $1 AND p.category_id = $2
			ORDER BY p.name LIMIT $3`, b.brandID, b.categoryID, maxBucketProduct-len(b.ids))
		if err != nil {
			return out, err
		}
		var pid, pname, gid string
		if _, err := pgx.ForEachRow(rows, []any{&pid, &pname, &gid}, func() error {
			b.ids, b.names = append(b.ids, pid), append(b.names, pname)
			b.base[pid] = gid
			return nil
		}); err != nil {
			return out, err
		}
		if len(own) < 2 && len(b.base) == 0 {
			continue
		}
		var groups []proposal
		if useAI {
			groups, err = s.askAI(ctx, conn, b)
			if err != nil {
				s.log.Warn("variants: ИИ не разобрал пачку сети", "network", networkID, "brand", b.brand, "err", err)
				out.Failed++
				continue
			}
		} else {
			groups = byNames(b)
		}
		out.Checked++
		n, err := s.saveNetProposals(ctx, networkID, b, groups)
		if err != nil {
			return out, err
		}
		out.Created += n
	}
	return out, nil
}

// saveNetProposals — предложения сети по одной пачке: в предложение идут
// только свои товары. Товары общего каталога в ответе означают «войти в их
// группу» (если они из одной группы — иначе берётся группа, где их больше).
func (s *Service) saveNetProposals(ctx context.Context, networkID string, b bucket, groups []proposal) (int, error) {
	n := 0
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		for _, g := range groups {
			var own []naming.Parsed
			votes := map[string]int{}
			for _, it := range g.items {
				if gid, ok := b.base[it.ID]; ok {
					votes[gid]++
				} else {
					own = append(own, it)
				}
			}
			if len(own) == 0 {
				continue
			}
			var base *string
			for gid, v := range votes {
				if base == nil || v > votes[*base] {
					id := gid
					base = &id
				}
			}
			ids := make([]string, len(own))
			for i, it := range own {
				ids[i] = it.ID
			}
			// Товар мог попасть в группу, пока шёл запрос к ИИ.
			var busy int
			if err := tx.QueryRow(ctx, `
				SELECT count(*)::int FROM products p
				WHERE p.id = ANY ($1::uuid[]) AND (p.variant_group_id IS NOT NULL OR EXISTS (
					SELECT 1 FROM variant_group_items i JOIN variant_groups vg ON vg.id = i.group_id
					WHERE i.product_id = p.id AND vg.status IN ('proposed', 'rejected')))`, ids).Scan(&busy); err != nil {
				return err
			}
			if busy > 0 {
				continue
			}
			name, nameUz, note, conf := g.name, g.nameUz, g.note, g.confidence
			var wl, wlUz, fl, flUz string
			if base != nil {
				// Значения своих товаров не должны повторять товары группы общего каталога.
				taken := map[string]string{}
				var pn, w, f string
				rows, err := tx.Query(ctx, `
					SELECT p.name, CASE WHEN g.weight_label = '' THEN '' ELSE p.variant_weight END,
					       CASE WHEN g.flavor_label = '' THEN '' ELSE p.variant_flavor END
					FROM products p JOIN variant_groups g ON g.id = p.variant_group_id
					WHERE p.variant_group_id = $1 AND p.is_active AND (p.network_id IS NULL OR p.network_id = $2)`, *base, networkID)
				if err != nil {
					return err
				}
				if _, err := pgx.ForEachRow(rows, []any{&pn, &w, &f}, func() error {
					taken[naming.Fold(w)+"|"+naming.Fold(f)] = pn
					return nil
				}); err != nil {
					return err
				}
				if err := tx.QueryRow(ctx, `SELECT name, name_uz, weight_label, weight_label_uz, flavor_label, flavor_label_uz
					FROM variant_groups WHERE id = $1`, *base).Scan(&name, &nameUz, &wl, &wlUz, &fl, &flUz); err != nil {
					return err
				}
				included := 0
				for i := range own {
					w, f := own[i].Weight, own[i].Flavor
					if wl == "" {
						w = ""
					}
					if fl == "" {
						f = ""
					}
					if prev, ok := taken[naming.Fold(w)+"|"+naming.Fold(f)]; ok && own[i].Included {
						own[i].Included, own[i].Note = false, "Похоже на дубль товара «"+prev+"»"
					}
					if own[i].Included {
						included++
					}
				}
				if included == 0 {
					continue
				}
			} else {
				var weights, flavors []string
				distinct := map[string]bool{}
				for _, it := range own {
					if it.Included {
						weights, flavors = append(weights, it.Weight), append(flavors, it.Flavor)
						distinct[naming.Fold(it.Weight)+"|"+naming.Fold(it.Flavor)] = true
					}
				}
				if len(distinct) < 2 {
					continue
				}
				wl, wlUz, fl, flUz = naming.Labels(weights, flavors)
				// Один и тот же вес у всех товаров — переключателя веса нет
				// (у кружек одного объёма выбирают только цвет).
				same := map[string]bool{}
				for _, w := range weights {
					same[naming.Fold(w)] = true
				}
				if len(same) == 1 && fl != "" {
					wl, wlUz = "", ""
				}
				if g.weightLabel != "" && wl != "" {
					wl, wlUz = g.weightLabel, g.weightLabelUz
				}
				if g.flavorLabel != "" && fl != "" {
					fl, flUz = g.flavorLabel, g.flavorLabelUz
				}
			}
			var id string
			if err := tx.QueryRow(ctx, `
				INSERT INTO variant_groups (name, name_uz, brand_id, category_id, source, confidence, note,
				                            weight_label, weight_label_uz, flavor_label, flavor_label_uz, network_id, base_group_id)
				VALUES ($1, $2, $3, $4, 'ai', $5, $6, $7, $8, $9, $10, $11, $12) RETURNING id`,
				name, nameUz, b.brandID, b.categoryID, conf, note, wl, wlUz, fl, flUz, networkID, base).Scan(&id); err != nil {
				return err
			}
			for i, it := range own {
				if _, err := tx.Exec(ctx, `
					INSERT INTO variant_group_items (group_id, product_id, weight, weight_uz, weight_sort, flavor, flavor_uz, included, note, sort)
					VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
					id, it.ID, clip(it.Weight, maxWeight), clip(it.WeightUz, maxWeight), it.WeightSort,
					clip(it.Flavor, maxFlavor), clip(g.flavorUz[it.ID], maxFlavor), it.Included, it.Note, i+1); err != nil {
					return err
				}
			}
			n++
		}
		return nil
	})
	return n, err
}

// ---------------------------------------------------------- фон

// netJobs — фоновый разбор «Найти новые группы» по сетям.
type netJobs struct {
	mu sync.Mutex
	m  map[string]*SuggestStatus
}

// StartNetSuggest запускает разбор своих товаров сети, если он ещё не идёт.
func (s *Service) StartNetSuggest(ctx context.Context, networkID string) SuggestStatus {
	if SuggestSync {
		now := time.Now()
		res, err := s.SuggestNetwork(ctx, networkID)
		st := SuggestStatus{SuggestResult: res, StartedAt: &now, FinishedAt: &now}
		if err != nil {
			st.Error = err.Error()
		}
		return st
	}
	s.net.mu.Lock()
	defer s.net.mu.Unlock()
	if s.net.m == nil {
		s.net.m = map[string]*SuggestStatus{}
	}
	if st := s.net.m[networkID]; st != nil && st.Running {
		return *st
	}
	now := time.Now()
	st := &SuggestStatus{Running: true, StartedAt: &now}
	s.net.m[networkID] = st
	lang := i18n.FromContext(ctx)
	go func() {
		fail := i18n.Pick(lang, "не удалось найти группы — попробуйте ещё раз", "guruhlarni topib boʻlmadi — qayta urinib koʻring")
		var res SuggestResult
		var err error
		func() {
			defer func() {
				if p := recover(); p != nil {
					s.log.Error("variants: паника в разборе сети", "network", networkID, "panic", p)
					err = errors.New("panic")
				}
			}()
			res, err = s.SuggestNetwork(i18n.WithLang(context.Background(), lang), networkID)
		}()
		done := time.Now()
		s.net.mu.Lock()
		defer s.net.mu.Unlock()
		st.Running, st.SuggestResult, st.FinishedAt = false, res, &done
		if err != nil {
			s.log.Error("variants: разбор сети не удался", "network", networkID, "err", err)
			st.Error = fail
			if e, ok := apperr.As(err); ok {
				st.Error = e.Text(lang)
			}
		}
	}()
	return *st
}

// NetSuggestState — состояние последнего разбора сети.
func (s *Service) NetSuggestState(networkID string) SuggestStatus {
	s.net.mu.Lock()
	defer s.net.mu.Unlock()
	if st := s.net.m[networkID]; st != nil {
		return *st
	}
	return SuggestStatus{}
}

// StartDaily — раз в день Super Market сам ищет группы среди новых своих
// товаров сетей (у которых есть товары вне групп и предложений).
func (s *Service) StartDaily() {
	go func() {
		time.Sleep(2 * time.Minute)
		for {
			ctx := context.Background()
			rows, err := s.pool.Query(ctx, `
				SELECT DISTINCT p.network_id::text FROM products p
				WHERE p.network_id IS NOT NULL AND p.is_active AND p.variant_group_id IS NULL AND p.brand_id IS NOT NULL
				  AND NOT EXISTS (
					SELECT 1 FROM variant_group_items i JOIN variant_groups g ON g.id = i.group_id
					WHERE i.product_id = p.id AND g.status IN ('proposed', 'rejected'))`)
			var nets []string
			if err == nil {
				nets, err = pgx.CollectRows(rows, pgx.RowTo[string])
			}
			if err != nil {
				s.log.Error("variants: ежедневный разбор сетей", "err", err)
			}
			for _, n := range nets {
				if _, err := s.SuggestNetwork(ctx, n); err != nil {
					s.log.Error("variants: ежедневный разбор сети", "network", n, "err", err)
				}
			}
			time.Sleep(24 * time.Hour)
		}
	}()
}
