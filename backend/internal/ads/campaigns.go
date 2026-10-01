package ads

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// NamedID — id с названием (товар, сеть).
type NamedID struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// Campaign — рекламная кампания бренда с показателями.
type Campaign struct {
	ID              string    `json:"id"`
	AdvertiserID    string    `json:"advertiser_id"`
	AdvertiserName  string    `json:"advertiser_name"`
	BrandID         string    `json:"brand_id"`
	BrandName       string    `json:"brand_name"`
	Format          string    `json:"format"` // shelf | banner
	Title           string    `json:"title"`
	Subtitle        string    `json:"subtitle"`
	ImageURL        string    `json:"image_url"`
	Products        []NamedID `json:"products"`
	Networks        []NamedID `json:"networks"` // пусто — все сети
	Cities          []string  `json:"cities"`   // пусто — все города
	Place           string    `json:"place"`    // after_platform | end
	StartsAt        time.Time `json:"starts_at"`
	EndsAt          time.Time `json:"ends_at"`
	Pricing         string    `json:"pricing"` // period | cpm
	Price           string    `json:"price"`
	ImpressionLimit *int64    `json:"impression_limit"`
	Paused          bool      `json:"paused"`
	// scheduled | running | paused | limit | finished
	Status string `json:"status"`
	// Показы из приложения; оплачиваемые — один покупатель в день.
	Views         int64     `json:"views"`
	BillableViews int64     `json:"billable_views"`
	Clicks        int64     `json:"clicks"`
	Orders        int64     `json:"orders"`
	Sales         string    `json:"sales"`
	Accrued       string    `json:"accrued"`
	Invoiced      string    `json:"invoiced"`
	CreatedAt     time.Time `json:"created_at"`
}

type CampaignInput struct {
	AdvertiserID    *string       `json:"advertiser_id"`
	BrandID         *string       `json:"brand_id"`
	Format          *string       `json:"format"`
	Title           *string       `json:"title"`
	Subtitle        *string       `json:"subtitle"`
	ImageURL        *string       `json:"image_url"`
	ProductIDs      []string      `json:"product_ids"`
	NetworkIDs      []string      `json:"network_ids"`
	Cities          []string      `json:"cities"`
	Place           *string       `json:"place"`
	StartsAt        *time.Time    `json:"starts_at"`
	EndsAt          *time.Time    `json:"ends_at"`
	Pricing         *string       `json:"pricing"`
	Price           *money.Amount `json:"price"`
	ImpressionLimit *int64        `json:"impression_limit"` // 0 — без лимита
	Paused          *bool         `json:"paused"`
}

// dayBounds — первый и последний день кампании по Ташкенту.
const dayBounds = `(c.starts_at AT TIME ZONE 'Asia/Tashkent')::date AS sd,
	((c.ends_at - interval '1 second') AT TIME ZONE 'Asia/Tashkent')::date AS ed`

const campaignSelect = `
	SELECT c.id, c.advertiser_id, a.name, c.brand_id, br.name, c.format, c.title, c.subtitle, c.image_url,
	       COALESCE((SELECT json_agg(json_build_object('id', p.id, 'name', p.name) ORDER BY array_position(c.product_ids, p.id))
	                 FROM products p WHERE p.id = ANY(c.product_ids)), '[]'),
	       COALESCE((SELECT json_agg(json_build_object('id', n.id, 'name', n.name) ORDER BY n.name)
	                 FROM networks n WHERE n.id = ANY(c.network_ids)), '[]'),
	       c.cities, c.place, c.starts_at, c.ends_at, c.pricing, c.price::text, c.impression_limit, c.paused,
	       CASE WHEN c.paused THEN 'paused' WHEN now() < c.starts_at THEN 'scheduled' WHEN now() >= c.ends_at THEN 'finished'
	            WHEN c.impression_limit IS NOT NULL AND bv.n >= c.impression_limit THEN 'limit' ELSE 'running' END AS status,
	       COALESCE(ev.views, 0), COALESCE(bv.n, 0), COALESCE(ev.clicks, 0), COALESCE(o.orders, 0), COALESCE(o.sales, 0)::text,
	       (` + `CASE WHEN c.pricing = 'period'
	             THEN round(c.price * GREATEST(0, LEAST(b.ed, (now() AT TIME ZONE 'Asia/Tashkent')::date) - b.sd + 1) / (b.ed - b.sd + 1), 2)
	             ELSE round(c.price * COALESCE(bv.n, 0) / 1000, 2) END)::text,
	       COALESCE((SELECT sum(amount) FROM ad_invoices i WHERE i.campaign_id = c.id AND i.status <> 'cancelled'), 0)::text,
	       c.created_at
	FROM ad_campaigns c
	JOIN ad_advertisers a ON a.id = c.advertiser_id
	JOIN brands br ON br.id = c.brand_id
	CROSS JOIN LATERAL (SELECT ` + dayBounds + `) b
	LEFT JOIN LATERAL (SELECT count(*) AS n FROM ad_views v WHERE v.campaign_id = c.id) bv ON true
	LEFT JOIN LATERAL (SELECT sum(views) AS views, sum(clicks) AS clicks FROM home_stats_daily h WHERE h.block_id = c.id) ev ON true
	LEFT JOIN LATERAL (SELECT count(DISTINCT oi.order_id) AS orders, sum(oi.total) AS sales FROM order_items oi
	                   JOIN orders od ON od.id = oi.order_id AND od.status NOT IN ('awaiting_payment', 'cancelled', 'expired')
	                   WHERE oi.home_block_id = c.id) o ON true`

