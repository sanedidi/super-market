package server_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// TestAbcXyz — ABC/XYZ-анализ: группы по накопленной доле, XYZ по неделям,
// возвраты, фильтр категории, «без продаж», новый магазин без 4 недель.
func TestAbcXyz(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	ctx := context.Background()
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")

	root := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Продукты"}), 201, "cat").str("id")
	bakery := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Выпечка", "parent_id": root}), 201, "sub").str("id")
	var pcs string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		if u["short_name"] == "шт" {
			pcs = u["id"].(string)
		}
	}
	product := func(name, cat string, price int) string {
		return a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
			"name": name, "category_id": cat, "unit_id": pcs, "base_price": price,
		}), 201, name).str("id")
	}
	bread := product("Хлеб", bakery, 5000)
	water := product("Вода", root, 10000)
	cake := product("Торт", bakery, 100000)
	spice := product("Специи", root, 2000)
	candy := product("Конфеты", root, 3000)

	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
	items := []map[string]any{}
	for _, id := range []string{bread, water, cake, spice, candy} {
		items = append(items, map[string]any{"product_id": id, "qty": 1000, "price": 1000})
	}
	doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{"type": "posting", "warehouse_id": wh, "items": items}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post")
	var cash string
	for _, m := range a.expect(a.do("GET", "/store/finance/payment-methods?store_id="+store, tok, nil), 200, "methods").items() {
		if m["name"] == "Наличные" {
			cash = m["id"].(string)
		}
	}

	// 8 недель: хлеб ровно по 20, вода 5/7 через неделю, торт дважды, специи по 1.
	tz := time.FixedZone("Asia/Tashkent", 5*60*60)
	now := time.Now().In(tz)
	to := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, tz).AddDate(0, 0, 1)
	from := to.AddDate(0, 0, -56)
	n := 0
	var firstBreadSale string
	sell := func(week int, id string, qty, price int) {
		n++
		s := a.expect(a.do("POST", "/store/sales", tok, map[string]any{
			"client_uid": fmt.Sprintf("abc-sale-%04d", n), "store_id": store,
			"items":    []map[string]any{{"product_id": id, "qty": qty}},
			"payments": []map[string]any{{"payment_method_id": cash, "amount": qty * price}},
		}), 201, "sale")
		at := from.AddDate(0, 0, 7*week).Add(10 * time.Hour)
		if _, err := pool.Exec(ctx, `UPDATE sales SET sold_at = $2 WHERE id = $1`, s.str("id"), at); err != nil {
			t.Fatal(err)
		}
		if id == bread && firstBreadSale == "" {
			firstBreadSale = s.str("id")
		}
	}
	for w := 0; w < 8; w++ {
		sell(w, bread, 20, 5000)
		sell(w, water, 5+2*(w%2), 10000)
		sell(w, spice, 1, 2000)
		if w == 2 || w == 6 {
			sell(w, cake, 1, 100000)
		}
	}
	// Возврат одного хлеба (сегодня — последняя неделя периода).
	a.expect(a.do("POST", "/store/sales/returns", tok, map[string]any{
		"sale_id": firstBreadSale, "payment_method_id": cash, "items": []map[string]any{{"sale_line": 1, "qty": 1}},
	}), 201, "return")

	// to не включается — передаём завтрашний день.
	period := fmt.Sprintf("from=%s&to=%s", from.Format("2006-01-02"), to.Format("2006-01-02"))
	r := a.expect(a.do("GET", "/store/reports/abc-xyz?"+period, tok, nil), 200, "abc")
	if r.Body["weeks"].(float64) != 8 || r.Body["xyz_available"] != true || r.str("totals", "revenue") != "1491000.00" {
		t.Fatalf("abc head = weeks %v xyz %v totals %v", r.Body["weeks"], r.Body["xyz_available"], r.Body["totals"])
	}
	got := map[string]map[string]any{}
	var order []string
	for _, x := range r.Body["items"].([]any) {
		it := x.(map[string]any)
		got[it["name"].(string)] = it
		order = append(order, it["name"].(string))
	}
	if fmt.Sprint(order) != "[Хлеб Вода Торт Специи]" {
		t.Fatalf("order = %v", order)
	}
	want := map[string]string{"Хлеб": "AX", "Вода": "AY", "Торт": "BZ", "Специи": "CX"}
	for name, cell := range want {
		it := got[name]
		if it["abc"].(string)+it["xyz"].(string) != cell {
			t.Fatalf("%s = %v%v, want %s (%v)", name, it["abc"], it["xyz"], cell, it)
		}
	}
	b := got["Хлеб"]
	if b["revenue"] != "795000.00" || b["qty"] != "159.000" || b["stock"] != "841.000" || b["days_cover"].(float64) != 301 || b["share"].(float64) != 53.32 {
		t.Fatalf("bread = %v", b)
	}
	if got["Вода"]["variation"].(float64) != 16.67 {
		t.Fatalf("water variation = %v", got["Вода"]["variation"])
	}
	if g := r.Body["groups"].(map[string]any)["A"].(map[string]any); g["count"].(float64) != 2 || g["revenue"] != "1275000.00" {
		t.Fatalf("group A = %v", g)
	}
	cells := map[string]float64{}
	for _, x := range r.Body["matrix"].([]any) {
		c := x.(map[string]any)
		cells[c["cell"].(string)] = c["count"].(float64)
	}
	if len(cells) != 9 || cells["AX"] != 1 || cells["AY"] != 1 || cells["BZ"] != 1 || cells["CX"] != 1 || cells["CZ"] != 0 {
		t.Fatalf("matrix = %v", r.Body["matrix"])
	}
	ns := r.Body["no_sale_items"].([]any)
	if len(ns) != 1 || ns[0].(map[string]any)["name"] != "Конфеты" || r.str("no_sales", "stock_value") != "1000000.00" {
		t.Fatalf("no sales = %v / %v", ns, r.Body["no_sales"])
	}

	// По умолчанию — 12 недель, но магазин продаёт только 8: пустые недели до
	// первой продажи не считаются, результат тот же.
	def := a.expect(a.do("GET", "/store/reports/abc-xyz", tok, nil), 200, "default")
	if def.Body["weeks"].(float64) != 8 || def.str("totals", "revenue") != "1491000.00" {
		t.Fatalf("default = weeks %v totals %v from %v", def.Body["weeks"], def.Body["totals"], def.Body["analysis_from"])
	}

	// По количеству и по прибыли: себестоимость 1 000 за штуку.
	q := a.expect(a.do("GET", "/store/reports/abc-xyz?by=qty&"+period, tok, nil), 200, "by qty")
	if it := q.Body["items"].([]any)[0].(map[string]any); it["name"] != "Хлеб" || q.Body["by"] != "qty" {
		t.Fatalf("by qty = %v", it)
	}
	p := a.expect(a.do("GET", "/store/reports/abc-xyz?by=profit&"+period, tok, nil), 200, "by profit")
	if p.str("totals", "profit") != "1274000.00" {
		t.Fatalf("profit = %v", p.Body["totals"])
	}

	// Категория «Выпечка» с подкатегориями: хлеб и торт.
	c := a.expect(a.do("GET", "/store/reports/abc-xyz?category_id="+bakery+"&"+period, tok, nil), 200, "category")
	if l := c.Body["items"].([]any); len(l) != 2 || len(c.Body["no_sale_items"].([]any)) != 0 {
		t.Fatalf("category items = %v", l)
	}
	if l := a.expect(a.do("GET", "/store/reports/abc-xyz?category_id="+root+"&"+period, tok, nil), 200, "root").Body["items"].([]any); len(l) != 4 {
		t.Fatalf("root category items = %d", len(l))
	}

	// 3 недели — XYZ ещё нет, до него 7 дней.
	short := fmt.Sprintf("from=%s&to=%s", to.AddDate(0, 0, -21).Format("2006-01-02"), to.Format("2006-01-02"))
	s := a.expect(a.do("GET", "/store/reports/abc-xyz?"+short, tok, nil), 200, "short")
	if s.Body["xyz_available"] != false || s.Body["xyz_days_left"].(float64) != 7 || len(s.Body["matrix"].([]any)) != 0 {
		t.Fatalf("short = %v %v %v", s.Body["xyz_available"], s.Body["xyz_days_left"], s.Body["matrix"])
	}
	if it := s.Body["items"].([]any)[0].(map[string]any); it["xyz"] != nil || it["variation"] != nil || it["abc"] != "A" {
		t.Fatalf("short item = %v", it)
	}

	// Период без продаж: XYZ нет, весь товар со склада — «без продаж».
	e := a.expect(a.do("GET", "/store/reports/abc-xyz?from=2025-01-01&to=2025-03-01", tok, nil), 200, "empty")
	if e.Body["weeks"].(float64) != 0 || e.Body["xyz_available"] != false || len(e.Body["items"].([]any)) != 0 || len(e.Body["no_sale_items"].([]any)) != 5 {
		t.Fatalf("empty = %v", e.Body)
	}

	a.expect(a.do("GET", "/store/reports/abc-xyz?by=margin", tok, nil), 400, "bad by")
	a.expect(a.do("GET", "/store/reports/abc-xyz?category_id=x", tok, nil), 400, "bad category")
	a.expect(a.do("GET", "/store/reports/abc-xyz?from=2024-01-01&to=2026-01-01", tok, nil), 400, "too long")
}
