package plans

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Plan — тариф как его хранит и правит супер-админ.
type Plan struct {
	Key             string         `json:"key"`
	Name            string         `json:"name"`
	NameUz          string         `json:"name_uz"`
	Description     string         `json:"description"`
	DescriptionUz   string         `json:"description_uz"`
	PriceUZS        string         `json:"price_uzs"`
	MinStores       int            `json:"min_stores"`
	OrderCommission string         `json:"order_commission"`
	Features        []string       `json:"features"`
	Limits          map[string]int `json:"limits"` // ключа нет — без лимита
	IsPublic        bool           `json:"is_public"`
	IsActive        bool           `json:"is_active"`
	Recommended     bool           `json:"recommended"`
	Sort            int            `json:"sort"`
	UpdatedAt       time.Time      `json:"updated_at"`
	// Сколько сетей на этом тарифе (выбран, не пробный).
	NetworksCount int `json:"networks_count"`
}

// Has — функция входит в тариф.
func (p Plan) Has(feature string) bool { return slices.Contains(p.Features, feature) }

// Limit — лимит тарифа; nil — без лимита. Для лимитов с умолчанием
// (реклама) отсутствие ключа — значение по умолчанию.
func (p Plan) Limit(key string) *int {
	if v, ok := p.Limits[key]; ok {
		return &v
	}
	if l, ok := limitInfo(key); ok && l.Default != nil {
		v := *l.Default
		return &v
	}
	return nil
}

// Allowed — лимит числом (без лимита — очень много).
func (p Plan) Allowed(key string) int {
	if v := p.Limit(key); v != nil {
		return *v
	}
	return 1 << 30
}

// Title — название на языке запроса.
func (p Plan) Title(ctx context.Context) string { return i18n.T(ctx, p.Name, p.NameUz) }

const planSelect = `SELECT p.key, p.name, p.name_uz, p.description, p.description_uz, p.price_uzs::text, p.min_stores,
	p.order_commission::text, p.features, p.limits, p.is_public, p.is_active, p.recommended, p.sort, p.updated_at,
	(SELECT count(*) FROM networks n WHERE n.plan_key = p.key)::int
	FROM plans p`

func scan(r pgx.CollectableRow) (Plan, error) {
	var p Plan
	err := r.Scan(&p.Key, &p.Name, &p.NameUz, &p.Description, &p.DescriptionUz, &p.PriceUZS, &p.MinStores,
		&p.OrderCommission, &p.Features, &p.Limits, &p.IsPublic, &p.IsActive, &p.Recommended, &p.Sort, &p.UpdatedAt,
		&p.NetworksCount)
	if p.Features == nil {
		p.Features = []string{}
	}
	if p.Limits == nil {
		p.Limits = map[string]int{}
	}
	return p, err
}

// List — тарифы по порядку; public — только действующие и открытые
// (сайт и панель магазина).
func List(ctx context.Context, q db.Querier, public bool) ([]Plan, error) {
	rows, err := q.Query(ctx, planSelect+` WHERE NOT $1 OR (p.is_active AND p.is_public) ORDER BY p.sort, p.key`, public)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scan)
}

// Get — тариф по ключу.
func Get(ctx context.Context, q db.Querier, key string) (Plan, error) {
	rows, err := q.Query(ctx, planSelect+` WHERE p.key = $1`, key)
	if err != nil {
		return Plan{}, err
	}
	p, err := pgx.CollectExactlyOneRow(rows, scan)
	if errors.Is(err, pgx.ErrNoRows) {
		return p, apperr.NotFound("тариф не найден").Uz("tarif topilmadi")
	}
	return p, err
}

// ------------------------------------------------------------ правка

// Input — создание и правка тарифа супер-админом. Поле не передано — не
// меняется. Features и Limits заменяются целиком; в Limits null — без лимита.
type Input struct {
	Key             *string          `json:"key"` // только при создании
	Name            *string          `json:"name"`
	NameUz          *string          `json:"name_uz"`
	Description     *string          `json:"description"`
	DescriptionUz   *string          `json:"description_uz"`
	PriceUZS        *money.Amount    `json:"price_uzs"`
	MinStores       *int             `json:"min_stores"`
	OrderCommission *money.Amount    `json:"order_commission"`
	Features        *[]string        `json:"features"`
	Limits          *map[string]*int `json:"limits"`
	IsPublic        *bool            `json:"is_public"`
	IsActive        *bool            `json:"is_active"`
	Recommended     *bool            `json:"recommended"`
	Sort            *int             `json:"sort"`
}

