// Package tenant — сети, магазины и склады.
package tenant

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/cafe"
	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/finance"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/plans"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// defaultWarehouseName — название создаётся на языке того, кто создаёт магазин.
var defaultWarehouseName = i18n.Text{RU: "Основной склад", UZ: "Asosiy ombor"}

// cafeWarehouseName — склад продуктов кафе.
var cafeWarehouseName = i18n.Text{RU: "Кухня", UZ: "Oshxona"}

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
	// Вход владельца: логин (пусто — логина ещё нет), пароль временный
	// (владелец ещё не придумал свой), когда входил последний раз.
	OwnerLogin        string     `json:"owner_login"`
	OwnerTempPassword bool       `json:"owner_temp_password"`
	OwnerPasswordAt   *time.Time `json:"owner_password_changed_at"`
	OwnerLastLoginAt  *time.Time `json:"owner_last_login_at"`
	// Тариф: выбранный и действующий сейчас (пробный, если идёт).
	PlanKey          string  `json:"plan_key"`
	PlanName         string  `json:"plan_name"`
	EffectivePlanKey string  `json:"effective_plan_key"`
	PlanTrialUntil   *string `json:"plan_trial_until"`
	// Тип бизнеса: store — магазин, cafe — кафе у прилавка, restaurant —
	// кафе со столами (в базе это cafe с режимом tables или both).
	BusinessType string `json:"business_type"`
}

const networkSelect = `
	SELECT n.id, n.name, n.kind, n.status,
	       COALESCE(e.full_name, ''), COALESCE(u.phone, ''),
	       (SELECT count(*) FROM stores s WHERE s.network_id = n.id)::int,
	       n.created_at,
	       COALESCE(el.login, ''), COALESCE(el.must_change_password, false),
	       el.password_changed_at, el.last_login_at,
	       n.plan_key, (SELECT loc(pl.name, pl.name_uz) FROM plans pl WHERE pl.key = n.plan_key), network_plan(n.id),
	       to_char(n.plan_trial_until, 'YYYY-MM-DD'),
	       CASE WHEN n.business_type = 'cafe' AND n.cafe_mode <> 'counter' THEN 'restaurant' ELSE n.business_type END
	FROM networks n
	LEFT JOIN roles r     ON r.network_id = n.id AND r.is_owner
	LEFT JOIN employees e ON e.role_id = r.id
	LEFT JOIN users u     ON u.id = e.user_id
	LEFT JOIN employee_logins el ON el.employee_id = e.id`

type CreateNetworkInput struct {
	Name       string `json:"name"`
	Kind       string `json:"kind"`
	OwnerPhone string `json:"owner_phone"`
	OwnerName  string `json:"owner_name"`
	// Логин и временный пароль владельца для панели и «SM Магазин».
	OwnerLogin    string `json:"owner_login"`
	OwnerPassword string `json:"owner_password"`
	// Тариф сети; пусто — одиночному «Бесплатный» (с пробным периодом),
	// сети магазинов — «Сеть».
	PlanKey string `json:"plan_key"`
	// Тип бизнеса: store (по умолчанию), cafe или restaurant (кафе со
	// столами). Кафе — только у сети магазинов или одиночного магазина, не у агента.
	BusinessType string `json:"business_type"`
}

