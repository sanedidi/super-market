// Package tenant — сети, магазины и склады.
package tenant

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/finance"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

const defaultWarehouseName = "Основной склад"

type Service struct {
	pool *pgxpool.Pool
}

func NewService(pool *pgxpool.Pool) *Service { return &Service{pool: pool} }

// ------------------------------------------------------------------ сети

type Network struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	Kind        string    `json:"kind"`
	Status      string    `json:"status"`
	OwnerName   string    `json:"owner_name"`
	OwnerPhone  string    `json:"owner_phone"`
	StoresCount int       `json:"stores_count"`
	CreatedAt   time.Time `json:"created_at"`
}

const networkSelect = `
	SELECT n.id, n.name, n.kind, n.status,
	       COALESCE(e.full_name, ''), COALESCE(u.phone, ''),
	       (SELECT count(*) FROM stores s WHERE s.network_id = n.id)::int,
	       n.created_at
	FROM networks n
	LEFT JOIN roles r     ON r.network_id = n.id AND r.is_owner
	LEFT JOIN employees e ON e.role_id = r.id
	LEFT JOIN users u     ON u.id = e.user_id`

type CreateNetworkInput struct {
	Name       string `json:"name"`
	Kind       string `json:"kind"`
	OwnerPhone string `json:"owner_phone"`
	OwnerName  string `json:"owner_name"`
}

// CreateNetwork создаёт сеть и её владельца (супер-админ).
func (s *Service) CreateNetwork(ctx context.Context, in CreateNetworkInput) (Network, error) {
	name := strings.TrimSpace(in.Name)
	if name == "" {
		return Network{}, apperr.Validation("name: обязательное поле")
	}
	if in.Kind != "chain" && in.Kind != "single" {
		return Network{}, apperr.Validation("kind: ожидается chain или single")
	}
	var out Network
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var id string
		if err := tx.QueryRow(ctx, `INSERT INTO networks (name, kind) VALUES ($1, $2) RETURNING id`,
			name, in.Kind).Scan(&id); err != nil {
			return err
		}
		if _, err := identity.CreateOwner(ctx, tx, id, in.OwnerPhone, in.OwnerName); err != nil {
			return err
		}
		if err := catalog.CreateDefaultPriceType(ctx, tx, id); err != nil {
			return err
		}
		if err := finance.CreateMainCashbox(ctx, tx, id); err != nil {
			return err
		}
		var err error
		out, err = getNetwork(ctx, tx, id)
		return err
	})
	return out, err
}

func getNetwork(ctx context.Context, q db.Querier, id string) (Network, error) {
	rows, err := q.Query(ctx, networkSelect+` WHERE n.id = $1`, id)
	if err != nil {
		return Network{}, err
	}
	n, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Network])
	if errors.Is(err, pgx.ErrNoRows) {
		return Network{}, apperr.NotFound("сеть не найдена")
	}
	return n, err
}

func (s *Service) GetNetwork(ctx context.Context, id string) (Network, error) {
	return getNetwork(ctx, s.pool, id)
}

func (s *Service) ListNetworks(ctx context.Context, search string, page httpx.Page) ([]Network, error) {
	rows, err := s.pool.Query(ctx, networkSelect+`
		WHERE $1 = '' OR n.name ILIKE '%' || $1 || '%' OR u.phone LIKE '%' || $1 || '%'
		ORDER BY n.created_at DESC LIMIT $2 OFFSET $3`,
		strings.TrimSpace(search), page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Network])
}

type UpdateNetworkInput struct {
	Name   *string `json:"name"`
	Status *string `json:"status"`
}

func (s *Service) UpdateNetwork(ctx context.Context, id string, in UpdateNetworkInput) (Network, error) {
	if in.Name != nil && strings.TrimSpace(*in.Name) == "" {
		return Network{}, apperr.Validation("name: не может быть пустым")
	}
	if in.Status != nil && *in.Status != "active" && *in.Status != "blocked" {
		return Network{}, apperr.Validation("status: ожидается active или blocked")
	}
	var name *string
	if in.Name != nil {
		n := strings.TrimSpace(*in.Name)
		name = &n
	}
	tag, err := s.pool.Exec(ctx, `
		UPDATE networks SET name = COALESCE($2, name), status = COALESCE($3, status) WHERE id = $1`,
		id, name, in.Status)
	if err != nil {
		return Network{}, err
	}
	if tag.RowsAffected() == 0 {
		return Network{}, apperr.NotFound("сеть не найдена")
	}
	return s.GetNetwork(ctx, id)
}

// -------------------------------------------------------------- магазины

