package cafe

import (
	"context"
	"errors"
	"regexp"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// RecipeLine — строка техкарты с себестоимостью по цене последнего прихода.
type RecipeLine struct {
	Line         int    `json:"line"`
	IngredientID string `json:"ingredient_id"`
	Name         string `json:"name"`
	Kind         string `json:"kind"`
	UnitShort    string `json:"unit_short"`
	Qty          string `json:"qty"`
	// Цена единицы продукта и стоимость строки; HasCost = false — продукт
	// ещё ни разу не приходовали, его цена неизвестна.
	UnitCost string `json:"unit_cost"`
	Cost     string `json:"cost"`
	HasCost  bool   `json:"has_cost"`
}

// Dish — блюдо или заготовка.
type Dish struct {
	ID          string  `json:"id"`
	Kind        string  `json:"kind"`
	Name        string  `json:"name"`
	NameRu      string  `json:"name_ru"`
	NameUz      string  `json:"name_uz"`
	Description string  `json:"description"`
	MenuCode    *int    `json:"menu_code"`
	MenuGroupID *string `json:"menu_group_id"`
	MenuGroup   *string `json:"menu_group_name"`
	// Свой цех блюда (nil — цех группы или «Кухня») и цех, куда блюдо уйдёт.
	WorkshopID     *string  `json:"workshop_id"`
	KitchenID      *string  `json:"kitchen_workshop_id"`
	KitchenName    *string  `json:"kitchen_workshop_name"`
	UnitID         string   `json:"unit_id"`
	UnitShort      string   `json:"unit_short"`
	IsFractional   bool     `json:"is_fractional"`
	Price          string   `json:"price"`
	YieldQty       string   `json:"yield_qty"`
	CookMinutes    *int     `json:"cook_minutes"`
	ShelfHours     *int     `json:"shelf_hours"`
	IKPU           string   `json:"ikpu"`
	PackageCode    string   `json:"package_code"`
	VatRate        string   `json:"vat_rate"`
	Images         []string `json:"images"`
	IsActive       bool     `json:"is_active"`
	StoreIDs       []string `json:"store_ids"`
	ModifierGroups []string `json:"modifier_group_ids"`
	// Себестоимость единицы (порции / кг заготовки), наценка и фудкост, %.
	Cost         string  `json:"cost"`
	CostComplete bool    `json:"cost_complete"`
	Markup       string  `json:"markup"`
	FoodCost     *string `json:"food_cost"`
	HasRecipe    bool    `json:"has_recipe"`
	// Сколько заготовки на складах (только для заготовок).
	Stock  *string      `json:"stock,omitempty"`
	Recipe []RecipeLine `json:"recipe,omitempty"`
}

const dishSelect = `
	SELECT p.id, p.kind, loc(p.name, p.name_uz), p.name, p.name_uz, loc(p.description, p.description_uz),
	       p.menu_code, p.menu_group_id, (SELECT loc(g.name, g.name_uz) FROM menu_groups g WHERE g.id = p.menu_group_id),
	       p.workshop_id, kw.id, loc(kw.name, kw.name_uz),
	       p.unit_id, loc(u.short_name, u.short_name_uz), u.is_fractional, p.base_price::text, trim_scale(p.yield_qty)::text,
	       p.cook_minutes, p.shelf_hours, p.ikpu, p.package_code, trim_scale(p.vat_rate)::text, p.images, p.is_active,
	       COALESCE((SELECT array_agg(sp.store_id::text ORDER BY sp.store_id) FROM store_products sp WHERE sp.product_id = p.id), '{}'),
	       COALESCE((SELECT array_agg(pm.group_id::text ORDER BY pm.sort, pm.group_id) FROM product_modifier_groups pm WHERE pm.product_id = p.id), '{}'),
	       EXISTS (SELECT 1 FROM recipe_items ri WHERE ri.product_id = p.id)
	FROM products p
	JOIN units u ON u.id = p.unit_id
	LEFT JOIN workshops kw ON kw.id = COALESCE(p.workshop_id,
	     (SELECT g.workshop_id FROM menu_groups g WHERE g.id = p.menu_group_id),
	     (SELECT d.id FROM workshops d WHERE d.network_id = p.network_id AND d.is_default))`

func scanDish(row pgx.CollectableRow) (Dish, error) {
	var d Dish
	err := row.Scan(&d.ID, &d.Kind, &d.Name, &d.NameRu, &d.NameUz, &d.Description,
		&d.MenuCode, &d.MenuGroupID, &d.MenuGroup, &d.WorkshopID, &d.KitchenID, &d.KitchenName,
		&d.UnitID, &d.UnitShort, &d.IsFractional, &d.Price, &d.YieldQty,
		&d.CookMinutes, &d.ShelfHours, &d.IKPU, &d.PackageCode, &d.VatRate, &d.Images, &d.IsActive,
		&d.StoreIDs, &d.ModifierGroups, &d.HasRecipe)
	return d, err
}

// ------------------------------------------------------------ себестоимость

// costBook — себестоимость единицы любого продукта сети: товар — по цене
// последней партии, блюдо и заготовка с техкартой — по техкарте.
type costBook struct {
	last    map[string]money.Dec
	recipes map[string][]recipeEdge
	yield   map[string]money.Dec
	memo    map[string]costVal
}

type recipeEdge struct {
	ingredient string
	qty        money.Dec
}

type costVal struct {
	cost     money.Dec
	complete bool
}

func loadCostBook(ctx context.Context, q db.Querier, networkID string) (*costBook, error) {
	b := &costBook{last: map[string]money.Dec{}, recipes: map[string][]recipeEdge{}, yield: map[string]money.Dec{}, memo: map[string]costVal{}}
	rows, err := q.Query(ctx, `
		SELECT ri.product_id, ri.ingredient_id, ri.qty::text, p.yield_qty::text
		FROM recipe_items ri JOIN products p ON p.id = ri.product_id
		WHERE p.network_id = $1 ORDER BY ri.product_id, ri.line`, networkID)
	if err != nil {
		return nil, err
	}
	var ingredients []string
	seen := map[string]bool{}
	for rows.Next() {
		var pid, ing, qty, yield string
		if err := rows.Scan(&pid, &ing, &qty, &yield); err != nil {
			rows.Close()
			return nil, err
		}
		b.recipes[pid] = append(b.recipes[pid], recipeEdge{ingredient: ing, qty: money.D(qty)})
		b.yield[pid] = money.D(yield)
		if !seen[ing] {
			seen[ing] = true
			ingredients = append(ingredients, ing)
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(ingredients) == 0 {
		return b, nil
	}
	rows, err = q.Query(ctx, `
		SELECT DISTINCT ON (product_id) product_id, unit_cost::text
		FROM batches WHERE network_id = $1 AND product_id = ANY($2::uuid[])
		ORDER BY product_id, created_at DESC, id DESC`, networkID, ingredients)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var pid, cost string
		if err := rows.Scan(&pid, &cost); err != nil {
			return nil, err
		}
		b.last[pid] = money.D(cost)
	}
	return b, rows.Err()
}

// unit — себестоимость единицы продукта.
func (b *costBook) unit(id string) costVal {
	if v, ok := b.memo[id]; ok {
		return v
	}
	edges, ok := b.recipes[id]
	if !ok {
		c, has := b.last[id]
		v := costVal{cost: c, complete: has}
		if !has {
			v.cost = money.D("0")
		}
		b.memo[id] = v
		return v
	}
	// Защита от цикла в данных: пока считаем — «неизвестно».
	b.memo[id] = costVal{cost: money.D("0"), complete: false}
	sum, complete := money.D("0"), true
	for _, e := range edges {
		u := b.unit(e.ingredient)
		sum = sum.Add(u.cost.Mul(e.qty))
		complete = complete && u.complete
	}
	v := costVal{cost: sum.Div(b.yield[id]), complete: complete}
	b.memo[id] = v
	return v
}

func (b *costBook) fill(d *Dish) {
	v := costVal{cost: money.D("0"), complete: false}
	if d.HasRecipe {
		v = b.unit(d.ID)
	} else if c, ok := b.last[d.ID]; ok {
		v = costVal{cost: c, complete: true}
	}
	d.Cost = v.cost.Money()
	d.CostComplete = v.complete && d.HasRecipe
	price := money.D(d.Price)
	d.Markup = price.Sub(money.D(d.Cost)).Money()
	if price.Sign() > 0 && d.Kind == KindDish {
		fc := money.D(d.Cost).Mul(money.D("100")).Div(price).Fixed(1)
		d.FoodCost = &fc
	}
}

// --------------------------------------------------------------- список

type DishFilter struct {
	Kind     string
	Query    string
	GroupID  string
	StoreID  string
	NoRecipe bool
	All      bool // и выключенные
	Page     httpx.Page
}

func (s *Service) ListDishes(ctx context.Context, p *identity.Principal, f DishFilter) ([]Dish, error) {
	if err := s.read(ctx, p); err != nil {
		return nil, err
	}
	if f.Kind == "" {
		f.Kind = KindDish
	}
	if f.Kind != KindDish && f.Kind != KindPrep {
		return nil, apperr.Validation("kind: ожидается dish или prep").Uz("kind: dish yoki prep boʻlishi kerak")
	}
	if (f.GroupID != "" && f.GroupID != "none" && !httpx.IsUUID(f.GroupID)) || (f.StoreID != "" && !httpx.IsUUID(f.StoreID)) {
		return nil, apperr.Validation("неверный фильтр").Uz("filtr notoʻgʻri")
	}
	q := strings.TrimSpace(f.Query)
	code := -1
	if n, err := strconv.Atoi(q); err == nil {
		code = n
	}
	rows, err := s.pool.Query(ctx, dishSelect+`
		WHERE p.network_id = $1 AND p.kind = $2 AND ($3 OR p.is_active)
		  AND ($4 = '' OR p.menu_code = $5 OR p.name ILIKE '%' || $4 || '%' OR p.name_uz ILIKE '%' || $4 || '%')
		  AND ($6 = '' OR ($6 = 'none' AND p.menu_group_id IS NULL) OR p.menu_group_id::text = $6)
		  AND ($7 = '' OR EXISTS (SELECT 1 FROM store_products sp WHERE sp.product_id = p.id AND sp.store_id::text = $7))
		  AND (NOT $8 OR NOT EXISTS (SELECT 1 FROM recipe_items ri WHERE ri.product_id = p.id))
		ORDER BY (SELECT g.sort FROM menu_groups g WHERE g.id = p.menu_group_id) NULLS LAST, p.menu_code NULLS LAST, p.name
		LIMIT $9 OFFSET $10`,
		p.NetworkID, f.Kind, f.All, q, code, f.GroupID, f.StoreID, f.NoRecipe, f.Page.Limit, f.Page.Offset)
	if err != nil {
		return nil, err
	}
	list, err := pgx.CollectRows(rows, scanDish)
	if err != nil {
		return nil, err
	}
	book, err := loadCostBook(ctx, s.pool, p.NetworkID)
	if err != nil {
		return nil, err
	}
	for i := range list {
		book.fill(&list[i])
	}
	return list, nil
}

func (s *Service) GetDish(ctx context.Context, p *identity.Principal, id string) (Dish, error) {
	if err := s.read(ctx, p); err != nil {
		return Dish{}, err
	}
	return getDish(ctx, s.pool, p.NetworkID, id)
}

func getDish(ctx context.Context, q db.Querier, networkID, id string) (Dish, error) {
	rows, err := q.Query(ctx, dishSelect+` WHERE p.network_id = $1 AND p.id = $2 AND p.kind <> 'goods'`, networkID, id)
	if err != nil {
		return Dish{}, err
	}
	d, err := pgx.CollectExactlyOneRow(rows, scanDish)
	if errors.Is(err, pgx.ErrNoRows) {
		return d, apperr.NotFound("блюдо не найдено").Uz("taom topilmadi")
	}
	if err != nil {
		return d, err
	}
	book, err := loadCostBook(ctx, q, networkID)
	if err != nil {
		return d, err
	}
	book.fill(&d)
	rows, err = q.Query(ctx, `
		SELECT ri.line, ri.ingredient_id, loc(i.name, i.name_uz), i.kind, loc(u.short_name, u.short_name_uz), trim_scale(ri.qty)::text
		FROM recipe_items ri JOIN products i ON i.id = ri.ingredient_id JOIN units u ON u.id = i.unit_id
		WHERE ri.product_id = $1 ORDER BY ri.line`, id)
	if err != nil {
		return d, err
	}
	d.Recipe, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (RecipeLine, error) {
		var l RecipeLine
		err := r.Scan(&l.Line, &l.IngredientID, &l.Name, &l.Kind, &l.UnitShort, &l.Qty)
		return l, err
	})
	if err != nil {
		return d, err
	}
	for i := range d.Recipe {
		u := book.unit(d.Recipe[i].IngredientID)
		d.Recipe[i].UnitCost = u.cost.Money()
		d.Recipe[i].Cost = u.cost.Mul(money.D(d.Recipe[i].Qty)).Money()
		d.Recipe[i].HasCost = u.complete
	}
	if d.Recipe == nil {
		d.Recipe = []RecipeLine{}
	}
	if d.Kind == KindPrep {
		var stock string
		if err := q.QueryRow(ctx, `SELECT trim_scale(COALESCE(sum(qty_remaining), 0))::text FROM batches WHERE product_id = $1`, id).Scan(&stock); err != nil {
			return d, err
		}
		d.Stock = &stock
	}
	return d, nil
}

// ---------------------------------------------------- создание и правка

type RecipeInput struct {
	IngredientID string    `json:"ingredient_id"`
	Qty          money.Qty `json:"qty"`
}

type DishInput struct {
	Kind          *string                `json:"kind"` // только при создании
	Name          *string                `json:"name"`
	NameUz        *string                `json:"name_uz"`
	Description   *string                `json:"description"`
	DescriptionUz *string                `json:"description_uz"`
	MenuCode      httpx.Optional[int]    `json:"menu_code"`
	MenuGroupID   httpx.Optional[string] `json:"menu_group_id"`
	WorkshopID    httpx.Optional[string] `json:"workshop_id"`
	UnitID        *string                `json:"unit_id"`
	Price         *money.Amount          `json:"price"`
	YieldQty      *money.Qty             `json:"yield_qty"`
	CookMinutes   httpx.Optional[int]    `json:"cook_minutes"`
	ShelfHours    httpx.Optional[int]    `json:"shelf_hours"`
	IKPU          *string                `json:"ikpu"`
	PackageCode   *string                `json:"package_code"`
	VatRate       *money.Amount          `json:"vat_rate"`
	Images        *[]string              `json:"images"`
	IsActive      *bool                  `json:"is_active"`
	// Где продаётся: магазины (точки) сети. При создании без поля — во всех.
	StoreIDs *[]string `json:"store_ids"`
	// Техкарта целиком (заменяет прежнюю) и группы модификаторов по порядку.
	Recipe           *[]RecipeInput `json:"recipe"`
	ModifierGroupIDs *[]string      `json:"modifier_group_ids"`
}

var ikpuRe = regexp.MustCompile(`^[0-9]{17}$`)

func (in *DishInput) validate(create bool) error {
	if create {
		if in.Kind == nil || (*in.Kind != KindDish && *in.Kind != KindPrep) {
			return apperr.Validation("kind: ожидается dish (блюдо) или prep (заготовка)").Uz("kind: dish (taom) yoki prep (yarim tayyor) boʻlishi kerak")
		}
	} else if in.Kind != nil {
		return apperr.Validation("kind: вид нельзя поменять").Uz("kind: turini oʻzgartirib boʻlmaydi")
	}
	ru, uz, err := names(NameInput{Name: in.Name, NameUz: in.NameUz}, create)
	if err != nil {
		return err
	}
	in.Name, in.NameUz = ru, uz
	if in.Description != nil {
		v := strings.TrimSpace(*in.Description)
		in.Description = &v
	}
	if in.DescriptionUz != nil {
		v := strings.TrimSpace(*in.DescriptionUz)
		in.DescriptionUz = &v
	}
	if (in.Description != nil && len(*in.Description) > 2000) || (in.DescriptionUz != nil && len(*in.DescriptionUz) > 2000) {
		return apperr.Validation("description: до 2000 символов").Uz("description: 2000 belgigacha")
	}
	if v := in.MenuCode.Value; v != nil && (*v < 1 || *v > 99999) {
		return apperr.Validation("menu_code: от 1 до 99999").Uz("menu_code: 1 dan 99999 gacha")
	}
	if v := in.CookMinutes.Value; v != nil && (*v < 1 || *v > 600) {
		return apperr.Validation("cook_minutes: от 1 до 600").Uz("cook_minutes: 1 dan 600 gacha")
	}
	if v := in.ShelfHours.Value; v != nil && (*v < 1 || *v > 8760) {
		return apperr.Validation("shelf_hours: от 1 до 8760").Uz("shelf_hours: 1 dan 8760 gacha")
	}
	if in.Price != nil && (!in.Price.Valid() || money.D(string(*in.Price)).Sign() < 0) {
		return apperr.Validation("price: неверная цена").Uz("price: narx notoʻgʻri")
	}
	if in.YieldQty != nil && (!in.YieldQty.Valid() || money.D(string(*in.YieldQty)).Sign() <= 0) {
		return apperr.Validation("yield_qty: выход должен быть больше нуля").Uz("yield_qty: chiqish noldan katta boʻlishi kerak")
	}
	if in.IKPU != nil {
		v := strings.TrimSpace(*in.IKPU)
		in.IKPU = &v
		if v != "" && !ikpuRe.MatchString(v) {
			return apperr.Validation("ikpu: 17 цифр").Uz("ikpu: 17 ta raqam")
		}
	}
	if in.PackageCode != nil && len(strings.TrimSpace(*in.PackageCode)) > 20 {
		return apperr.Validation("package_code: до 20 символов").Uz("package_code: 20 belgigacha")
	}
	if in.VatRate != nil {
		v := money.D(string(*in.VatRate))
		if !in.VatRate.Valid() || v.Sign() < 0 || v.Cmp(money.D("100")) > 0 {
			return apperr.Validation("vat_rate: от 0 до 100").Uz("vat_rate: 0 dan 100 gacha")
		}
	}
	if in.Images != nil {
		if len(*in.Images) > 10 {
			return apperr.Validation("images: не больше 10 фото").Uz("images: 10 tadan koʻp boʻlmasin")
		}
		for _, u := range *in.Images {
			if !strings.HasPrefix(u, "https://") && !strings.HasPrefix(u, "http://") && !strings.HasPrefix(u, "/") {
				return apperr.Validation("images: ожидается ссылка на фото").Uz("images: rasm havolasi kerak")
			}
		}
	}
	return nil
}

func (s *Service) CreateDish(ctx context.Context, p *identity.Principal, in DishInput) (Dish, error) {
	if err := s.manage(ctx, p); err != nil {
		return Dish{}, err
	}
	if err := in.validate(true); err != nil {
		return Dish{}, err
	}
	var out Dish
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		unitID := ""
		if in.UnitID != nil {
			unitID = *in.UnitID
		} else if *in.Kind == KindDish {
			if err := tx.QueryRow(ctx, `SELECT id FROM units WHERE lower(name) = 'порция'`).Scan(&unitID); err != nil {
				return err
			}
		} else {
			return apperr.Validation("unit_id: укажите единицу заготовки (кг, л, шт)").Uz("unit_id: yarim tayyor mahsulot birligini kiriting (kg, l, dona)")
		}
		if err := checkUnit(ctx, tx, unitID); err != nil {
			return err
		}
		images := []string{}
		if in.Images != nil {
			images = *in.Images
		}
		var id string
		err := tx.QueryRow(ctx, `
			INSERT INTO products (network_id, proposed_by, name, name_uz, description, description_uz, category_id, unit_id,
			                      base_price, images, moderation_status, kind, yield_qty, ikpu, package_code, vat_rate)
			VALUES ($1, $1, $2, COALESCE($3, ''), COALESCE($4, ''), COALESCE($5, ''), $6, $7,
			        COALESCE($8::numeric, 0), $9, 'approved', $10, COALESCE($11::numeric, 1), COALESCE($12, ''), COALESCE($13, ''), COALESCE($14::numeric, 12))
			RETURNING id`,
			p.NetworkID, *in.Name, in.NameUz, in.Description, in.DescriptionUz, DishCategoryID, unitID,
			in.Price, images, *in.Kind, in.YieldQty, in.IKPU, in.PackageCode, in.VatRate).Scan(&id)
		if err != nil {
			return err
		}
		if in.StoreIDs == nil {
			all := []string{}
			if err := tx.QueryRow(ctx, `SELECT COALESCE(array_agg(id::text), '{}') FROM stores WHERE network_id = $1 AND status = 'active'`,
				p.NetworkID).Scan(&all); err != nil {
				return err
			}
			in.StoreIDs = &all
		}
		if err := applyDish(ctx, tx, p, id, *in.Kind, &in, true); err != nil {
			return err
		}
		out, err = getDish(ctx, tx, p.NetworkID, id)
		return err
	})
	return out, err
}

