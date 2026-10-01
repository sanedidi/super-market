package ads

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/showcase"
)

// Реклама брендов в панели магазина: доля сети, бренды в её магазинах,
// скрытые бренды и категории, сколько рекламных блоков.

type NetworkCampaign struct {
	ID        string    `json:"id"`
	BrandID   string    `json:"brand_id"`
	BrandName string    `json:"brand_name"`
	Format    string    `json:"format"`
	Title     string    `json:"title"`
	Products  []string  `json:"products"`
	StartsAt  time.Time `json:"starts_at"`
	EndsAt    time.Time `json:"ends_at"`
	Hidden    bool      `json:"hidden"`
	Views     int64     `json:"views"`
	Orders    int64     `json:"orders"`
	Sales     string    `json:"sales"`
}

type ShareRow struct {
	Period   string `json:"period"`
	Label    string `json:"label"`
	Amount   string `json:"amount"`
	Applied  string `json:"applied"`
	Credited string `json:"credited"`
	Settled  bool   `json:"settled"`
}

type NetworkAds struct {
	SharePct               string            `json:"share_pct"`
	ShareToSubscription    bool              `json:"share_to_subscription"`
	AllowHideBrands        bool              `json:"allow_hide_brands"`
	AllowExcludeCategories bool              `json:"allow_exclude_categories"`
	Plan                   showcase.Plan     `json:"plan"`
	AdsMax                 int               `json:"ads_max"`
	AdsChoice              *int              `json:"ads_choice"`
	HiddenBrands           []NamedID         `json:"hidden_brands"`
	ExcludedCategories     []NamedID         `json:"excluded_categories"`
	MonthShare             string            `json:"month_share"`
	MonthViews             int64             `json:"month_views"`
	MonthOrders            int64             `json:"month_orders"`
	MonthSales             string            `json:"month_sales"`
	Shares                 []ShareRow        `json:"shares"`
	Campaigns              []NetworkCampaign `json:"campaigns"`
}

func (s *Service) NetworkAds(ctx context.Context, networkID string) (NetworkAds, error) {
	var out NetworkAds
	st, err := GetSettings(ctx, s.pool)
	if err != nil {
		return out, err
	}
	out.SharePct, out.ShareToSubscription, out.AllowHideBrands, out.AllowExcludeCategories =
		st.NetworkSharePct, st.ShareToSubscription, st.AllowHideBrands, st.AllowExcludeCategories
	plan, err := showcase.ForNetwork(ctx, s.pool, networkID)
	if err != nil {
		return out, err
	}
	out.Plan = plan.Effective
	if err := s.pool.QueryRow(ctx, `
		SELECT n.ads_max,
		       COALESCE((SELECT json_agg(json_build_object('id', b.id, 'name', b.name) ORDER BY b.name) FROM brands b WHERE b.id = ANY(n.ads_hidden_brands)), '[]'),
		       COALESCE((SELECT json_agg(json_build_object('id', c.id, 'name', c.name) ORDER BY c.name) FROM categories c WHERE c.id = ANY(n.ads_excluded_categories)), '[]')
		FROM networks n WHERE n.id = $1`, networkID).Scan(&out.AdsChoice, &out.HiddenBrands, &out.ExcludedCategories); err != nil {
		return out, err
	}
	out.AdsMax = MaxAds(plan.Effective, out.AdsChoice)

	now := s.now()
	p0 := MonthStart(now)
	today := now.In(tashkent)
	if out.MonthShare, out.MonthViews, err = ShareEstimate(ctx, s.pool, networkID, p0, today); err != nil {
		return out, err
	}
	if err := s.pool.QueryRow(ctx, `
		SELECT count(DISTINCT o.id), COALESCE(sum(i.total), 0)::text FROM order_items i JOIN orders o ON o.id = i.order_id
		JOIN ad_campaigns c ON c.id = i.home_block_id
		WHERE o.network_id = $1 AND o.created_at >= $2 AND o.status NOT IN ('awaiting_payment', 'cancelled', 'expired')`,
		networkID, p0).Scan(&out.MonthOrders, &out.MonthSales); err != nil {
		return out, err
	}

	rows, err := s.pool.Query(ctx, `SELECT period, amount::text, applied::text, credited::text, settled_at IS NOT NULL
		FROM network_ad_shares WHERE network_id = $1 ORDER BY period DESC LIMIT 12`, networkID)
	if err != nil {
		return out, err
	}
	out.Shares, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (ShareRow, error) {
		var x ShareRow
		var p time.Time
		err := r.Scan(&p, &x.Amount, &x.Applied, &x.Credited, &x.Settled)
		x.Period, x.Label = p.Format("2006-01"), periodLabel(p)
		return x, err
	})
	if err != nil {
		return out, err
	}

	// Кампании для этой сети: идут, скоро или закончились за последний месяц.
	rows, err = s.pool.Query(ctx, `
		SELECT c.id, c.brand_id, br.name, c.format, c.title,
		       COALESCE(array(SELECT p.name FROM products p WHERE p.id = ANY(c.product_ids) ORDER BY p.name LIMIT 4), '{}'),
		       c.starts_at, c.ends_at, c.brand_id = ANY(n.ads_hidden_brands),
		       (SELECT count(*) FROM ad_views v JOIN stores s ON s.id = v.store_id WHERE v.campaign_id = c.id AND s.network_id = n.id),
		       COALESCE(od.orders, 0), COALESCE(od.sales, 0)::text
		FROM ad_campaigns c JOIN brands br ON br.id = c.brand_id JOIN networks n ON n.id = $1
		LEFT JOIN LATERAL (SELECT count(DISTINCT o.id) AS orders, sum(i.total) AS sales FROM order_items i JOIN orders o ON o.id = i.order_id
		                   WHERE i.home_block_id = c.id AND o.network_id = n.id AND o.status NOT IN ('awaiting_payment', 'cancelled', 'expired')) od ON true
		WHERE (cardinality(c.network_ids) = 0 OR n.id = ANY(c.network_ids)) AND NOT c.paused AND c.ends_at > now() - interval '30 days'
		ORDER BY c.ends_at < now(), c.starts_at`, networkID)
	if err != nil {
		return out, err
	}
	out.Campaigns, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (NetworkCampaign, error) {
		var x NetworkCampaign
		err := r.Scan(&x.ID, &x.BrandID, &x.BrandName, &x.Format, &x.Title, &x.Products, &x.StartsAt, &x.EndsAt, &x.Hidden, &x.Views, &x.Orders, &x.Sales)
		return x, err
	})
	return out, err
}

