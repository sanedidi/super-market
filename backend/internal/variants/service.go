// Package variants — вариации товара: группа (бренд + линейка, «Чипсы
// Lay's») → вес → вкус. Каждая вариация — обычный товар со своим
// штрихкодом, фото, ИКПУ и остатком; группа связывает их для карточки в
// приложении, быстрых кнопок кассы и цены «на вес» в панели магазина.
//
// Группы предлагает Super Market (ИИ, без него — разбор названий) по уже
// добавленным товарам общего каталога; супер-админ правит вес и вкус,
// снимает лишние товары и подтверждает. Пока группа не подтверждена,
// состав живёт в variant_group_items; подтверждение пишет группу, вес и
// вкус в сами товары.
package variants

import (
	"context"
	"errors"
	"log/slog"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/ai"
	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/variants/naming"
)

type Service struct {
	pool *pgxpool.Pool
	cat  *catalog.Service
	ai   *ai.Service
	log  *slog.Logger
	// Фоновый разбор «Найти новые группы».
	job suggestJob
}

func NewService(pool *pgxpool.Pool, cat *catalog.Service, aiSvc *ai.Service, log *slog.Logger) *Service {
	return &Service{pool: pool, cat: cat, ai: aiSvc, log: log}
}

const (
	StatusProposed  = "proposed"
	StatusConfirmed = "confirmed"
	StatusRejected  = "rejected"
)

// Item — товар группы.
type Item struct {
	ProductID string  `json:"product_id"`
	Name      string  `json:"name"`
	Image     *string `json:"image"`
	Barcode   string  `json:"barcode"`
	Weight    string  `json:"weight"`
	WeightUz  string  `json:"weight_uz"`
	Flavor    string  `json:"flavor"`
	FlavorUz  string  `json:"flavor_uz"`
	Included  bool    `json:"included"`
	Note      string  `json:"note"`
	// OtherGroup — товар уже в другой подтверждённой группе (её название).
	OtherGroup *string `json:"other_group"`
}

// Group — группа вариаций для супер-админа.
type Group struct {
	ID           string     `json:"id"`
	Name         string     `json:"name"`
	NameUz       string     `json:"name_uz"`
	BrandID      *string    `json:"brand_id"`
	BrandName    *string    `json:"brand_name"`
	CategoryID   *string    `json:"category_id"`
	CategoryName *string    `json:"category_name"`
	Status       string     `json:"status"`
	Source       string     `json:"source"`
	Confidence   string     `json:"confidence"`
	Note         string     `json:"note"`
	DecidedAt    *time.Time `json:"decided_at"`
	CreatedAt    time.Time  `json:"created_at"`
	// Сколько магазинов продают хотя бы один товар группы.
	StoresCount int    `json:"stores_count"`
	Items       []Item `json:"items"`
}

// GroupList — страница групп и счётчики по вкладкам.
type GroupList struct {
	Items  []Group        `json:"items"`
	Total  int            `json:"total"`
	Counts map[string]int `json:"counts"`
}

const groupSelect = `
	SELECT g.id, g.name, g.name_uz, g.brand_id, b.name, g.category_id, loc(c.name, c.name_uz),
	       g.status, g.source, g.confidence, g.note, g.decided_at, g.created_at,
	       (SELECT count(DISTINCT sp.store_id)::int FROM store_products sp
	        JOIN variant_group_items i ON i.product_id = sp.product_id AND i.included
	        WHERE i.group_id = g.id)
	FROM variant_groups g
	LEFT JOIN brands b ON b.id = g.brand_id
	LEFT JOIN categories c ON c.id = g.category_id`

func scanGroup(row pgx.CollectableRow) (Group, error) {
	var g Group
	err := row.Scan(&g.ID, &g.Name, &g.NameUz, &g.BrandID, &g.BrandName, &g.CategoryID, &g.CategoryName,
		&g.Status, &g.Source, &g.Confidence, &g.Note, &g.DecidedAt, &g.CreatedAt, &g.StoresCount)
	g.Items = []Item{}
	return g, err
}

// ListFilter — вкладка и поиск.
type ListFilter struct {
	Status string
	Query  string
	Page   httpx.Page
}