type Store struct {
	ID                 string    `json:"id"`
	Name               string    `json:"name"`
	Address            string    `json:"address"`
	Phone              string    `json:"phone"`
	Lat                *float64  `json:"lat"`
	Lng                *float64  `json:"lng"`
	Status             string    `json:"status"`
	DefaultWarehouseID *string   `json:"default_warehouse_id"`
	OnlinePriceTypeID  *string   `json:"online_price_type_id"`
	CreatedAt          time.Time `json:"created_at"`
	LogoURL            string    `json:"logo_url"`
}

const storeSelect = `
	SELECT id, name, address, phone,
	       ST_Y(location::geometry), ST_X(location::geometry),
	       status, default_warehouse_id, online_price_type_id, created_at, logo_url
	FROM stores`

type StoreInput struct {
	Name               *string  `json:"name"`
	Address            *string  `json:"address"`
	Phone              *string  `json:"phone"`
	Lat                *float64 `json:"lat"`
	Lng                *float64 `json:"lng"`
	Status             *string  `json:"status"`
	DefaultWarehouseID *string  `json:"default_warehouse_id"`
	OnlinePriceTypeID  *string  `json:"online_price_type_id"`
	LogoURL            *string  `json:"logo_url"`
}

func (in StoreInput) validate() error {
	if in.Name != nil && strings.TrimSpace(*in.Name) == "" {
		return apperr.Validation("name: не может быть пустым")
	}
	if (in.Lat == nil) != (in.Lng == nil) {
		return apperr.Validation("lat и lng задаются вместе")
	}
	if in.Lat != nil && (*in.Lat < -90 || *in.Lat > 90 || *in.Lng < -180 || *in.Lng > 180) {
		return apperr.Validation("lat/lng: координаты вне диапазона")
	}
	if in.Status != nil && *in.Status != "active" && *in.Status != "inactive" {
		return apperr.Validation("status: ожидается active или inactive")
	}
	if in.DefaultWarehouseID != nil && !httpx.IsUUID(*in.DefaultWarehouseID) {
		return apperr.Validation("default_warehouse_id: склад не найден")
	}
	if in.LogoURL != nil && *in.LogoURL != "" && !strings.HasPrefix(*in.LogoURL, "https://") && !strings.HasPrefix(*in.LogoURL, "http://") {
		return apperr.Validation("logo_url: ожидается ссылка http(s)")
	}
	if in.OnlinePriceTypeID != nil && *in.OnlinePriceTypeID != "" && !httpx.IsUUID(*in.OnlinePriceTypeID) {
		return apperr.Validation("online_price_type_id: тип цены не найден")
	}
	return nil
}

func (s *Service) ListStores(ctx context.Context, p *identity.Principal) ([]Store, error) {
	rows, err := s.pool.Query(ctx, storeSelect+`
		WHERE network_id = $1 AND ($2 OR id = ANY($3::uuid[]))
		ORDER BY name`, p.NetworkID, p.SeesAllStores(), p.StoreIDs)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Store])
}

func (s *Service) GetStore(ctx context.Context, p *identity.Principal, id string) (Store, error) {
	if !p.CanAccessStore(id) {
		return Store{}, apperr.NotFound("магазин не найден")
	}
	return getStore(ctx, s.pool, p.NetworkID, id)
}

func getStore(ctx context.Context, q db.Querier, networkID, id string) (Store, error) {
	rows, err := q.Query(ctx, storeSelect+` WHERE network_id = $1 AND id = $2`, networkID, id)
	if err != nil {
		return Store{}, err
	}
	st, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Store])
	if errors.Is(err, pgx.ErrNoRows) {
		return Store{}, apperr.NotFound("магазин не найден")
	}
	return st, err
}

