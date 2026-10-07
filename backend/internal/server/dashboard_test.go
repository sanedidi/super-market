package server_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// TestSalesDashboard — данные главной: выручка по часам и дням сходится с
// «Прибылью и убытком», сравнение с прошлой неделей, «Когда покупают»,
// разрезы по категориям, товарам и оплатам, компактный ABC/XYZ.
func TestSalesDashboard(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	a := newAPI(t, paymeConfig(), pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	shop := newAdminShop(t, a, adminTok, "+998900000002", "+998901234567")
	tok, _ := a.login("+998900000002", identity.AppStore)

	bakery := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Выпечка"}), 201, "bakery").str("id")
	breadCat := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Хлеб", "parent_id": bakery}), 201, "bread cat").str("id")
	var pcs string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		if u["short_name"] == "шт" {
			pcs = u["id"].(string)
		}
	}
	bread := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
		"name": "Хлеб «Нон»", "category_id": breadCat, "unit_id": pcs, "base_price": 50000,
	}), 201, "bread").str("id")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+shop.store, tok, nil), 200, "wh").items()[0]["id"].(string)
	d := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{"type": "posting", "warehouse_id": wh,
		"items": []map[string]any{{"product_id": bread, "qty": 4, "price": 20000}}}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+d.str("id")+"/post", tok, nil), 200, "post")

	var cash, card, cardName string
	for _, m := range a.expect(a.do("GET", "/store/finance/payment-methods?store_id="+shop.store, tok, nil), 200, "methods").items() {
		if m["name"] == "Наличные" {
			cash = m["id"].(string)
		} else {
			card, cardName = m["id"].(string), m["name"].(string)
		}
	}

	// Вчера и неделей раньше — периоды целиком в прошлом, тест не зависит от часа запуска.
	tz := time.FixedZone("Asia/Tashkent", 5*60*60)
	now := time.Now().In(tz)
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, tz)
	yday := today.AddDate(0, 0, -1)
	n := 0
	sell := func(at time.Time, items []map[string]any, pays []map[string]any) string {
		n++
		s := a.expect(a.do("POST", "/store/sales", tok, map[string]any{
			"client_uid": fmt.Sprintf("dash-sale-%04d", n), "store_id": shop.store, "items": items, "payments": pays,
		}), 201, "sale")
		if _, err := pool.Exec(ctx, `UPDATE sales SET sold_at = $2 WHERE id = $1`, s.str("id"), at); err != nil {
			t.Fatal(err)
		}
		return s.str("id")
	}
	item := func(id string, qty int) map[string]any { return map[string]any{"product_id": id, "qty": qty} }
	pay := func(m string, amount int) map[string]any {
		return map[string]any{"payment_method_id": m, "amount": amount}
	}

	sell(yday.Add(10*time.Hour+15*time.Minute), []map[string]any{item(shop.cola, 2)}, []map[string]any{pay(cash, 30000)})
	sell(yday.Add(10*time.Hour+40*time.Minute), []map[string]any{item(bread, 1), item(shop.cola, 1)}, []map[string]any{pay(card, 65000)})
	c := sell(yday.Add(15*time.Hour+5*time.Minute), []map[string]any{item(bread, 3)}, []map[string]any{pay(cash, 150000)})
	ret := a.expect(a.do("POST", "/store/sales/returns", tok, map[string]any{
		"sale_id": c, "payment_method_id": cash, "items": []map[string]any{{"sale_line": 1, "qty": 1}},
	}), 201, "return")
	if _, err := pool.Exec(ctx, `UPDATE customer_returns SET created_at = $2 WHERE id = $1`, ret.str("id"), yday.Add(16*time.Hour)); err != nil {
		t.Fatal(err)
	}
	order, _ := shop.order(t)
	if _, err := pool.Exec(ctx, `UPDATE orders SET status = 'delivered', paid_at = $2, delivered_at = $2 WHERE id = $1`, order, yday.Add(18*time.Hour+30*time.Minute)); err != nil {
		t.Fatal(err)
	}
	online := sqlStr(t, pool, `SELECT (subtotal + delivery_fee)::numeric(18,2)::text FROM orders WHERE id = $1`, order)
	sell(yday.AddDate(0, 0, -7).Add(10*time.Hour+20*time.Minute), []map[string]any{item(shop.cola, 1)}, []map[string]any{pay(cash, 15000)})

	day := fmt.Sprintf("from=%s&to=%s", yday.Format("2006-01-02"), today.Format("2006-01-02"))

	// По часам за вчера: суммы совпадают с «Прибылью и убытком».
	s := a.expect(a.do("GET", "/store/reports/sales-series?bucket=hour&compare=week&"+day, tok, nil), 200, "series")
	pl := a.expect(a.do("GET", "/store/reports/profit-loss?"+day, tok, nil), 200, "pl")
	if s.str("totals", "revenue") != pl.str("revenue", "total") || s.str("totals", "profit") != pl.str("gross_profit") {
		t.Fatalf("series totals %v ≠ P&L %v / %v", s.Body["totals"], pl.Body["revenue"], pl.Body["gross_profit"])
	}
	pts := s.Body["points"].([]any)
	if len(pts) != 24 {
		t.Fatalf("points = %d", len(pts))
	}
	hour := func(h int) map[string]any { return pts[h].(map[string]any) }
	if p := hour(10); p["pos"] != "95000.00" || p["checks"].(float64) != 2 || p["online"] != "0.00" {
		t.Fatalf("10:00 = %v", p)
	}
	if p := hour(16); p["pos"] != "-50000.00" || p["checks"].(float64) != 0 {
		t.Fatalf("16:00 (возврат) = %v", p)
	}
	if p := hour(18); p["online"] != online || p["orders"].(float64) != 1 {
		t.Fatalf("18:00 (заказ) = %v, want online %s", p, online)
	}
	if s.str("totals", "pos") != "195000.00" || s.Body["totals"].(map[string]any)["checks"].(float64) != 3 || s.str("totals", "avg_check") != "81666.67" {
		t.Fatalf("totals = %v", s.Body["totals"])
	}
	// Неделей раньше — одна кола; линия прошлого периода — все 24 часа.
	if s.str("prev_totals", "revenue") != "15000.00" || len(s.Body["prev"].([]any)) != 24 || s.Body["change_pct"] == nil {
		t.Fatalf("prev = %v / %v", s.Body["prev_totals"], s.Body["change_pct"])
	}

	// По дням за 8 дней, сравнение с прошлыми 8.
	week := fmt.Sprintf("from=%s&to=%s", yday.AddDate(0, 0, -7).Format("2006-01-02"), today.Format("2006-01-02"))
	dd := a.expect(a.do("GET", "/store/reports/sales-series?bucket=day&compare=prev&"+week, tok, nil), 200, "days")
	if l := dd.Body["points"].([]any); len(l) != 8 || l[0].(map[string]any)["revenue"] != "15000.00" || l[7].(map[string]any)["revenue"] != s.str("totals", "revenue") {
		t.Fatalf("days = %v", l)
	}
	if dd.Body["prev_totals"] == nil || dd.str("prev_totals", "revenue") != "0.00" || dd.Body["change_pct"] != nil {
		t.Fatalf("days prev = %v %v", dd.Body["prev_totals"], dd.Body["change_pct"])
	}

	// «Когда покупают»: день недели вчера попал в период дважды — 3 чека в 10 часов за 2 дня.
	h := a.expect(a.do("GET", "/store/reports/sales-series?bucket=weekday_hour&"+week, tok, nil), 200, "heatmap")
	wd := int(yday.Weekday())
	if wd == 0 {
		wd = 7
	}
	found := false
	for _, x := range h.Body["heatmap"].([]any) {
		c := x.(map[string]any)
		if int(c["weekday"].(float64)) == wd && c["hour"].(float64) == 10 {
			found = c["checks"].(float64) == 1.5 && c["revenue"] == "55000.00"
		}
	}
	if !found {
		t.Fatalf("heatmap = %v", h.Body["heatmap"])
	}

	// Категории: разделы верхнего уровня, потом подкатегории «Выпечки».
	cat := a.expect(a.do("GET", "/store/reports/sales-breakdown?by=category&"+day, tok, nil), 200, "categories")
	names := map[string]string{}
	for _, x := range cat.Body["items"].([]any) {
		it := x.(map[string]any)
		names[it["name"].(string)] = it["value"].(string)
	}
	if names["Выпечка"] != "150000.00" || names["Продукты"] == "" || len(names) != 2 {
		t.Fatalf("categories = %v", cat.Body["items"])
	}
	sub := a.expect(a.do("GET", "/store/reports/sales-breakdown?by=category&parent_id="+bakery+"&"+day, tok, nil), 200, "subcategories").items()
	if len(sub) != 1 || sub[0]["name"] != "Хлеб" || sub[0]["key"] != breadCat {
		t.Fatalf("subcategories = %v", sub)
	}

	// Товары: limit=1 — остальное в other.
	pr := a.expect(a.do("GET", "/store/reports/sales-breakdown?by=product&limit=1&compare=week&"+day, tok, nil), 200, "products")
	top := pr.Body["items"].([]any)[0].(map[string]any)
	if top["name"] != "Хлеб «Нон»" || top["qty"] != "3.000" || top["value"] != "150000.00" || top["prev_value"] != "0.00" {
		t.Fatalf("top product = %v", top)
	}
	if o := pr.Body["other"].(map[string]any); o["count"].(float64) != 1 || o["prev_value"] != "15000.00" {
		t.Fatalf("other = %v", o)
	}

	// Оплаты: наличные, карта и Payme онлайн-заказа.
	pays := map[string]string{}
	for _, x := range a.expect(a.do("GET", "/store/reports/sales-breakdown?by=payment&"+day, tok, nil), 200, "payments").items() {
		pays[x["name"].(string)] = x["value"].(string)
	}
	if pays["Наличные"] != "180000.00" || pays[cardName] != "65000.00" || pays["Payme"] != online {
		t.Fatalf("payments = %v", pays)
	}

	// Компактный ABC/XYZ для главной: хлеба осталось 1 при 3 продажах за 14 дней — на 4 дня.
	ab := a.expect(a.do("GET", "/store/reports/abc-xyz?compact=1", tok, nil), 200, "abc compact")
	l := ab.Body["items"].([]any)
	if len(l) != 1 || l[0].(map[string]any)["name"] != "Хлеб «Нон»" || l[0].(map[string]any)["days_cover"].(float64) != 4 || len(ab.Body["no_sale_items"].([]any)) != 0 {
		t.Fatalf("abc compact = %v", ab.Body["items"])
	}

	a.expect(a.do("GET", "/store/reports/sales-series?bucket=minute", tok, nil), 400, "bad bucket")
	a.expect(a.do("GET", "/store/reports/sales-series?bucket=hour&"+week, tok, nil), 400, "hours too long")
	a.expect(a.do("GET", "/store/reports/sales-series?compare=year", tok, nil), 400, "bad compare")
	a.expect(a.do("GET", "/store/reports/sales-breakdown?by=brand", tok, nil), 400, "bad by")
	a.expect(a.do("GET", "/store/reports/sales-breakdown?by=product&parent_id="+bakery, tok, nil), 400, "parent for product")
	a.expect(a.do("GET", "/store/reports/sales-breakdown?by=product&limit=0", tok, nil), 400, "bad limit")
}