func (s *Service) UpdateDish(ctx context.Context, p *identity.Principal, id string, in DishInput) (Dish, error) {
	if err := s.manage(ctx, p); err != nil {
		return Dish{}, err
	}
	if err := in.validate(false); err != nil {
		return Dish{}, err
	}
	var out Dish
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var kind string
		err := tx.QueryRow(ctx, `SELECT kind FROM products WHERE id = $1 AND network_id = $2 AND kind <> 'goods' FOR UPDATE`,
			id, p.NetworkID).Scan(&kind)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.NotFound("блюдо не найдено").Uz("taom topilmadi")
		}
		if err != nil {
			return err
		}
		if in.UnitID != nil {
			if err := checkUnit(ctx, tx, *in.UnitID); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `
			UPDATE products SET name = COALESCE($2, name), name_uz = COALESCE($3, name_uz),
			       description = COALESCE($4, description), description_uz = COALESCE($5, description_uz),
			       unit_id = COALESCE($6, unit_id), base_price = COALESCE($7::numeric, base_price),
			       yield_qty = COALESCE($8::numeric, yield_qty), ikpu = COALESCE($9, ikpu),
			       package_code = COALESCE($10, package_code), vat_rate = COALESCE($11::numeric, vat_rate),
			       images = COALESCE($12, images), is_active = COALESCE($13, is_active)
			WHERE id = $1`,
			id, in.Name, in.NameUz, in.Description, in.DescriptionUz, in.UnitID, in.Price, in.YieldQty,
			in.IKPU, in.PackageCode, in.VatRate, in.Images, in.IsActive); err != nil {
			return err
		}
		if err := applyDish(ctx, tx, p, id, kind, &in, false); err != nil {
			return err
		}
		out, err = getDish(ctx, tx, p.NetworkID, id)
		return err
	})
	return out, err
}