// CreateNetwork создаёт сеть и её владельца (супер-админ).
func (s *Service) CreateNetwork(ctx context.Context, in CreateNetworkInput) (Network, error) {
	name := strings.TrimSpace(in.Name)
	if name == "" {
		return Network{}, apperr.Validation("name: обязательное поле").Uz("name: majburiy maydon")
	}
	if in.Kind != "chain" && in.Kind != "single" && in.Kind != "distributor" {
		return Network{}, apperr.Validation("kind: ожидается chain, single или distributor").Uz("kind: chain, single yoki distributor boʻlishi kerak")
	}
	if in.BusinessType == "" {
		in.BusinessType = cafe.BusinessStore
	}
	if err := checkBusinessType(in.Kind, in.BusinessType); err != nil {
		return Network{}, err
	}
	login, hash, err := identity.PrepareOwnerLogin(identity.LoginInput{Login: in.OwnerLogin, Password: in.OwnerPassword})
	if err != nil {
		return Network{}, err
	}
	var out Network
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var id string
		planKey := strings.TrimSpace(in.PlanKey)
		if planKey == "" && in.Kind == "distributor" {
			// Агенту — тариф новых агентов из настроек биллинга.
			if err := tx.QueryRow(ctx, `SELECT agent_plan FROM billing_settings WHERE id = 1`).Scan(&planKey); err != nil {
				return err
			}
		}
		if planKey == "" {
			planKey = map[string]string{"single": "free", "chain": "network"}[in.Kind]
		}
		if p, err := plans.Get(ctx, tx, planKey); err != nil || !p.IsActive {
			return apperr.Validation("plan_key: тариф не найден").Uz("plan_key: tarif topilmadi")
		} else if p.Audience != plans.AudienceOf(in.Kind) {
			return apperr.Validation("plan_key: тариф для другого вида сетей (магазины / агенты)").Uz("plan_key: tarif boshqa turdagi tarmoqlar uchun (doʻkonlar / agentlar)")
		}
		bt, mode := businessOf(in.BusinessType)
		if err := tx.QueryRow(ctx, `INSERT INTO networks (name, kind, plan_key, business_type, cafe_mode) VALUES ($1, $2, $3, $4, COALESCE(NULLIF($5, ''), 'counter')) RETURNING id`,
			name, in.Kind, planKey, bt, mode).Scan(&id); err != nil {
			return err
		}
		if bt == cafe.BusinessCafe {
			// Новое кафе сразу получает цех «Кухня».
			if err := cafe.EnsureDefaults(ctx, tx, id); err != nil {
				return err
			}
		}
		ownerID, err := identity.CreateOwner(ctx, tx, id, in.OwnerPhone, in.OwnerName)
		if err != nil {
			return err
		}
		if err := identity.CreateOwnerLogin(ctx, tx, ownerID, id, login, hash); err != nil {
			return err
		}
		if err := catalog.CreateDefaultPriceType(ctx, tx, id); err != nil {
			return err
		}
		if err := finance.CreateMainCashbox(ctx, tx, id); err != nil {
			return err
		}
		// Новая сеть начинает с пробного периода (тариф и срок — в настройках биллинга).
		if err := plans.StartTrial(ctx, tx, id); err != nil {
			return err
		}
		out, err = getNetwork(ctx, tx, id)
		return err
	})
	return out, err
}

// UpdateOwner — супер-админ меняет имя или телефон владельца сети.
func (s *Service) UpdateOwner(ctx context.Context, id string, in identity.OwnerInput) (Network, error) {
	if err := identity.UpdateOwner(ctx, s.pool, id, in); err != nil {
		return Network{}, err
	}
	return s.GetNetwork(ctx, id)
}

// SetOwnerLogin — супер-админ задаёт логин владельца или сбрасывает пароль.
func (s *Service) SetOwnerLogin(ctx context.Context, id string, in identity.LoginInput) (Network, error) {
	if _, err := identity.SetOwnerLogin(ctx, s.pool, id, in); err != nil {
		return Network{}, err
	}
	return s.GetNetwork(ctx, id)
}

func getNetwork(ctx context.Context, q db.Querier, id string) (Network, error) {
	rows, err := q.Query(ctx, networkSelect+` WHERE n.id = $1`, id)
	if err != nil {
		return Network{}, err
	}
	n, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Network])
	if errors.Is(err, pgx.ErrNoRows) {
		return Network{}, apperr.NotFound("сеть не найдена").Uz("tarmoq topilmadi")
	}
	return n, err
}

func (s *Service) GetNetwork(ctx context.Context, id string) (Network, error) {
	return getNetwork(ctx, s.pool, id)
}

// EmployeeBrief — имя, телефон и роль сотрудника (для «Кто вошёл» в приложении магазина).
type EmployeeBrief struct {
	FullName string
	Phone    string
	RoleName string
}

func (s *Service) EmployeeBrief(ctx context.Context, employeeID string) (EmployeeBrief, error) {
	var b EmployeeBrief
	err := s.pool.QueryRow(ctx, `
		SELECT e.full_name, u.phone, r.name
		FROM employees e
		JOIN users u ON u.id = e.user_id
		JOIN roles r ON r.id = e.role_id
		WHERE e.id = $1`, employeeID).Scan(&b.FullName, &b.Phone, &b.RoleName)
	return b, err
}