// List — группы для супер-админа: вкладка, поиск по названию группы или товара.
func (s *Service) List(ctx context.Context, f ListFilter) (GroupList, error) {
	out := GroupList{Items: []Group{}, Counts: map[string]int{StatusProposed: 0, StatusConfirmed: 0, StatusRejected: 0}}
	if f.Status == "" {
		f.Status = StatusProposed
	}
	if _, ok := out.Counts[f.Status]; !ok {
		return out, apperr.Validation("status: proposed, confirmed или rejected").Uz("status: proposed, confirmed yoki rejected")
	}
	q := strings.TrimSpace(f.Query)
	rows, err := s.pool.Query(ctx, `SELECT g.status, count(*)::int FROM variant_groups g WHERE `+groupMatch(1)+` GROUP BY g.status`, q)
	if err != nil {
		return out, err
	}
	for rows.Next() {
		var st string
		var n int
		if err := rows.Scan(&st, &n); err != nil {
			rows.Close()
			return out, err
		}
		out.Counts[st] = n
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return out, err
	}
	out.Total = out.Counts[f.Status]

	order := `g.created_at DESC, g.name`
	if f.Status != StatusProposed {
		order = `g.decided_at DESC NULLS LAST, g.name`
	}
	rows, err = s.pool.Query(ctx, groupSelect+` WHERE g.status = $1 AND `+groupMatch(2)+` ORDER BY `+order+` LIMIT $3 OFFSET $4`,
		f.Status, q, f.Page.Limit, f.Page.Offset)
	if err != nil {
		return out, err
	}
	if out.Items, err = pgx.CollectRows(rows, scanGroup); err != nil {
		return out, err
	}
	err = s.loadItems(ctx, s.pool, out.Items)
	return out, err
}

// groupMatch — поиск по названию группы или её товара; $n — строка поиска.
func groupMatch(n int) string {
	p := "$" + strconv.Itoa(n)
	return `(` + p + ` = '' OR g.name ILIKE '%' || ` + p + ` || '%' OR g.name_uz ILIKE '%' || ` + p + ` || '%' OR EXISTS (
		SELECT 1 FROM variant_group_items i JOIN products p ON p.id = i.product_id
		WHERE i.group_id = g.id AND (p.name ILIKE '%' || ` + p + ` || '%' OR p.name_uz ILIKE '%' || ` + p + ` || '%')))`
}

// Get — одна группа.
func (s *Service) Get(ctx context.Context, id string) (Group, error) {
	return s.get(ctx, s.pool, id)
}

func (s *Service) get(ctx context.Context, q db.Querier, id string) (Group, error) {
	rows, err := q.Query(ctx, groupSelect+` WHERE g.id = $1`, id)
	if err != nil {
		return Group{}, err
	}
	g, err := pgx.CollectExactlyOneRow(rows, scanGroup)
	if errors.Is(err, pgx.ErrNoRows) {
		return g, apperr.NotFound("группа не найдена").Uz("guruh topilmadi")
	}
	if err != nil {
		return g, err
	}
	gs := []Group{g}
	err = s.loadItems(ctx, q, gs)
	return gs[0], err
}

func (s *Service) loadItems(ctx context.Context, q db.Querier, groups []Group) error {
	if len(groups) == 0 {
		return nil
	}
	ids := make([]string, len(groups))
	at := map[string]int{}
	for i, g := range groups {
		ids[i], at[g.ID] = g.ID, i
	}
	rows, err := q.Query(ctx, `
		SELECT i.group_id, i.product_id, loc(p.name, p.name_uz), p.images[1],
		       COALESCE((SELECT min(b.barcode) FROM product_barcodes b WHERE b.product_id = p.id), ''),
		       i.weight, i.weight_uz, i.flavor, i.flavor_uz, i.included, i.note,
		       (SELECT og.name FROM variant_groups og WHERE og.id = p.variant_group_id AND og.id <> i.group_id)
		FROM variant_group_items i JOIN products p ON p.id = i.product_id
		WHERE i.group_id = ANY ($1::uuid[])
		ORDER BY i.group_id, i.included DESC, i.weight_sort, i.sort, p.name`, ids)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var gid string
		var it Item
		if err := rows.Scan(&gid, &it.ProductID, &it.Name, &it.Image, &it.Barcode, &it.Weight, &it.WeightUz,
			&it.Flavor, &it.FlavorUz, &it.Included, &it.Note, &it.OtherGroup); err != nil {
			return err
		}
		g := &groups[at[gid]]
		g.Items = append(g.Items, it)
	}
	return rows.Err()
}