func trimPtr(p *string) *string {
	if p == nil {
		return nil
	}
	v := strings.TrimSpace(*p)
	return &v
}

func amountPtr(a *money.Amount) *string {
	if a == nil {
		return nil
	}
	v := string(*a)
	return &v
}

func (in Input) validate() (features []string, limits map[string]int, err error) {
	if in.Name != nil && strings.TrimSpace(*in.Name) == "" {
		return nil, nil, apperr.Validation("name: обязательное поле").Uz("name: majburiy maydon")
	}
	if in.PriceUZS != nil && money.D(string(*in.PriceUZS)).Sign() < 0 {
		return nil, nil, apperr.Validation("price_uzs: не меньше нуля").Uz("price_uzs: noldan kichik boʻlmasin")
	}
	if in.MinStores != nil && (*in.MinStores < 1 || *in.MinStores > 1000) {
		return nil, nil, apperr.Validation("min_stores: от 1 до 1000").Uz("min_stores: 1 dan 1000 gacha")
	}
	if in.OrderCommission != nil {
		c := money.D(string(*in.OrderCommission))
		if c.Sign() < 0 || c.Cmp(money.D("50")) > 0 {
			return nil, nil, apperr.Validation("order_commission: от 0 до 50 %").Uz("order_commission: 0 dan 50 % gacha")
		}
	}
	if in.Features != nil {
		features = []string{}
		for _, f := range *in.Features {
			if _, ok := featureInfo(f); !ok {
				return nil, nil, apperr.Validation("features: неизвестная функция " + f).Uz("features: nomaʼlum funksiya " + f)
			}
			if !slices.Contains(features, f) {
				features = append(features, f)
			}
		}
	}
	if in.Limits != nil {
		limits = map[string]int{}
		for k, v := range *in.Limits {
			l, ok := limitInfo(k)
			if !ok {
				return nil, nil, apperr.Validation("limits: неизвестный лимит " + k).Uz("limits: nomaʼlum limit " + k)
			}
			if v == nil || *v < 0 {
				continue // без лимита
			}
			if *v > 100000 || (l.Max > 0 && *v > l.Max) {
				return nil, nil, apperr.Validation(fmt.Sprintf("limits.%s: слишком большое значение", k)).Uz(fmt.Sprintf("limits.%s: qiymat juda katta", k))
			}
			limits[k] = *v
		}
	}
	return features, limits, nil
}

// Create — новый тариф.
func Create(ctx context.Context, q db.Querier, in Input) (Plan, error) {
	if in.Key == nil || in.Name == nil {
		return Plan{}, apperr.Validation("key и name обязательны").Uz("key va name majburiy")
	}
	key := strings.TrimSpace(*in.Key)
	if !validKey(key) {
		return Plan{}, apperr.Validation("key: латиница в нижнем регистре, цифры и _, от 2 до 31 символа").Uz("key: kichik lotin harflari, raqamlar va _, 2 dan 31 belgigacha")
	}
	if _, _, err := in.validate(); err != nil {
		return Plan{}, err
	}
	_, err := q.Exec(ctx, `INSERT INTO plans (key, name, sort) VALUES ($1, $2, COALESCE((SELECT max(sort) + 1 FROM plans), 0))`,
		key, strings.TrimSpace(*in.Name))
	if db.IsUniqueViolation(err, "plans_pkey") {
		return Plan{}, apperr.Conflict("plan_exists", "тариф с таким ключом уже есть").Uz("bunday kalitli tarif allaqachon bor")
	}
	if err != nil {
		return Plan{}, err
	}
	in.Key = nil
	return Update(ctx, q, key, in)
}

func validKey(k string) bool {
	if len(k) < 2 || len(k) > 31 || k[0] < 'a' || k[0] > 'z' {
		return false
	}
	for _, c := range k {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_') {
			return false
		}
	}
	return true
}