func scanCampaign(r pgx.CollectableRow) (Campaign, error) {
	var c Campaign
	err := r.Scan(&c.ID, &c.AdvertiserID, &c.AdvertiserName, &c.BrandID, &c.BrandName, &c.Format, &c.Title, &c.Subtitle, &c.ImageURL,
		&c.Products, &c.Networks, &c.Cities, &c.Place, &c.StartsAt, &c.EndsAt, &c.Pricing, &c.Price, &c.ImpressionLimit, &c.Paused, &c.Status,
		&c.Views, &c.BillableViews, &c.Clicks, &c.Orders, &c.Sales, &c.Accrued, &c.Invoiced, &c.CreatedAt)
	return c, err
}

// Campaigns — кампании; status — фильтр (running, scheduled, finished…).
func (s *Service) Campaigns(ctx context.Context, status string, page httpx.Page) ([]Campaign, error) {
	rows, err := s.pool.Query(ctx, `SELECT * FROM (`+campaignSelect+`) x WHERE ($1 = '' OR x.status = $1)
		ORDER BY CASE x.status WHEN 'running' THEN 0 WHEN 'limit' THEN 1 WHEN 'scheduled' THEN 2 WHEN 'paused' THEN 3 ELSE 4 END, x.starts_at DESC
		LIMIT $2 OFFSET $3`, status, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanCampaign)
}

func (s *Service) Campaign(ctx context.Context, id string) (Campaign, error) {
	if !httpx.IsUUID(id) {
		return Campaign{}, apperr.NotFound("кампания не найдена")
	}
	rows, err := s.pool.Query(ctx, campaignSelect+` WHERE c.id = $1`, id)
	if err != nil {
		return Campaign{}, err
	}
	c, err := pgx.CollectExactlyOneRow(rows, scanCampaign)
	if errors.Is(err, pgx.ErrNoRows) {
		return c, apperr.NotFound("кампания не найдена")
	}
	return c, err
}

func oneOf(v string, allowed ...string) bool {
	for _, a := range allowed {
		if v == a {
			return true
		}
	}
	return false
}

