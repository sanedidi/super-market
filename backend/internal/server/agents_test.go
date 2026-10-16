package server_test

import (
	"context"
	"strconv"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// TestAgentRegistration — «SM Агент»: вход и регистрация по номеру и коду,
// выбор бренда из каталога, заявка на новый бренд и решение супер-админа,
// тестовый номер для проверки в магазинах приложений.
func TestAgentRegistration(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	cfg.ReviewAgentLogin = "+998900000299:654321"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	catalogBasics(t, a, adminTok)
	var cocaBrand string
	if err := pool.QueryRow(ctx, `INSERT INTO brands (name) VALUES ('Coca-Cola') RETURNING id`).Scan(&cocaBrand); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `UPDATE products SET brand_id = $1 WHERE name LIKE 'Coca%'`, cocaBrand); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO brands (name) VALUES ('Hydrolife')`); err != nil {
		t.Fatal(err)
	}

	verify := func(phone, code string) resp {
		a.expect(a.do("POST", "/auth/agent/otp/request", "", map[string]any{"phone": phone}), 200, "agent code "+phone)
		return a.do("POST", "/auth/agent/otp/verify", "", map[string]any{"phone": phone, "code": code})
	}

	// Новый номер: код по SMS → билет регистрации.
	if r := a.expect(a.do("POST", "/auth/agent/otp/request", "", map[string]any{"phone": "+998900000201"}), 200, "request"); r.str("channel") != "sms" {
		t.Fatalf("channel = %v", r.Body)
	}
	a.expect(a.do("POST", "/auth/agent/otp/verify", "", map[string]any{"phone": "+998900000201", "code": "000000"}), 400, "wrong code")
	reg := a.expect(a.do("POST", "/auth/agent/otp/verify", "", map[string]any{"phone": "+998900000201", "code": "111111"}), 200, "verify new")
	ticket := reg.str("ticket")
	if reg.str("status") != "register" || ticket == "" {
		t.Fatalf("verify = %v", reg.Body)
	}

	// Поиск бренда — только с билетом.
	a.expect(a.do("GET", "/auth/agent/brands?q=coca", "", nil), 401, "brands without ticket")
	if c := a.expect(a.do("GET", "/auth/agent/categories?ticket="+ticket, "", nil), 200, "categories").items(); len(c) != 1 {
		t.Fatalf("categories = %v", c)
	}
	hits := a.expect(a.do("GET", "/auth/agent/brands?q=coca&ticket="+ticket, "", nil), 200, "brands").items()
	if len(hits) != 1 || hits[0]["id"] != cocaBrand || hits[0]["products"].(float64) != 1 || hits[0]["category"] != "Продукты" {
		t.Fatalf("hits = %v", hits)
	}

	// Регистрация с брендом — сразу в приложении, магазины открыты.
	a.expect(a.do("POST", "/auth/agent/register", "", map[string]any{"ticket": "bad", "full_name": "Алишер"}), 401, "bad ticket")
	a.expect(a.do("POST", "/auth/agent/register", "", map[string]any{"ticket": ticket, "full_name": " "}), 400, "no name")
	tok := a.expect(a.do("POST", "/auth/agent/register", "", map[string]any{
		"ticket": ticket, "full_name": "Алишер Каримов", "company": "Fayz Distribution", "brand_ids": []string{cocaBrand},
	}), 201, "register").str("access_token")
	a.expect(a.do("POST", "/auth/agent/register", "", map[string]any{"ticket": ticket, "full_name": "Ещё раз"}), 409, "register twice")
	// Склада ещё нет — приложение сначала показывает «Где ваш склад?».
	a.expect(a.do("GET", "/store/supply/summary", tok, nil), 409, "summary without point")
	me := a.expect(a.do("GET", "/store/supply/brands", tok, nil), 200, "my brands")
	if me.Body["verified"] != true || me.Body["self_registered"] != true || len(me.Body["brands"].([]any)) != 1 {
		t.Fatalf("brands = %v", me.Body)
	}
	// Без склада магазины ещё не посчитать — сначала точка склада.
	a.expect(a.do("GET", "/store/supply/stores", tok, nil), 409, "no point yet")
	if n := sqlStr(t, pool, `SELECT name || '|' || kind || '|' || plan_key FROM networks WHERE self_registered`); n != "Fayz Distribution|distributor|agent" {
		t.Fatalf("network = %s", n)
	}

	// Отдельная подписка агента: тариф агентов, бесплатный срок, только тарифы агентов.
	plan := a.expect(a.do("GET", "/store/plan", tok, nil), 200, "agent plan")
	if plan.str("chosen", "key") != "agent" || plan.str("trial_until") == "" || plan.Body["in_trial"] != false {
		t.Fatalf("agent plan = %v", plan.Body)
	}
	if ps := plan.Body["plans"].([]any); len(ps) != 1 || ps[0].(map[string]any)["key"] != "agent" {
		t.Fatalf("agent plans = %v", ps)
	}
	a.expect(a.do("POST", "/store/plan", tok, map[string]string{"plan": "business"}), 404, "agent cannot take store plan")
	a.expect(a.do("PUT", "/admin/billing/settings", adminTok, map[string]any{"agent_plan": "business"}), 400, "store plan for agents")
	if st := a.expect(a.do("PUT", "/admin/billing/settings", adminTok, map[string]any{"agent_trial_days": 7}), 200, "agent trial"); st.Body["agent_trial_days"].(float64) != 7 || st.str("agent_plan") != "agent" {
		t.Fatalf("settings = %v", st.Body)
	}
	a.expect(a.do("PATCH", "/admin/plans/agent", adminTok, map[string]any{"is_active": false}), 409, "archive agent plan")
	// У агента не бывает сотрудников.
	if r := a.expect(a.do("POST", "/store/employees", tok, map[string]any{"phone": "+998900000250", "full_name": "Помощник", "role_id": "x"}), 409, "agent staff"); r.str("error", "code") != "agent_no_staff" {
		t.Fatalf("agent staff = %v", r.Body)
	}

	// Повторный вход — по коду сразу в приложение.
	if r := a.expect(verify("+998900000201", "111111"), 200, "login"); r.str("status") != "login" || r.str("tokens", "access_token") == "" {
		t.Fatalf("login = %v", r.Body)
	}
	// Сотрудник магазина агентом не входит.
	a.expect(a.do("POST", "/admin/networks", adminTok, map[string]string{
		"name": "Baraka", "kind": "chain", "owner_phone": "+998900000002", "owner_name": "Владелец",
	}), 201, "store network")
	if r := a.expect(verify("+998900000002", "111111"), 409, "store employee"); r.str("error", "code") != "store_employee" {
		t.Fatalf("store employee = %v", r.Body)
	}

	// Второй агент без бренда: заявка на новый, магазины закрыты.
	t2 := a.expect(verify("+998900000202", "111111"), 200, "verify 2").str("ticket")
	tok2 := a.expect(a.do("POST", "/auth/agent/register", "", map[string]any{"ticket": t2, "full_name": "Бахтиёр"}), 201, "register 2").str("access_token")
	if s := a.expect(a.do("GET", "/store/supply/summary", tok2, nil), 200, "summary 2"); s.Body["verified"] != false {
		t.Fatalf("summary 2 = %v", s.Body)
	}
	if r := a.expect(a.do("GET", "/store/supply/stores", tok2, nil), 403, "stores closed"); r.str("error", "code") != "forbidden" {
		t.Fatalf("stores closed = %v", r.Body)
	}
	cats := a.expect(a.do("GET", "/store/supply/categories", tok2, nil), 200, "categories").items()
	if len(cats) != 1 {
		t.Fatalf("categories = %v", cats)
	}
	a.expect(a.do("POST", "/store/supply/brand-requests", tok2, map[string]any{"name": ""}), 400, "empty name")
	req := a.expect(a.do("POST", "/store/supply/brand-requests", tok2, map[string]any{
		"name": "Hydrolife Eco", "category_id": cats[0]["id"], "manufacturer": "ООО «Hydrolife»", "comment": "Вода 0,5–19 л",
		"logo_url": "https://example.com/logo.jpg",
	}), 201, "brand request")
	if req.str("status") != "pending" {
		t.Fatalf("request = %v", req.Body)
	}
	reqID := req.str("id")
	a.expect(a.do("GET", "/admin/brand-requests", tok2, nil), 403, "agent is not admin")

	list := a.expect(a.do("GET", "/admin/brand-requests", adminTok, nil), 200, "admin list")
	if list.Body["pending"].(float64) != 1 || len(list.Body["items"].([]any)) != 1 {
		t.Fatalf("admin list = %v", list.Body)
	}
	card := a.expect(a.do("GET", "/admin/brand-requests/"+reqID, adminTok, nil), 200, "admin card")
	if card.str("agent_phone") != "+998900000202" || len(card.Body["similar"].([]any)) == 0 {
		t.Fatalf("card = %v", card.Body)
	}
	a.expect(a.do("POST", "/admin/brand-requests/"+reqID+"/reject", adminTok, map[string]any{"reason": " "}), 400, "reject without reason")
	rej := a.expect(a.do("POST", "/admin/brand-requests/"+reqID+"/reject", adminTok, map[string]any{"reason": "Такой бренд уже есть: Hydrolife"}), 200, "reject")
	if rej.str("status") != "rejected" {
		t.Fatalf("rejected = %v", rej.Body)
	}
	a.expect(a.do("POST", "/admin/brand-requests/"+reqID+"/approve", adminTok, map[string]any{}), 409, "approve rejected")

	// Агент исправил заявку — снова на проверке; супер-админ одобряет с новым названием.
	a.expect(a.do("PUT", "/store/supply/brand-requests/"+reqID, tok2, map[string]any{"name": "Hydrolife Eco", "comment": "Это другой бренд"}), 200, "fix request")
	ok := a.expect(a.do("POST", "/admin/brand-requests/"+reqID+"/approve", adminTok, map[string]any{"name": "HydroLife Eco"}), 200, "approve")
	if ok.str("status") != "approved" || ok.str("brand_name") != "HydroLife Eco" || ok.Body["linked_existing"] != false {
		t.Fatalf("approved = %v", ok.Body)
	}
	if s := a.expect(a.do("GET", "/store/supply/brands", tok2, nil), 200, "brands 2"); s.Body["verified"] != true {
		t.Fatalf("brands 2 = %v", s.Body)
	}
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM notifications_outbox WHERE kind IN ('brand_approved', 'brand_rejected')`); n != "0" {
		t.Fatalf("push without device = %s", n) // устройства нет — push не ставится
	}

	// Заявка на бренд, который уже есть в каталоге, — сразу добавлен.
	auto := a.expect(a.do("POST", "/store/supply/brand-requests", tok2, map[string]any{"name": "coca-cola"}), 201, "existing brand")
	if auto.str("status") != "approved" || auto.Body["linked_existing"] != true {
		t.Fatalf("auto = %v", auto.Body)
	}
	// «Это существующий бренд».
	t3 := a.expect(verify("+998900000203", "111111"), 200, "verify 3").str("ticket")
	tok3 := a.expect(a.do("POST", "/auth/agent/register", "", map[string]any{"ticket": t3, "full_name": "Дилноза"}), 201, "register 3").str("access_token")
	r3 := a.expect(a.do("POST", "/store/supply/brand-requests", tok3, map[string]any{"name": "Hydro Life"}), 201, "request 3").str("id")
	var hydro string
	if err := pool.QueryRow(ctx, `SELECT id FROM brands WHERE name = 'Hydrolife'`).Scan(&hydro); err != nil {
		t.Fatal(err)
	}
	if l := a.expect(a.do("POST", "/admin/brand-requests/"+r3+"/link", adminTok, map[string]any{"brand_id": hydro}), 200, "link"); l.Body["linked_existing"] != true || l.str("brand_name") != "Hydrolife" {
		t.Fatalf("link = %v", l.Body)
	}

	// Тестовый номер для проверки: SMS не уходит, код постоянный.
	a.expect(a.do("POST", "/auth/agent/otp/request", "", map[string]any{"phone": "+998900000299"}), 200, "review request")
	a.expect(a.do("POST", "/auth/agent/otp/verify", "", map[string]any{"phone": "+998900000299", "code": "111111"}), 400, "review: dev code not accepted")
	a.expect(a.do("POST", "/auth/agent/otp/request", "", map[string]any{"phone": "+998900000299"}), 429, "cooldown")
	if _, err := pool.Exec(ctx, `UPDATE auth_codes SET sent_at = now() - interval '2 minutes'`); err != nil {
		t.Fatal(err)
	}
	if r := a.expect(verify("+998900000299", "654321"), 200, "review verify"); r.str("status") != "register" {
		t.Fatalf("review = %v", r.Body)
	}
}

