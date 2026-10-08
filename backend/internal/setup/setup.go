// Package setup — первая настройка магазина: мастер в панели и «SM Магазин».
// Шаги: магазин (название, телефон, адрес, точка на карте), часы работы,
// доставка. Первые два обязательны — пока в сети нет магазина с точкой и
// часами, панель и приложение показывают только мастер. Доставку можно
// пропустить: тогда на главной висит чек-лист.
package setup

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/delivery"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
	"github.com/sanedidi/super-market/backend/internal/platform/phone"
	"github.com/sanedidi/super-market/backend/internal/tenant"
)

type Service struct {
	pool   *pgxpool.Pool
	tenant *tenant.Service
	dlv    *delivery.Service
}

func NewService(pool *pgxpool.Pool, t *tenant.Service, d *delivery.Service) *Service {
	return &Service{pool: pool, tenant: t, dlv: d}
}

// State — где магазин в настройке.
type State struct {
	// Required — мастер не пройден: в сети нет магазина с точкой и часами.
	Required bool `json:"required"`
	// CanSetup — сотрудник может пройти мастер (право «Магазины»).
	CanSetup bool `json:"can_setup"`
	// Store — магазин, который настраиваем (null — магазинов ещё нет).
	Store        *Store                  `json:"store"`
	WorkingHours []delivery.WorkingHours `json:"working_hours"`
	Steps        Steps                   `json:"steps"`
	Delivery     Delivery                `json:"delivery"`
	// Wishes — сколько покупателей нажали «Хочу доставку».
	Wishes int `json:"wishes"`
}

type Store struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Phone   string   `json:"phone"`
	Address string   `json:"address"`
	Lat     *float64 `json:"lat"`
	Lng     *float64 `json:"lng"`
}

// Steps — пройденные шаги; Done — все три.
type Steps struct {
	Store    bool `json:"store"`
	Hours    bool `json:"hours"`
	Delivery bool `json:"delivery"`
	Done     bool `json:"done"`
}

type Delivery struct {
	AcceptsOnline bool `json:"accepts_online"`
	// Declined — выбрано «Пока без доставки».
	Declined       bool    `json:"declined"`
	RadiusM        int     `json:"delivery_radius_m"`
	MinOrderAmount string  `json:"min_order_amount"`
	EtaMin         *int    `json:"eta_min"`
	EtaMax         *int    `json:"eta_max"`
	Fee            *string `json:"fee"`
	FreeFrom       *string `json:"free_from"`
}

