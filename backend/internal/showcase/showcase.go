// Package showcase — тарифы витрины магазина в приложении («Старт / Бизнес /
// Про»): что сеть может настроить на главной и сколько своих блоков и
// баннеров. Цены, лимиты и пробный период задаёт супер-админ.
package showcase

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Plan — тариф витрины. Лимиты nil — без лимита.
type Plan struct {
	Key         string `json:"key"`
	Name        string `json:"name"`
	PriceUZS    string `json:"price_uzs"`
	Custom      bool   `json:"custom"`
	Banners     *int   `json:"banners"`
	Shelves     *int   `json:"shelves"`
	Promos      *int   `json:"promos"`
	Manual      bool   `json:"manual"`
	Schedule    bool   `json:"schedule"`
	PerStore    bool   `json:"per_store"`
	Stats       string `json:"stats"`
	Recommended bool   `json:"recommended"`
	Sort        int    `json:"sort"`
	// Рекламных блоков брендов на главной; AdsReducible — сеть может
	// поставить меньше или выключить рекламу.
	AdsMax       int  `json:"ads_max"`
	AdsReducible bool `json:"ads_reducible"`
}

const planSelect = `SELECT key, name, price_uzs::text, custom, banners, shelves, promos, manual, schedule, per_store, stats, recommended, sort, ads_max, ads_reducible FROM showcase_plans`

func scan(r pgx.CollectableRow) (Plan, error) {
	var p Plan
	err := r.Scan(&p.Key, &p.Name, &p.PriceUZS, &p.Custom, &p.Banners, &p.Shelves, &p.Promos, &p.Manual, &p.Schedule, &p.PerStore,
		&p.Stats, &p.Recommended, &p.Sort, &p.AdsMax, &p.AdsReducible)
	return p, err
}

// Plans — все тарифы по порядку.
func Plans(ctx context.Context, q db.Querier) ([]Plan, error) {
	rows, err := q.Query(ctx, planSelect+` ORDER BY sort`)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scan)
}

func get(ctx context.Context, q db.Querier, key string) (Plan, error) {
	rows, err := q.Query(ctx, planSelect+` WHERE key = $1`, key)
	if err != nil {
		return Plan{}, err
	}
	p, err := pgx.CollectExactlyOneRow(rows, scan)
	if errors.Is(err, pgx.ErrNoRows) {
		return p, apperr.NotFound("тариф не найден")
	}
	return p, err
}

// PlanInput — правка тарифа супер-админом. Лимит -1 — без лимита.
type PlanInput struct {
	Name         *string       `json:"name"`
	PriceUZS     *money.Amount `json:"price_uzs"`
	Custom       *bool         `json:"custom"`
	Banners      *int          `json:"banners"`
	Shelves      *int          `json:"shelves"`
	Promos       *int          `json:"promos"`
	Manual       *bool         `json:"manual"`
	Schedule     *bool         `json:"schedule"`
	PerStore     *bool         `json:"per_store"`
	Stats        *string       `json:"stats"`
	Recommended  *bool         `json:"recommended"`
	AdsMax       *int          `json:"ads_max"`
	AdsReducible *bool         `json:"ads_reducible"`
}

// SavePlan меняет тариф.
func SavePlan(ctx context.Context, q db.Querier, key string, in PlanInput) (Plan, error) {
	if _, err := get(ctx, q, key); err != nil {
		return Plan{}, err
	}
	if in.Name != nil && strings.TrimSpace(*in.Name) == "" {
		return Plan{}, apperr.Validation("name: не может быть пустым")
	}
	if in.AdsMax != nil && (*in.AdsMax < 0 || *in.AdsMax > 2) {
		return Plan{}, apperr.Validation("ads_max: от 0 до 2")
	}
	if in.Stats != nil && *in.Stats != "none" && *in.Stats != "basic" && *in.Stats != "full" {
		return Plan{}, apperr.Validation("stats: none, basic или full")
	}
	var price *string
	if in.PriceUZS != nil {
		if money.D(string(*in.PriceUZS)).Sign() < 0 {
			return Plan{}, apperr.Validation("price_uzs: не меньше нуля")
		}
		v := string(*in.PriceUZS)
		price = &v
	}
	// Лимит: ключа нет — не менять, -1 — без лимита, иначе число.
	limit := func(v *int) (set bool, val *int, err error) {
		if v == nil {
			return false, nil, nil
		}
		if *v < -1 || *v > 1000 {
			return false, nil, apperr.Validation("лимит от 0 до 1000 или -1 (без лимита)")
		}
		if *v == -1 {
			return true, nil, nil
		}
		return true, v, nil
	}
	bSet, b, err := limit(in.Banners)
	if err != nil {
		return Plan{}, err
	}
	sSet, sh, err := limit(in.Shelves)
	if err != nil {
		return Plan{}, err
	}
	pSet, pr, err := limit(in.Promos)
	if err != nil {
		return Plan{}, err
	}
	if in.Recommended != nil && *in.Recommended {
		if _, err := q.Exec(ctx, `UPDATE showcase_plans SET recommended = false WHERE key <> $1`, key); err != nil {
			return Plan{}, err
		}
	}
	if _, err := q.Exec(ctx, `
		UPDATE showcase_plans SET
			name = COALESCE($2, name), price_uzs = COALESCE($3::numeric, price_uzs), custom = COALESCE($4, custom),
			banners = CASE WHEN $5 THEN $6 ELSE banners END,
			shelves = CASE WHEN $7 THEN $8 ELSE shelves END,
			promos = CASE WHEN $9 THEN $10 ELSE promos END,
			manual = COALESCE($11, manual), schedule = COALESCE($12, schedule), per_store = COALESCE($13, per_store),
			stats = COALESCE($14, stats), recommended = COALESCE($15, recommended),
			ads_max = COALESCE($16, ads_max), ads_reducible = COALESCE($17, ads_reducible), updated_at = now()
		WHERE key = $1`,
		key, trimPtr(in.Name), price, in.Custom, bSet, b, sSet, sh, pSet, pr, in.Manual, in.Schedule, in.PerStore, in.Stats, in.Recommended,
		in.AdsMax, in.AdsReducible); err != nil {
		return Plan{}, err
	}
	return get(ctx, q, key)
}

