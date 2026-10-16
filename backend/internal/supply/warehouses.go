package supply

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Склады агента (Figma «Правки 16 окт» → А2–А4). У агента одна точка
// (stores), складов у неё может быть несколько, у каждого — адрес и точка
// на карте. Магазины видны в 15 км от любого активного склада; расход по
// умолчанию — с ближайшего к магазину склада, где есть все товары.

// whPointsSQL — точки активных складов агента; $2 — точка агента (stores.id).
// Склад без своей точки — основной: его место — место точки агента.
const whPointsSQL = `
	SELECT COALESCE(w.location, ps.location) AS location
	FROM warehouses w JOIN stores ps ON ps.id = w.store_id
	WHERE w.store_id = $2 AND w.is_active
	  AND (w.location IS NOT NULL OR w.id = ps.default_warehouse_id)
	  AND COALESCE(w.location, ps.location) IS NOT NULL`

// AgentWarehouse — склад агента в списке «Склады».
type AgentWarehouse struct {
	ID        string   `json:"id"`
	Name      string   `json:"name"`
	Address   string   `json:"address"`
	Lat       *float64 `json:"lat"`
	Lng       *float64 `json:"lng"`
	IsDefault bool     `json:"is_default"`
	IsActive  bool     `json:"is_active"`
	// Подключённых магазинов в 15 км от склада.
	StoresInZone int `json:"stores_in_zone"`
	// Товаров с остатком и их стоимость по закупке.
	Products  int    `json:"products"`
	StockCost string `json:"stock_cost"`
	// Только в выборе склада для расхода магазину.
	DistanceKm *float64 `json:"distance_km,omitempty"`
	Missing    *int     `json:"missing,omitempty"`
}

const agentWarehouseSelect = `
	SELECT w.id::text AS id, w.name, COALESCE(NULLIF(w.address, ''), CASE WHEN w.id = ps.default_warehouse_id THEN ps.address ELSE '' END) AS address,
	       ST_Y(COALESCE(w.location, CASE WHEN w.id = ps.default_warehouse_id THEN ps.location END)::geometry) AS lat,
	       ST_X(COALESCE(w.location, CASE WHEN w.id = ps.default_warehouse_id THEN ps.location END)::geometry) AS lng,
	       w.id = ps.default_warehouse_id AS is_default, w.is_active,
	       (SELECT count(*)::int FROM supply_links l JOIN stores s ON s.id = l.store_id
	        WHERE l.distributor_id = w.network_id AND l.status = 'active'
	          AND ST_DWithin(s.location, COALESCE(w.location, CASE WHEN w.id = ps.default_warehouse_id THEN ps.location END), $3)) AS stores_in_zone,
	       (SELECT count(DISTINCT b.product_id)::int FROM batches b WHERE b.warehouse_id = w.id AND b.qty_remaining > 0) AS products,
	       (SELECT COALESCE(sum(b.qty_remaining * b.unit_cost), 0)::numeric(18,2)::text FROM batches b WHERE b.warehouse_id = w.id AND b.qty_remaining > 0) AS stock_cost,
	       COALESCE(w.location, CASE WHEN w.id = ps.default_warehouse_id THEN ps.location END) AS loc
	FROM warehouses w JOIN stores ps ON ps.id = w.store_id`

const whCols = `id, name, address, lat, lng, is_default, is_active, stores_in_zone, products, stock_cost`

func scanAgentWarehouse(row pgx.CollectableRow) (AgentWarehouse, error) {
	var w AgentWarehouse
	err := row.Scan(&w.ID, &w.Name, &w.Address, &w.Lat, &w.Lng, &w.IsDefault, &w.IsActive, &w.StoresInZone, &w.Products, &w.StockCost)
	return w, err
}

// AgentWarehouses — склады агента: основной первым, потом по названию.
func (s *Service) AgentWarehouses(ctx context.Context, p *identity.Principal) ([]AgentWarehouse, error) {
	if err := requireDistributor(p); err != nil {
		return nil, err
	}
	pt, err := distPoint(ctx, s.pool, p.NetworkID)
	if err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `SELECT `+whCols+` FROM (`+agentWarehouseSelect+`
		WHERE w.store_id = $1 AND w.network_id = $2) y
		ORDER BY is_default DESC, is_active DESC, name`, pt.StoreID, p.NetworkID, nearbyRadiusM)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanAgentWarehouse)
}

func (s *Service) agentWarehouse(ctx context.Context, q db.Querier, p *identity.Principal, pt point, id string) (AgentWarehouse, error) {
	if !httpx.IsUUID(id) {
		return AgentWarehouse{}, apperr.NotFound("склад не найден").Uz("ombor topilmadi")
	}
	rows, err := q.Query(ctx, `SELECT `+whCols+` FROM (`+agentWarehouseSelect+`
		WHERE w.store_id = $1 AND w.network_id = $2 AND w.id = $4) y`, pt.StoreID, p.NetworkID, nearbyRadiusM, id)
	if err != nil {
		return AgentWarehouse{}, err
	}
	w, err := pgx.CollectExactlyOneRow(rows, scanAgentWarehouse)
	if errors.Is(err, pgx.ErrNoRows) {
		return AgentWarehouse{}, apperr.NotFound("склад не найден").Uz("ombor topilmadi")
	}
	return w, err
}

