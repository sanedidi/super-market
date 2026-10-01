package orders

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
	"github.com/sanedidi/super-market/backend/internal/showcase"
)

// Статистика главной: показ — блок был виден хотя бы наполовину секунду,
// нажатие — касание внутри блока (считает приложение, шлёт пачкой); заказы
// и выручка — строки заказов с товарами, добавленными из блока.

// HomeEventsInput — пачка показов и нажатий из приложения.
type HomeEventsInput struct {
	StoreID string `json:"store_id"`
	Items   []struct {
		BlockID string `json:"block_id"`
		Views   int    `json:"views"`
		Clicks  int    `json:"clicks"`
	} `json:"items"`
}

// RecordHomeEvents складывает показы и нажатия за сегодня.
func (s *Service) RecordHomeEvents(ctx context.Context, in HomeEventsInput) error {
	if !httpx.IsUUID(in.StoreID) {
		return apperr.NotFound("магазин не найден")
	}
	if len(in.Items) > 60 {
		return apperr.Validation("не больше 60 блоков в пачке")
	}
	ids, views, clicks := []string{}, []int{}, []int{}
	for _, it := range in.Items {
		if !httpx.IsUUID(it.BlockID) || it.Views < 0 || it.Clicks < 0 || it.Views > 1000 || it.Clicks > 1000 {
			return apperr.Validation("неверное событие")
		}
		if it.Views == 0 && it.Clicks == 0 {
			continue
		}
		ids, views, clicks = append(ids, it.BlockID), append(views, it.Views), append(clicks, it.Clicks)
	}
	if len(ids) == 0 {
		return nil
	}
	tag, err := s.pool.Exec(ctx, `
		INSERT INTO home_stats_daily (day, store_id, block_id, views, clicks)
		SELECT (now() AT TIME ZONE 'Asia/Tashkent')::date, s.id, e.block_id, sum(e.views), sum(e.clicks)
		FROM unnest($2::uuid[], $3::int[], $4::int[]) AS e(block_id, views, clicks)
		JOIN stores s ON s.id = $1
		GROUP BY s.id, e.block_id
		ON CONFLICT (store_id, day, block_id) DO UPDATE
		SET views = home_stats_daily.views + EXCLUDED.views, clicks = home_stats_daily.clicks + EXCLUDED.clicks`,
		in.StoreID, ids, views, clicks)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.NotFound("магазин не найден")
	}
	return nil
}

// BlockStat — строка таблицы «по блокам».
type BlockStat struct {
	BlockID string  `json:"block_id"`
	Type    string  `json:"type"`
	Title   string  `json:"title"`
	Views   int64   `json:"views"`
	Clicks  int64   `json:"clicks"`
	CTR     float64 `json:"ctr"`
	Orders  int64   `json:"orders"`
	Revenue string  `json:"revenue"`
}

// DayStat — точка графика по дням.
type DayStat struct {
	Day     string `json:"day"`
	Views   int64  `json:"views"`
	Clicks  int64  `json:"clicks"`
	Orders  int64  `json:"orders"`
	Revenue string `json:"revenue"`
}

// HomeStats — статистика витрины за период.
type HomeStats struct {
	// basic — только показы и нажатия; full — ещё заказы, выручка и по дням.
	Level   string      `json:"level"`
	Days    int         `json:"days"`
	From    string      `json:"from"`
	To      string      `json:"to"`
	Views   int64       `json:"views"`
	Clicks  int64       `json:"clicks"`
	Orders  int64       `json:"orders"`
	Revenue string      `json:"revenue"`
	Blocks  []BlockStat `json:"blocks"`
	Series  []DayStat   `json:"series"`
	Hint    string      `json:"hint"`
}

// statsFilter — какие магазины считать: сеть, один магазин или все.
type statsFilter struct {
	networkID string
	storeID   string
	days      int
}

// blockTitle — название блока для таблицы.
func blockTitle(b HomeBlock) string {
	switch b.Type {
	case BlockShelf:
		return "Полка «" + b.Title + "»"
	case BlockBanners:
		if b.Size == "strip" {
			return "Узкая лента «" + b.Title + "»"
		}
		return "Баннеры"
	case BlockPromo:
		if b.Kind == "free_delivery" {
			return "Промо-полоска «до бесплатной доставки»"
		}
		return "Промо-полоска «" + b.Title + "»"
	case BlockCategoryIcons:
		return "Иконки разделов"
	case BlockCatalogSections:
		return "Каталог по разделам"
	}
	return "Блок"
}