func checkUnit(ctx context.Context, q db.Querier, id string) error {
	var ok bool
	if httpx.IsUUID(id) {
		if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM units WHERE id = $1 AND is_active)`, id).Scan(&ok); err != nil {
			return err
		}
	}
	if !ok {
		return apperr.Validation("unit_id: единица не найдена").Uz("unit_id: birlik topilmadi")
	}
	return nil
}

// applyDish — поля, общие для создания и правки: код, группа, цех, нормы,
// где продаётся, техкарта, модификаторы.
func applyDish(ctx context.Context, tx pgx.Tx, p *identity.Principal, id, kind string, in *DishInput, create bool) error {
	if in.MenuGroupID.Set && in.MenuGroupID.Value != nil {
		var ok bool
		if httpx.IsUUID(*in.MenuGroupID.Value) {
			if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM menu_groups WHERE id = $1 AND network_id = $2 AND is_active)`,
				*in.MenuGroupID.Value, p.NetworkID).Scan(&ok); err != nil {
				return err
			}
		}
		if !ok {
			return apperr.Validation("menu_group_id: группа меню не найдена").Uz("menu_group_id: menyu guruhi topilmadi")
		}
	}
	if in.WorkshopID.Set {
		if err := checkWorkshop(ctx, tx, p.NetworkID, in.WorkshopID.Value); err != nil {
			return err
		}
	}
	_, err := tx.Exec(ctx, `
		UPDATE products SET
		       menu_code     = CASE WHEN $2 THEN $3::int ELSE menu_code END,
		       menu_group_id = CASE WHEN $4 THEN $5::uuid ELSE menu_group_id END,
		       workshop_id   = CASE WHEN $6 THEN $7::uuid ELSE workshop_id END,
		       cook_minutes  = CASE WHEN $8 THEN $9::int ELSE cook_minutes END,
		       shelf_hours   = CASE WHEN $10 THEN $11::int ELSE shelf_hours END
		WHERE id = $1`,
		id, in.MenuCode.Set, in.MenuCode.Value, in.MenuGroupID.Set, in.MenuGroupID.Value,
		in.WorkshopID.Set, in.WorkshopID.Value, in.CookMinutes.Set, in.CookMinutes.Value,
		in.ShelfHours.Set, in.ShelfHours.Value)
	if db.IsUniqueViolation(err, "products_menu_code_key") {
		return apperr.Conflict("menu_code_taken", "этот код уже у другого блюда").Uz("bu kod boshqa taomda bor")
	}
	if err != nil {
		return err
	}
	if in.StoreIDs != nil {
		if err := setStores(ctx, tx, p, id, *in.StoreIDs); err != nil {
			return err
		}
	}
	if in.Recipe != nil {
		if err := setRecipe(ctx, tx, p.NetworkID, id, *in.Recipe); err != nil {
			return err
		}
	}
	if in.ModifierGroupIDs != nil {
		if kind != KindDish {
			return apperr.Validation("modifier_group_ids: модификаторы бывают только у блюд").Uz("modifier_group_ids: modifikatorlar faqat taomlarda boʻladi")
		}
		if err := setModifierGroups(ctx, tx, p.NetworkID, id, *in.ModifierGroupIDs); err != nil {
			return err
		}
	}
	return nil
}

