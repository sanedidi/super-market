package cafe

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Производство заготовки (П12 «Произвести», с экрана кухни — «Сделал 18 кг»):
// продукты по техкарте списываются, заготовка приходуется партией по их
// себестоимости и со сроком годности.

type ProductionItem struct {
	IngredientID string `json:"ingredient_id"`
	Name         string `json:"name"`
	UnitShort    string `json:"unit_short"`
	Qty          string `json:"qty"`
	ShortQty     string `json:"short_qty"`
	Cost         string `json:"cost"`
}

type Production struct {
	ID          string           `json:"id"`
	Number      int64            `json:"number"`
	StoreID     string           `json:"store_id"`
	WarehouseID string           `json:"warehouse_id"`
	ProductID   string           `json:"product_id"`
	ProductName string           `json:"product_name"`
	UnitShort   string           `json:"unit_short"`
	Qty         string           `json:"qty"`
	Cost        string           `json:"cost"`
	UnitCost    string           `json:"unit_cost"`
	ExpiresAt   *time.Time       `json:"expires_at"`
	Note        string           `json:"note"`
	CreatedBy   string           `json:"created_by"`
	CreatedAt   time.Time        `json:"created_at"`
	Items       []ProductionItem `json:"items,omitempty"`
}

const productionSelect = `
	SELECT d.id, d.number, d.store_id, d.warehouse_id, d.product_id, loc(p.name, p.name_uz), loc(u.short_name, u.short_name_uz),
	       trim_scale(d.qty)::text, d.cost::text, round(d.cost / d.qty, 2)::text, d.expires_at, d.note, e.full_name, d.created_at
	FROM production_docs d
	JOIN products p ON p.id = d.product_id
	JOIN units u ON u.id = p.unit_id
	JOIN employees e ON e.id = d.created_by`

func scanProduction(row pgx.CollectableRow) (Production, error) {
	var d Production
	err := row.Scan(&d.ID, &d.Number, &d.StoreID, &d.WarehouseID, &d.ProductID, &d.ProductName, &d.UnitShort,
		&d.Qty, &d.Cost, &d.UnitCost, &d.ExpiresAt, &d.Note, &d.CreatedBy, &d.CreatedAt)
	return d, err
}

func getProduction(ctx context.Context, q db.Querier, p *identity.Principal, id string) (Production, error) {
	rows, err := q.Query(ctx, productionSelect+` WHERE d.network_id = $1 AND d.id = $2`, p.NetworkID, id)
	if err != nil {
		return Production{}, err
	}
	d, err := pgx.CollectExactlyOneRow(rows, scanProduction)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !p.CanAccessStore(d.StoreID)) {
		return Production{}, apperr.NotFound("документ производства не найден").Uz("ishlab chiqarish hujjati topilmadi")
	}
	if err != nil {
		return d, err
	}
	rows, err = q.Query(ctx, `
		SELECT i.ingredient_id, loc(p.name, p.name_uz), loc(u.short_name, u.short_name_uz), trim_scale(i.qty)::text,
		       trim_scale(i.short_qty)::text, i.cost::text
		FROM production_doc_items i JOIN products p ON p.id = i.ingredient_id JOIN units u ON u.id = p.unit_id
		WHERE i.doc_id = $1 ORDER BY p.name`, id)
	if err != nil {
		return d, err
	}
	d.Items, err = pgx.CollectRows(rows, pgx.RowToStructByPos[ProductionItem])
	return d, err
}

func (s *Service) GetProduction(ctx context.Context, p *identity.Principal, id string) (Production, error) {
	if err := s.read(ctx, p); err != nil {
		return Production{}, err
	}
	return getProduction(ctx, s.pool, p, id)
}

type ProductionFilter struct {
	StoreID   string
	ProductID string
	Page      httpx.Page
}

func (s *Service) ListProduction(ctx context.Context, p *identity.Principal, f ProductionFilter) ([]Production, error) {
	if err := s.read(ctx, p); err != nil {
		return nil, err
	}
	if (f.StoreID != "" && !httpx.IsUUID(f.StoreID)) || (f.ProductID != "" && !httpx.IsUUID(f.ProductID)) {
		return nil, apperr.Validation("неверный фильтр").Uz("filtr notoʻgʻri")
	}
	rows, err := s.pool.Query(ctx, productionSelect+`
		WHERE d.network_id = $1 AND ($2 OR d.store_id = ANY($3::uuid[]))
		  AND ($4 = '' OR d.store_id::text = $4) AND ($5 = '' OR d.product_id::text = $5)
		ORDER BY d.created_at DESC LIMIT $6 OFFSET $7`,
		p.NetworkID, p.SeesAllStores(), p.StoreIDs, f.StoreID, f.ProductID, f.Page.Limit, f.Page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanProduction)
}