// Get — состояние настройки. storeID пуст — первый доступный магазин.
func (s *Service) Get(ctx context.Context, p *identity.Principal, storeID string) (State, error) {
	if storeID != "" && (!httpx.IsUUID(storeID) || !p.CanAccessStore(storeID)) {
		return State{}, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	out := State{CanSetup: p.Can(identity.PermStoresManage), WorkingHours: []delivery.WorkingHours{}, Delivery: Delivery{MinOrderAmount: "0.00"}}
	if err := s.pool.QueryRow(ctx, `
		SELECT NOT EXISTS (SELECT 1 FROM stores WHERE network_id = $1 AND location IS NOT NULL AND hours_set_at IS NOT NULL)`,
		p.NetworkID).Scan(&out.Required); err != nil {
		return out, err
	}
	if storeID == "" {
		err := s.pool.QueryRow(ctx, `
			SELECT id FROM stores WHERE network_id = $1 AND ($2 OR id = ANY($3::uuid[]))
			ORDER BY (location IS NOT NULL AND hours_set_at IS NOT NULL) DESC, created_at, id LIMIT 1`,
			p.NetworkID, p.SeesAllStores(), p.StoreIDs).Scan(&storeID)
		if errors.Is(err, pgx.ErrNoRows) {
			return out, nil
		}
		if err != nil {
			return out, err
		}
	}
	var st Store
	var hoursSet, declined bool
	err := s.pool.QueryRow(ctx, `
		SELECT id, name, phone, address, ST_Y(location::geometry), ST_X(location::geometry),
		       hours_set_at IS NOT NULL, online_declined_at IS NOT NULL,
		       (SELECT count(*) FROM delivery_wishes w WHERE w.store_id = s.id)::int
		FROM stores s WHERE id = $1 AND network_id = $2`, storeID, p.NetworkID).
		Scan(&st.ID, &st.Name, &st.Phone, &st.Address, &st.Lat, &st.Lng, &hoursSet, &declined, &out.Wishes)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	if err != nil {
		return out, err
	}
	out.Store = &st
	set, err := s.dlv.GetSettings(ctx, p, storeID)
	if err != nil {
		return out, err
	}
	out.WorkingHours = set.WorkingHours
	out.Delivery = Delivery{AcceptsOnline: set.AcceptsOnline, Declined: declined, RadiusM: set.DeliveryRadiusM,
		MinOrderAmount: set.MinOrderAmount, EtaMin: set.EtaMin, EtaMax: set.EtaMax}
	for _, r := range set.Rules {
		var prm struct {
			Price  *string `json:"price"`
			Amount *string `json:"amount"`
		}
		_ = json.Unmarshal(r.Params, &prm)
		switch {
		case r.Type == "fixed" && out.Delivery.Fee == nil:
			out.Delivery.Fee = prm.Price
		case r.Type == "free_from" && out.Delivery.FreeFrom == nil:
			out.Delivery.FreeFrom = prm.Amount
		}
	}
	out.Steps = Steps{Store: st.Lat != nil, Hours: hoursSet, Delivery: set.AcceptsOnline || declined}
	out.Steps.Done = out.Steps.Store && out.Steps.Hours && out.Steps.Delivery
	return out, nil
}

// ------------------------------------------------------------ шаг 1

type StoreInput struct {
	StoreID string   `json:"store_id"`
	Name    string   `json:"name"`
	Phone   string   `json:"phone"`
	Address string   `json:"address"`
	Lat     *float64 `json:"lat"`
	Lng     *float64 `json:"lng"`
	// City — город точки (по геокодеру карты), для рекламы брендов по городам.
	City *string `json:"city"`
}

// SaveStore — название, телефон, адрес и точка. Без store_id создаёт первый магазин сети.
func (s *Service) SaveStore(ctx context.Context, p *identity.Principal, in StoreInput) (State, error) {
	if err := p.Require(identity.PermStoresManage); err != nil {
		return State{}, err
	}
	in.Name, in.Address, in.Phone = strings.TrimSpace(in.Name), strings.TrimSpace(in.Address), strings.TrimSpace(in.Phone)
	switch {
	case in.Name == "":
		return State{}, apperr.Validation("name: укажите название магазина").Uz("name: doʻkon nomini kiriting")
	case len([]rune(in.Name)) > 120:
		return State{}, apperr.Validation("name: не длиннее 120 символов").Uz("name: 120 belgidan oshmasin")
	case in.Address == "":
		return State{}, apperr.Validation("address: укажите адрес").Uz("address: manzilni kiriting")
	case in.Lat == nil || in.Lng == nil:
		return State{}, apperr.Validation("lat/lng: поставьте метку на карте").Uz("lat/lng: xaritada belgi qoʻying")
	}
	if in.Phone != "" {
		n, err := phone.Normalize(in.Phone)
		if err != nil {
			return State{}, apperr.Validation("phone: номер в формате +998 XX XXX XX XX").Uz("phone: raqam +998 XX XXX XX XX formatida")
		}
		in.Phone = n
	}
	body := tenant.StoreInput{Name: &in.Name, Address: &in.Address, Phone: &in.Phone, Lat: in.Lat, Lng: in.Lng, City: in.City}
	id := in.StoreID
	if id == "" {
		// Повторное нажатие «Дальше» не должно создать второй магазин.
		err := s.pool.QueryRow(ctx, `SELECT id FROM stores WHERE network_id = $1 AND ($2 OR id = ANY($3::uuid[]))
			ORDER BY created_at, id LIMIT 1`, p.NetworkID, p.SeesAllStores(), p.StoreIDs).Scan(&id)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return State{}, err
		}
	}
	if id == "" {
		st, err := s.tenant.CreateStore(ctx, p, body)
		if err != nil {
			return State{}, err
		}
		id = st.ID
	} else if _, err := s.tenant.UpdateStore(ctx, p, id, body); err != nil {
		return State{}, err
	}
	return s.Get(ctx, p, id)
}

// ------------------------------------------------------------ шаг 2

type HoursInput struct {
	StoreID string `json:"store_id"`
	// WorkingHours — пусто: круглосуточно.
	WorkingHours []delivery.WorkingHours `json:"working_hours"`
}