// WarehouseInput — новый склад или правка: название, адрес, точка, основной.
type WarehouseInput struct {
	Name      *string  `json:"name"`
	Address   *string  `json:"address"`
	Lat       *float64 `json:"lat"`
	Lng       *float64 `json:"lng"`
	IsDefault *bool    `json:"is_default"`
	IsActive  *bool    `json:"is_active"`
}

func validPoint(lat, lng *float64) error {
	if (lat == nil) != (lng == nil) || (lat != nil && (*lat < -90 || *lat > 90 || *lng < -180 || *lng > 180)) {
		return apperr.Validation("lat, lng: поставьте точку на карте").Uz("lat, lng: xaritada nuqtani belgilang")
	}
	return nil
}

// CreateAgentWarehouse — «Новый склад» (А3): название, адрес и точка обязательны.
func (s *Service) CreateAgentWarehouse(ctx context.Context, p *identity.Principal, in WarehouseInput) (AgentWarehouse, error) {
	if err := requireDistributor(p); err != nil {
		return AgentWarehouse{}, err
	}
	name, addr := trimmed(in.Name), trimmed(in.Address)
	if name == "" {
		return AgentWarehouse{}, apperr.Validation("name: обязательное поле").Uz("name: majburiy maydon")
	}
	if addr == "" {
		return AgentWarehouse{}, apperr.Validation("address: обязательное поле").Uz("address: majburiy maydon")
	}
	if in.Lat == nil || in.Lng == nil {
		return AgentWarehouse{}, apperr.Validation("lat, lng: поставьте точку на карте").Uz("lat, lng: xaritada nuqtani belgilang")
	}
	if err := validPoint(in.Lat, in.Lng); err != nil {
		return AgentWarehouse{}, err
	}
	var out AgentWarehouse
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		pt, err := distPoint(ctx, tx, p.NetworkID)
		if err != nil {
			return err
		}
		var id string
		err = tx.QueryRow(ctx, `
			INSERT INTO warehouses (network_id, store_id, name, address, location)
			VALUES ($1, $2, $3, $4, ST_SetSRID(ST_MakePoint($6, $5), 4326)::geography) RETURNING id`,
			p.NetworkID, pt.StoreID, name, addr, *in.Lat, *in.Lng).Scan(&id)
		if db.IsUniqueViolation(err, "warehouses_store_id_name_key") {
			return apperr.Conflict("warehouse_exists", "склад с таким названием уже есть").Uz("bunday nomli ombor allaqachon bor")
		}
		if err != nil {
			return err
		}
		if in.IsDefault != nil && *in.IsDefault {
			if err := setDefaultWarehouse(ctx, tx, pt.StoreID, id); err != nil {
				return err
			}
		}
		out, err = s.agentWarehouse(ctx, tx, p, pt, id)
		return err
	})
	return out, err
}

// UpdateAgentWarehouse — правка склада; «основной» переносит точку агента туда же.
func (s *Service) UpdateAgentWarehouse(ctx context.Context, p *identity.Principal, id string, in WarehouseInput) (AgentWarehouse, error) {
	if err := requireDistributor(p); err != nil {
		return AgentWarehouse{}, err
	}
	if in.Name != nil && trimmed(in.Name) == "" {
		return AgentWarehouse{}, apperr.Validation("name: не может быть пустым").Uz("name: boʻsh boʻlishi mumkin emas")
	}
	if in.Address != nil && trimmed(in.Address) == "" {
		return AgentWarehouse{}, apperr.Validation("address: не может быть пустым").Uz("address: boʻsh boʻlishi mumkin emas")
	}
	if err := validPoint(in.Lat, in.Lng); err != nil {
		return AgentWarehouse{}, err
	}
	var out AgentWarehouse
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		pt, err := distPoint(ctx, tx, p.NetworkID)
		if err != nil {
			return err
		}
		cur, err := s.agentWarehouse(ctx, tx, p, pt, id)
		if err != nil {
			return err
		}
		if in.IsDefault != nil && !*in.IsDefault && cur.IsDefault {
			return apperr.Conflict("default_warehouse", "основной склад меняется так: сделайте основным другой").Uz("asosiy omborni almashtirish uchun boshqasini asosiy qiling")
		}
		if in.IsActive != nil && !*in.IsActive && (cur.IsDefault || (in.IsDefault != nil && *in.IsDefault)) {
			return apperr.Conflict("default_warehouse", "основной склад нельзя отключить — сначала выберите другой").Uz("asosiy omborni oʻchirib boʻlmaydi — avval boshqasini tanlang")
		}
		var name, addr *string
		if in.Name != nil {
			n := trimmed(in.Name)
			name = &n
		}
		if in.Address != nil {
			a := trimmed(in.Address)
			addr = &a
		}
		_, err = tx.Exec(ctx, `
			UPDATE warehouses SET name = COALESCE($3, name), address = COALESCE($4, address),
			       location = CASE WHEN $5::float8 IS NULL THEN location ELSE ST_SetSRID(ST_MakePoint($6, $5), 4326)::geography END,
			       is_active = COALESCE($7, is_active)
			WHERE id = $1 AND network_id = $2`, id, p.NetworkID, name, addr, in.Lat, in.Lng, in.IsActive)
		if db.IsUniqueViolation(err, "warehouses_store_id_name_key") {
			return apperr.Conflict("warehouse_exists", "склад с таким названием уже есть").Uz("bunday nomli ombor allaqachon bor")
		}
		if err != nil {
			return err
		}
		if (in.IsDefault != nil && *in.IsDefault) || cur.IsDefault {
			if err := setDefaultWarehouse(ctx, tx, pt.StoreID, id); err != nil {
				return err
			}
		}
		out, err = s.agentWarehouse(ctx, tx, p, pt, id)
		return err
	})
	return out, err
}