type NetworkAdsInput struct {
	HiddenBrands       []string `json:"hidden_brands"`
	ExcludedCategories []string `json:"excluded_categories"`
	// Сколько рекламных блоков (0–2); -1 — по тарифу. Меньше стандарта — только на «Про».
	AdsMax *int `json:"ads_max"`
}

// SaveNetworkAds — сеть скрывает бренды и категории, выбирает число блоков.
func (s *Service) SaveNetworkAds(ctx context.Context, networkID string, in NetworkAdsInput) (NetworkAds, error) {
	st, err := GetSettings(ctx, s.pool)
	if err != nil {
		return NetworkAds{}, err
	}
	for _, list := range [][]string{in.HiddenBrands, in.ExcludedCategories} {
		if len(list) > 100 {
			return NetworkAds{}, apperr.Validation("не больше 100 значений")
		}
		for _, id := range list {
			if !httpx.IsUUID(id) {
				return NetworkAds{}, apperr.Validation("неверный id бренда или категории")
			}
		}
	}
	if in.HiddenBrands != nil && len(in.HiddenBrands) > 0 && !st.AllowHideBrands {
		return NetworkAds{}, apperr.Forbidden("скрывать бренды сейчас нельзя — правило Super Market")
	}
	if in.ExcludedCategories != nil && len(in.ExcludedCategories) > 0 && !st.AllowExcludeCategories {
		return NetworkAds{}, apperr.Forbidden("исключать категории сейчас нельзя — правило Super Market")
	}
	setMax := in.AdsMax != nil
	var max *int
	if setMax && *in.AdsMax >= 0 {
		if *in.AdsMax > 2 {
			return NetworkAds{}, apperr.Validation("ads_max: от 0 до 2")
		}
		plan, err := showcase.ForNetwork(ctx, s.pool, networkID)
		if err != nil {
			return NetworkAds{}, err
		}
		if *in.AdsMax < plan.Effective.AdsMax && !plan.Effective.AdsReducible {
			return NetworkAds{}, showcase.Limit("ads", plan.Effective, plan.Effective.AdsMax, *in.AdsMax,
				"меньше рекламы или без неё — на тарифе «Про»")
		}
		max = in.AdsMax
	}
	if _, err := s.pool.Exec(ctx, `UPDATE networks SET
		ads_hidden_brands = COALESCE($2::uuid[], ads_hidden_brands),
		ads_excluded_categories = COALESCE($3::uuid[], ads_excluded_categories),
		ads_max = CASE WHEN $4 THEN $5::int ELSE ads_max END WHERE id = $1`,
		networkID, in.HiddenBrands, in.ExcludedCategories, setMax, max); err != nil {
		return NetworkAds{}, err
	}
	bump()
	return s.NetworkAds(ctx, networkID)
}
