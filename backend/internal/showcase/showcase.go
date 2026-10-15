// Package showcase — что сеть может настроить на витрине (главной магазина в
// приложении) по своему тарифу. Сами тарифы — в пакете plans; здесь их
// функции и лимиты витрины в том виде, в котором их ждут витрина, баннеры
// и реклама (и панель магазина).
package showcase

import (
	"context"
	"fmt"

	"github.com/sanedidi/super-market/backend/internal/plans"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// Plan — тариф глазами витрины. Лимиты nil — без лимита.
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

// From — витринная часть тарифа.
func From(ctx context.Context, p plans.Plan) Plan {
	stats := "none"
	switch {
	case p.Has(plans.FeatureShowcaseStatsAll):
		stats = "full"
	case p.Has(plans.FeatureShowcaseStats):
		stats = "basic"
	}
	return Plan{
		Key: p.Key, Name: p.Title(ctx), PriceUZS: p.PriceUZS,
		Custom:   p.Has(plans.FeatureShowcaseCustom),
		Banners:  p.Limit(plans.LimitBanners),
		Shelves:  p.Limit(plans.LimitShelves),
		Promos:   p.Limit(plans.LimitPromos),
		Manual:   p.Has(plans.FeatureShowcaseManual),
		Schedule: p.Has(plans.FeatureShowcaseSchedule),
		PerStore: p.Has(plans.FeatureShowcasePerStore),
		Stats:    stats, Recommended: p.Recommended, Sort: p.Sort,
		AdsMax:       min(max(p.Allowed(plans.LimitAds), 0), 2),
		AdsReducible: p.Has(plans.FeatureAdsOff),
	}
}

// Plans — открытые тарифы по порядку.
func Plans(ctx context.Context, q db.Querier) ([]Plan, error) {
	list, err := plans.List(ctx, q, true)
	if err != nil {
		return nil, err
	}
	out := make([]Plan, len(list))
	for i, p := range list {
		out[i] = From(ctx, p)
	}
	return out, nil
}

// Network — тариф сети: выбранный, действующий сейчас (с учётом
// пробного периода) и до какого числа пробный.
type Network struct {
	Chosen     Plan    `json:"chosen"`
	Effective  Plan    `json:"effective"`
	TrialPlan  string  `json:"trial_plan"`
	TrialUntil *string `json:"trial_until"`
	InTrial    bool    `json:"in_trial"`
}

// ForNetwork — тариф витрины сети.
func ForNetwork(ctx context.Context, q db.Querier, networkID string) (Network, error) {
	n, err := plans.ForNetwork(ctx, q, networkID)
	if err != nil {
		return Network{}, err
	}
	return Network{Chosen: From(ctx, n.Chosen), Effective: From(ctx, n.Effective), TrialPlan: n.TrialPlan,
		TrialUntil: n.TrialUntil, InTrial: n.InTrial}, nil
}

// Choose — сеть выбирает тариф (тот же, что в «Мой тариф»).
func Choose(ctx context.Context, q db.Querier, networkID, key string) (Network, error) {
	if _, err := plans.Choose(ctx, q, networkID, key); err != nil {
		return Network{}, err
	}
	return ForNetwork(ctx, q, networkID)
}

// Limit — ошибка «лимит тарифа»: что упёрлось, сколько можно и сколько
// уже есть. Панель показывает по ней окно «Лимит тарифа».
func Limit(feature string, plan Plan, limit, used int, text i18n.Text) error {
	return apperr.Conflict("tariff_limit", text.RU).Uz(text.UZ).WithDetails(map[string]any{
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

// Describe — «3 из 3» для полоски лимитов.
func Describe(limit *int, used int) string {
	if limit == nil {
		return fmt.Sprintf("%d · без лимита", used)
	}
	return fmt.Sprintf("%d из %d", used, *limit)
}

// Ключи функций витрины в старых ответах (feature в tariff_limit) →
// функции тарифа.
var featureKeys = map[string]string{
	"custom":    plans.FeatureShowcaseCustom,
	"manual":    plans.FeatureShowcaseManual,
	"schedule":  plans.FeatureShowcaseSchedule,
	"per_store": plans.FeatureShowcasePerStore,
	"stats":     plans.FeatureShowcaseStats,
	"ads":       plans.FeatureAdsOff,
}

// Locked — функции витрины нет на тарифе: ошибка tariff_limit с
// подсказкой, на каком тарифе она есть («своя витрина — на тарифе «Бизнес»»).
func Locked(ctx context.Context, q db.Querier, plan Plan, feature string, what i18n.Text) error {
	key, name := plans.Cheapest(ctx, q, plans.AudienceStore, featureKeys[feature], "", 0)
	ru, uz := what.RU+" недоступно на тарифе «"+plan.Name+"»", what.UZ+" «"+plan.Name+"» tarifida mavjud emas"
	if name != "" {
		ru, uz = what.RU+" — на тарифе «"+name+"»", what.UZ+" — «"+name+"» tarifida"
	}
	err := Limit(feature, plan, 0, 0, i18n.Text{RU: ru, UZ: uz}).(*apperr.Error)
	err.Details["need_plan"] = key
	err.Details["need_plan_name"] = name
	return err
}

// LimitNeed — Limit с подсказкой, на каком тарифе лимит больше.
func LimitNeed(ctx context.Context, q db.Querier, feature string, plan Plan, limit, used int, text i18n.Text) error {
	key, name := plans.Cheapest(ctx, q, plans.AudienceStore, "", feature, used)
	err := Limit(feature, plan, limit, used, text).(*apperr.Error)
	err.Details["need_plan"] = key
	err.Details["need_plan_name"] = name
	return err
}