type ProductionInput struct {
	ClientUID   *string    `json:"client_uid"`
	StoreID     string     `json:"store_id"`
	WarehouseID *string    `json:"warehouse_id"`
	ProductID   string     `json:"product_id"`
	Qty         money.Qty  `json:"qty"`
	ExpiresAt   *time.Time `json:"expires_at"`
	Note        string     `json:"note"`
}

// CreateProduction проводит производство заготовки сразу (без черновика).
func (s *Service) CreateProduction(ctx context.Context, p *identity.Principal, in ProductionInput) (Production, bool, error) {
	if err := p.RequireAny(identity.PermInventoryManage, identity.PermSalesPOS); err != nil {
		return Production{}, false, err
	}
	if err := s.read(ctx, p); err != nil {
		return Production{}, false, err
	}
	if p.DeviceID != "" && len(p.StoreIDs) > 0 {
		in.StoreID = p.StoreIDs[0]
	}
	if !httpx.IsUUID(in.StoreID) || !p.CanAccessStore(in.StoreID) {
		return Production{}, false, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	if !httpx.IsUUID(in.ProductID) {
		return Production{}, false, apperr.Validation("product_id: заготовка не найдена").Uz("product_id: yarim tayyor mahsulot topilmadi")
	}
	if !in.Qty.Valid() || money.D(string(in.Qty)).Sign() <= 0 {
		return Production{}, false, apperr.Validation("qty: количество должно быть больше нуля").Uz("qty: miqdor noldan katta boʻlishi kerak")
	}
	in.Note = strings.TrimSpace(in.Note)
	if len(in.Note) > 500 {
		return Production{}, false, apperr.Validation("note: до 500 символов").Uz("note: 500 belgigacha")
	}
	if in.ClientUID != nil {
		v := strings.TrimSpace(*in.ClientUID)
		if len(v) < 8 || len(v) > 64 {
			return Production{}, false, apperr.Validation("client_uid: 8–64 символа").Uz("client_uid: 8–64 belgi")
		}
		in.ClientUID = &v
		var existing string
		err := s.pool.QueryRow(ctx, `SELECT id FROM production_docs WHERE network_id = $1 AND client_uid = $2`, p.NetworkID, v).Scan(&existing)
		if err == nil {
			d, err := getProduction(ctx, s.pool, p, existing)
			return d, false, err
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return Production{}, false, err
		}
	}
	var id string
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		warehouseID, err := storeWarehouse(ctx, tx, p.NetworkID, in.StoreID, in.WarehouseID)
		if err != nil {
			return err
		}
		var kind string
		var shelf *int
		var hasRecipe bool
		err = tx.QueryRow(ctx, `SELECT kind, shelf_hours, EXISTS (SELECT 1 FROM recipe_items WHERE product_id = p.id)
			FROM products p WHERE id = $1 AND network_id = $2`, in.ProductID, p.NetworkID).Scan(&kind, &shelf, &hasRecipe)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && kind != KindPrep) {
			return apperr.Validation("product_id: заготовка не найдена").Uz("product_id: yarim tayyor mahsulot topilmadi")
		}
		if err != nil {
			return err
		}
		if !hasRecipe {
			return apperr.Conflict("no_recipe", "у заготовки нет техкарты — заполните её").Uz("yarim tayyor mahsulotda texnologik karta yoʻq — uni toʻldiring")
		}
		expires := in.ExpiresAt
		if expires == nil && shelf != nil {
			t := s.now().Add(time.Duration(*shelf) * time.Hour)
			expires = &t
		}
		qty := money.D(money.D(string(in.Qty)).Fixed(3))
		n, err := db.NextNumber(ctx, tx, "production_docs", p.NetworkID, "")
		if err != nil {
			return err
		}
		err = tx.QueryRow(ctx, `
			INSERT INTO production_docs (network_id, number, store_id, warehouse_id, product_id, qty, expires_at, note, client_uid, created_by)
			VALUES ($1, $2, $3, $4, $5, $6::numeric, $7, $8, $9, $10) RETURNING id`,
			p.NetworkID, n, in.StoreID, warehouseID, in.ProductID, qty.Fixed(3), expires, in.Note, in.ClientUID, p.EmployeeID).Scan(&id)
		if db.IsUniqueViolation(err, "production_docs_network_id_client_uid_key") {
			return errDupProduction
		}
		if err != nil {
			return err
		}
		needs, err := Explode(ctx, tx, in.ProductID, qty, nil)
		if err != nil {
			return err
		}
		taken, err := TakeIngredients(ctx, tx, p.NetworkID, warehouseID, needs, inventory.DocProduction, id)
		if err != nil {
			return err
		}
		total := money.D("0")
		for _, t := range taken {
			if _, err := tx.Exec(ctx, `
				INSERT INTO production_doc_items (doc_id, ingredient_id, qty, short_qty, cost)
				VALUES ($1, $2, $3::numeric, $4::numeric, $5::numeric)`,
				id, t.IngredientID, t.Qty.Fixed(3), t.Short.Fixed(3), t.Cost.Money()); err != nil {
				return err
			}
			if err := inventory.AddShortfall(ctx, tx, p.NetworkID, warehouseID, t.IngredientID, t.Short.Fixed(3), inventory.DocProduction, id, nil); err != nil {
				return err
			}
			total = total.Add(t.Cost)
		}
		if _, err := tx.Exec(ctx, `UPDATE production_docs SET cost = $2::numeric WHERE id = $1`, id, total.Money()); err != nil {
			return err
		}
		unitCost := total.Div(qty).Fixed(4)
		if err := inventory.AddBatch(ctx, tx, p.NetworkID, warehouseID, in.ProductID, qty.Fixed(3), unitCost, "0", inventory.DocProduction, id); err != nil {
			return err
		}
		if expires != nil {
			if _, err := tx.Exec(ctx, `UPDATE batches SET expires_at = $3 WHERE doc_id = $1 AND product_id = $2`, id, in.ProductID, *expires); err != nil {
				return err
			}
		}
		// Заготовку уже продали «в минус» — досписываем из новой партии.
		return inventory.CloseShortfalls(ctx, tx, p.NetworkID, warehouseID, in.ProductID)
	})
	if errors.Is(err, errDupProduction) {
		return s.CreateProduction(ctx, p, in)
	}
	if err != nil {
		return Production{}, false, err
	}
	d, err := getProduction(ctx, s.pool, p, id)
	return d, true, err
}