// ---------------------------------------------------------- правка

// ItemInput — правка товара группы; nil — не менять.
type ItemInput struct {
	ProductID string  `json:"product_id"`
	Weight    *string `json:"weight"`
	WeightUz  *string `json:"weight_uz"`
	Flavor    *string `json:"flavor"`
	FlavorUz  *string `json:"flavor_uz"`
	Included  *bool   `json:"included"`
}

// UpdateInput — PATCH группы.
type UpdateInput struct {
	Name   *string      `json:"name"`
	NameUz *string      `json:"name_uz"`
	Items  *[]ItemInput `json:"items"`
}

// Update — название и вес/вкус товаров. У подтверждённой группы изменения
// сразу уходят в товары (и на кассы).
func (s *Service) Update(ctx context.Context, id string, in UpdateInput) (Group, error) {
	var out Group
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		status, err := lockGroup(ctx, tx, id)
		if err != nil {
			return err
		}
		if in.Name != nil {
			name := strings.TrimSpace(*in.Name)
			if name == "" || len([]rune(name)) > 120 {
				return apperr.Validation("name: от 1 до 120 символов").Uz("name: 1 dan 120 belgigacha")
			}
			if _, err := tx.Exec(ctx, `UPDATE variant_groups SET name = $2 WHERE id = $1`, id, name); err != nil {
				return err
			}
		}
		if in.NameUz != nil {
			if _, err := tx.Exec(ctx, `UPDATE variant_groups SET name_uz = $2 WHERE id = $1`, id, strings.TrimSpace(*in.NameUz)); err != nil {
				return err
			}
		}
		if in.Items != nil {
			for _, it := range *in.Items {
				if err := updateItem(ctx, tx, id, it); err != nil {
					return err
				}
			}
		}
		if status == StatusConfirmed {
			if err := validate(ctx, tx, id); err != nil {
				return err
			}
			if err := apply(ctx, tx, id); err != nil {
				return err
			}
		}
		out, err = s.get(ctx, tx, id)
		return err
	})
	return out, err
}

func updateItem(ctx context.Context, tx pgx.Tx, groupID string, it ItemInput) error {
	if !httpx.IsUUID(it.ProductID) {
		return apperr.Validation("items: неверный product_id").Uz("items: product_id notoʻgʻri")
	}
	var weight, weightUz, flavor, flavorUz string
	var included bool
	err := tx.QueryRow(ctx, `SELECT weight, weight_uz, flavor, flavor_uz, included FROM variant_group_items
		WHERE group_id = $1 AND product_id = $2`, groupID, it.ProductID).Scan(&weight, &weightUz, &flavor, &flavorUz, &included)
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.Validation("items: товара нет в группе").Uz("items: mahsulot guruhda yoʻq")
	}
	if err != nil {
		return err
	}
	if it.Weight != nil {
		weight = strings.TrimSpace(*it.Weight)
		if it.WeightUz == nil {
			weightUz = naming.WeightUz(weight)
		}
	}
	if it.WeightUz != nil {
		weightUz = strings.TrimSpace(*it.WeightUz)
	}
	if it.Flavor != nil {
		flavor = strings.TrimSpace(*it.Flavor)
	}
	if it.FlavorUz != nil {
		flavorUz = strings.TrimSpace(*it.FlavorUz)
	}
	if it.Included != nil {
		included = *it.Included
	}
	if len([]rune(weight)) > maxWeight || len([]rune(weightUz)) > maxWeight {
		return apperr.Validation("weight: не длиннее 40 символов").Uz("weight: 40 belgidan oshmasin")
	}
	if len([]rune(flavor)) > maxFlavor || len([]rune(flavorUz)) > maxFlavor {
		return apperr.Validation("flavor: не длиннее 80 символов").Uz("flavor: 80 belgidan oshmasin")
	}
	note := ""
	_, err = tx.Exec(ctx, `
		UPDATE variant_group_items SET weight = $3, weight_uz = $4, weight_sort = $5, flavor = $6, flavor_uz = $7,
		       included = $8, note = CASE WHEN $8 = included THEN note ELSE $9 END
		WHERE group_id = $1 AND product_id = $2`,
		groupID, it.ProductID, weight, weightUz, naming.WeightSort(weight), flavor, flavorUz, included, note)
	return err
}