// TestAgentPayments — магазин отдаёт деньги агенту, агент подтверждает,
// «Другая сумма», магазин соглашается или исправляет; акт сверки агента.
func TestAgentPayments(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, _ := catalogBasics(t, a, adminTok)

	a.expect(a.do("POST", "/admin/networks", adminTok, map[string]string{
		"name": "Baraka", "kind": "chain", "owner_phone": "+998900000002", "owner_name": "Владелец",
	}), 201, "store network")
	storeTok, _ := a.login("+998900000002", identity.AppStore)
	store1 := a.expect(a.do("POST", "/store/stores", storeTok, map[string]any{"name": "Baraka Market", "lat": 41.30, "lng": 69.24}), 201, "store").str("id")
	distTok, _, distWh := setupDistributor(t, a, adminTok, "+998900000003", 41.305, 69.245)

	// Товар и отпускная цена у агента, связь по коду, заказ → доставлен.
	maker := a.expect(a.do("POST", "/store/finance/counterparties", distTok, map[string]any{"name": "Coca-Cola Bottlers"}), 201, "maker").str("id")
	inc := a.expect(a.do("POST", "/store/inventory/documents", distTok, map[string]any{
		"type": "income", "warehouse_id": distWh, "counterparty_id": maker,
		"items": []map[string]any{{"product_id": cola, "qty": 100, "price": 9800}},
	}), 201, "income")
	a.expect(a.do("POST", "/store/inventory/documents/"+inc.str("id")+"/post", distTok, nil), 200, "post income")
	pts := a.expect(a.do("GET", "/store/price-types", distTok, nil), 200, "price types").items()
	pd := a.expect(a.do("POST", "/store/price-documents", distTok, map[string]any{
		"price_type_id": pts[0]["id"], "items": []map[string]any{{"product_id": cola, "new_price": 10000}},
	}), 201, "price doc")
	a.expect(a.do("POST", "/store/price-documents/"+pd.str("id")+"/post", distTok, nil), 200, "post price")
	code := a.expect(a.do("POST", "/store/supply/stores/"+store1+"/code", distTok, nil), 201, "code").str("code")
	a.expect(a.do("POST", "/store/suppliers/connect", storeTok, map[string]any{"store_id": store1, "code": code}), 200, "connect")
	distID := a.expect(a.do("GET", "/store/suppliers?store_id="+store1, storeTok, nil), 200, "suppliers").items()[0]["id"].(string)
	ord := a.expect(a.do("POST", "/store/supplier-orders", storeTok, map[string]any{
		"store_id": store1, "distributor_id": distID, "items": []map[string]any{{"product_id": cola, "qty": 24}},
	}), 201, "order").str("id")
	a.expect(a.do("POST", "/store/supply/orders/"+ord+"/accept", distTok, nil), 200, "accept")
	a.expect(a.do("POST", "/store/supply/orders/"+ord+"/deliver", distTok, nil), 200, "deliver")

	st := a.expect(a.do("GET", "/store/supply/stores/"+store1+"/statement", distTok, nil), 200, "statement")
	if st.str("debt") != "240000.00" || st.str("pending_sum") != "0.00" {
		t.Fatalf("statement = %v", st.Body)
	}
	if s := a.expect(a.do("GET", "/store/supply/summary", distTok, nil), 200, "summary"); s.str("owed_total") != "240000.00" || s.Body["owed_stores"].(float64) != 1 {
		t.Fatalf("summary = %v", s.Body)
	}
	if d := a.expect(a.do("GET", "/store/supply/debtors", distTok, nil), 200, "debtors").items(); len(d) != 1 || d[0]["store_id"] != store1 || d[0]["debt"] != "240000.00" {
		t.Fatalf("debtors = %v", d)
	}
	for _, period := range []string{"today", "week", "month"} {
		dash := a.expect(a.do("GET", "/store/supply/dashboard?period="+period, distTok, nil), 200, "dashboard "+period)
		pts := dash.Body["points"].([]any)
		var sum float64
		for _, x := range pts {
			v, _ := strconv.ParseFloat(x.(map[string]any)["shipped"].(string), 64)
			sum += v
		}
		want := map[string]int{"today": 24, "week": 7, "month": 30}[period]
		if dash.str("shipped") != "240000.00" || dash.Body["shipments"].(float64) != 1 || dash.Body["stores"].(float64) != 1 ||
			len(pts) != want || sum != 240000 || dash.str("owed_total") != "240000.00" || len(dash.Body["top_products"].([]any)) != 1 ||
			dash.Body["change_pct"] != nil {
			t.Fatalf("dashboard %s = %v", period, dash.Body)
		}
	}
	a.expect(a.do("GET", "/store/supply/dashboard?period=year", distTok, nil), 400, "bad period")

	// Деньги в кассе магазина.
	var box string
	for _, b := range a.expect(a.do("GET", "/store/finance/cashboxes", storeTok, nil), 200, "boxes").items() {
		if b["store_id"] == store1 {
			box = b["id"].(string)
		}
	}
	reason := a.expect(a.do("POST", "/store/finance/reasons", storeTok, map[string]any{"name": "Выручка", "kind": "income"}), 201, "reason").str("id")
	a.expect(a.do("POST", "/store/finance/operations", storeTok, map[string]any{
		"kind": "income", "cashbox_id": box, "amount": 1000000, "reason_id": reason,
	}), 201, "cash in")

	// 1) Магазин отдал 100 000 — агент подтверждает.
	a.expect(a.do("POST", "/store/suppliers/"+distID+"/pay", storeTok, map[string]any{"amount": 100000, "cashbox_id": box, "method": "bitcoin"}), 400, "bad method")
	p1 := a.expect(a.do("POST", "/store/suppliers/"+distID+"/pay", storeTok, map[string]any{
		"amount": 100000, "cashbox_id": box, "method": "cash", "store_id": store1, "note": "Кассир Дильноза",
	}), 201, "pay 1")
	if p1.str("status") != "pending" || p1.str("store_id") != store1 || p1.str("method") != "cash" {
		t.Fatalf("pay 1 = %v", p1.Body)
	}
	if s := a.expect(a.do("GET", "/store/supply/summary", distTok, nil), 200, "summary"); s.Body["pending_payments"].(float64) != 1 || s.str("pending_payments_sum") != "100000.00" || s.str("owed_total") != "240000.00" {
		t.Fatalf("summary pending = %v", s.Body)
	}
	a.expect(a.do("POST", "/store/supply/payments/"+p1.str("id")+"/confirm", storeTok, nil), 403, "store cannot confirm")
	c1 := a.expect(a.do("POST", "/store/supply/payments/"+p1.str("id")+"/confirm", distTok, nil), 200, "confirm")
	if c1.str("status") != "confirmed" || c1.str("received") != "100000.00" {
		t.Fatalf("confirm = %v", c1.Body)
	}
	a.expect(a.do("POST", "/store/supply/payments/"+p1.str("id")+"/confirm", distTok, nil), 409, "confirm twice")

	// 2) Обычная оплата из «Финансов» контрагенту-агенту — тоже ждёт агента.
	var cp string
	for _, c := range a.expect(a.do("GET", "/store/finance/counterparties", storeTok, nil), 200, "counterparties").items() {
		if c["distributor_id"] == distID {
			cp = c["id"].(string)
		}
	}
	if cp == "" {
		cp = sqlStr(t, pool, `SELECT id::text FROM counterparties WHERE distributor_id IS NOT NULL`)
	}
	a.expect(a.do("POST", "/store/finance/operations", storeTok, map[string]any{
		"kind": "expense", "cashbox_id": box, "amount": 50000, "counterparty_id": cp,
	}), 201, "pay via finance")
	pays := a.expect(a.do("GET", "/store/supply/payments?status=pending", distTok, nil), 200, "pending").items()
	if len(pays) != 1 || pays[0]["amount"] != "50000.00" {
		t.Fatalf("pending = %v", pays)
	}
	p2 := pays[0]["id"].(string)

	// Агент получил 40 000 — расхождение; магазин соглашается.
	a.expect(a.do("POST", "/store/supply/payments/"+p2+"/dispute", distTok, map[string]any{"received": 60000}), 400, "more than paid")
	d2 := a.expect(a.do("POST", "/store/supply/payments/"+p2+"/dispute", distTok, map[string]any{"received": 40000, "comment": "В пачке было 40"}), 200, "dispute")
	if d2.str("status") != "disputed" || d2.str("received") != "40000.00" {
		t.Fatalf("dispute = %v", d2.Body)
	}
	sp := a.expect(a.do("GET", "/store/suppliers/"+distID+"/payments", storeTok, nil), 200, "store payments").items()
	if len(sp) != 2 || sp[0]["status"] != "disputed" || sp[0]["agent_comment"] != "В пачке было 40" {
		t.Fatalf("store payments = %v", sp)
	}
	a.expect(a.do("POST", "/store/suppliers/payments/"+p2+"/resolve", storeTok, map[string]any{"amount": 70000}), 400, "more than paid")
	r2 := a.expect(a.do("POST", "/store/suppliers/payments/"+p2+"/resolve", storeTok, map[string]any{"amount": 40000}), 200, "agree")
	if r2.str("status") != "confirmed" || r2.str("amount") != "40000.00" {
		t.Fatalf("agree = %v", r2.Body)
	}

	// 3) «Не получал» → магазин исправляет на 30 000 → снова ждёт → агент подтверждает.
	p3 := a.expect(a.do("POST", "/store/suppliers/"+distID+"/pay", storeTok, map[string]any{"amount": 30000, "cashbox_id": box}), 201, "pay 3").str("id")
	a.expect(a.do("POST", "/store/supply/payments/"+p3+"/dispute", distTok, map[string]any{"received": 0}), 200, "not received")
	r3 := a.expect(a.do("POST", "/store/suppliers/payments/"+p3+"/resolve", storeTok, map[string]any{"amount": 25000}), 200, "fix")
	if r3.str("status") != "pending" || r3.str("amount") != "25000.00" {
		t.Fatalf("fix = %v", r3.Body)
	}
	a.expect(a.do("POST", "/store/supply/payments/"+p3+"/confirm", distTok, nil), 200, "confirm 3")

	// 4) «Не получал» → магазин согласен: оплата отменена, деньги вернулись в кассу.
	p4 := a.expect(a.do("POST", "/store/suppliers/"+distID+"/pay", storeTok, map[string]any{"amount": 20000, "cashbox_id": box}), 201, "pay 4").str("id")
	a.expect(a.do("POST", "/store/suppliers/payments/"+p4+"/resolve", storeTok, map[string]any{"amount": 0}), 400, "cancel without dispute")
	a.expect(a.do("POST", "/store/supply/payments/"+p4+"/dispute", distTok, map[string]any{"received": 0}), 200, "not received 4")
	if r4 := a.expect(a.do("POST", "/store/suppliers/payments/"+p4+"/resolve", storeTok, map[string]any{"amount": 0}), 200, "agree not received"); r4.str("status") != "cancelled" {
		t.Fatalf("cancel = %v", r4.Body)
	}

	// Итог у агента: 240 000 − 100 000 − 40 000 − 25 000 = 75 000.
	st = a.expect(a.do("GET", "/store/supply/stores/"+store1+"/statement", distTok, nil), 200, "statement after")
	if st.str("debt") != "75000.00" || len(st.Body["open"].([]any)) != 0 {
		t.Fatalf("statement after = %v", st.Body)
	}
	// Касса магазина: 1 000 000 − 100 000 − 50 000 + 10 000 − 30 000 + 5 000 = 835 000.
	if b := sqlStr(t, pool, `SELECT sum(amount)::numeric(18,2)::text FROM cash_entries WHERE cashbox_id = '`+box+`'`); b != "835000.00" {
		t.Fatalf("store cash = %s", b)
	}
	// Долг магазина поставщику по журналу: приход не проведён (0) − оплаты (100 000 + 40 000 + 25 000).
	if b := sqlStr(t, pool, `SELECT sum(amount)::numeric(18,2)::text FROM counterparty_entries WHERE counterparty_id = '`+cp+`'`); b != "-165000.00" {
		t.Fatalf("store debt = %s", b)
	}
}
