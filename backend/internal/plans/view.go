package plans

import (
	"context"

	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// FeatureView — функция в карточке тарифа (на языке запроса).
type FeatureView struct {
	Key      string `json:"key"`
	Group    string `json:"group"`
	Name     string `json:"name"`
	Hint     string `json:"hint"`
	Included bool   `json:"included"`
}

// LimitView — лимит в карточке тарифа; Value nil — без лимита. Used —
// сколько уже занято (только в «моём тарифе» и где это считается).
type LimitView struct {
	Key   string `json:"key"`
	Group string `json:"group"`
	Name  string `json:"name"`
	Hint  string `json:"hint"`
	Value *int   `json:"value"`
	Used  *int   `json:"used,omitempty"`
}

// View — тариф для сайта и панели магазина: всё на языке запроса,
// функции — полным списком с отметкой «входит».
type View struct {
	Key             string        `json:"key"`
	Name            string        `json:"name"`
	Description     string        `json:"description"`
	PriceUZS        string        `json:"price_uzs"`
	Currency        string        `json:"currency"`
	MinStores       int           `json:"min_stores"`
	OrderCommission string        `json:"order_commission"`
	Recommended     bool          `json:"recommended"`
	Sort            int           `json:"sort"`
	Features        []FeatureView `json:"features"`
	Limits          []LimitView   `json:"limits"`
}

// View — карточка тарифа на языке ctx.
func (p Plan) View(ctx context.Context) View {
	lang := i18n.FromContext(ctx)
	v := View{
		Key: p.Key, Name: p.Title(ctx), Description: i18n.Pick(lang, p.Description, p.DescriptionUz),
		PriceUZS: p.PriceUZS, Currency: "UZS", MinStores: p.MinStores, OrderCommission: p.OrderCommission,
		Recommended: p.Recommended, Sort: p.Sort, Features: []FeatureView{}, Limits: []LimitView{},
	}
	for _, f := range Features {
		v.Features = append(v.Features, FeatureView{Key: f.Key, Group: f.Group, Name: f.Name.In(lang), Hint: f.Hint.In(lang), Included: p.Has(f.Key)})
	}
	for _, l := range Limits {
		v.Limits = append(v.Limits, LimitView{Key: l.Key, Group: l.Group, Name: l.Name.In(lang), Hint: l.Hint.In(lang), Value: p.Limit(l.Key)})
	}
	return v
}

// Views — открытые тарифы карточками.
func Views(ctx context.Context, q db.Querier) ([]View, error) {
	list, err := List(ctx, q, true)
	if err != nil {
		return nil, err
	}
	out := make([]View, len(list))
	for i, p := range list {
		out[i] = p.View(ctx)
	}
	return out, nil
}

// Registry — реестр функций и лимитов для экрана тарифов супер-админа.
type Registry struct {
	Groups   []RegistryItem `json:"groups"`
	Features []RegistryItem `json:"features"`
	Limits   []RegistryItem `json:"limits"`
}

type RegistryItem struct {
	Key     string `json:"key"`
	Group   string `json:"group,omitempty"`
	Name    string `json:"name"`
	NameUz  string `json:"name_uz"`
	Hint    string `json:"hint,omitempty"`
	HintUz  string `json:"hint_uz,omitempty"`
	Max     int    `json:"max,omitempty"`
	Default *int   `json:"default,omitempty"`
}

// GetRegistry — что можно включать в тарифы.
func GetRegistry() Registry {
	r := Registry{}
	for _, g := range Groups {
		r.Groups = append(r.Groups, RegistryItem{Key: g.Key, Name: g.Name.RU, NameUz: g.Name.UZ})
	}
	for _, f := range Features {
		r.Features = append(r.Features, RegistryItem{Key: f.Key, Group: f.Group, Name: f.Name.RU, NameUz: f.Name.UZ, Hint: f.Hint.RU, HintUz: f.Hint.UZ})
	}
	for _, l := range Limits {
		r.Limits = append(r.Limits, RegistryItem{Key: l.Key, Group: l.Group, Name: l.Name.RU, NameUz: l.Name.UZ, Hint: l.Hint.RU, HintUz: l.Hint.UZ, Max: l.Max, Default: l.Default})
	}
	return r
}

// Mine — «мой тариф» для панели магазина.
type Mine struct {
	Network
	Current     View   `json:"current"`
	Plans       []View `json:"plans"`
	StoresCount int    `json:"stores_count"`
	CanChange   bool   `json:"can_change"`
}

// ForStore — «мой тариф»: действующий тариф с занятыми лимитами и
// открытые тарифы для смены.
func ForStore(ctx context.Context, q db.Querier, networkID string, canChange bool) (Mine, error) {
	var out Mine
	var err error
	if out.Network, err = ForNetwork(ctx, q, networkID); err != nil {
		return out, err
	}
	// Сколько сетей на тарифе — только для супер-админа.
	out.Chosen.NetworksCount, out.Effective.NetworksCount = 0, 0
	out.CanChange = canChange
	out.Current = out.Effective.View(ctx)
	for i, l := range out.Current.Limits {
		if _, ok := usageSQL[l.Key]; !ok {
			continue
		}
		n, err := Used(ctx, q, networkID, l.Key)
		if err != nil {
			return out, err
		}
		out.Current.Limits[i].Used = &n
		if l.Key == LimitStores {
			out.StoresCount = n
		}
	}
	out.Plans, err = Views(ctx, q)
	return out, err
}