// setDefaultWarehouse — склад становится основным; точка агента (её видят
// магазины при поиске агентов) переезжает на место склада.
func setDefaultWarehouse(ctx context.Context, tx pgx.Tx, pointID, whID string) error {
	// Прежний основной без своей точки стоял на месте точки агента — закрепить её за ним.
	if _, err := tx.Exec(ctx, `
		UPDATE warehouses w SET location = COALESCE(w.location, s.location), address = COALESCE(NULLIF(w.address, ''), s.address)
		FROM stores s WHERE s.id = $1 AND w.id = s.default_warehouse_id AND w.id <> $2`, pointID, whID); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `
		UPDATE stores s SET default_warehouse_id = w.id,
		       location = COALESCE(w.location, s.location), address = COALESCE(NULLIF(w.address, ''), s.address)
		FROM warehouses w
		WHERE s.id = $1 AND w.id = $2 AND w.store_id = s.id AND w.is_active`, pointID, whID)
	return err
}

// WarehousesForStore — «Со склада» в расходе магазину (А4): склады агента
// с расстоянием до магазина и сколько товаров из products на складе нет.
// Подходящий (весь товар есть, ближе всех) — первым.
func (s *Service) WarehousesForStore(ctx context.Context, p *identity.Principal, storeID string, products []string) ([]AgentWarehouse, error) {
	if err := requireDistributor(p); err != nil {
		return nil, err
	}
	pt, err := distPoint(ctx, s.pool, p.NetworkID)
	if err != nil {
		return nil, err
	}
	if _, err := checkStore(ctx, s.pool, storeID); err != nil {
		return nil, err
	}
	return warehousesByStore(ctx, s.pool, p, pt, storeID, products)
}

func warehousesByStore(ctx context.Context, q db.Querier, p *identity.Principal, pt point, storeID string, products []string) ([]AgentWarehouse, error) {
	for _, id := range products {
		if !httpx.IsUUID(id) {
			return nil, apperr.Validation("products: неверный id товара").Uz("products: mahsulot id notoʻgʻri")
		}
	}
	if products == nil {
		products = []string{}
	}
	rows, err := q.Query(ctx, `
		SELECT `+whCols+`, km, missing FROM (
			SELECT y.*,
			       (SELECT round((ST_Distance(st.location, y.loc) / 1000)::numeric, 1)::float8 FROM stores st WHERE st.id = $4 AND st.location IS NOT NULL) AS km,
			       (SELECT count(*)::int FROM unnest($5::uuid[]) pid
			        WHERE NOT EXISTS (SELECT 1 FROM batches b WHERE b.warehouse_id = y.id::uuid AND b.product_id = pid AND b.qty_remaining > 0)) AS missing
			FROM (`+agentWarehouseSelect+`
			      WHERE w.store_id = $1 AND w.network_id = $2 AND w.is_active) y
		) x
		ORDER BY missing, km NULLS LAST, is_default DESC, name`, pt.StoreID, p.NetworkID, nearbyRadiusM, storeID, products)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (AgentWarehouse, error) {
		var w AgentWarehouse
		var km *float64
		var missing int
		err := row.Scan(&w.ID, &w.Name, &w.Address, &w.Lat, &w.Lng, &w.IsDefault, &w.IsActive, &w.StoresInZone, &w.Products, &w.StockCost, &km, &missing)
		w.DistanceKm, w.Missing = km, &missing
		return w, err
	})
}

// bestWarehouse — склад для расхода магазину: весь товар есть и ближе всех;
// нет такого — ближайший; совсем нет складов с точкой — основной.
func bestWarehouse(ctx context.Context, q db.Querier, pt point, storeID string, products []string) (string, error) {
	p := &identity.Principal{}
	var network string
	if err := q.QueryRow(ctx, `SELECT network_id::text FROM stores WHERE id = $1`, pt.StoreID).Scan(&network); err != nil {
		return "", err
	}
	p.NetworkID = network
	list, err := warehousesByStore(ctx, q, p, pt, storeID, products)
	if err != nil || len(list) == 0 {
		return pt.WarehouseID, err
	}
	return list[0].ID, nil
}

func trimmed(s *string) string {
	if s == nil {
		return ""
	}
	return strings.TrimSpace(*s)
}
