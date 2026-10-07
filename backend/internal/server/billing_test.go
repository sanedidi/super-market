package server_test

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// TestBillingPayoutsReports — этап 6: тарифы и счета за подписку, автосписание
// с баланса, скрытие магазинов должника, вывод денег, отчёты.
func TestBillingPayoutsReports(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	tg := &fakeTelegram{}
	app, err := server.Build(ctx, cfg, pool, tg, quietLog())
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app.Handler)
	t.Cleanup(srv.Close)
	a := api{t: t, srv: srv, pool: pool}

	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, _ := catalogBasics(t, a, adminTok)
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	if _, err := pool.Exec(ctx, `INSERT INTO telegram_links (phone, chat_id, tg_user_id) VALUES ('+998900000002', 2002, 2002), ('+998900000001', 1001, 1001)`); err != nil {
		t.Fatal(err)
	}
	network := a.expect(a.do("GET", "/store/me", tok, nil), 200, "me").str("network_id")
	if network == "" {
		network = sqlStr(t, pool, `SELECT network_id::text FROM stores WHERE id = $1`, store)
	}
	a.expect(a.do("PATCH", "/store/stores/"+store, tok, map[string]any{"lat": 41.2995, "lng": 69.2401}), 200, "location")
	a.expect(a.do("PUT", "/store/stores/"+store+"/delivery", tok, map[string]any{"accepts_online": true}), 200, "online")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
	d := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{"type": "posting", "warehouse_id": wh,
		"items": []map[string]any{{"product_id": cola, "qty": 10, "price": 10000}}}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+d.str("id")+"/post", tok, nil), 200, "post")
	nearby := func() int {
		return len(a.expect(a.do("GET", "/client/stores/nearby?lat=41.30&lng=69.24", "", nil), 200, "nearby").items())
	}
	if nearby() != 1 {
		t.Fatal("store not visible before billing")
	}

	// ---- Тарифы и настройки.
	tariffs := a.expect(a.do("GET", "/admin/billing/tariffs", adminTok, nil), 200, "tariffs").items()
	if len(tariffs) != 2 || tariffs[0]["price_per_store"] != "20.00" || tariffs[1]["price_per_store"] != "15.00" {
		t.Fatalf("tariffs = %v", tariffs)
	}
	// Тарифы для сайта — без входа, только действующие, с диапазоном магазинов.
	pub := a.expect(a.do("GET", "/public/tariffs", "", nil), 200, "public tariffs").items()
	if len(pub) != 2 || pub[0]["min_stores"] != float64(1) || pub[0]["max_stores"] != float64(2) ||
		pub[0]["price_per_store"] != "20.00" || pub[1]["max_stores"] != nil || pub[1]["currency"] != "USD" {
		t.Fatalf("public tariffs = %v", pub)
	}
	a.expect(a.do("POST", "/admin/billing/tariffs", adminTok, map[string]any{"name": "Дубль", "min_stores": 3, "price_per_store": 10}), 409, "duplicate tariff")
	a.expect(a.do("POST", "/admin/billing/tariffs", tok, map[string]any{"name": "x", "min_stores": 9, "price_per_store": 1}), 403, "store token on admin billing")
	st := a.expect(a.do("PUT", "/admin/billing/settings", adminTok, map[string]any{"usd_rate": "12500", "grace_days": 5}), 200, "settings")
	if st.str("usd_rate") != "12500.0000" || st.Body["grace_days"].(float64) != 5 {
		t.Fatalf("settings = %v", st.Body)
	}
	nb := a.expect(a.do("GET", "/admin/billing/networks/"+network, adminTok, nil), 200, "network billing")
	if nb.Body["stores_count"].(float64) != 1 || nb.str("price_per_store") != "20.00" || nb.str("monthly_usd") != "20.00" {
		t.Fatalf("network billing = %v", nb.Body)
	}

	// Новая сеть платит со следующего месяца: счёт за текущий не выставляется.
	if n, err := app.Billing.GenerateInvoices(ctx, time.Now()); err != nil || n != 0 {
		t.Fatalf("invoices for new network: %d, %v", n, err)
	}
	a.expect(a.do("PATCH", "/admin/billing/networks/"+network, adminTok, map[string]any{"billing_from": "2026-01-01"}), 200, "billing from")
	if n, err := app.Billing.GenerateInvoices(ctx, time.Now()); err != nil || n != 1 {
		t.Fatalf("generate: %d, %v", n, err)
	}
	if n, _ := app.Billing.GenerateInvoices(ctx, time.Now()); n != 0 {
		t.Fatal("invoice generated twice")
	}
	invs := a.expect(a.do("GET", "/store/billing/invoices", tok, nil), 200, "store invoices").items()
	if len(invs) != 1 || invs[0]["amount_usd"] != "20.00" || invs[0]["amount_uzs"] != "250000.00" || invs[0]["status"] != "unpaid" {
		t.Fatalf("invoices = %v", invs)
	}
	invoice := invs[0]["id"].(string)
	tg.mu.Lock()
	notified := len(tg.sent) > 0 && tg.sent[len(tg.sent)-1].chatID == 2002 && strings.Contains(tg.sent[len(tg.sent)-1].text, "Счёт за подписку")
	tg.mu.Unlock()
	if !notified {
		t.Fatal("owner not notified about invoice")
	}

	// Денег на балансе нет — автосписание ничего не делает, ручная оплата — 409.
	if err := app.Billing.AutoCharge(ctx); err != nil {
		t.Fatal(err)
	}
	a.expect(a.do("POST", "/store/billing/invoices/"+invoice+"/pay", tok, nil), 409, "pay without balance")

	// Просрочка: магазин исчезает из приложения.
	if _, err := pool.Exec(ctx, `UPDATE subscription_invoices SET due_date = current_date - 2 WHERE id = $1`, invoice); err != nil {
		t.Fatal(err)
	}
	if nearby() != 0 {
		t.Fatal("overdue network still visible")
	}
	a.expect(a.do("GET", "/client/stores/"+store+"/products", "", nil), 404, "overdue catalog")
	if od := a.expect(a.do("GET", "/admin/billing/networks?overdue=true", adminTok, nil), 200, "overdue").items(); len(od) != 1 {
		t.Fatalf("overdue networks = %v", od)
	}

	// Деньги онлайн-заказов (доставленных) пришли на баланс — счёт оплачивается сам.
	if _, err := pool.Exec(ctx, `INSERT INTO balance_entries (network_id, store_id, kind, status, amount) VALUES
		($1, $2, 'adjustment', 'available', 500000), ($1, $2, 'adjustment', 'pending', 70000)`, network, store); err != nil {
		t.Fatal(err)
	}
	if err := app.Billing.AutoCharge(ctx); err != nil {
		t.Fatal(err)
	}
	bal := a.expect(a.do("GET", "/store/balance", tok, nil), 200, "balance")
	if bal.str("available") != "250000.00" || bal.str("pending") != "70000.00" {
		t.Fatalf("balance = %v", bal.Body)
	}
	if s := sqlStr(t, pool, `SELECT status || ':' || paid_via FROM subscription_invoices WHERE id = $1`, invoice); s != "paid:balance" {
		t.Fatalf("invoice = %s", s)
	}
	if nearby() != 1 {
		t.Fatal("paid network hidden")
	}

	// ---- Вывод: не больше доступного, раз в неделю, отказ возвращает деньги.
	payout := func(amount any) resp {
		return a.do("POST", "/store/payouts", tok, map[string]any{"amount": amount, "requisites": "8600 **** 1234"})
	}
	a.expect(payout(300000), 409, "payout over balance")
	p1 := a.expect(payout(200000), 201, "payout")
	a.expect(payout(1000), 409, "second payout in a week")
	if b := a.expect(a.do("GET", "/store/balance", tok, nil), 200, "balance").str("available"); b != "50000.00" {
		t.Fatalf("balance after payout = %s", b)
	}
	a.expect(a.do("POST", "/admin/payouts/"+p1.str("id")+"/reject", adminTok, map[string]any{}), 400, "reject without note")
	a.expect(a.do("POST", "/admin/payouts/"+p1.str("id")+"/reject", adminTok, map[string]any{"note": "неверная карта"}), 200, "reject")
	if b := a.expect(a.do("GET", "/store/balance", tok, nil), 200, "balance").str("available"); b != "250000.00" {
		t.Fatalf("balance after reject = %s", b)
	}
	p2 := a.expect(payout(250000), 201, "payout after reject")
	if q := a.expect(a.do("GET", "/admin/payouts?status=requested", adminTok, nil), 200, "payout queue").items(); len(q) != 1 {
		t.Fatalf("payout queue = %v", q)
	}
	a.expect(a.do("POST", "/admin/payouts/"+p2.str("id")+"/paid", adminTok, map[string]any{"note": "п/п 15"}), 200, "paid")
	a.expect(a.do("POST", "/admin/payouts/"+p2.str("id")+"/paid", adminTok, map[string]any{}), 409, "paid twice")
	if b := a.expect(a.do("GET", "/store/balance", tok, nil), 200, "balance"); b.str("available") != "0.00" || b.Body["next_payout_at"] == nil {
		t.Fatalf("balance after payout = %v", b.Body)
	}
	if n := len(a.expect(a.do("GET", "/store/balance/entries", tok, nil), 200, "entries").items()); n != 4 {
		t.Fatalf("balance entries = %d", n)
	}

	// Индивидуальная цена сети.
	nb = a.expect(a.do("PATCH", "/admin/billing/networks/"+network, adminTok, map[string]any{"custom_price_per_store": 5}), 200, "custom price")
	if nb.str("price_per_store") != "5.00" {
		t.Fatalf("custom price = %v", nb.Body)
	}
	nb = a.expect(a.do("PATCH", "/admin/billing/networks/"+network, adminTok, map[string]any{"clear_custom_price": true}), 200, "clear price")
	if nb.str("price_per_store") != "20.00" {
		t.Fatalf("cleared price = %v", nb.Body)
	}

	// ---- Отчёты: продажа 2 колы (15 000, себестоимость 10 000), аренда 20 000, списание 1 колы.
	methods := a.expect(a.do("GET", "/store/finance/payment-methods?store_id="+store, tok, nil), 200, "methods").items()
	var cash string
	for _, m := range methods {
		if m["name"] == "Наличные" {
			cash = m["id"].(string)
		}
	}
	a.expect(a.do("POST", "/store/sales", tok, map[string]any{
		"client_uid": "pos-rep-1", "store_id": store, "items": []map[string]any{{"product_id": cola, "qty": 2}},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 30000}},
	}), 201, "sale")
	boxes := a.expect(a.do("GET", "/store/finance/cashboxes", tok, nil), 200, "boxes").items()
	storeBox := boxes[1]["id"].(string)
	rent := a.expect(a.do("POST", "/store/finance/reasons", tok, map[string]any{"name": "Аренда", "kind": "expense"}), 201, "reason").str("id")
	a.expect(a.do("POST", "/store/finance/operations", tok, map[string]any{
		"kind": "expense", "cashbox_id": storeBox, "amount": 20000, "reason_id": rent,
	}), 201, "rent")
	wo := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{"type": "write_off", "warehouse_id": wh, "reason": "Бой",
		"items": []map[string]any{{"product_id": cola, "qty": 1}}}), 201, "write-off")
	a.expect(a.do("POST", "/store/inventory/documents/"+wo.str("id")+"/post", tok, nil), 200, "post write-off")

	pl := a.expect(a.do("GET", "/store/reports/profit-loss", tok, nil), 200, "p&l")
	rev := pl.Body["revenue"].(map[string]any)
	if rev["pos_sales"] != "30000.00" || pl.str("gross_profit") != "10000.00" {
		t.Fatalf("p&l = %v", pl.Body)
	}
	if adj := pl.Body["stock_adjustments"].(map[string]any); adj["write_offs"] != "10000.00" || adj["total"] != "-10000.00" {
		t.Fatalf("adjustments = %v", adj)
	}
	if exp := pl.Body["expenses"].([]any); len(exp) != 1 || exp[0].(map[string]any)["amount"] != "20000.00" {
		t.Fatalf("expenses = %v", exp)
	}
	// 10 000 − 10 000 − 20 000 − подписка 250 000.
	if pl.str("platform_subscription") != "250000.00" || pl.str("net_profit") != "-270000.00" {
		t.Fatalf("net = %v / %v", pl.str("platform_subscription"), pl.str("net_profit"))
	}
	// По магазину подписка (расход сети) не учитывается.
	if pls := a.expect(a.do("GET", "/store/reports/profit-loss?store_id="+store, tok, nil), 200, "store p&l"); pls.str("net_profit") != "-20000.00" {
		t.Fatalf("store p&l = %v", pls.Body)
	}

	cf := a.expect(a.do("GET", "/store/reports/cash-flow?store_id="+store, tok, nil), 200, "cash flow")
	cbs := cf.Body["cashboxes"].([]any)
	if len(cbs) != 1 {
		t.Fatalf("cash flow boxes = %v", cbs)
	}
	if b := cbs[0].(map[string]any); b["opening"] != "0.00" || b["income"] != "30000.00" || b["expense"] != "20000.00" || b["closing"] != "10000.00" {
		t.Fatalf("cash flow box = %v", b)
	}
	titles := map[string]string{}
	for _, l := range cf.Body["lines"].([]any) {
		m := l.(map[string]any)
		titles[m["title"].(string)] = m["income"].(string) + "/" + m["expense"].(string)
	}
	if titles["Продажи"] != "30000.00/0.00" || titles["Аренда"] != "0.00/20000.00" {
		t.Fatalf("cash flow lines = %v", titles)
	}
	a.expect(a.do("GET", "/store/reports/cash-flow?from=2026-02-01&to=2026-01-01", tok, nil), 400, "bad period")
}