// lockGroup — блокирует группу и возвращает её статус.
func lockGroup(ctx context.Context, tx pgx.Tx, id string) (string, error) {
	var status string
	err := tx.QueryRow(ctx, `SELECT status FROM variant_groups WHERE id = $1 FOR UPDATE`, id).Scan(&status)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", apperr.NotFound("группа не найдена").Uz("guruh topilmadi")
	}
	return status, err
}

// ---------------------------------------------------------- создание руками

// CreateInput — группа, собранная супер-админом.
type CreateInput struct {
	Name       string   `json:"name"`
	NameUz     string   `json:"name_uz"`
	ProductIDs []string `json:"product_ids"`
}

func (s *Service) Create(ctx context.Context, in CreateInput) (Group, error) {
	name := strings.TrimSpace(in.Name)
	if name == "" || len([]rune(name)) > 120 {
		return Group{}, apperr.Validation("name: от 1 до 120 символов").Uz("name: 1 dan 120 belgigacha")
	}
	if len(in.ProductIDs) < 2 || len(in.ProductIDs) > 200 {
		return Group{}, apperr.Validation("product_ids: от 2 до 200 товаров").Uz("product_ids: 2 dan 200 tagacha mahsulot")
	}
	var out Group
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var id string
		if err := tx.QueryRow(ctx, `
			INSERT INTO variant_groups (name, name_uz, brand_id, category_id, source, confidence)
			SELECT $1, $2, p.brand_id, p.category_id, 'manual', 'high' FROM products p WHERE p.id = $3::uuid
			RETURNING id`, name, strings.TrimSpace(in.NameUz), firstUUID(in.ProductIDs)).Scan(&id); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return apperr.Validation("product_ids: товар не найден").Uz("product_ids: mahsulot topilmadi")
			}
			return err
		}
		seen := map[string]bool{}
		for _, pid := range in.ProductIDs {
			if seen[pid] {
				continue
			}
			seen[pid] = true
			if err := addItem(ctx, tx, id, name, pid); err != nil {
				return err
			}
		}
		var err error
		out, err = s.get(ctx, tx, id)
		return err
	})
	return out, err
}

func firstUUID(ids []string) string {
	for _, id := range ids {
		if httpx.IsUUID(id) {
			return id
		}
	}
	return "00000000-0000-0000-0000-000000000000"
}

// AddItem — добавить товар в группу; вес и вкус — из названия.
func (s *Service) AddItem(ctx context.Context, groupID, productID string) (Group, error) {
	var out Group
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		status, err := lockGroup(ctx, tx, groupID)
		if err != nil {
			return err
		}
		var name string
		if err := tx.QueryRow(ctx, `SELECT name FROM variant_groups WHERE id = $1`, groupID).Scan(&name); err != nil {
			return err
		}
		if err := addItem(ctx, tx, groupID, name, productID); err != nil {
			return err
		}
		if status == StatusConfirmed {
			if err := validate(ctx, tx, groupID); err != nil {
				return err
			}
			if err := apply(ctx, tx, groupID); err != nil {
				return err
			}
		}
		out, err = s.get(ctx, tx, groupID)
		return err
	})
	return out, err
}

// addItem — товар общего каталога в группу (повторно — ошибка).
func addItem(ctx context.Context, tx pgx.Tx, groupID, groupName, productID string) error {
	if !httpx.IsUUID(productID) {
		return apperr.Validation("product_id: товар не найден").Uz("product_id: mahsulot topilmadi")
	}
	var pname string
	err := tx.QueryRow(ctx, `SELECT name FROM products WHERE id = $1 AND network_id IS NULL`, productID).Scan(&pname)
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.Validation("product_id: товар не найден в общем каталоге").Uz("product_id: mahsulot umumiy katalogda topilmadi")
	}
	if err != nil {
		return err
	}
	_, w, wuz, ws := naming.Weight(pname)
	tag, err := tx.Exec(ctx, `
		INSERT INTO variant_group_items (group_id, product_id, weight, weight_uz, weight_sort, flavor, sort)
		VALUES ($1, $2, $3, $4, $5, $6, (SELECT COALESCE(max(sort), 0) + 1 FROM variant_group_items WHERE group_id = $1))
		ON CONFLICT DO NOTHING`, groupID, productID, clip(w, maxWeight), clip(wuz, maxWeight), ws,
		clip(naming.Flavor(pname, groupName), maxFlavor))
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.Conflict("already_in_group", "товар уже в этой группе").Uz("mahsulot allaqachon shu guruhda")
	}
	return nil
}