func (s *Service) ListNetworks(ctx context.Context, search string, page httpx.Page) ([]Network, error) {
	rows, err := s.pool.Query(ctx, networkSelect+`
		WHERE $1 = '' OR n.name ILIKE '%' || $1 || '%' OR u.phone LIKE '%' || $1 || '%' OR el.login = lower($1)
		ORDER BY n.created_at DESC, n.id LIMIT $2 OFFSET $3`,
		strings.TrimSpace(search), page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Network])
}

type UpdateNetworkInput struct {
	Name   *string `json:"name"`
	Status *string `json:"status"`
	// Тип бизнеса меняет только супер-админ.
	BusinessType *string `json:"business_type"`
}

// businessRestaurant — ресторан: кафе со столами и официантами (режим кафе
// «со столами»; владелец может переключить на «столы + с собой» в панели).
const businessRestaurant = "restaurant"

// businessOf — тип бизнеса в базе и режим кафе (” — не менять).
func businessOf(in string) (string, string) {
	switch in {
	case businessRestaurant:
		return cafe.BusinessCafe, "tables"
	case cafe.BusinessCafe:
		return cafe.BusinessCafe, "counter"
	}
	return in, ""
}

func checkBusinessType(kind, bt string) error {
	if bt != cafe.BusinessStore && bt != cafe.BusinessCafe && bt != businessRestaurant {
		return apperr.Validation("business_type: ожидается store, cafe или restaurant").Uz("business_type: store, cafe yoki restaurant boʻlishi kerak")
	}
	if bt != cafe.BusinessStore && kind == "distributor" {
		return apperr.Validation("business_type: агент не может быть кафе").Uz("business_type: agent kafe boʻla olmaydi")
	}
	return nil
}

func (s *Service) UpdateNetwork(ctx context.Context, id string, in UpdateNetworkInput) (Network, error) {
	if in.Name != nil && strings.TrimSpace(*in.Name) == "" {
		return Network{}, apperr.Validation("name: не может быть пустым").Uz("name: boʻsh boʻlishi mumkin emas")
	}
	if in.Status != nil && *in.Status != "active" && *in.Status != "blocked" {
		return Network{}, apperr.Validation("status: ожидается active или blocked").Uz("status: active yoki blocked boʻlishi kerak")
	}
	var name *string
	if in.Name != nil {
		n := strings.TrimSpace(*in.Name)
		name = &n
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var kind string
		err := tx.QueryRow(ctx, `SELECT kind FROM networks WHERE id = $1 FOR UPDATE`, id).Scan(&kind)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.NotFound("сеть не найдена").Uz("tarmoq topilmadi")
		}
		if err != nil {
			return err
		}
		if in.BusinessType != nil {
			if err := checkBusinessType(kind, *in.BusinessType); err != nil {
				return err
			}
			bt, mode := businessOf(*in.BusinessType)
			if bt == cafe.BusinessCafe {
				if err := cafe.EnsureDefaults(ctx, tx, id); err != nil {
					return err
				}
			}
			// Кафе ↔ ресторан — режим кассы: у прилавка или со столами. Режим
			// «столы + с собой», выбранный владельцем, ресторан не сбрасывает.
			if _, err := tx.Exec(ctx, `
				UPDATE networks SET business_type = $2,
				       cafe_mode = CASE WHEN $3 = 'counter' THEN 'counter'
				                        WHEN $3 = 'tables' AND cafe_mode = 'counter' THEN 'tables'
				                        ELSE cafe_mode END
				WHERE id = $1`, id, bt, mode); err != nil {
				return err
			}
		}
		_, err = tx.Exec(ctx, `
			UPDATE networks SET name = COALESCE($2, name), status = COALESCE($3, status) WHERE id = $1`,
			id, name, in.Status)
		return err
	})
	if err != nil {
		return Network{}, err
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
	City               string    `json:"city"`
}