func (s *Service) SaveHours(ctx context.Context, p *identity.Principal, in HoursInput) (State, error) {
	if in.WorkingHours == nil {
		in.WorkingHours = []delivery.WorkingHours{}
	}
	if _, err := s.dlv.SaveSettings(ctx, p, in.StoreID, delivery.SettingsInput{WorkingHours: &in.WorkingHours}); err != nil {
		return State{}, err
	}
	return s.Get(ctx, p, in.StoreID)
}

// ------------------------------------------------------------ шаг 3

type DeliveryInput struct {
	StoreID string `json:"store_id"`
	// Mode: deliver — доставляем сами; none — пока без доставки.
	Mode           string        `json:"mode"`
	RadiusM        int           `json:"delivery_radius_m"`
	Fee            *money.Amount `json:"fee"`
	FreeFrom       *money.Amount `json:"free_from"`
	MinOrderAmount *money.Amount `json:"min_order_amount"`
	EtaMin         *int          `json:"eta_min"`
	EtaMax         *int          `json:"eta_max"`
}

func (s *Service) SaveDelivery(ctx context.Context, p *identity.Principal, in DeliveryInput) (State, error) {
	if err := p.Require(identity.PermStoresManage); err != nil {
		return State{}, err
	}
	if !httpx.IsUUID(in.StoreID) || !p.CanAccessStore(in.StoreID) {
		return State{}, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	switch in.Mode {
	case "none":
		off := false
		if _, err := s.dlv.SaveSettings(ctx, p, in.StoreID, delivery.SettingsInput{AcceptsOnline: &off}); err != nil {
			return State{}, err
		}
		if _, err := s.pool.Exec(ctx, `UPDATE stores SET online_declined_at = now() WHERE id = $1 AND network_id = $2`,
			in.StoreID, p.NetworkID); err != nil {
			return State{}, err
		}
		return s.Get(ctx, p, in.StoreID)
	case "deliver":
	default:
		return State{}, apperr.Validation("mode: ожидается deliver или none").Uz("mode: deliver yoki none boʻlishi kerak")
	}
	if in.RadiusM < 100 || in.RadiusM > 100_000 {
		return State{}, apperr.Validation("delivery_radius_m: от 100 метров до 100 км").Uz("delivery_radius_m: 100 metrdan 100 km gacha")
	}
	if in.Fee == nil {
		return State{}, apperr.Validation("fee: укажите стоимость доставки (0 — бесплатно)").Uz("fee: yetkazib berish narxini kiriting (0 — bepul)")
	}
	if (in.EtaMin == nil) != (in.EtaMax == nil) {
		return State{}, apperr.Validation("eta_min/eta_max: задаются вместе").Uz("eta_min/eta_max: birga kiritiladi")
	}
	cur, err := s.dlv.GetSettings(ctx, p, in.StoreID)
	if err != nil {
		return State{}, err
	}
	// Зоны и цену по расстоянию из раздела «Доставка» оставляем, меняем
	// только фиксированную цену и «бесплатно от».
	rules := []delivery.Rule{}
	sort := 0
	for _, r := range cur.Rules {
		if r.Type != "fixed" && r.Type != "free_from" {
			rules = append(rules, r)
			sort = max(sort, r.Sort+1)
		}
	}
	param := func(k string, v money.Amount) json.RawMessage {
		b, _ := json.Marshal(map[string]string{k: string(v)})
		return b
	}
	if in.FreeFrom != nil {
		rules = append(rules, delivery.Rule{Type: "free_from", Params: param("amount", *in.FreeFrom), Sort: sort})
		sort++
	}
	rules = append(rules, delivery.Rule{Type: "fixed", Params: param("price", *in.Fee), Sort: sort})
	on := true
	set := delivery.SettingsInput{AcceptsOnline: &on, DeliveryRadiusM: &in.RadiusM, MinOrderAmount: in.MinOrderAmount, Rules: &rules,
		EtaMin: delivery.OptInt{Set: true, Value: in.EtaMin}, EtaMax: delivery.OptInt{Set: true, Value: in.EtaMax}}
	if _, err := s.dlv.SaveSettings(ctx, p, in.StoreID, set); err != nil {
		return State{}, err
	}
	return s.Get(ctx, p, in.StoreID)
}