// Update — правка тарифа. Цена действует со следующего счёта, функции и
// лимиты — сразу.
func Update(ctx context.Context, q db.Querier, key string, in Input) (Plan, error) {
	cur, err := Get(ctx, q, key)
	if err != nil {
		return Plan{}, err
	}
	features, limits, err := in.validate()
	if err != nil {
		return Plan{}, err
	}
	if in.IsActive != nil && !*in.IsActive && cur.IsActive {
		var trial bool
		if err := q.QueryRow(ctx, `SELECT trial_plan = $1 FROM billing_settings WHERE id = 1`, key).Scan(&trial); err != nil {
			return Plan{}, err
		}
		if trial {
			return Plan{}, apperr.Conflict("trial_plan", "это тариф пробного периода — сначала выберите другой в настройках биллинга").Uz("bu sinov davri tarifi — avval biling sozlamalarida boshqasini tanlang")
		}
	}
	if in.Recommended != nil && *in.Recommended {
		if _, err := q.Exec(ctx, `UPDATE plans SET recommended = false WHERE key <> $1`, key); err != nil {
			return Plan{}, err
		}
	}
	var limitsArg any
	if limits != nil {
		limitsArg = limits
	}
	if _, err := q.Exec(ctx, `
		UPDATE plans SET
			name = COALESCE($2, name), name_uz = COALESCE($3, name_uz),
			description = COALESCE($4, description), description_uz = COALESCE($5, description_uz),
			price_uzs = COALESCE($6::numeric, price_uzs), min_stores = COALESCE($7, min_stores),
			order_commission = COALESCE($8::numeric, order_commission),
			features = COALESCE($9::text[], features), limits = COALESCE($10::jsonb, limits),
			is_public = COALESCE($11, is_public), is_active = COALESCE($12, is_active),
			recommended = COALESCE($13, recommended), sort = COALESCE($14, sort), updated_at = now()
		WHERE key = $1`,
		key, trimPtr(in.Name), trimPtr(in.NameUz), trimPtr(in.Description), trimPtr(in.DescriptionUz),
		amountPtr(in.PriceUZS), in.MinStores, amountPtr(in.OrderCommission), features, limitsArg,
		in.IsPublic, in.IsActive, in.Recommended, in.Sort); err != nil {
		return Plan{}, err
	}
	return Get(ctx, q, key)
}

// Delete удаляет тариф, на котором нет ни одной сети и который не
// пробный; иначе его можно только убрать в архив.
func Delete(ctx context.Context, q db.Querier, key string) error {
	p, err := Get(ctx, q, key)
	if err != nil {
		return err
	}
	var trial bool
	if err := q.QueryRow(ctx, `SELECT trial_plan = $1 FROM billing_settings WHERE id = 1`, key).Scan(&trial); err != nil {
		return err
	}
	if p.NetworksCount > 0 || trial {
		return apperr.Conflict("plan_in_use", "на тарифе есть сети или он пробный — уберите его в архив").Uz("tarifda tarmoqlar bor yoki u sinov tarifi — uni arxivga oʻtkazing").
			WithDetails(map[string]any{"networks_count": p.NetworksCount})
	}
	_, err = q.Exec(ctx, `DELETE FROM plans WHERE key = $1`, key)
	return err
}

// ------------------------------------------------------------- сеть

// Network — тариф сети: выбранный, действующий сейчас (с учётом
// пробного периода), до какого числа пробный и индивидуальная цена.
type Network struct {
	Chosen         Plan    `json:"chosen"`
	Effective      Plan    `json:"effective"`
	TrialPlan      string  `json:"trial_plan"`
	TrialUntil     *string `json:"trial_until"`
	InTrial        bool    `json:"in_trial"`
	CustomPriceUZS *string `json:"custom_price_uzs"`
}

// ForNetwork — тариф сети.
func ForNetwork(ctx context.Context, q db.Querier, networkID string) (Network, error) {
	var out Network
	var chosen, effective string
	var until *time.Time
	if !isUUID(networkID) {
		return out, apperr.NotFound("сеть не найдена").Uz("tarmoq topilmadi")
	}
	err := q.QueryRow(ctx, `
		SELECT n.plan_key, network_plan(n.id), n.plan_trial_until, bs.trial_plan, n.custom_price_uzs::text
		FROM networks n CROSS JOIN billing_settings bs WHERE n.id = $1`, networkID).
		Scan(&chosen, &effective, &until, &out.TrialPlan, &out.CustomPriceUZS)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, apperr.NotFound("сеть не найдена").Uz("tarmoq topilmadi")
	}
	if err != nil {
		return out, err
	}
	if out.Chosen, err = Get(ctx, q, chosen); err != nil {
		return out, err
	}
	out.Effective = out.Chosen
	if effective != chosen {
		if out.Effective, err = Get(ctx, q, effective); err != nil {
			return out, err
		}
		out.InTrial = true
	}
	if until != nil {
		s := until.Format("2006-01-02")
		out.TrialUntil = &s
	}
	return out, nil
}