func (s *Service) homeStats(ctx context.Context, f statsFilter, full bool) (HomeStats, error) {
	if f.days != 7 && f.days != 30 && f.days != 90 {
		f.days = 7
	}
	out := HomeStats{Level: "basic", Days: f.days, Revenue: "0", Blocks: []BlockStat{}, Series: []DayStat{}}
	if full {
		out.Level = "full"
	}
	if err := s.pool.QueryRow(ctx, `
		SELECT to_char(d - ($1 - 1), 'YYYY-MM-DD'), to_char(d, 'YYYY-MM-DD')
		FROM (SELECT (now() AT TIME ZONE 'Asia/Tashkent')::date AS d) x`, f.days).Scan(&out.From, &out.To); err != nil {
		return out, err
	}
	// Показы, нажатия и заказы по блокам и дням.
	rows, err := s.pool.Query(ctx, `
		WITH st AS (
			SELECT id FROM stores WHERE ($1 = '' OR network_id::text = $1) AND ($2 = '' OR id::text = $2)
		), ev AS (
			SELECT h.block_id, h.day, sum(h.views) AS views, sum(h.clicks) AS clicks
			FROM home_stats_daily h JOIN st ON st.id = h.store_id
			WHERE h.day BETWEEN $3::date AND $4::date
			GROUP BY h.block_id, h.day
		), ord AS (
			SELECT i.home_block_id AS block_id, (o.created_at AT TIME ZONE 'Asia/Tashkent')::date AS day,
			       count(DISTINCT o.id) AS orders, sum(i.total) AS revenue
			FROM orders o JOIN st ON st.id = o.store_id
			JOIN order_items i ON i.order_id = o.id AND i.home_block_id IS NOT NULL
			WHERE o.status NOT IN ('awaiting_payment', 'cancelled', 'expired')
			  AND (o.created_at AT TIME ZONE 'Asia/Tashkent')::date BETWEEN $3::date AND $4::date
			GROUP BY 1, 2
		)
		SELECT COALESCE(ev.block_id, ord.block_id)::text, to_char(COALESCE(ev.day, ord.day), 'YYYY-MM-DD'),
		       COALESCE(ev.views, 0), COALESCE(ev.clicks, 0), COALESCE(ord.orders, 0), COALESCE(ord.revenue, 0)::text
		FROM ev FULL JOIN ord ON ord.block_id = ev.block_id AND ord.day = ev.day`,
		f.networkID, f.storeID, out.From, out.To)
	if err != nil {
		return out, err
	}
	type acc struct {
		views, clicks, orders int64
		revenue               string
	}
	byBlock := map[string]*acc{}
	byDay := map[string]*acc{}
	for rows.Next() {
		var id, day, rev string
		var v, c, o int64
		if err := rows.Scan(&id, &day, &v, &c, &o, &rev); err != nil {
			rows.Close()
			return out, err
		}
		for _, m := range []struct {
			m   map[string]*acc
			key string
		}{{byBlock, id}, {byDay, day}} {
			a := m.m[m.key]
			if a == nil {
				a = &acc{revenue: "0"}
				m.m[m.key] = a
			}
			a.views += v
			a.clicks += c
			a.orders += o
			a.revenue = money.D(a.revenue).Add(money.D(rev)).Money()
		}
		out.Views += v
		out.Clicks += c
		out.Revenue = money.D(out.Revenue).Add(money.D(rev)).Money()
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return out, err
	}
	// Заказы «с главной» — разные заказы, а не сумма по блокам.
	if err := s.pool.QueryRow(ctx, `
		SELECT count(DISTINCT o.id) FROM orders o
		JOIN stores s ON s.id = o.store_id AND ($1 = '' OR s.network_id::text = $1) AND ($2 = '' OR s.id::text = $2)
		WHERE o.status NOT IN ('awaiting_payment', 'cancelled', 'expired')
		  AND (o.created_at AT TIME ZONE 'Asia/Tashkent')::date BETWEEN $3::date AND $4::date
		  AND EXISTS (SELECT 1 FROM order_items i WHERE i.order_id = o.id AND i.home_block_id IS NOT NULL)`,
		f.networkID, f.storeID, out.From, out.To).Scan(&out.Orders); err != nil {
		return out, err
	}

	// Названия блоков — из последних опубликованных версий (и удалённых блоков).
	names := map[string]HomeBlock{}
	if len(byBlock) > 0 {
		ids := make([]string, 0, len(byBlock))
		for id := range byBlock {
			ids = append(ids, id)
		}
		nrows, err := s.pool.Query(ctx, `
			SELECT DISTINCT ON (b->>'id') b FROM home_layout_versions v, jsonb_array_elements(v.blocks) b
			WHERE b->>'id' = ANY($1::text[]) ORDER BY b->>'id', v.published_at DESC`, ids)
		if err != nil {
			return out, err
		}
		for nrows.Next() {
			var raw []byte
			if err := nrows.Scan(&raw); err != nil {
				nrows.Close()
				return out, err
			}
			var b HomeBlock
			if json.Unmarshal(raw, &b) == nil {
				names[b.ID] = b
			}
		}
		nrows.Close()
		if err := nrows.Err(); err != nil {
			return out, err
		}
	}
	for id, a := range byBlock {
		st := BlockStat{BlockID: id, Views: a.views, Clicks: a.clicks, Orders: a.orders, Revenue: a.revenue, Title: "Удалённый блок"}
		if b, ok := names[id]; ok {
			st.Type, st.Title = b.Type, blockTitle(b)
		}
		if a.views > 0 {
			st.CTR = float64(a.clicks) / float64(a.views)
		}
		out.Blocks = append(out.Blocks, st)
	}
	sort.Slice(out.Blocks, func(i, j int) bool {
		a, b := out.Blocks[i], out.Blocks[j]
		if a.Orders != b.Orders {
			return a.Orders > b.Orders
		}
		if a.Clicks != b.Clicks {
			return a.Clicks > b.Clicks
		}
		return a.Views > b.Views
	})
	if full {
		for day, a := range byDay {
			out.Series = append(out.Series, DayStat{Day: day, Views: a.views, Clicks: a.clicks, Orders: a.orders, Revenue: a.revenue})
		}
		sort.Slice(out.Series, func(i, j int) bool { return out.Series[i].Day < out.Series[j].Day })
	} else {
		// На базовой статистике заказы и выручка закрыты.
		out.Orders, out.Revenue = 0, "0"
		for i := range out.Blocks {
			out.Blocks[i].Orders, out.Blocks[i].Revenue = 0, "0"
		}
	}
	if len(out.Blocks) > 0 && out.Blocks[0].Type != "" {
		top := out.Blocks[0]
		if full && top.Orders > 0 {
			out.Hint = fmt.Sprintf("%s приносит больше всего заказов", top.Title)
		} else if top.Clicks > 0 {
			out.Hint = fmt.Sprintf("%s нажимают чаще всего", top.Title)
		}
	}
	return out, nil
}