// Пределы подписей — как CHECK в variant_group_items.
const (
	maxWeight = 40
	maxFlavor = 80
)

// clip обрезает подпись, разобранную из названия или пришедшую от ИИ, до
// предела колонки, чтобы длинное название не роняло запрос ошибкой CHECK.
func clip(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return strings.TrimSpace(string(r[:n]))
}

// SplitInput — какие товары вынести в новую группу.
type SplitInput struct {
	ProductIDs []string `json:"product_ids"`
}

// SplitResult — исходная и новая группы.
type SplitResult struct {
	Group    Group `json:"group"`
	NewGroup Group `json:"new_group"`
}

// Split — «Разбить группу»: выбранные товары уходят в новое предложение
// с тем же названием (супер-админ переименует).
func (s *Service) Split(ctx context.Context, groupID string, in SplitInput) (SplitResult, error) {
	var out SplitResult
	if len(in.ProductIDs) == 0 {
		return out, apperr.Validation("product_ids: выберите товары").Uz("product_ids: mahsulotlarni tanlang")
	}
	for _, id := range in.ProductIDs {
		if !httpx.IsUUID(id) {
			return out, apperr.Validation("product_ids: неверный id").Uz("product_ids: id notoʻgʻri")
		}
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		status, err := lockGroup(ctx, tx, groupID)
		if err != nil {
			return err
		}
		if status != StatusProposed {
			return apperr.Conflict("not_proposed", "разбить можно только предложение — подтверждённую группу сначала расформируйте").
				Uz("faqat taklifni boʻlish mumkin — tasdiqlangan guruhni avval tarqating")
		}
		var total, moving int
		if err := tx.QueryRow(ctx, `SELECT count(*)::int, (count(*) FILTER (WHERE product_id = ANY ($2::uuid[])))::int
			FROM variant_group_items WHERE group_id = $1`, groupID, in.ProductIDs).Scan(&total, &moving); err != nil {
			return err
		}
		if moving != len(uniq(in.ProductIDs)) {
			return apperr.Validation("product_ids: товара нет в группе").Uz("product_ids: mahsulot guruhda yoʻq")
		}
		if moving == total {
			return apperr.Validation("product_ids: в группе должен остаться хотя бы один товар").Uz("product_ids: guruhda kamida bitta mahsulot qolishi kerak")
		}
		var newID string
		if err := tx.QueryRow(ctx, `
			INSERT INTO variant_groups (name, name_uz, brand_id, category_id, source, confidence, note)
			SELECT name, name_uz, brand_id, category_id, 'manual', 'check', '' FROM variant_groups WHERE id = $1
			RETURNING id`, groupID).Scan(&newID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE variant_group_items SET group_id = $3 WHERE group_id = $1 AND product_id = ANY ($2::uuid[])`,
			groupID, in.ProductIDs, newID); err != nil {
			return err
		}
		if out.Group, err = s.get(ctx, tx, groupID); err != nil {
			return err
		}
		out.NewGroup, err = s.get(ctx, tx, newID)
		return err
	})
	return out, err
}

func uniq(ids []string) map[string]bool {
	m := map[string]bool{}
	for _, id := range ids {
		m[id] = true
	}
	return m
}

// ---------------------------------------------------------- решение

// Confirm — подтвердить группу: вес и вкус уходят в товары.
func (s *Service) Confirm(ctx context.Context, id string) (Group, error) {
	var out Group
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := lockGroup(ctx, tx, id); err != nil {
			return err
		}
		if err := validate(ctx, tx, id); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE variant_groups SET status = 'confirmed', decided_at = now() WHERE id = $1`, id); err != nil {
			return err
		}
		if err := apply(ctx, tx, id); err != nil {
			return err
		}
		var err error
		out, err = s.get(ctx, tx, id)
		return err
	})
	return out, err
}