func setStores(ctx context.Context, tx pgx.Tx, p *identity.Principal, productID string, storeIDs []string) error {
	for _, sid := range storeIDs {
		if !httpx.IsUUID(sid) || !p.CanAccessStore(sid) {
			return apperr.Validation("store_ids: магазин не найден").Uz("store_ids: doʻkon topilmadi")
		}
	}
	var n int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM stores WHERE network_id = $1 AND id = ANY($2::uuid[])`,
		p.NetworkID, storeIDs).Scan(&n); err != nil {
		return err
	}
	if n != len(uniq(storeIDs)) {
		return apperr.Validation("store_ids: магазин не найден").Uz("store_ids: doʻkon topilmadi")
	}
	if _, err := tx.Exec(ctx, `DELETE FROM store_products WHERE product_id = $1 AND NOT (store_id = ANY($2::uuid[]))`,
		productID, storeIDs); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `
		INSERT INTO store_products (network_id, store_id, product_id)
		SELECT $1, s, $2 FROM unnest($3::uuid[]) s
		ON CONFLICT DO NOTHING`, p.NetworkID, productID, storeIDs)
	return err
}

func uniq(in []string) []string {
	seen := map[string]bool{}
	out := in[:0:0]
	for _, v := range in {
		if !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}
	return out
}

// setRecipe заменяет техкарту. Продукт — товар каталога (виден сети) или
// заготовка сети; блюдо в техкарту не входит. Заготовка не может входить
// сама в себя, в том числе через другие заготовки.
func setRecipe(ctx context.Context, tx pgx.Tx, networkID, productID string, lines []RecipeInput) error {
	if len(lines) > 100 {
		return apperr.Validation("recipe: не больше 100 строк").Uz("recipe: 100 qatordan koʻp boʻlmasin")
	}
	if _, err := tx.Exec(ctx, `DELETE FROM recipe_items WHERE product_id = $1`, productID); err != nil {
		return err
	}
	seen := map[string]bool{}
	for i, l := range lines {
		ls := strconv.Itoa(i + 1)
		if !httpx.IsUUID(l.IngredientID) {
			return apperr.Validation("recipe: продукт не найден в строке " + ls).Uz("recipe: " + ls + "-qatorda mahsulot topilmadi")
		}
		if seen[l.IngredientID] {
			return apperr.Validation("recipe: продукт повторяется в строке " + ls).Uz("recipe: " + ls + "-qatorda mahsulot takrorlanadi")
		}
		seen[l.IngredientID] = true
		if !l.Qty.Valid() || money.D(string(l.Qty)).Sign() <= 0 {
			return apperr.Validation("recipe: количество должно быть больше нуля в строке " + ls).Uz("recipe: " + ls + "-qatorda miqdor noldan katta boʻlishi kerak")
		}
		var kind string
		err := tx.QueryRow(ctx, `SELECT kind FROM products WHERE id = $1 AND (network_id IS NULL OR network_id = $2)`,
			l.IngredientID, networkID).Scan(&kind)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Validation("recipe: продукт не найден в строке " + ls).Uz("recipe: " + ls + "-qatorda mahsulot topilmadi")
		}
		if err != nil {
			return err
		}
		if kind == KindDish {
			return apperr.Validation("recipe: блюдо не может входить в техкарту (строка " + ls + ") — сделайте его заготовкой").Uz("recipe: taom texnologik kartaga kira olmaydi (" + ls + "-qator) — uni yarim tayyor mahsulot qiling")
		}
		if l.IngredientID == productID {
			return errCycle
		}
		if _, err := tx.Exec(ctx, `INSERT INTO recipe_items (product_id, line, ingredient_id, qty) VALUES ($1, $2, $3, $4::numeric)`,
			productID, i+1, l.IngredientID, money.D(string(l.Qty)).Fixed(4)); err != nil {
			return err
		}
	}
	var cycle bool
	if err := tx.QueryRow(ctx, `
		WITH RECURSIVE r(id) AS (
			SELECT ingredient_id FROM recipe_items WHERE product_id = $1
			UNION
			SELECT ri.ingredient_id FROM recipe_items ri JOIN r ON ri.product_id = r.id)
		SELECT EXISTS (SELECT 1 FROM r WHERE id = $1)`, productID).Scan(&cycle); err != nil {
		return err
	}
	if cycle {
		return errCycle
	}
	return nil
}

var errCycle = apperr.Validation("recipe: заготовка не может входить сама в себя").Uz("recipe: yarim tayyor mahsulot oʻz-oʻziga kira olmaydi")
