package start

import (
	"context"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/productsearch"
)

// Поиск по центральной базе на шаге «Мои товары»: товары общего каталога и
// свои товары сети. У каждого — отметка, что он уже в «Моих товарах».

type SearchItem struct {
	ProductID    string  `json:"product_id"`
	Name         string  `json:"name"`
	Image        *string `json:"image"`
	UnitShort    string  `json:"unit_short"`
	CurrentPrice string  `json:"current_price"`
	Barcode      *string `json:"barcode"`
	Own          bool    `json:"own"`
	Moderation   string  `json:"moderation"`
	// Added — товар уже в «Моих товарах» (в черновике или в ассортименте магазина).
	Added bool `json:"added"`
	// InStore — уже в товарах магазина (был на складе или в цене магазина), а не в этом списке.
	InStore bool `json:"in_store"`
}

type SearchFilter struct {
	StoreID string
	Query   string
	Page    httpx.Page
}

// Search — товары центральной базы по штрихкоду (точно) или названию: каждое
// слово запроса должно встречаться в русском или узбекском названии (в любой
// письменности, см. productsearch). Сначала — точные совпадения и названия,
// начинающиеся с запроса, потом популярные.
func (s *Service) Search(ctx context.Context, p *identity.Principal, f SearchFilter) ([]SearchItem, error) {
	st, err := s.store(ctx, s.pool, p, f.StoreID)
	if err != nil {
		return nil, err
	}
	if len([]rune(strings.TrimSpace(f.Query))) < 2 {
		return []SearchItem{}, nil
	}
	m, err := productsearch.Resolve(ctx, s.pool, f.Query, productsearch.Scope{NetworkID: p.NetworkID})
	if err != nil || m.Empty() {
		return []SearchItem{}, err
	}
	draft, err := s.draftID(ctx, s.pool, st)
	if err != nil {
		return nil, err
	}
	var draftArg any // нет черновика — NULL
	if draft != "" {
		draftArg = draft
	}
	args := []any{st.PriceTypeID, st.ID, draftArg, f.Page.Limit, f.Page.Offset}
	scope := productsearch.Scope{NetworkID: p.NetworkID}.Where("s", &args)
	where := m.Where("s", &args)
	rank := m.Rank("s", &args)
	// Сначала отбираем страницу по индексу (узкая таблица product_search),
	// потом дочитываем товар, цены и отметки — только для неё.
	rows, err := s.pool.Query(ctx, `
		WITH c AS (
			SELECT s.product_id AS id, `+rank+` AS rank, s.score, `+productsearch.NameOrder("s")+` AS sort
			FROM product_search s
			WHERE `+scope+` AND `+where+`
			ORDER BY 2 DESC, 3 DESC, 4, 1
			LIMIT $4 OFFSET $5
		)
		SELECT p.id, loc(p.name, p.name_uz), p.images[1], loc(u.short_name, u.short_name_uz), COALESCE(sp.price, np.price, p.base_price)::text,
		       (SELECT min(pb.barcode) FROM product_barcodes pb WHERE pb.product_id = p.id),
		       p.network_id IS NOT NULL, p.moderation_status,
		       l.product_id IS NOT NULL OR a.product_id IS NOT NULL, l.product_id IS NULL AND a.product_id IS NOT NULL
		FROM c
		JOIN products p ON p.id = c.id
		JOIN units u ON u.id = p.unit_id
		LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = $1 AND sp.store_id = $2
		LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = $1 AND np.store_id IS NULL
		LEFT JOIN start_lines l ON l.draft_id = $3::uuid AND l.product_id = p.id
		LEFT JOIN store_products a ON a.store_id = $2 AND a.product_id = p.id
		ORDER BY c.rank DESC, c.score DESC, c.sort, c.id`, productsearch.Args(args)...)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (SearchItem, error) {
		var it SearchItem
		err := row.Scan(&it.ProductID, &it.Name, &it.Image, &it.UnitShort, &it.CurrentPrice, &it.Barcode, &it.Own, &it.Moderation, &it.Added, &it.InStore)
		return it, err
	})
}

// draftID — открытый черновик или пустая строка.
func (s *Service) draftID(ctx context.Context, q db.Querier, st store) (string, error) {
	id, _, err := openDraft(ctx, q, st.WarehouseID)
	if err != nil || id == nil {
		return "", err
	}
	return *id, nil
}