// Effective — действующий тариф сети.
func Effective(ctx context.Context, q db.Querier, networkID string) (Plan, error) {
	if !isUUID(networkID) {
		return Plan{}, apperr.NotFound("сеть не найдена").Uz("tarmoq topilmadi")
	}
	var key *string
	if err := q.QueryRow(ctx, `SELECT network_plan($1::uuid)`, networkID).Scan(&key); err != nil {
		return Plan{}, err
	}
	if key == nil {
		return Plan{}, apperr.NotFound("сеть не найдена").Uz("tarmoq topilmadi")
	}
	return Get(ctx, q, *key)
}

func isUUID(s string) bool { return httpx.IsUUID(s) }

// StartTrial начинает пробный период новой сети, если он включён и
// пробный тариф выше выбранного.
func StartTrial(ctx context.Context, q db.Querier, networkID string) error {
	_, err := q.Exec(ctx, `
		UPDATE networks n SET plan_trial_until = (now() AT TIME ZONE 'Asia/Tashkent')::date + bs.trial_days - 1
		FROM billing_settings bs
		WHERE n.id = $1 AND n.plan_trial_until IS NULL AND bs.trial_days > 0
		  AND (SELECT sort FROM plans WHERE key = bs.trial_plan) > (SELECT sort FROM plans WHERE key = n.plan_key)`, networkID)
	return err
}

// Choose — сеть сама переходит на другой тариф: только на действующий
// открытый и если магазинов не меньше, чем требует тариф. Плата войдёт в
// ближайший счёт за подписку; функции меняются сразу.
func Choose(ctx context.Context, q db.Querier, networkID, key string) (Network, error) {
	p, err := Get(ctx, q, key)
	if err != nil {
		return Network{}, err
	}
	if !p.IsActive || !p.IsPublic {
		return Network{}, apperr.NotFound("тариф не найден").Uz("tarif topilmadi")
	}
	var stores int
	if err := q.QueryRow(ctx, `SELECT count(*) FROM stores WHERE network_id = $1 AND status = 'active'`, networkID).Scan(&stores); err != nil {
		return Network{}, err
	}
	if stores < p.MinStores {
		return Network{}, apperr.Conflict("plan_min_stores",
			fmt.Sprintf("тариф «%s» — для сетей от %d магазинов", p.Name, p.MinStores)).
			Uz(fmt.Sprintf("«%s» tarifi — %d ta va undan koʻp doʻkonli tarmoqlar uchun", p.NameUz, p.MinStores)).
			WithDetails(map[string]any{"min_stores": p.MinStores, "stores": stores})
	}
	if _, err := q.Exec(ctx, `UPDATE networks SET plan_key = $2 WHERE id = $1`, networkID, key); err != nil {
		return Network{}, err
	}
	return ForNetwork(ctx, q, networkID)
}

// AssignInput — супер-админ назначает сети тариф, пробный период и цену.
type AssignInput struct {
	PlanKey          *string       `json:"plan_key"`
	TrialUntil       *string       `json:"trial_until"` // YYYY-MM-DD
	ClearTrial       bool          `json:"clear_trial"`
	CustomPriceUZS   *money.Amount `json:"custom_price_uzs"`
	ClearCustomPrice bool          `json:"clear_custom_price"`
}

