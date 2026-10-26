package assistant

// Товар по словам владельца: «kola», «sut», «non», «Nestle 1 litr». Владелец
// говорит коротко и по-своему — помощник ищет сразу по нескольким вариантам
// (find_products) и запоминает, как владелец называет товар
// (remember_alias → assistant_aliases).

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/productsearch"
)

type foundProduct struct {
	ProductID    string `json:"product_id"`
	Name         string `json:"name"`
	Unit         string `json:"unit,omitempty"`
	Qty          string `json:"qty,omitempty"`
	PerDay       string `json:"per_day,omitempty"`
	Pack         any    `json:"pack,omitempty"`
	LastCost     any    `json:"last_cost,omitempty"`
	LastSupplier any    `json:"last_supplier,omitempty"`
	Price        any    `json:"price,omitempty"`
	// Stores — в скольких магазинах Super Market продаётся (для выбора из
	// почти одинаковых карточек базы).
	Stores int `json:"stores,omitempty"`
	// Where — mine (в «Моих товарах»), base (в базе Super Market, не добавлен), alias (так владелец называл раньше).
	Where string `json:"where"`
	Query string `json:"query"`
}

// aliasWord — слово владельца в виде ключа: без регистра и знаков.
func aliasWord(w string) string {
	w = productsearch.Fold(w)
	if r := []rune(w); len(r) > 60 {
		w = string(r[:60])
	}
	return w
}

// findProducts — товары по нескольким вариантам названия: сначала то, как
// владелец уже называл товар, потом «Мои товары», потом база Super Market.
func (s *Service) findProducts(ctx context.Context, st *agentState, queries []string) string {
	seen := map[string]bool{}
	out := []foundProduct{}
	add := func(f foundProduct) {
		if f.ProductID == "" || seen[f.ProductID] || len(out) >= 15 {
			return
		}
		seen[f.ProductID] = true
		out = append(out, f)
	}
	clean := []string{}
	for _, q := range queries {
		if q = strings.TrimSpace(q); q != "" && len(clean) < 8 {
			clean = append(clean, q)
		}
	}
	// Как владелец называл раньше.
	for _, q := range clean {
		var id string
		if s.pool.QueryRow(ctx, `SELECT product_id::text FROM assistant_aliases WHERE network_id = $1 AND word = $2`, st.p.NetworkID, aliasWord(q)).Scan(&id) == nil {
			_, resp := s.loopback(ctx, st.token, st.lang, http.MethodGet, "/store/inventory/my-products", map[string]any{"store_id": st.storeID, "product_id": id, "limit": 1}, nil)
			for _, it := range items(resp) {
				f := mine(it, q)
				f.Where = "alias"
				add(f)
			}
		}
	}
	for _, q := range clean {
		_, resp := s.loopback(ctx, st.token, st.lang, http.MethodGet, "/store/inventory/my-products", map[string]any{"store_id": st.storeID, "q": q, "order": "name", "limit": 10}, nil)
		for _, it := range items(resp) {
			add(mine(it, q))
		}
	}
	if len(out) == 0 {
		for _, q := range clean {
			_, resp := s.loopback(ctx, st.token, st.lang, http.MethodGet, "/store/start/search", map[string]any{"store_id": st.storeID, "q": q, "limit": 8}, nil)
			for _, it := range items(resp) {
				if added, _ := it["added"].(bool); added {
					continue
				}
				f := foundProduct{ProductID: str(it["product_id"]), Name: str(it["name"]), Unit: str(it["unit_short"]), Price: it["current_price"], Where: "base", Query: q}
				_ = s.pool.QueryRow(ctx, `SELECT count(*)::int FROM store_products WHERE product_id = $1::uuid`, f.ProductID).Scan(&f.Stores)
				add(f)
			}
		}
	}
	b, _ := json.Marshal(map[string]any{"items": out, "hint": findHint(out)})
	return string(b)
}

func findHint(out []foundProduct) string {
	switch {
	case len(out) == 0:
		return "ничего не нашлось ни в «Моих товарах», ни в базе Super Market: попробуй другие варианты (бренд полностью, по-русски и по-узбекски, латиницей и кириллицей), потом предложи «Сфотографировать товар» (attach product)"
	case out[0].Where == "alias":
		return "первый — так владелец уже называл этот товар: бери его без вопросов"
	case len(out) == 1:
		return "один товар — бери его"
	}
	return "несколько товаров: если они подходят под слова владельца одинаково (дубли одной карточки) — не спрашивай: бери where mine, затем с большим per_day или stores, скажи, какой взял, и дай кнопки «другой» (ref — product_id). Спрашивай только если варианты правда разные (размер, вкус). После выбора владельца вызови remember_alias"
}

func mine(it map[string]any, q string) foundProduct {
	return foundProduct{ProductID: str(it["product_id"]), Name: str(it["name"]), Unit: str(it["unit_short"]), Qty: str(it["qty"]),
		PerDay: str(it["per_day"]), Pack: it["pack"], LastCost: it["last_cost"], LastSupplier: it["last_supplier"], Price: it["price"], Where: "mine", Query: q}
}

func items(resp any) []map[string]any {
	m, _ := resp.(map[string]any)
	raw, _ := m["items"].([]any)
	out := make([]map[string]any, 0, len(raw))
	for _, x := range raw {
		if it, ok := x.(map[string]any); ok {
			out = append(out, it)
		}
	}
	return out
}

func str(v any) string {
	s, _ := v.(string)
	return s
}

// rememberAlias — «kola» у этого владельца = товар.
func (s *Service) rememberAlias(ctx context.Context, st *agentState, word, productID string) string {
	w := aliasWord(word)
	if len([]rune(w)) < 2 || !httpx.IsUUID(productID) {
		return `{"error": "word: 2–60 символов, product_id — id товара"}`
	}
	tag, err := s.pool.Exec(ctx, `
		INSERT INTO assistant_aliases (network_id, word, product_id)
		SELECT $1, $2, p.id FROM products p WHERE p.id = $3 AND (p.network_id IS NULL OR p.network_id = $1)
		ON CONFLICT (network_id, word) DO UPDATE SET product_id = EXCLUDED.product_id, uses = assistant_aliases.uses + 1, updated_at = now()`,
		st.p.NetworkID, w, productID)
	if err != nil || tag.RowsAffected() == 0 {
		return `{"error": "товар не найден"}`
	}
	return `{"ok": true}`
}

// aliases — что владелец называл раньше (для контекста): «kola → Coca-Cola 1,5 л».
func (s *Service) aliases(ctx context.Context, networkID string) []string {
	rows, err := s.pool.Query(ctx, `
		SELECT a.word || ' → ' || loc(p.name, p.name_uz) FROM assistant_aliases a JOIN products p ON p.id = a.product_id
		WHERE a.network_id = $1 ORDER BY a.uses DESC, a.updated_at DESC LIMIT 60`, networkID)
	if err != nil {
		return nil
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var l string
		if rows.Scan(&l) == nil {
			out = append(out, l)
		}
	}
	return out
}
