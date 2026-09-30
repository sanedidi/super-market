package server_test

import (
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

func ids(items []map[string]any) map[string]bool {
	out := map[string]bool{}
	for _, it := range items {
		out[it["id"].(string)] = true
	}
	return out
}

// TestStockDocumentsStoreFilter — список складских документов по магазину
// (перемещения видны и магазину-получателю), постранично; цена в строке — до 4 знаков.
func TestStockDocumentsStoreFilter(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, _ := catalogBasics(t, a, adminTok)
	tok, s1 := setupNetwork(t, a, adminTok, "+998900000002")
	s2 := a.expect(a.do("POST", "/store/stores", tok, map[string]any{"name": "Магазин 2"}), 201, "store 2").str("id")
	wh1 := a.expect(a.do("GET", "/store/warehouses?store_id="+s1, tok, nil), 200, "wh1").items()[0]["id"].(string)
	wh2 := a.expect(a.do("GET", "/store/warehouses?store_id="+s2, tok, nil), 200, "wh2").items()[0]["id"].(string)

	posting := func(wh, price string) string {
		d := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
			"type": "posting", "warehouse_id": wh, "items": []map[string]any{{"product_id": cola, "qty": 5, "price": price}},
		}), 201, "posting")
		a.expect(a.do("POST", "/store/inventory/documents/"+d.str("id")+"/post", tok, nil), 200, "post")
		return d.str("id")
	}
	p1 := posting(wh1, "1234.5678")
	p2 := posting(wh2, "100")
	tr := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "transfer", "warehouse_id": wh1, "to_warehouse_id": wh2, "items": []map[string]any{{"product_id": cola, "qty": 1}},
	}), 201, "transfer").str("id")

	doc := a.expect(a.do("GET", "/store/inventory/documents/"+p1, tok, nil), 200, "doc")
	items := doc.Body["items"].([]any)
	if price := items[0].(map[string]any)["price"]; price != "1234.5678" {
		t.Fatalf("price keeps 4 decimals: %v", price)
	}

	got := ids(a.expect(a.do("GET", "/store/inventory/documents?store_id="+s1, tok, nil), 200, "store 1 docs").items())
	if len(got) != 2 || !got[p1] || !got[tr] {
		t.Fatalf("store 1 docs = %v", got)
	}
	got = ids(a.expect(a.do("GET", "/store/inventory/documents?store_id="+s2, tok, nil), 200, "store 2 docs").items())
	if len(got) != 2 || !got[p2] || !got[tr] {
		t.Fatalf("store 2 docs = %v (incoming transfer must be visible)", got)
	}
	got = ids(a.expect(a.do("GET", "/store/inventory/documents?type=posting&store_id="+s2, tok, nil), 200, "store 2 postings").items())
	if len(got) != 1 || !got[p2] {
		t.Fatalf("store 2 postings = %v", got)
	}
	a.expect(a.do("GET", "/store/inventory/documents?store_id=nope", tok, nil), 400, "bad store_id")

	// Страницы не пересекаются.
	page1 := a.expect(a.do("GET", "/store/inventory/documents?limit=2", tok, nil), 200, "page 1").items()
	page2 := a.expect(a.do("GET", "/store/inventory/documents?limit=2&offset=2", tok, nil), 200, "page 2").items()
	if len(page1) != 2 || len(page2) != 1 || ids(page1)[page2[0]["id"].(string)] {
		t.Fatalf("pages = %v / %v", page1, page2)
	}
}