// Assign — супер-админ меняет тариф сети (в том числе на скрытый) без
// проверки числа магазинов.
func Assign(ctx context.Context, q db.Querier, networkID string, in AssignInput) error {
	if in.PlanKey != nil {
		p, err := Get(ctx, q, *in.PlanKey)
		if err != nil {
			return err
		}
		if !p.IsActive {
			return apperr.Validation("plan_key: тариф в архиве").Uz("plan_key: tarif arxivda")
		}
	}
	var until *time.Time
	if in.TrialUntil != nil {
		t, err := time.Parse("2006-01-02", *in.TrialUntil)
		if err != nil {
			return apperr.Validation("trial_until: дата YYYY-MM-DD").Uz("trial_until: sana YYYY-MM-DD koʻrinishida boʻlsin")
		}
		until = &t
	}
	if in.CustomPriceUZS != nil && money.D(string(*in.CustomPriceUZS)).Sign() < 0 {
		return apperr.Validation("custom_price_uzs: не меньше нуля").Uz("custom_price_uzs: noldan kichik boʻlmasin")
	}
	_, err := q.Exec(ctx, `UPDATE networks SET
		plan_key = COALESCE($2, plan_key),
		plan_trial_until = CASE WHEN $3 THEN NULL ELSE COALESCE($4::date, plan_trial_until) END,
		custom_price_uzs = CASE WHEN $5 THEN NULL ELSE COALESCE($6::numeric, custom_price_uzs) END
		WHERE id = $1`, networkID, in.PlanKey, in.ClearTrial, until, in.ClearCustomPrice, amountPtr(in.CustomPriceUZS))
	return err
}

// ---------------------------------------------------------- проверки

// Cheapest — первый по порядку открытый тариф, где есть функция или
// лимит больше used; подсказка «доступно на тарифе …».
func Cheapest(ctx context.Context, q db.Querier, feature, limit string, used int) (key, name string) {
	_ = q.QueryRow(ctx, `
		SELECT key, loc(name, name_uz) FROM plans
		WHERE is_active AND is_public
		  AND ($1 = '' OR $1 = ANY (features))
		  AND ($2 = '' OR NOT limits ? $2 OR (limits ->> $2)::int > $3)
		ORDER BY sort, key LIMIT 1`, feature, limit, used).Scan(&key, &name)
	return key, name
}

// Require — ошибка 403 plan_feature, если функции нет в действующем
// тарифе сети. Панель показывает по ней окно «Доступно на тарифе …».
func Require(ctx context.Context, q db.Querier, networkID, feature string) error {
	p, err := Effective(ctx, q, networkID)
	if err != nil {
		return err
	}
	return FeatureError(ctx, q, p, feature)
}

// FeatureError — nil, если функция есть в тарифе p, иначе ошибка plan_feature.
func FeatureError(ctx context.Context, q db.Querier, p Plan, feature string) error {
	if p.Has(feature) {
		return nil
	}
	f, _ := featureInfo(feature)
	needKey, needName := Cheapest(ctx, q, feature, "", 0)
	ru := fmt.Sprintf("«%s» нет на тарифе «%s»", f.Name.RU, p.Name)
	uz := fmt.Sprintf("«%s» «%s» tarifida yoʻq", f.Name.UZ, orRU(p.NameUz, p.Name))
	if needName != "" {
		ru += fmt.Sprintf(" — доступно на тарифе «%s»", needName)
		uz += fmt.Sprintf(" — «%s» tarifida mavjud", needName)
	}
	return apperr.New(http.StatusForbidden, "plan_feature", ru).Uz(uz).WithDetails(map[string]any{
		"feature": feature, "feature_name": f.Name.Ctx(ctx), "plan": p.Key, "plan_name": p.Title(ctx),
		"need_plan": nullable(needKey), "need_plan_name": nullable(needName),
	})
}

// LimitError — ошибка 409 tariff_limit: что упёрлось, сколько можно и
// сколько уже есть. Тот же код, что у старых лимитов витрины, — панель
// показывает по нему окно «Лимит тарифа».
func LimitError(ctx context.Context, q db.Querier, p Plan, key string, used int) error {
	l, _ := limitInfo(key)
	limit := p.Allowed(key)
	needKey, needName := Cheapest(ctx, q, "", key, used)
	ru := fmt.Sprintf("лимит тарифа «%s»: %s — не больше %d", p.Name, strings.ToLower(l.Name.RU), limit)
	uz := fmt.Sprintf("«%s» tarifi limiti: %s — %d tadan koʻp emas", orRU(p.NameUz, p.Name), strings.ToLower(l.Name.UZ), limit)
	return apperr.Conflict("tariff_limit", ru).Uz(uz).WithDetails(map[string]any{
		"feature": key, "limit_name": l.Name.Ctx(ctx), "plan": p.Key, "plan_name": p.Title(ctx), "limit": limit, "used": used,
		"need_plan": nullable(needKey), "need_plan_name": nullable(needName),
	})
}