// SaveCampaign создаёт (id == "") или меняет кампанию.
func (s *Service) SaveCampaign(ctx context.Context, id string, in CampaignInput) (Campaign, error) {
	var cur Campaign
	if id != "" {
		var err error
		if cur, err = s.Campaign(ctx, id); err != nil {
			return cur, err
		}
	}
	str := func(p *string, def string) string {
		if p == nil {
			return def
		}
		return strings.TrimSpace(*p)
	}
	ids := func(list []NamedID) []string {
		out := []string{}
		for _, x := range list {
			out = append(out, x.ID)
		}
		return out
	}
	c := struct {
		advertiser, brand, format, title, subtitle, image, place, pricing, price string
		products, networks, cities                                               []string
		starts, ends                                                             time.Time
		limit                                                                    *int64
		paused                                                                   bool
	}{
		str(in.AdvertiserID, cur.AdvertiserID), str(in.BrandID, cur.BrandID), str(in.Format, cur.Format), str(in.Title, cur.Title),
		str(in.Subtitle, cur.Subtitle), str(in.ImageURL, cur.ImageURL), str(in.Place, valueOr(cur.Place, "after_platform")),
		str(in.Pricing, cur.Pricing), cur.Price, ids(cur.Products), ids(cur.Networks), cur.Cities, cur.StartsAt, cur.EndsAt, cur.ImpressionLimit, cur.Paused,
	}
	if in.Price != nil {
		c.price = string(*in.Price)
	}
	if in.ProductIDs != nil {
		c.products = in.ProductIDs
	}
	if in.NetworkIDs != nil {
		c.networks = in.NetworkIDs
	}
	if in.Cities != nil {
		c.cities = []string{}
		for _, x := range in.Cities {
			if x = strings.TrimSpace(x); x != "" {
				c.cities = append(c.cities, x)
			}
		}
	}
	if c.cities == nil {
		c.cities = []string{}
	}
	if len(c.cities) > 30 {
		return Campaign{}, apperr.Validation("cities: не больше 30 городов")
	}
	if in.StartsAt != nil {
		c.starts = *in.StartsAt
	}
	if in.EndsAt != nil {
		c.ends = *in.EndsAt
	}
	if in.ImpressionLimit != nil {
		if *in.ImpressionLimit <= 0 {
			c.limit = nil
		} else {
			c.limit = in.ImpressionLimit
		}
	}
	if in.Paused != nil {
		c.paused = *in.Paused
	}
	switch {
	case !httpx.IsUUID(c.advertiser):
		return Campaign{}, apperr.Validation("advertiser_id: выберите рекламодателя")
	case !httpx.IsUUID(c.brand):
		return Campaign{}, apperr.Validation("brand_id: выберите бренд")
	case !oneOf(c.format, "shelf", "banner"):
		return Campaign{}, apperr.Validation("format: shelf или banner")
	case c.title == "" || len([]rune(c.title)) > 60:
		return Campaign{}, apperr.Validation("title: от 1 до 60 символов")
	case len([]rune(c.subtitle)) > 80:
		return Campaign{}, apperr.Validation("subtitle: не длиннее 80 символов")
	case c.format == "banner" && !strings.HasPrefix(c.image, "https://") && !strings.HasPrefix(c.image, "http://"):
		return Campaign{}, apperr.Validation("image_url: загрузите фото баннера")
	case len(c.products) == 0 || len(c.products) > 20:
		return Campaign{}, apperr.Validation("product_ids: от 1 до 20 товаров бренда")
	case !oneOf(c.place, "after_platform", "end"):
		return Campaign{}, apperr.Validation("place: after_platform или end")
	case c.starts.IsZero() || c.ends.IsZero() || !c.ends.After(c.starts):
		return Campaign{}, apperr.Validation("даты: окончание позже начала")
	case !oneOf(c.pricing, "period", "cpm"):
		return Campaign{}, apperr.Validation("pricing: period или cpm")
	case money.D(c.price).Sign() <= 0:
		return Campaign{}, apperr.Validation("price: больше нуля")
	}
	for _, x := range append(append([]string{}, c.products...), c.networks...) {
		if !httpx.IsUUID(x) {
			return Campaign{}, apperr.Validation("неверный id товара или сети")
		}
	}
	// Товары — только этого бренда.
	var foreign int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM unnest($1::uuid[]) u(pid) LEFT JOIN products p ON p.id = u.pid
		WHERE p.id IS NULL OR p.brand_id IS DISTINCT FROM $2::uuid`, c.products, c.brand).Scan(&foreign); err != nil {
		return Campaign{}, err
	}
	if foreign > 0 {
		return Campaign{}, apperr.Validation("product_ids: в кампании только товары выбранного бренда")
	}
	if _, err := s.advertiser(ctx, s.pool, c.advertiser); err != nil {
		return Campaign{}, err
	}
	var err error
	if id == "" {
		err = s.pool.QueryRow(ctx, `INSERT INTO ad_campaigns (advertiser_id, brand_id, format, title, subtitle, image_url, product_ids,
			network_ids, place, starts_at, ends_at, pricing, price, impression_limit, paused, cities)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13::numeric, $14, $15, $16) RETURNING id`,
			c.advertiser, c.brand, c.format, c.title, c.subtitle, c.image, c.products, c.networks, c.place, c.starts, c.ends,
			c.pricing, c.price, c.limit, c.paused, c.cities).Scan(&id)
	} else {
		_, err = s.pool.Exec(ctx, `UPDATE ad_campaigns SET advertiser_id = $2, brand_id = $3, format = $4, title = $5, subtitle = $6,
			image_url = $7, product_ids = $8, network_ids = $9, place = $10, starts_at = $11, ends_at = $12, pricing = $13,
			price = $14::numeric, impression_limit = $15, paused = $16, cities = $17, updated_at = now() WHERE id = $1`,
			id, c.advertiser, c.brand, c.format, c.title, c.subtitle, c.image, c.products, c.networks, c.place, c.starts, c.ends,
			c.pricing, c.price, c.limit, c.paused, c.cities)
	}
	if err != nil {
		return Campaign{}, err
	}
	bump()
	return s.Campaign(ctx, id)
}

func valueOr(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

// NetworkRow — показатели кампании по сети (отчёт для бренда и проверка
// накрутки: много показов и нет покупок).
type NetworkRow struct {
	NetworkID     string `json:"network_id"`
	NetworkName   string `json:"network_name"`
	Views         int64  `json:"views"`
	BillableViews int64  `json:"billable_views"`
	Clicks        int64  `json:"clicks"`
	Orders        int64  `json:"orders"`
	Sales         string `json:"sales"`
	Suspicious    bool   `json:"suspicious"`
}

// CampaignReport — кампания по сетям.
func (s *Service) CampaignReport(ctx context.Context, id string) ([]NetworkRow, error) {
	if _, err := s.Campaign(ctx, id); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `
		WITH ev AS (SELECT s.network_id, sum(h.views) views, sum(h.clicks) clicks FROM home_stats_daily h JOIN stores s ON s.id = h.store_id
		            WHERE h.block_id = $1 GROUP BY 1),
		bv AS (SELECT s.network_id, count(*) n FROM ad_views v JOIN stores s ON s.id = v.store_id WHERE v.campaign_id = $1 GROUP BY 1),
		od AS (SELECT o.network_id, count(DISTINCT o.id) orders, sum(i.total) sales FROM order_items i JOIN orders o ON o.id = i.order_id
		       WHERE i.home_block_id = $1 AND o.status NOT IN ('awaiting_payment', 'cancelled', 'expired') GROUP BY 1)
		SELECT n.id, n.name, COALESCE(ev.views, 0), COALESCE(bv.n, 0), COALESCE(ev.clicks, 0), COALESCE(od.orders, 0), COALESCE(od.sales, 0)::text
		FROM networks n LEFT JOIN ev ON ev.network_id = n.id LEFT JOIN bv ON bv.network_id = n.id LEFT JOIN od ON od.network_id = n.id
		WHERE ev.network_id IS NOT NULL OR bv.network_id IS NOT NULL OR od.network_id IS NOT NULL
		ORDER BY COALESCE(bv.n, 0) DESC`, id)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (NetworkRow, error) {
		var x NetworkRow
		err := r.Scan(&x.NetworkID, &x.NetworkName, &x.Views, &x.BillableViews, &x.Clicks, &x.Orders, &x.Sales)
		// Подозрительно: заметные оплачиваемые показы, но ни нажатий в сотню
		// показов, ни покупок.
		x.Suspicious = x.BillableViews >= 500 && x.Orders == 0 && x.Clicks*100 < x.BillableViews
		return x, err
	})
	return out, err
}

// Summary — цифры над списком кампаний.
type Summary struct {
	Active      int64  `json:"active"`
	Views7d     int64  `json:"views_7d"`
	Clicks7d    int64  `json:"clicks_7d"`
	AccruedUZS  string `json:"accrued_month"`
	InvoicedUZS string `json:"invoiced_month"`
}

func (s *Service) Summary(ctx context.Context) (Summary, error) {
	var out Summary
	err := s.pool.QueryRow(ctx, `
		WITH m AS (SELECT date_trunc('month', now() AT TIME ZONE 'Asia/Tashkent')::date AS p0, (now() AT TIME ZONE 'Asia/Tashkent')::date AS today)
		SELECT
			(SELECT count(*) FROM ad_campaigns c WHERE NOT c.paused AND now() BETWEEN c.starts_at AND c.ends_at),
			COALESCE((SELECT sum(h.views) FROM home_stats_daily h JOIN ad_campaigns c ON c.id = h.block_id, m WHERE h.day > m.today - 7), 0),
			COALESCE((SELECT sum(h.clicks) FROM home_stats_daily h JOIN ad_campaigns c ON c.id = h.block_id, m WHERE h.day > m.today - 7), 0),
			COALESCE((SELECT sum(`+monthRevenue+`) FROM ad_campaigns c CROSS JOIN m CROSS JOIN LATERAL (SELECT `+dayBounds+`) b
			          LEFT JOIN LATERAL (SELECT count(*) n FROM ad_views v WHERE v.campaign_id = c.id AND v.day BETWEEN m.p0 AND m.today) bv ON true), 0)::text,
			COALESCE((SELECT sum(amount) FROM ad_invoices i, m WHERE i.status <> 'cancelled' AND i.created_at >= m.p0), 0)::text
		FROM m`).Scan(&out.Active, &out.Views7d, &out.Clicks7d, &out.AccruedUZS, &out.InvoicedUZS)
	return out, err
}

// monthRevenue — начислено по кампании c за дни [m.p0, m.today].
const monthRevenue = `CASE WHEN c.pricing = 'period'
	THEN round(c.price * GREATEST(0, LEAST(b.ed, m.today) - GREATEST(b.sd, m.p0) + 1) / (b.ed - b.sd + 1), 2)
	ELSE round(c.price * COALESCE(bv.n, 0) / 1000, 2) END`

// Cities — города магазинов (для выбора в кампании).
func (s *Service) Cities(ctx context.Context) ([]string, error) {
	rows, err := s.pool.Query(ctx, `SELECT DISTINCT btrim(city) FROM stores WHERE btrim(city) <> '' AND status = 'active' ORDER BY 1`)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}