// Reject — отклонить предложение или расформировать подтверждённую группу:
// товары снова живут отдельно. Отклонённые товары Super Market больше не
// предлагает.
func (s *Service) Reject(ctx context.Context, id string) (Group, error) {
	var out Group
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := lockGroup(ctx, tx, id); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE variant_groups SET status = 'rejected', decided_at = now() WHERE id = $1`, id); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			UPDATE products SET variant_group_id = NULL, variant_weight = '', variant_weight_uz = '', variant_weight_sort = 0,
			       variant_flavor = '', variant_flavor_uz = '', variant_sort = 0
			WHERE variant_group_id = $1`, id); err != nil {
			return err
		}
		var err error
		out, err = s.get(ctx, tx, id)
		return err
	})
	return out, err
}

// validate — группу можно подтвердить: от двух товаров, вес и вкус не
// повторяются, товары не в другой подтверждённой группе.
func validate(ctx context.Context, tx pgx.Tx, id string) error {
	rows, err := tx.Query(ctx, `
		SELECT p.name, i.weight, i.flavor, og.name
		FROM variant_group_items i JOIN products p ON p.id = i.product_id
		LEFT JOIN variant_groups og ON og.id = p.variant_group_id AND og.id <> i.group_id
		WHERE i.group_id = $1 AND i.included`, id)
	if err != nil {
		return err
	}
	type row struct{ name, weight, flavor string }
	var items []row
	var busy []string
	for rows.Next() {
		var r row
		var other *string
		if err := rows.Scan(&r.name, &r.weight, &r.flavor, &other); err != nil {
			rows.Close()
			return err
		}
		items = append(items, r)
		if other != nil {
			busy = append(busy, r.name+" — «"+*other+"»")
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	if len(items) < 2 {
		return apperr.Validation("в группе должно быть хотя бы два товара").Uz("guruhda kamida ikkita mahsulot boʻlishi kerak")
	}
	if len(busy) > 0 {
		return apperr.Conflict("in_other_group", "товары уже в другой группе: "+strings.Join(busy, "; ")).
			Uz("mahsulotlar boshqa guruhda: " + strings.Join(busy, "; ")).
			WithDetails(map[string]any{"products": busy})
	}
	seen := map[string]string{}
	for _, r := range items {
		k := naming.Fold(r.weight) + "|" + naming.Fold(r.flavor)
		if prev, ok := seen[k]; ok {
			return apperr.Validation("у товаров «" + prev + "» и «" + r.name + "» одинаковые вес и вкус — поправьте или снимите один").
				Uz("«" + prev + "» va «" + r.name + "» mahsulotlarining vazni va taʼmi bir xil — tuzating yoki bittasini olib tashlang")
		}
		seen[k] = r.name
	}
	return nil
}

// apply — состав подтверждённой группы в товары.
func apply(ctx context.Context, tx pgx.Tx, id string) error {
	if _, err := tx.Exec(ctx, `
		UPDATE products SET variant_group_id = NULL, variant_weight = '', variant_weight_uz = '', variant_weight_sort = 0,
		       variant_flavor = '', variant_flavor_uz = '', variant_sort = 0
		WHERE variant_group_id = $1
		  AND id NOT IN (SELECT product_id FROM variant_group_items WHERE group_id = $1 AND included)`, id); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `
		UPDATE products p SET variant_group_id = i.group_id, variant_weight = i.weight, variant_weight_uz = i.weight_uz,
		       variant_weight_sort = i.weight_sort, variant_flavor = i.flavor, variant_flavor_uz = i.flavor_uz, variant_sort = i.sort
		FROM variant_group_items i
		WHERE i.group_id = $1 AND i.included AND p.id = i.product_id
		  AND (p.variant_group_id IS DISTINCT FROM i.group_id OR p.variant_weight <> i.weight OR p.variant_weight_uz <> i.weight_uz
		       OR p.variant_flavor <> i.flavor OR p.variant_flavor_uz <> i.flavor_uz OR p.variant_sort <> i.sort
		       OR p.variant_weight_sort <> i.weight_sort)`, id)
	return err
}