// CreateStore создаёт магазин и сразу его основной склад.
func (s *Service) CreateStore(ctx context.Context, p *identity.Principal, in StoreInput) (Store, error) {
	if err := p.Require(identity.PermStoresManage); err != nil {
		return Store{}, err
	}
	if in.Name == nil {
		return Store{}, apperr.Validation("name: обязательное поле")
	}
	if in.DefaultWarehouseID != nil || in.Status != nil || in.OnlinePriceTypeID != nil {
		return Store{}, apperr.Validation("status, default_warehouse_id и online_price_type_id задаются после создания")
	}
	if err := in.validate(); err != nil {
		return Store{}, err
	}

	var out Store
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		// Блокируем сеть, чтобы два параллельных запроса не создали
		// второй магазин у одиночной сети.
		var kind string
		if err := tx.QueryRow(ctx, `SELECT kind FROM networks WHERE id = $1 FOR UPDATE`, p.NetworkID).Scan(&kind); err != nil {
			return err
		}
		if kind == "single" {
			var n int
			if err := tx.QueryRow(ctx, `SELECT count(*) FROM stores WHERE network_id = $1`, p.NetworkID).Scan(&n); err != nil {
				return err
			}
			if n > 0 {
				return apperr.Conflict("store_limit", "у одиночного магазина может быть только один магазин")
			}
		}

		var id string
		if err := tx.QueryRow(ctx, `
			INSERT INTO stores (network_id, name, address, phone, location)
			VALUES ($1, $2, COALESCE($3, ''), COALESCE($4, ''),
			        CASE WHEN $5::float8 IS NULL THEN NULL
			             ELSE ST_SetSRID(ST_MakePoint($6::float8, $5::float8), 4326)::geography END)
			RETURNING id`,
			p.NetworkID, strings.TrimSpace(*in.Name), trimPtr(in.Address), trimPtr(in.Phone), in.Lat, in.Lng).Scan(&id); err != nil {
			return err
		}
		var whID string
		if err := tx.QueryRow(ctx, `
			INSERT INTO warehouses (network_id, store_id, name) VALUES ($1, $2, $3) RETURNING id`,
			p.NetworkID, id, defaultWarehouseName).Scan(&whID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE stores SET default_warehouse_id = $2 WHERE id = $1`, id, whID); err != nil {
			return err
		}
		if err := finance.CreateStoreCashbox(ctx, tx, p.NetworkID, id, strings.TrimSpace(*in.Name)); err != nil {
			return err
		}
		var err error
		out, err = getStore(ctx, tx, p.NetworkID, id)
		return err
	})
	return out, err
}

func (s *Service) UpdateStore(ctx context.Context, p *identity.Principal, id string, in StoreInput) (Store, error) {
	if err := p.Require(identity.PermStoresManage); err != nil {
		return Store{}, err
	}
	if !p.CanAccessStore(id) {
		return Store{}, apperr.NotFound("магазин не найден")
	}
	if err := in.validate(); err != nil {
		return Store{}, err
	}

	var out Store
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if in.DefaultWarehouseID != nil {
			var active bool
			err := tx.QueryRow(ctx, `SELECT is_active FROM warehouses WHERE id = $1 AND store_id = $2`,
				*in.DefaultWarehouseID, id).Scan(&active)
			if errors.Is(err, pgx.ErrNoRows) {
				return apperr.Validation("default_warehouse_id: склад не найден в этом магазине")
			}
			if err != nil {
				return err
			}
			if !active {
				return apperr.Validation("default_warehouse_id: склад отключён")
			}
		}
		if in.OnlinePriceTypeID != nil && *in.OnlinePriceTypeID != "" {
			var active bool
			err := tx.QueryRow(ctx, `SELECT is_active FROM price_types WHERE id = $1 AND network_id = $2`,
				*in.OnlinePriceTypeID, p.NetworkID).Scan(&active)
			if errors.Is(err, pgx.ErrNoRows) || (err == nil && !active) {
				return apperr.Validation("online_price_type_id: тип цены не найден или отключён")
			}
			if err != nil {
				return err
			}
		}
		setOnline := in.OnlinePriceTypeID != nil
		var online *string
		if setOnline && *in.OnlinePriceTypeID != "" {
			online = in.OnlinePriceTypeID
		}
		tag, err := tx.Exec(ctx, `
			UPDATE stores SET
				name     = COALESCE($3, name),
				address  = COALESCE($4, address),
				phone    = COALESCE($5, phone),
				location = CASE WHEN $6::float8 IS NULL THEN location
				                ELSE ST_SetSRID(ST_MakePoint($7::float8, $6::float8), 4326)::geography END,
				status   = COALESCE($8, status),
				default_warehouse_id = COALESCE($9, default_warehouse_id),
				online_price_type_id = CASE WHEN $10 THEN $11::uuid ELSE online_price_type_id END,
				logo_url = COALESCE($12, logo_url)
			WHERE id = $1 AND network_id = $2`,
			id, p.NetworkID, trimPtr(in.Name), trimPtr(in.Address), trimPtr(in.Phone),
			in.Lat, in.Lng, in.Status, in.DefaultWarehouseID, setOnline, online, trimPtr(in.LogoURL))
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.NotFound("магазин не найден")
		}
		out, err = getStore(ctx, tx, p.NetworkID, id)
		return err
	})
	return out, err
}

// ---------------------------------------------------------------- склады

type Warehouse struct {
	ID        string    `json:"id"`
	StoreID   string    `json:"store_id"`
	Name      string    `json:"name"`
	IsActive  bool      `json:"is_active"`
	IsDefault bool      `json:"is_default"`
	CreatedAt time.Time `json:"created_at"`
}

const warehouseSelect = `
	SELECT w.id, w.store_id, w.name, w.is_active, s.default_warehouse_id IS NOT DISTINCT FROM w.id, w.created_at
	FROM warehouses w JOIN stores s ON s.id = w.store_id`

// ListWarehouses — склады доступных магазинов; storeID фильтрует по магазину.
func (s *Service) ListWarehouses(ctx context.Context, p *identity.Principal, storeID string) ([]Warehouse, error) {
	if storeID != "" && (!httpx.IsUUID(storeID) || !p.CanAccessStore(storeID)) {
		return []Warehouse{}, nil
	}
	rows, err := s.pool.Query(ctx, warehouseSelect+`
		WHERE w.network_id = $1
		  AND ($2 = '' OR w.store_id::text = $2)
		  AND ($3 OR w.store_id = ANY($4::uuid[]))
		ORDER BY s.name, w.name`, p.NetworkID, storeID, p.SeesAllStores(), p.StoreIDs)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Warehouse])
}

type WarehouseInput struct {
	StoreID  *string `json:"store_id"`
	Name     *string `json:"name"`
	IsActive *bool   `json:"is_active"`
}

func (s *Service) CreateWarehouse(ctx context.Context, p *identity.Principal, in WarehouseInput) (Warehouse, error) {
	if err := p.Require(identity.PermStoresManage); err != nil {
		return Warehouse{}, err
	}
	if in.StoreID == nil || !httpx.IsUUID(*in.StoreID) || !p.CanAccessStore(*in.StoreID) {
		return Warehouse{}, apperr.Validation("store_id: магазин не найден")
	}
	if in.Name == nil || strings.TrimSpace(*in.Name) == "" {
		return Warehouse{}, apperr.Validation("name: обязательное поле")
	}
	var id string
	err := s.pool.QueryRow(ctx, `
		INSERT INTO warehouses (network_id, store_id, name) VALUES ($1, $2, $3) RETURNING id`,
		p.NetworkID, *in.StoreID, strings.TrimSpace(*in.Name)).Scan(&id)
	switch {
	case db.IsForeignKeyViolation(err):
		return Warehouse{}, apperr.Validation("store_id: магазин не найден")
	case db.IsUniqueViolation(err, "warehouses_store_id_name_key"):
		return Warehouse{}, apperr.Conflict("warehouse_exists", "склад с таким названием уже есть в магазине")
	case err != nil:
		return Warehouse{}, err
	}
	return s.getWarehouse(ctx, p, id)
}

func (s *Service) UpdateWarehouse(ctx context.Context, p *identity.Principal, id string, in WarehouseInput) (Warehouse, error) {
	if err := p.Require(identity.PermStoresManage); err != nil {
		return Warehouse{}, err
	}
	if in.StoreID != nil {
		return Warehouse{}, apperr.Validation("store_id: склад нельзя перенести в другой магазин")
	}
	if in.Name != nil && strings.TrimSpace(*in.Name) == "" {
		return Warehouse{}, apperr.Validation("name: не может быть пустым")
	}
	cur, err := s.getWarehouse(ctx, p, id)
	if err != nil {
		return Warehouse{}, err
	}
	if cur.IsDefault && in.IsActive != nil && !*in.IsActive {
		return Warehouse{}, apperr.Conflict("default_warehouse", "склад по умолчанию нельзя отключить — сначала выберите другой")
	}
	_, err = s.pool.Exec(ctx, `
		UPDATE warehouses SET name = COALESCE($3, name), is_active = COALESCE($4, is_active)
		WHERE id = $1 AND network_id = $2`, id, p.NetworkID, trimPtr(in.Name), in.IsActive)
	if db.IsUniqueViolation(err, "warehouses_store_id_name_key") {
		return Warehouse{}, apperr.Conflict("warehouse_exists", "склад с таким названием уже есть в магазине")
	}
	if err != nil {
		return Warehouse{}, err
	}
	return s.getWarehouse(ctx, p, id)
}

func (s *Service) getWarehouse(ctx context.Context, p *identity.Principal, id string) (Warehouse, error) {
	rows, err := s.pool.Query(ctx, warehouseSelect+` WHERE w.network_id = $1 AND w.id = $2`, p.NetworkID, id)
	if err != nil {
		return Warehouse{}, err
	}
	w, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Warehouse])
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !p.CanAccessStore(w.StoreID)) {
		return Warehouse{}, apperr.NotFound("склад не найден")
	}
	return w, err
}

func trimPtr(s *string) *string {
	if s == nil {
		return nil
	}
	t := strings.TrimSpace(*s)
	return &t
}
