package server_test

import (
	"strconv"
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

// TestSalesAndStockSummary — итоги считаются сервером по всем записям,
// а не по странице; поиск чека по номеру и телефону; возвраты по чеку.
func TestSalesAndStockSummary(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, sugar := catalogBasics(t, a, adminTok)
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
	doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "posting", "warehouse_id": wh,
		"items": []map[string]any{{"product_id": cola, "qty": 10, "price": 10000}, {"product_id": sugar, "qty": 5, "price": 8000}},
	}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post")
	cash := a.expect(a.do("GET", "/store/finance/payment-methods?store_id="+store, tok, nil), 200, "methods").items()[0]["id"].(string)

	sell := func(uid, phone string, n int, discount int) resp {
		return a.expect(a.do("POST", "/store/sales", tok, map[string]any{
			"client_uid": uid, "store_id": store, "customer_phone": phone,
			"items":    []map[string]any{{"product_id": cola, "qty": n, "discount": discount}},
			"payments": []map[string]any{{"payment_method_id": cash, "amount": 15000*n - discount}},
		}), 201, "sale "+uid)
	}
	s1 := sell("sum-000001", "+998 90 123-45-67", 1, 0)
	sell("sum-000002", "", 2, 1000)
	s3 := sell("sum-000003", "", 1, 0)
	a.expect(a.do("POST", "/store/sales/returns", tok, map[string]any{
		"sale_id": s1.str("id"), "payment_method_id": cash, "items": []map[string]any{{"sale_line": 1, "qty": 1}},
	}), 201, "return")

	// Список на одной странице — 1 чек, итоги — по всем трём.
	if n := len(a.expect(a.do("GET", "/store/sales?limit=1&store_id="+store, tok, nil), 200, "page").items()); n != 1 {
		t.Fatalf("page = %d", n)
	}
	sum := a.expect(a.do("GET", "/store/sales/summary?store_id="+store, tok, nil), 200, "summary")
	if sum.Body["sales_count"].(float64) != 3 || sum.str("subtotal") != "60000.00" || sum.str("discount") != "1000.00" ||
		sum.str("revenue") != "59000.00" || sum.Body["returns_count"].(float64) != 1 || sum.str("returns") != "15000.00" ||
		sum.str("net") != "44000.00" {
		t.Fatalf("summary = %v", sum.Body)
	}
	empty := a.expect(a.do("GET", "/store/sales/summary?from=2000-01-01&to=2000-01-02", tok, nil), 200, "empty summary")
	if empty.Body["sales_count"].(float64) != 0 || empty.str("revenue") != "0.00" {
		t.Fatalf("empty summary = %v", empty.Body)
	}
	a.expect(a.do("GET", "/store/sales/summary?from=bad", tok, nil), 400, "bad period")

	// Поиск: по номеру чека и по телефону покупателя.
	num := s3.Body["number"].(float64)
	found := a.expect(a.do("GET", "/store/sales?q=%E2%84%96"+itoa(int(num)), tok, nil), 200, "by number").items()
	if len(found) != 1 || found[0]["id"] != s3.str("id") {
		t.Fatalf("by number = %v", found)
	}
	found = a.expect(a.do("GET", "/store/sales?q=4567", tok, nil), 200, "by phone").items()
	if len(found) != 1 || found[0]["id"] != s1.str("id") {
		t.Fatalf("by phone = %v", found)
	}
	// Возвраты по чеку.
	if r := a.expect(a.do("GET", "/store/sales/returns?sale_id="+s1.str("id"), tok, nil), 200, "returns of sale").items(); len(r) != 1 {
		t.Fatalf("returns of sale = %v", r)
	}
	if r := a.expect(a.do("GET", "/store/sales/returns?sale_id="+s3.str("id"), tok, nil), 200, "no returns").items(); len(r) != 0 {
		t.Fatalf("returns of s3 = %v", r)
	}

	// Остатки: итоги по всем строкам; себестоимость — только с правом.
	st := a.expect(a.do("GET", "/store/inventory/stock/summary?store_id="+store, tok, nil), 200, "stock summary")
	// Кола: 10 − 4 проданы + 1 возврат = 7 × 10 000; сахар 5 × 8 000.
	if st.Body["positions"].(float64) != 2 || st.Body["products"].(float64) != 2 || st.str("cost_value") != "110000.00" {
		t.Fatalf("stock summary = %v", st.Body)
	}
	if n := len(a.expect(a.do("GET", "/store/inventory/stock?store_id="+store+"&limit=1", tok, nil), 200, "stock page").items()); n != 1 {
		t.Fatalf("stock page = %d", n)
	}
	seller, _ := employee(t, a, tok, "+998900000030", "Продавец", nil, []string{store})
	st = a.expect(a.do("GET", "/store/inventory/stock/summary?warehouse_id="+wh, seller, nil), 200, "seller stock summary")
	if st.Body["positions"].(float64) != 2 || st.Body["cost_value"] != nil {
		t.Fatalf("seller stock summary = %v", st.Body)
	}

	// История движения: остаток после каждой операции верен на любой странице.
	moves := a.expect(a.do("GET", "/store/inventory/movements?warehouse_id="+wh+"&product_id="+cola, tok, nil), 200, "moves").items()
	if len(moves) != 5 || moves[0]["balance_after"] != "7.000" || moves[len(moves)-1]["balance_after"] != "10.000" {
		t.Fatalf("moves = %v", moves)
	}
	second := a.expect(a.do("GET", "/store/inventory/movements?warehouse_id="+wh+"&product_id="+cola+"&limit=2&offset=2", tok, nil), 200, "moves p2").items()
	if len(second) != 2 || second[0]["balance_after"] != moves[2]["balance_after"] {
		t.Fatalf("moves page 2 = %v", second)
	}
	sm := a.expect(a.do("GET", "/store/inventory/movements?warehouse_id="+wh+"&product_id="+cola, seller, nil), 200, "seller moves").items()
	if sm[0]["unit_cost"] != nil {
		t.Fatalf("seller sees movement cost: %v", sm[0])
	}
}

func itoa(n int) string { return strconv.Itoa(n) }
