package start

import (
	"context"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Поиск по центральной базе на шаге «Мои товары»: товары общего каталога и
// свои товары сети. У каждого — отметка, что он уже в «Моих товарах».

// Товары, которые магазин может завести: общий каталог и свои товары сети ($1).
const catalogWhere = `p.is_active AND (p.network_id IS NULL OR p.network_id = $1)`

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

// likeEscape — слово для LIKE '%…%' без спецсимволов.
func likeEscape(w string) string {
	return strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(w)
}

// Search — товары центральной базы по штрихкоду (точно) или названию: каждое
// слово запроса должно встречаться в русском или узбекском названии.
// Сначала — совпадение штрихкода, потом названия, начинающиеся с запроса.
func (s *Service) Search(ctx context.Context, p *identity.Principal, f SearchFilter) ([]SearchItem, error) {
	st, err := s.store(ctx, s.pool, p, f.StoreID)
	if err != nil {
		return nil, err
	}
	q := strings.ToLower(strings.TrimSpace(f.Query))
	if len([]rune(q)) < 2 {
		return []SearchItem{}, nil
	}
	words := []string{}
	for _, w := range strings.Fields(q) {
		words = append(words, likeEscape(w))
	}
	draft, err := s.draftID(ctx, s.pool, st)
	if err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT p.id, loc(p.name, p.name_uz), p.images[1], loc(u.short_name, u.short_name_uz), COALESCE(sp.price, np.price, p.base_price)::text,
		       (SELECT min(pb.barcode) FROM product_barcodes pb WHERE pb.product_id = p.id),
		       p.network_id IS NOT NULL, p.moderation_status,
		       l.product_id IS NOT NULL OR a.product_id IS NOT NULL, l.product_id IS NULL AND a.product_id IS NOT NULL
		FROM products p
		JOIN units u ON u.id = p.unit_id
		LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = $4 AND sp.store_id = $5
		LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = $4 AND np.store_id IS NULL
		LEFT JOIN start_lines l ON l.draft_id::text = $6 AND l.product_id = p.id
		LEFT JOIN store_products a ON a.store_id = $5 AND a.product_id = p.id
		WHERE `+catalogWhere+`
		  AND (EXISTS (SELECT 1 FROM product_barcodes pb WHERE pb.product_id = p.id AND pb.barcode = $2)
		       OR NOT EXISTS (SELECT 1 FROM unnest($3::text[]) w
		                      WHERE NOT (lower(p.name) LIKE '%' || w || '%' OR lower(p.name_uz) LIKE '%' || w || '%')))
		ORDER BY EXISTS (SELECT 1 FROM product_barcodes pb WHERE pb.product_id = p.id AND pb.barcode = $2) DESC,
		         (lower(p.name) LIKE $7 || '%' OR lower(p.name_uz) LIKE $7 || '%') DESC,
		         loc(p.name, p.name_uz), p.id
		LIMIT $8 OFFSET $9`,
		p.NetworkID, strings.TrimSpace(f.Query), words, st.PriceTypeID, st.ID, draft, likeEscape(q), f.Page.Limit, f.Page.Offset)
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