// CheckLimit — можно ли добавить ещё одно (used — сколько уже есть).
func CheckLimit(ctx context.Context, q db.Querier, networkID, key string, used int) error {
	p, err := Effective(ctx, q, networkID)
	if err != nil {
		return err
	}
	if used < p.Allowed(key) {
		return nil
	}
	return LimitError(ctx, q, p, key, used)
}

// Счётчики лимитов, которые считаются по базе (витрина считает свои сама).
var usageSQL = map[string]string{
	LimitStores:    `SELECT count(*) FROM stores WHERE network_id = $1 AND status = 'active'`,
	LimitRegisters: `SELECT count(*) FROM pos_devices WHERE network_id = $1 AND revoked_at IS NULL AND employee_id IS NULL`, // телефоны сотрудников — бесплатно
	// Курьер — сотрудник, чья роль даёт право доставки; остальные (кроме
	// владельца) — сотрудники.
	LimitStaff: `SELECT count(*) FROM employees e JOIN roles r ON r.id = e.role_id
		WHERE e.network_id = $1 AND e.status = 'active' AND NOT r.is_owner AND NOT ('orders.deliver' = ANY (r.permissions))`,
	LimitCouriers: `SELECT count(*) FROM employees e JOIN roles r ON r.id = e.role_id
		WHERE e.network_id = $1 AND e.status = 'active' AND NOT r.is_owner AND 'orders.deliver' = ANY (r.permissions)`,
	// Фото от Super Market в этом месяце (по Ташкенту); как ai.StoreUsedSQL.
	LimitAIPhotos: `SELECT count(*) FROM photo_jobs WHERE network_id = $1 AND status IN ('queued', 'processing', 'done')
		AND created_at >= date_trunc('month', now() AT TIME ZONE 'Asia/Tashkent') AT TIME ZONE 'Asia/Tashkent'`,
}

// Used — сколько уже использовано по лимиту key (для stores, registers,
// staff, couriers).
func Used(ctx context.Context, q db.Querier, networkID, key string) (int, error) {
	sql, ok := usageSQL[key]
	if !ok {
		return 0, fmt.Errorf("plans: нет счётчика для лимита %q", key)
	}
	var n int
	err := q.QueryRow(ctx, sql, networkID).Scan(&n)
	return n, err
}

// CheckAdd — Used + CheckLimit: можно ли добавить ещё один магазин,
// кассу, сотрудника или курьера.
func CheckAdd(ctx context.Context, q db.Querier, networkID, key string) error {
	used, err := Used(ctx, q, networkID, key)
	if err != nil {
		return err
	}
	return CheckLimit(ctx, q, networkID, key, used)
}

func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func orRU(uz, ru string) string {
	if strings.TrimSpace(uz) == "" {
		return ru
	}
	return uz
}

// Guard выполняет fn (в той же транзакции q) и проверяет, что она не
// вывела сеть за лимиты тарифа: если счётчик вырос и стал больше лимита —
// ошибка tariff_limit (транзакция откатится). Правки, которые счётчик не
// увеличивают, проходят, даже если сеть уже сверх лимита (после понижения
// тарифа ничего не удаляется).
func Guard(ctx context.Context, q db.Querier, networkID string, keys []string, fn func() error) error {
	before := make(map[string]int, len(keys))
	for _, k := range keys {
		n, err := Used(ctx, q, networkID, k)
		if err != nil {
			return err
		}
		before[k] = n
	}
	if err := fn(); err != nil {
		return err
	}
	var p *Plan
	for _, k := range keys {
		after, err := Used(ctx, q, networkID, k)
		if err != nil {
			return err
		}
		if after <= before[k] {
			continue
		}
		if p == nil {
			eff, err := Effective(ctx, q, networkID)
			if err != nil {
				return err
			}
			p = &eff
		}
		if after > p.Allowed(k) {
			return LimitError(ctx, q, *p, k, before[k])
		}
	}
	return nil
}