var errDupProduction = errors.New("duplicate production client_uid")

// storeWarehouse — указанный склад магазина или склад магазина по умолчанию.
func storeWarehouse(ctx context.Context, q db.Querier, networkID, storeID string, warehouseID *string) (string, error) {
	var id string
	if warehouseID != nil {
		if !httpx.IsUUID(*warehouseID) {
			return "", apperr.Validation("warehouse_id: склад не найден").Uz("warehouse_id: ombor topilmadi")
		}
		err := q.QueryRow(ctx, `SELECT id FROM warehouses WHERE id = $1 AND store_id = $2 AND network_id = $3 AND is_active`,
			*warehouseID, storeID, networkID).Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			return "", apperr.Validation("warehouse_id: склад не найден в этом магазине").Uz("warehouse_id: ombor bu doʻkonda topilmadi")
		}
		return id, err
	}
	var wh *string
	err := q.QueryRow(ctx, `SELECT default_warehouse_id FROM stores WHERE id = $1 AND network_id = $2`, storeID, networkID).Scan(&wh)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && wh == nil) {
		return "", apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	if err != nil {
		return "", err
	}
	return *wh, nil
}

// ------------------------------------------------------------- «минусы»

type Shortfall struct {
	ProductID   string    `json:"product_id"`
	ProductName string    `json:"product_name"`
	UnitShort   string    `json:"unit_short"`
	WarehouseID string    `json:"warehouse_id"`
	Qty         string    `json:"qty"`
	Since       time.Time `json:"since"`
}

// ListShortfalls — открытые «минусы» продуктов по складам магазина:
// продано по техкартам больше, чем оприходовано.
func (s *Service) ListShortfalls(ctx context.Context, p *identity.Principal, storeID string) ([]Shortfall, error) {
	if err := s.read(ctx, p); err != nil {
		return nil, err
	}
	if storeID != "" && (!httpx.IsUUID(storeID) || !p.CanAccessStore(storeID)) {
		return nil, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	rows, err := s.pool.Query(ctx, `
		SELECT sf.product_id, loc(p.name, p.name_uz), loc(u.short_name, u.short_name_uz), sf.warehouse_id,
		       trim_scale(sum(sf.qty - sf.qty_closed))::text, min(sf.created_at)
		FROM stock_shortfalls sf
		JOIN warehouses w ON w.id = sf.warehouse_id
		JOIN products p ON p.id = sf.product_id
		JOIN units u ON u.id = p.unit_id
		WHERE sf.network_id = $1 AND sf.closed_at IS NULL AND ($2 OR w.store_id = ANY($3::uuid[]))
		  AND ($4 = '' OR w.store_id::text = $4)
		GROUP BY sf.product_id, p.name, p.name_uz, u.short_name, u.short_name_uz, sf.warehouse_id
		ORDER BY min(sf.created_at)`, p.NetworkID, p.SeesAllStores(), p.StoreIDs, storeID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Shortfall])
}