// StoreHomeStats — статистика витрины для панели магазина по тарифу:
// «Старт» — нет, «Бизнес» — показы и нажатия за 7 дней, «Про» — всё.
func (s *Service) StoreHomeStats(ctx context.Context, p *identity.Principal, storeID string, days int) (HomeStats, error) {
	if storeID != "" && !p.CanAccessStore(storeID) {
		return HomeStats{}, apperr.Forbidden("нет доступа к магазину")
	}
	plan, err := showcase.ForNetwork(ctx, s.pool, p.NetworkID)
	if err != nil {
		return HomeStats{}, err
	}
	switch plan.Effective.Stats {
	case "none":
		return HomeStats{}, showcase.Limit("stats", plan.Effective, 0, 0, "статистика витрины — с тарифа «Бизнес»")
	case "basic":
		days = 7
	}
	return s.homeStats(ctx, statsFilter{networkID: p.NetworkID, storeID: storeID, days: days}, plan.Effective.Stats == "full")
}

// AdminHomeStats — статистика для супер-админа: все сети или одна.
func (s *Service) AdminHomeStats(ctx context.Context, networkID string, days int) (HomeStats, error) {
	if networkID != "" && !httpx.IsUUID(networkID) {
		return HomeStats{}, apperr.NotFound("сеть не найдена")
	}
	return s.homeStats(ctx, statsFilter{networkID: networkID, days: days}, true)
}
