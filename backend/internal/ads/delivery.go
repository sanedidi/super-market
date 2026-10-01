package ads

import (
	"context"
	"sync/atomic"
	"time"

	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/showcase"
)

// Spot — рекламный блок для главной магазина: кампания и товары бренда
// без исключённых сетью категорий (наличие проверяет сборка главной).
type Spot struct {
	CampaignID string
	Format     string
	Title      string
	Subtitle   string
	ImageURL   string
	Brand      string
	Place      string
	ProductIDs []string
}

// MaxAds — сколько рекламных блоков на главной у сети: по тарифу, а на
// тарифе, где можно меньше, — как выбрала сеть.
func MaxAds(plan showcase.Plan, networkChoice *int) int {
	if plan.AdsReducible && networkChoice != nil && *networkChoice < plan.AdsMax {
		return *networkChoice
	}
	return plan.AdsMax
}

// LiveForStore — кампании, которые сейчас можно показать в магазине:
// идут, не на паузе, не выбрали лимит показов, нацелены на эту сеть, бренд
// не скрыт сетью. Берётся с запасом (лимит доставки — у сборки главной:
// кампания без товаров в наличии пропускается).
func LiveForStore(ctx context.Context, q db.Querier, networkID string, now time.Time) ([]Spot, error) {
	rows, err := q.Query(ctx, `
		WITH n AS (SELECT ads_hidden_brands, ads_excluded_categories FROM networks WHERE id = $1),
		     st AS (SELECT allow_hide_brands, allow_exclude_categories FROM ad_settings WHERE id = 1),
		     -- исключённые категории и все их подкатегории
		     ex AS (
		         WITH RECURSIVE t AS (
		             SELECT c.id FROM categories c, n, st WHERE st.allow_exclude_categories AND c.id = ANY(n.ads_excluded_categories)
		             UNION SELECT c.id FROM categories c JOIN t ON c.parent_id = t.id)
		         SELECT id FROM t)
		SELECT c.id, c.format, c.title, c.subtitle, c.image_url, br.name, c.place,
		       COALESCE(array(SELECT p.id::text FROM unnest(c.product_ids) WITH ORDINALITY u(id, ord)
		                      JOIN products p ON p.id = u.id
		                      WHERE p.category_id NOT IN (SELECT id FROM ex) ORDER BY u.ord), '{}')
		FROM ad_campaigns c JOIN brands br ON br.id = c.brand_id, n, st
		WHERE NOT c.paused AND $2 >= c.starts_at AND $2 < c.ends_at
		  AND (cardinality(c.network_ids) = 0 OR $1::uuid = ANY(c.network_ids))
		  AND NOT (st.allow_hide_brands AND c.brand_id = ANY(n.ads_hidden_brands))
		  AND (c.impression_limit IS NULL OR (SELECT count(*) FROM ad_views v WHERE v.campaign_id = c.id) < c.impression_limit)
		ORDER BY c.place, c.starts_at, c.id
		LIMIT 10`, networkID, now)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Spot{}
	for rows.Next() {
		var sp Spot
		if err := rows.Scan(&sp.CampaignID, &sp.Format, &sp.Title, &sp.Subtitle, &sp.ImageURL, &sp.Brand, &sp.Place, &sp.ProductIDs); err != nil {
			return nil, err
		}
		if len(sp.ProductIDs) > 0 {
			out = append(out, sp)
		}
	}
	return out, rows.Err()
}

// RecordBillable — оплачиваемые показы рекламы: один вошедший покупатель —
// один показ кампании в день. ids — блоки из пачки событий; не кампании
// отбрасываются.
func RecordBillable(ctx context.Context, q db.Querier, storeID, userID string, ids []string) error {
	if userID == "" || len(ids) == 0 {
		return nil
	}
	_, err := q.Exec(ctx, `
		INSERT INTO ad_views (campaign_id, day, user_id, store_id)
		SELECT c.id, (now() AT TIME ZONE 'Asia/Tashkent')::date, $2, $1
		FROM ad_campaigns c WHERE c.id = ANY($3::uuid[])
		ON CONFLICT DO NOTHING`, storeID, userID, ids)
	return err
}

// IsCampaign — множество id кампаний из списка (чтобы не путать с блоками витрины).
func IsCampaign(ctx context.Context, q db.Querier, ids []string) (map[string]bool, error) {
	out := map[string]bool{}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := q.Query(ctx, `SELECT id::text FROM ad_campaigns WHERE id = ANY($1::uuid[])`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out[id] = true
	}
	return out, rows.Err()
}

// generation меняется при каждой правке кампаний и настроек рекламы сетей:
// сборка главной сбрасывает по нему свой минутный кэш.
var generation atomic.Int64

// Generation — номер последней правки рекламы.
func Generation() int64 { return generation.Load() }

func bump() { generation.Add(1) }