const storeSelect = `
	SELECT id, name, address, phone,
	       ST_Y(location::geometry), ST_X(location::geometry),
	       status, default_warehouse_id, online_price_type_id, created_at, logo_url, city
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
	City               *string  `json:"city"`
}

func (in StoreInput) validate() error {
	if in.Name != nil && strings.TrimSpace(*in.Name) == "" {
		return apperr.Validation("name: не может быть пустым").Uz("name: boʻsh boʻlishi mumkin emas")
	}
	if (in.Lat == nil) != (in.Lng == nil) {
		return apperr.Validation("lat и lng задаются вместе").Uz("lat va lng birga kiritiladi")
	}
	if in.Lat != nil && (*in.Lat < -90 || *in.Lat > 90 || *in.Lng < -180 || *in.Lng > 180) {
		return apperr.Validation("lat/lng: координаты вне диапазона").Uz("lat/lng: koordinatalar ruxsat etilgan oraliqdan tashqarida")
	}
	if in.Status != nil && *in.Status != "active" && *in.Status != "inactive" {
		return apperr.Validation("status: ожидается active или inactive").Uz("status: active yoki inactive boʻlishi kerak")
	}
	if in.DefaultWarehouseID != nil && !httpx.IsUUID(*in.DefaultWarehouseID) {
		return apperr.Validation("default_warehouse_id: склад не найден").Uz("default_warehouse_id: ombor topilmadi")
	}
	if in.City != nil && len([]rune(strings.TrimSpace(*in.City))) > 60 {
		return apperr.Validation("city: не длиннее 60 символов").Uz("city: 60 belgidan oshmasin")
	}
	if in.LogoURL != nil && *in.LogoURL != "" && !strings.HasPrefix(*in.LogoURL, "https://") && !strings.HasPrefix(*in.LogoURL, "http://") {
		return apperr.Validation("logo_url: ожидается ссылка http(s)").Uz("logo_url: http(s) havola boʻlishi kerak")
	}
	if in.OnlinePriceTypeID != nil && *in.OnlinePriceTypeID != "" && !httpx.IsUUID(*in.OnlinePriceTypeID) {
		return apperr.Validation("online_price_type_id: тип цены не найден").Uz("online_price_type_id: narx turi topilmadi")
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

// AdminListStores — магазины сети для супер-админа (карточка сети, фильтр заказов).
func (s *Service) AdminListStores(ctx context.Context, networkID string) ([]Store, error) {
	if _, err := s.GetNetwork(ctx, networkID); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, storeSelect+` WHERE network_id = $1 ORDER BY name, id`, networkID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Store])
}

func (s *Service) GetStore(ctx context.Context, p *identity.Principal, id string) (Store, error) {
	if !p.CanAccessStore(id) {
		return Store{}, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
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
		return Store{}, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	return st, err
}

// CreateStore создаёт магазин и сразу его основной склад.
func (s *Service) CreateStore(ctx context.Context, p *identity.Principal, in StoreInput) (Store, error) {
	if err := p.Require(identity.PermStoresManage); err != nil {
		return Store{}, err
	}
	if in.Name == nil {
		return Store{}, apperr.Validation("name: обязательное поле").Uz("name: majburiy maydon")
	}
	if in.DefaultWarehouseID != nil || in.Status != nil || in.OnlinePriceTypeID != nil {
		return Store{}, apperr.Validation("status, default_warehouse_id и online_price_type_id задаются после создания").Uz("status, default_warehouse_id va online_price_type_id yaratilgandan keyin kiritiladi")
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
		// У дистрибьютора, как у одиночного магазина, одна точка (его склад).
		if kind == "single" || kind == "distributor" {
			var n int
			if err := tx.QueryRow(ctx, `SELECT count(*) FROM stores WHERE network_id = $1`, p.NetworkID).Scan(&n); err != nil {
				return err
			}
			if n > 0 {
				return apperr.Conflict("store_limit", "у одиночного магазина может быть только один магазин").Uz("yakka doʻkonda faqat bitta doʻkon boʻlishi mumkin")
			}
		}
		// Сколько магазинов можно — по тарифу сети.
		if err := plans.CheckAdd(ctx, tx, p.NetworkID, plans.LimitStores); err != nil {
			return err
		}

		var id string
		if err := tx.QueryRow(ctx, `
			INSERT INTO stores (network_id, name, address, phone, location, city)
			VALUES ($1, $2, COALESCE($3, ''), COALESCE($4, ''),
			        CASE WHEN $5::float8 IS NULL THEN NULL
			             ELSE ST_SetSRID(ST_MakePoint($6::float8, $5::float8), 4326)::geography END, COALESCE($7, ''))
			RETURNING id`,
			p.NetworkID, strings.TrimSpace(*in.Name), trimPtr(in.Address), trimPtr(in.Phone), in.Lat, in.Lng, trimPtr(in.City)).Scan(&id); err != nil {
			return err
		}
		// Склад по умолчанию; у кафе — «Кухня» (склад продуктов).
		whName := defaultWarehouseName
		var bt string
		if err := tx.QueryRow(ctx, `SELECT business_type FROM networks WHERE id = $1`, p.NetworkID).Scan(&bt); err != nil {
			return err
		}
		if bt == cafe.BusinessCafe {
			whName = cafeWarehouseName
		}
		var whID string
		if err := tx.QueryRow(ctx, `
			INSERT INTO warehouses (network_id, store_id, name) VALUES ($1, $2, $3) RETURNING id`,
			p.NetworkID, id, whName.Ctx(ctx)).Scan(&whID); err != nil {
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
		return Store{}, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
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
				return apperr.Validation("default_warehouse_id: склад не найден в этом магазине").Uz("default_warehouse_id: ombor bu doʻkonda topilmadi")
			}
			if err != nil {
				return err
			}
			if !active {
				return apperr.Validation("default_warehouse_id: склад отключён").Uz("default_warehouse_id: ombor oʻchirilgan")
			}
		}
		if in.OnlinePriceTypeID != nil && *in.OnlinePriceTypeID != "" {
			var active bool
			err := tx.QueryRow(ctx, `SELECT is_active FROM price_types WHERE id = $1 AND network_id = $2`,
				*in.OnlinePriceTypeID, p.NetworkID).Scan(&active)
			if errors.Is(err, pgx.ErrNoRows) || (err == nil && !active) {
				return apperr.Validation("online_price_type_id: тип цены не найден или отключён").Uz("online_price_type_id: narx turi topilmadi yoki oʻchirilgan")
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
				logo_url = COALESCE($12, logo_url),
				city     = COALESCE($13, city)
			WHERE id = $1 AND network_id = $2`,
			id, p.NetworkID, trimPtr(in.Name), trimPtr(in.Address), trimPtr(in.Phone),
			in.Lat, in.Lng, in.Status, in.DefaultWarehouseID, setOnline, online, trimPtr(in.LogoURL), trimPtr(in.City))
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
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
		return Warehouse{}, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	if in.Name == nil || strings.TrimSpace(*in.Name) == "" {
		return Warehouse{}, apperr.Validation("name: обязательное поле").Uz("name: majburiy maydon")
	}
	var id string
	err := s.pool.QueryRow(ctx, `
		INSERT INTO warehouses (network_id, store_id, name) VALUES ($1, $2, $3) RETURNING id`,
		p.NetworkID, *in.StoreID, strings.TrimSpace(*in.Name)).Scan(&id)
	switch {
	case db.IsForeignKeyViolation(err):
		return Warehouse{}, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	case db.IsUniqueViolation(err, "warehouses_store_id_name_key"):
		return Warehouse{}, apperr.Conflict("warehouse_exists", "склад с таким названием уже есть в магазине").Uz("doʻkonda bunday nomli ombor allaqachon bor")
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
		return Warehouse{}, apperr.Validation("store_id: склад нельзя перенести в другой магазин").Uz("store_id: omborni boshqa doʻkonga koʻchirib boʻlmaydi")
	}
	if in.Name != nil && strings.TrimSpace(*in.Name) == "" {
		return Warehouse{}, apperr.Validation("name: не может быть пустым").Uz("name: boʻsh boʻlishi mumkin emas")
	}
	cur, err := s.getWarehouse(ctx, p, id)
	if err != nil {
		return Warehouse{}, err
	}
	if cur.IsDefault && in.IsActive != nil && !*in.IsActive {
		return Warehouse{}, apperr.Conflict("default_warehouse", "склад по умолчанию нельзя отключить — сначала выберите другой").Uz("asosiy omborni oʻchirib boʻlmaydi — avval boshqasini tanlang")
	}
	_, err = s.pool.Exec(ctx, `
		UPDATE warehouses SET name = COALESCE($3, name), is_active = COALESCE($4, is_active)
		WHERE id = $1 AND network_id = $2`, id, p.NetworkID, trimPtr(in.Name), in.IsActive)
	if db.IsUniqueViolation(err, "warehouses_store_id_name_key") {
		return Warehouse{}, apperr.Conflict("warehouse_exists", "склад с таким названием уже есть в магазине").Uz("doʻkonda bunday nomli ombor allaqachon bor")
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
		return Warehouse{}, apperr.NotFound("склад не найден").Uz("ombor topilmadi")
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
