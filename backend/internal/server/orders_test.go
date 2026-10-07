package server_test

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/payments"
	"github.com/sanedidi/super-market/backend/internal/server"
)

const (
	paymeKey    = "payme-test-key"
	clickSvc    = "1001"
	clickSecret = "click-secret"
)

// providers — имитация запросов Payme и Click к нашему серверу.
type providers struct {
	t   *testing.T
	srv *httptest.Server
}

func (p providers) payme(key, method string, params map[string]any) map[string]any {
	p.t.Helper()
	body, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
	req, _ := http.NewRequest("POST", p.srv.URL+"/api/v1/payments/payme", strings.NewReader(string(body)))
	req.Header.Set("Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte("Paycom:"+key)))
	res, err := p.srv.Client().Do(req)
	if err != nil {
		p.t.Fatal(err)
	}
	defer res.Body.Close()
	out := map[string]any{}
	_ = json.NewDecoder(res.Body).Decode(&out)
	return out
}

func paymeErr(r map[string]any) int {
	e, ok := r["error"].(map[string]any)
	if !ok {
		return 0
	}
	return int(e["code"].(float64))
}

func (p providers) click(path, transID, orderID, prepareID, amount, action, clickErr string) map[string]any {
	p.t.Helper()
	signTime := time.Now().Format("2006-01-02 15:04:05")
	sign := payments.ClickSign(clickSecret, payments.ClickRequestForTest(transID, clickSvc, orderID, prepareID, amount, action, signTime))
	form := url.Values{
		"click_trans_id": {transID}, "service_id": {clickSvc}, "click_paydoc_id": {"pd-" + transID},
		"merchant_trans_id": {orderID}, "merchant_prepare_id": {prepareID}, "amount": {amount}, "action": {action},
		"error": {clickErr}, "error_note": {""}, "sign_time": {signTime}, "sign_string": {sign},
	}
	res, err := p.srv.Client().PostForm(p.srv.URL+"/api/v1/payments/click/"+path, form)
	if err != nil {
		p.t.Fatal(err)
	}
	defer res.Body.Close()
	out := map[string]any{}
	_ = json.NewDecoder(res.Body).Decode(&out)
	return out
}

func clickCode(r map[string]any) int { return int(r["error"].(float64)) }

func sqlStr(t *testing.T, pool *pgxpool.Pool, q string, args ...any) string {
	t.Helper()
	var s string
	if err := pool.QueryRow(context.Background(), q, args...).Scan(&s); err != nil {
		t.Fatalf("%s: %v", q, err)
	}
	return s
}

// TestOnlineOrdersFlow — этап 5: магазины рядом, каталог, корзина, заказ с
// резервом, оплата Payme и Click, сборка с другого склада, доставка, отмена
// с возвратом, истечение неоплаченного заказа, уведомление супер-админа.
func TestOnlineOrdersFlow(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	cfg.PaymeMerchantID, cfg.PaymeKey = "merchant-1", paymeKey
	cfg.ClickServiceID, cfg.ClickMerchantID, cfg.ClickSecretKey = clickSvc, "2002", clickSecret
	cfg.PaymentTimeout, cfg.AcceptTimeout = 15*time.Minute, 10*time.Minute
	tg := &fakeTelegram{}
	app, err := server.Build(ctx, cfg, pool, tg, quietLog())
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app.Handler)
	t.Cleanup(srv.Close)
	a := api{t: t, srv: srv, pool: pool}
	prov := providers{t: t, srv: srv}

	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, sugar := catalogBasics(t, a, adminTok)
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	for phone, chat := range map[string]int{"+998900000001": 1001, "+998900000002": 1002} {
		if _, err := pool.Exec(ctx, `INSERT INTO telegram_links (phone, chat_id, tg_user_id) VALUES ($1, $2, $2)`, phone, chat); err != nil {
			t.Fatal(err)
		}
	}

	// Магазин в центре Ташкента, второй склад, остатки.
	const lat, lng = 41.2995, 69.2401
	a.expect(a.do("PATCH", "/store/stores/"+store, tok, map[string]any{"lat": lat, "lng": lng, "address": "Амир Темур 1"}), 200, "store location")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
	wh2 := a.expect(a.do("POST", "/store/warehouses", tok, map[string]any{"store_id": store, "name": "Склад 2"}), 201, "wh2").str("id")
	post := func(w string, items []map[string]any) {
		t.Helper()
		d := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{"type": "posting", "warehouse_id": w, "items": items}), 201, "posting")
		a.expect(a.do("POST", "/store/inventory/documents/"+d.str("id")+"/post", tok, nil), 200, "post")
	}
	post(wh, []map[string]any{{"product_id": cola, "qty": 10, "price": 10000}, {"product_id": sugar, "qty": 5, "price": 8000}})
	post(wh2, []map[string]any{{"product_id": cola, "qty": 5, "price": 9000}})

	// Магазин без точки на карте не может включить онлайн-заказы — точка уже есть.
	a.expect(a.do("PUT", "/store/stores/"+store+"/delivery", tok, map[string]any{
		"accepts_online": true, "min_order_amount": 20000, "delivery_radius_m": 5000,
		"rules": []map[string]any{
			{"type": "free_from", "params": map[string]any{"amount": 200000}},
			{"type": "distance", "params": map[string]any{"base": 5000, "per_km": 1000}, "sort": 1},
		},
	}), 200, "delivery settings")
	a.expect(a.do("PUT", "/store/stores/"+store+"/delivery", tok, map[string]any{
		"rules": []map[string]any{{"type": "fixed", "params": map[string]any{}}},
	}), 400, "bad rule")

	// Покупатель в ~1,5 км: магазин рядом, рекомендован, доставка 5 000 + 2 км × 1 000.
	const clat, clng = 41.3130, 69.2401
	near := a.expect(a.do("GET", fmt.Sprintf("/client/stores/nearby?lat=%v&lng=%v", clat, clng), "", nil), 200, "nearby").items()
	if len(near) != 1 || near[0]["id"] != store || near[0]["recommended"] != true {
		t.Fatalf("nearby = %v", near)
	}
	if fee := near[0]["delivery"].(map[string]any)["delivery_fee"]; fee != "7000.00" {
		t.Fatalf("delivery fee = %v", fee)
	}
	if far := a.expect(a.do("GET", "/client/stores/nearby?lat=41.40&lng=69.2401", "", nil), 200, "far").items(); len(far) != 0 {
		t.Fatalf("far nearby = %v", far)
	}
	products := a.expect(a.do("GET", "/client/stores/"+store+"/products", "", nil), 200, "catalog").items()
	if len(products) != 2 {
		t.Fatalf("catalog = %v", products)
	}
	cats := a.expect(a.do("GET", "/client/stores/"+store+"/categories", "", nil), 200, "categories").items()
	if len(cats) != 1 || cats[0]["products_count"].(float64) != 2 {
		t.Fatalf("categories = %v", cats)
	}

	client, _ := a.login("+998900000050", identity.AppClient)
	addr := a.expect(a.do("POST", "/client/addresses", client, map[string]any{
		"label": "Дом", "address": "Чиланзар 5", "apartment": "12", "lat": clat, "lng": clng,
	}), 201, "address").str("id")
	farAddr := a.expect(a.do("POST", "/client/addresses", client, map[string]any{
		"address": "Далеко", "lat": 41.40, "lng": 69.2401,
	}), 201, "far address").str("id")

	cart := func(address string, provider string, items ...map[string]any) map[string]any {
		return map[string]any{"store_id": store, "address_id": address, "items": items, "payment_provider": provider}
	}
	line := func(product string, qty any) map[string]any { return map[string]any{"product_id": product, "qty": qty} }

	pv := a.expect(a.do("POST", "/client/checkout/preview", client, cart(addr, "", line(cola, 2))), 200, "preview")
	if pv.Body["can_order"] != true || pv.str("subtotal") != "30000.00" || pv.str("total") != "37000.00" {
		t.Fatalf("preview = %v", pv.Body)
	}
	small := a.expect(a.do("POST", "/client/checkout/preview", client, cart(addr, "", line(cola, 1))), 200, "small preview")
	if small.Body["can_order"] != false || fmt.Sprint(small.Body["problems"]) != "[min_order_amount]" {
		t.Fatalf("small preview = %v", small.Body)
	}
	farPv := a.expect(a.do("POST", "/client/checkout/preview", client, cart(farAddr, "", line(cola, 2))), 200, "far preview")
	if fmt.Sprint(farPv.Body["problems"]) != "[not_deliverable]" {
		t.Fatalf("far preview = %v", farPv.Body)
	}
	a.expect(a.do("POST", "/client/orders", client, cart(addr, "payme", line(cola, 50))), 409, "too many")
	a.expect(a.do("POST", "/client/orders", client, cart(addr, "card", line(cola, 2))), 400, "unknown provider")

	// ---- Заказ 1: Payme, 3 колы + 1,5 кг сахара = 63 000 + 7 000 доставки.
	o1 := a.expect(a.do("POST", "/client/orders", client, cart(addr, "payme", line(cola, 3), line(sugar, "1.5"))), 201, "order 1")
	order1 := o1.str("order", "id")
	if o1.str("order", "total") != "70000.00" || !strings.HasPrefix(o1.str("payment_url"), "https://checkout.paycom.uz/") {
		t.Fatalf("order 1 = %v", o1.Body)
	}
	// Резерв: в каталоге колы стало 7, в магазине неоплаченный заказ не виден.
	for _, p := range a.expect(a.do("GET", "/client/stores/"+store+"/products", "", nil), 200, "catalog").items() {
		if p["id"] == cola && p["available"] != "7.000" {
			t.Fatalf("cola available = %v", p["available"])
		}
	}
	if n := len(a.expect(a.do("GET", "/store/orders", tok, nil), 200, "store orders").items()); n != 0 {
		t.Fatalf("store sees unpaid orders: %d", n)
	}

	acc := map[string]any{"order_id": order1}
	if paymeErr(prov.payme("wrong", "CheckPerformTransaction", map[string]any{"amount": 7000000, "account": acc})) != -32504 {
		t.Fatal("payme wrong key accepted")
	}
	if paymeErr(prov.payme(paymeKey, "CheckPerformTransaction", map[string]any{"amount": 100, "account": acc})) != -31001 {
		t.Fatal("payme wrong amount accepted")
	}
	if paymeErr(prov.payme(paymeKey, "CheckPerformTransaction", map[string]any{"amount": 7000000, "account": map[string]any{"order_id": "x"}})) != -31050 {
		t.Fatal("payme unknown order accepted")
	}
	chk := prov.payme(paymeKey, "CheckPerformTransaction", map[string]any{"amount": 7000000, "account": acc})
	if chk["result"].(map[string]any)["allow"] != true {
		t.Fatalf("check perform = %v", chk)
	}
	now := time.Now().UnixMilli()
	cr := prov.payme(paymeKey, "CreateTransaction", map[string]any{"id": "pm-1", "time": now, "amount": 7000000, "account": acc})
	if paymeErr(cr) != 0 || cr["result"].(map[string]any)["state"].(float64) != 1 {
		t.Fatalf("create = %v", cr)
	}
	if paymeErr(prov.payme(paymeKey, "CreateTransaction", map[string]any{"id": "pm-2", "time": now, "amount": 7000000, "account": acc})) != -31099 {
		t.Fatal("second payme transaction for the same order")
	}
	for i := 0; i < 2; i++ { // повтор PerformTransaction — тот же ответ
		pf := prov.payme(paymeKey, "PerformTransaction", map[string]any{"id": "pm-1"})
		if paymeErr(pf) != 0 || pf["result"].(map[string]any)["state"].(float64) != 2 {
			t.Fatalf("perform = %v", pf)
		}
	}
	if st := prov.payme(paymeKey, "CheckTransaction", map[string]any{"id": "pm-1"}); st["result"].(map[string]any)["state"].(float64) != 2 {
		t.Fatalf("check transaction = %v", st)
	}
	if s := sqlStr(t, pool, `SELECT status || ':' || amount::text FROM balance_entries WHERE order_id = $1`, order1); s != "pending:70000.00" {
		t.Fatalf("balance after payment = %s", s)
	}
	// Магазину пришло уведомление о новом заказе (отправляется асинхронно).
	deadline := time.Now().Add(3 * time.Second)
	for {
		tg.mu.Lock()
		got := false
		for _, m := range tg.sent {
			if m.chatID == 1002 && strings.Contains(m.text, "Новый заказ") {
				got = true
			}
		}
		tg.mu.Unlock()
		if got {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("store was not notified about the new order")
		}
		time.Sleep(20 * time.Millisecond)
	}

	// Магазин: принять → собрать (колу со склада 2) → в путь → чек → доставлен.
	list := a.expect(a.do("GET", "/store/orders", tok, nil), 200, "store orders").items()
	if len(list) != 1 || list[0]["status"] != "paid" {
		t.Fatalf("store orders = %v", list)
	}
	// Поиск по номеру заказа (можно с «№») и по цифрам телефона покупателя.
	num := itoa(int(list[0]["number"].(float64)))
	for _, q := range []string{num, "%E2%84%96" + num, "90000-0050"} {
		if found := a.expect(a.do("GET", "/store/orders?q="+q, tok, nil), 200, "search "+q).items(); len(found) != 1 {
			t.Fatalf("search %q = %v", q, found)
		}
	}
	if found := a.expect(a.do("GET", "/store/orders?q=99999", tok, nil), 200, "search miss").items(); len(found) != 0 {
		t.Fatalf("search miss = %v", found)
	}
	a.expect(a.do("POST", "/store/orders/"+order1+"/start-picking", tok, nil), 409, "picking before accept")
	a.expect(a.do("POST", "/store/orders/"+order1+"/accept", tok, nil), 200, "accept")
	a.expect(a.do("POST", "/store/orders/"+order1+"/start-picking", tok, nil), 200, "start picking")
	a.expect(a.do("POST", "/store/orders/"+order1+"/fiscal", tok, map[string]any{"fiscal_number": "1", "fiscal_sign": "s"}), 409, "fiscal before pick")
	picked := a.expect(a.do("POST", "/store/orders/"+order1+"/picked", tok, map[string]any{
		"items": []map[string]any{{"line": 1, "warehouse_id": wh2}},
	}), 200, "picked")
	items := picked.Body["items"].([]any)
	if l1 := items[0].(map[string]any); l1["from_other_warehouse"] != true || l1["picked_warehouse_id"] != wh2 {
		t.Fatalf("line 1 = %v", l1)
	}
	if q, _ := stockOf(t, a, tok, wh2, cola); q != "2.000" {
		t.Fatalf("wh2 cola = %s", q)
	}
	if q, _ := stockOf(t, a, tok, wh, cola); q != "10.000" {
		t.Fatalf("wh cola = %s (reservation not released?)", q)
	}
	if q, _ := stockOf(t, a, tok, wh, sugar); q != "3.500" {
		t.Fatalf("wh sugar = %s", q)
	}
	a.expect(a.do("POST", "/store/orders/"+order1+"/cancel", tok, map[string]any{"reason": "поздно"}), 409, "cancel after pick")
	a.expect(a.do("POST", "/store/orders/"+order1+"/start-delivery", tok, nil), 200, "start delivery")
	a.expect(a.do("POST", "/store/orders/"+order1+"/fiscal", tok, map[string]any{"fiscal_number": "77", "fiscal_sign": "abc"}), 200, "fiscal")
	done := a.expect(a.do("POST", "/store/orders/"+order1+"/delivered", tok, nil), 200, "delivered")
	if done.str("status") != "delivered" || done.str("fiscal_status") != "registered" {
		t.Fatalf("delivered = %v", done.Body)
	}
	if s := sqlStr(t, pool, `SELECT status FROM balance_entries WHERE order_id = $1`, order1); s != "available" {
		t.Fatalf("balance after delivery = %s", s)
	}
	if paymeErr(prov.payme(paymeKey, "CancelTransaction", map[string]any{"id": "pm-1", "reason": 5})) != -31007 {
		t.Fatal("payme refund of a delivered order")
	}
	if c := a.expect(a.do("GET", "/client/orders/"+order1, client, nil), 200, "client order"); len(c.Body["history"].([]any)) < 6 {
		t.Fatalf("history = %v", c.Body["history"])
	}

	// ---- Заказ 2: Click, магазин отменяет → возврат.
	o2 := a.expect(a.do("POST", "/client/orders", client, cart(addr, "click", line(cola, 2))), 201, "order 2")
	order2 := o2.str("order", "id")
	if !strings.Contains(o2.str("payment_url"), "my.click.uz") {
		t.Fatalf("click url = %s", o2.str("payment_url"))
	}
	if clickCode(prov.click("prepare", "ct-1", order2, "", "1000", "0", "0")) != -2 {
		t.Fatal("click wrong amount")
	}
	bad := prov.click("prepare", "ct-1", order2, "", "37000", "0", "0")
	if clickCode(bad) != 0 {
		t.Fatalf("click prepare = %v", bad)
	}
	prep := fmt.Sprint(int64(bad["merchant_prepare_id"].(float64)))
	if clickCode(prov.click("complete", "ct-1", order2, "999999", "37000", "1", "0")) != -6 {
		t.Fatal("click complete with wrong prepare id")
	}
	comp := prov.click("complete", "ct-1", order2, prep, "37000", "1", "0")
	if clickCode(comp) != 0 {
		t.Fatalf("click complete = %v", comp)
	}
	if clickCode(prov.click("complete", "ct-1", order2, prep, "37000", "1", "0")) != -4 {
		t.Fatal("click complete twice")
	}
	a.expect(a.do("POST", "/client/orders/"+order2+"/cancel", client, nil), 200, "client cancel paid order")
	if s := sqlStr(t, pool, `SELECT status FROM payments WHERE order_id = $1`, order2); s != "refund_pending" {
		t.Fatalf("payment after cancel = %s", s)
	}
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM balance_entries WHERE order_id = $1`, order2); n != "0" {
		t.Fatal("cancelled order kept balance")
	}
	queue := a.expect(a.do("GET", "/admin/payments?status=refund_pending", adminTok, nil), 200, "refund queue").items()
	if len(queue) != 1 {
		t.Fatalf("refund queue = %v", queue)
	}
	a.expect(a.do("POST", "/admin/payments/"+queue[0]["id"].(string)+"/refunded", adminTok, nil), 200, "mark refunded")
	a.expect(a.do("POST", "/admin/payments/"+queue[0]["id"].(string)+"/refunded", adminTok, nil), 409, "mark refunded twice")

	// ---- Заказ 3: не оплачен вовремя → истёк, резерв снят.
	o3 := a.expect(a.do("POST", "/client/orders", client, cart(addr, "payme", line(cola, 4))), 201, "order 3").str("order", "id")
	if _, err := pool.Exec(ctx, `UPDATE orders SET created_at = now() - interval '20 minutes' WHERE id = $1`, o3); err != nil {
		t.Fatal(err)
	}
	if err := app.Orders.ExpireUnpaid(ctx); err != nil {
		t.Fatal(err)
	}
	if s := sqlStr(t, pool, `SELECT status FROM orders WHERE id = $1`, o3); s != "expired" {
		t.Fatalf("order 3 = %s", s)
	}
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM stock_reservations WHERE order_id = $1`, o3); n != "0" {
		t.Fatal("expired order kept reservation")
	}
	if paymeErr(prov.payme(paymeKey, "CheckPerformTransaction", map[string]any{"amount": 3500000 + 700000, "account": map[string]any{"order_id": o3}})) != -31050 {
		t.Fatal("payme accepts expired order")
	}

	// ---- Заказ 4: оплачен, но не принят 10 минут → супер-админ уведомлён один раз.
	o4 := a.expect(a.do("POST", "/client/orders", client, cart(addr, "payme", line(cola, 8))), 201, "order 4").str("order", "id")
	prov.payme(paymeKey, "CreateTransaction", map[string]any{"id": "pm-4", "time": time.Now().UnixMilli(), "amount": 12700000, "account": map[string]any{"order_id": o4}})
	if paymeErr(prov.payme(paymeKey, "PerformTransaction", map[string]any{"id": "pm-4"})) != 0 {
		t.Fatal("perform order 4")
	}
	// POS не может продать зарезервированный товар: на складе 10, в резерве 8.
	methods := a.expect(a.do("GET", "/store/finance/payment-methods?store_id="+store, tok, nil), 200, "methods").items()
	a.expect(a.do("POST", "/store/sales", tok, map[string]any{
		"client_uid": "pos-res-1", "store_id": store, "items": []map[string]any{line(cola, 3)},
		"payments": []map[string]any{{"payment_method_id": methods[0]["id"], "amount": 45000}},
	}), 409, "sale of reserved stock")
	a.expect(a.do("POST", "/store/sales", tok, map[string]any{
		"client_uid": "pos-res-2", "store_id": store, "items": []map[string]any{line(cola, 2)},
		"payments": []map[string]any{{"payment_method_id": methods[0]["id"], "amount": 30000}},
	}), 201, "sale of free stock")

	if _, err := pool.Exec(ctx, `UPDATE orders SET paid_at = now() - interval '11 minutes' WHERE id = $1`, o4); err != nil {
		t.Fatal(err)
	}
	tg.mu.Lock()
	before := len(tg.sent)
	tg.mu.Unlock()
	for i := 0; i < 2; i++ {
		if err := app.Orders.AlertUnaccepted(ctx); err != nil {
			t.Fatal(err)
		}
	}
	tg.mu.Lock()
	alerts := 0
	for _, m := range tg.sent[before:] {
		if m.chatID == 1001 && strings.Contains(m.text, "не принят") {
			alerts++
		}
	}
	tg.mu.Unlock()
	if alerts != 1 {
		t.Fatalf("super-admin alerts = %d", alerts)
	}
	stale := a.expect(a.do("GET", "/admin/orders?stale=true", adminTok, nil), 200, "stale orders").items()
	if len(stale) != 1 || stale[0]["id"] != o4 {
		t.Fatalf("stale = %v", stale)
	}
	// Супер-админ отменяет зависший заказ: резерв снят, деньги к возврату.
	a.expect(a.do("POST", "/admin/orders/"+o4+"/cancel", adminTok, map[string]any{"reason": "магазин не отвечает"}), 200, "admin cancel")
	if q := sqlStr(t, pool, `SELECT COALESCE(sum(qty), 0)::text FROM stock_reservations`); q != "0" {
		t.Fatalf("reservations left: %s", q)
	}
	// Payme сообщает о возврате — платёж refunded.
	if r := prov.payme(paymeKey, "CancelTransaction", map[string]any{"id": "pm-4", "reason": 5}); r["result"].(map[string]any)["state"].(float64) != -2 {
		t.Fatalf("payme refund = %v", r)
	}
	if s := sqlStr(t, pool, `SELECT status FROM payments WHERE external_id = 'pm-4'`); s != "refunded" {
		t.Fatalf("payment 4 = %s", s)
	}
	// Выписка Payme содержит обе транзакции.
	stmt := prov.payme(paymeKey, "GetStatement", map[string]any{"from": now - 60000, "to": time.Now().UnixMilli() + 60000})
	if n := len(stmt["result"].(map[string]any)["transactions"].([]any)); n != 2 {
		t.Fatalf("statement = %d transactions", n)
	}

	// ВРЕМЕННО: наличные курьеру — заказ сразу у магазина, без ссылки на оплату
	// и без денег в балансе сети. Отменяем, чтобы не мешать остальным проверкам.
	oc := a.expect(a.do("POST", "/client/orders", client, cart(addr, "cash", line(cola, 2))), 201, "cash order")
	if oc.str("order", "status") != "paid" || oc.Body["payment_url"] != nil && oc.Body["payment_url"] != "" {
		t.Fatalf("cash order = %v", oc.Body)
	}
	var cashBalance int
	if err := pool.QueryRow(context.Background(), `SELECT count(*) FROM balance_entries WHERE order_id = $1`, oc.str("order", "id")).Scan(&cashBalance); err != nil || cashBalance != 0 {
		t.Fatalf("cash order balance entries = %d, %v", cashBalance, err)
	}
	a.expect(a.do("POST", "/client/orders/"+oc.str("order", "id")+"/cancel", client, nil), 200, "cancel cash order")
}