func trimPtr(p *string) *string {
	if p == nil {
		return nil
	}
	v := strings.TrimSpace(*p)
	return &v
}

// Network — тариф витрины сети: выбранный, действующий сейчас (с учётом
// пробного периода) и до какого числа пробный.
type Network struct {
	Chosen     Plan    `json:"chosen"`
	Effective  Plan    `json:"effective"`
	TrialPlan  string  `json:"trial_plan"`
	TrialUntil *string `json:"trial_until"`
	InTrial    bool    `json:"in_trial"`
}

// ForNetwork — тариф витрины сети. Сеть без тарифа — «Старт».
func ForNetwork(ctx context.Context, q db.Querier, networkID string) (Network, error) {
	var out Network
	var chosen, trialPlan string
	var until *time.Time
	var today time.Time
	err := q.QueryRow(ctx, `
		SELECT n.showcase_plan, n.showcase_trial_until, bs.showcase_trial_plan, (now() AT TIME ZONE 'Asia/Tashkent')::date
		FROM networks n CROSS JOIN billing_settings bs WHERE n.id = $1`, networkID).Scan(&chosen, &until, &trialPlan, &today)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, apperr.NotFound("сеть не найдена")
	}
	if err != nil {
		return out, err
	}
	if out.Chosen, err = get(ctx, q, chosen); err != nil {
		return out, err
	}
	out.Effective, out.TrialPlan = out.Chosen, trialPlan
	if until != nil {
		s := until.Format("2006-01-02")
		out.TrialUntil = &s
		if !until.Before(today) {
			trial, err := get(ctx, q, trialPlan)
			if err != nil {
				return out, err
			}
			if trial.Sort > out.Chosen.Sort {
				out.Effective, out.InTrial = trial, true
			}
		}
	}
	return out, nil
}

// StartTrial начинает пробный период сети, если его ещё не было и он
// включён в настройках.
func StartTrial(ctx context.Context, q db.Querier, networkID string) error {
	_, err := q.Exec(ctx, `
		UPDATE networks n SET showcase_trial_until = (now() AT TIME ZONE 'Asia/Tashkent')::date + bs.showcase_trial_days - 1
		FROM billing_settings bs
		WHERE n.id = $1 AND n.showcase_trial_until IS NULL AND bs.showcase_trial_days > 0`, networkID)
	return err
}

// Choose — сеть выбирает тариф; плата войдёт в ближайший счёт за подписку.
func Choose(ctx context.Context, q db.Querier, networkID, key string) (Network, error) {
	if !httpx.IsUUID(networkID) {
		return Network{}, apperr.NotFound("сеть не найдена")
	}
	if _, err := get(ctx, q, key); err != nil {
		return Network{}, err
	}
	if _, err := q.Exec(ctx, `UPDATE networks SET showcase_plan = $2 WHERE id = $1`, networkID, key); err != nil {
		return Network{}, err
	}
	return ForNetwork(ctx, q, networkID)
}

// Limit — ошибка «лимит тарифа»: что упёрлось, сколько можно и сколько
// уже есть. Панель показывает по ней окно «Лимит тарифа».
func Limit(feature string, plan Plan, limit, used int, text string) error {
	return apperr.Conflict("tariff_limit", text).WithDetails(map[string]any{
		"feature": feature, "plan": plan.Key, "plan_name": plan.Name, "limit": limit, "used": used,
	})
}

// Allowed — лимит в число (без лимита — очень много).
func Allowed(v *int) int {
	if v == nil {
		return 1 << 30
	}
	return *v
}

// Need — какой тариф нужен для функции: подсказка для окна лимита.
func Need(feature string) string {
	switch feature {
	case "schedule", "per_store":
		return "pro"
	}
	return "business"
}

// Describe — «3 из 3» для полоски лимитов.
func Describe(limit *int, used int) string {
	if limit == nil {
		return fmt.Sprintf("%d · без лимита", used)
	}
	return fmt.Sprintf("%d из %d", used, *limit)
}
