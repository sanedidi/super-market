package server_test

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/sanedidi/super-market/backend/internal/debts"
	"github.com/sanedidi/super-market/backend/internal/identity"
)

// TestDebts — долги покупателей: переключатель магазина, код подтверждения,
// продажа в долг с кассы и из панели, лимит, возврат, погашение, X-отчёт,
// списание, «Мои долги» в приложении, спор, напоминания.
func TestDebts(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	ctx := context.Background()
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, _ := catalogBasics(t, a, adminTok)
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
	doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "posting", "warehouse_id": wh, "items": []map[string]any{{"product_id": cola, "qty": 20, "price": 10000}},
	}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post")

	// Касса и кассир с правом продавать в долг.
	dev := a.expect(a.do("POST", "/store/pos/devices", tok, map[string]any{"store_id": store, "name": "Касса 1"}), 201, "device")
	dt := a.expect(a.do("POST", "/pos/activate", "", map[string]any{"code": dev.str("activation_code")}), 200, "activate").str("token")
	role := a.expect(a.do("POST", "/store/roles", tok, map[string]any{
		"name": "Кассир", "permissions": []string{identity.PermSalesPOS, identity.PermDebtsGive, identity.PermSalesReturn},
	}), 201, "role").str("id")
	cashier := a.expect(a.do("POST", "/store/employees", tok, map[string]any{
		"phone": "+998900000006", "full_name": "Дилноза", "role_id": role, "store_ids": []string{store},
	}), 201, "cashier").str("id")
	a.expect(a.do("PUT", "/store/pos/pins/"+cashier, tok, map[string]any{"pin": "1234"}), 200, "pin")
	cat := a.expect(posDo(a, "GET", "/pos/catalog", dt, "", nil), 200, "catalog")
	if cat.Body["settings"].(map[string]any)["debt_enabled"] != false {
		t.Fatalf("debt_enabled by default = %v", cat.Body["settings"])
	}
	var cash, card string
	for _, x := range cat.Body["payment_methods"].([]any) {
		m := x.(map[string]any)
		switch m["kind"] {
		case "cash":
			cash = m["id"].(string)
		case "card":
			card = m["id"].(string)
		}
	}
	shift := a.expect(posDo(a, "POST", "/pos/shifts", dt, cashier, map[string]any{"client_uid": "shift-0001", "opening_cash": 100000}), 201, "shift").str("id")

	const buyer = "+998905764723"
	sale := func(uid string, qty int, pays []map[string]any, debt map[string]any) map[string]any {
		b := map[string]any{"client_uid": uid, "shift_id": shift, "items": []map[string]any{{"product_id": cola, "qty": qty}}, "payments": pays}
		if debt != nil {
			b["debt"] = debt
		}
		return b
	}

	// Магазин не даёт в долг: из панели — отказ.
	a.expect(a.do("POST", "/store/sales", tok, map[string]any{
		"client_uid": "panel-debt-0", "store_id": store, "items": []map[string]any{{"product_id": cola, "qty": 1}},
		"debt": map[string]any{"phone": buyer, "amount": 15000},
	}), 409, "debt disabled")
	st := a.expect(a.do("PUT", "/store/debt-settings/stores/"+store, tok, map[string]any{"debt_enabled": true}), 200, "enable")
	if st.Body["stores"].([]any)[0].(map[string]any)["debt_enabled"] != true || st.Body["default_limit"] != "500000.00" {
		t.Fatalf("settings = %v", st.Body)
	}
	if c := a.expect(posDo(a, "GET", "/pos/catalog", dt, "", nil), 200, "catalog"); c.Body["settings"].(map[string]any)["debt_enabled"] != true {
		t.Fatal("pos does not see debt_enabled")
	}
	// Признак не попадает покупателям в магазины рядом.
	if strings.Contains(jsonStr(a.do("GET", "/client/stores/nearby?lat=41.3&lng=69.2", "", nil).Body), "debt_enabled") {
		t.Fatal("debt_enabled leaked to client")
	}

	// Новый покупатель: на кассе не найден, код, подтверждение.
	look := a.expect(posDo(a, "GET", "/pos/debtors?phone=90%20576%2047%2023", dt, cashier, nil), 200, "lookup")
	if look.Body["found"] != false || look.Body["unverified_limit"] != "100000.00" || look.Body["debt_enabled"] != true {
		t.Fatalf("lookup new = %v", look.Body)
	}
	code := a.expect(posDo(a, "POST", "/pos/debtors/code", dt, cashier, map[string]any{"phone": buyer}), 200, "code")
	if code.Body["channel"] != "dev" {
		t.Fatalf("code = %v", code.Body)
	}
	a.expect(posDo(a, "POST", "/pos/debtors/code", dt, cashier, map[string]any{"phone": buyer}), 429, "code cooldown")
	a.expect(posDo(a, "POST", "/pos/debtors/verify", dt, cashier, map[string]any{"phone": buyer, "code": "0000"}), 400, "wrong code")
	ver := a.expect(posDo(a, "POST", "/pos/debtors/verify", dt, cashier, map[string]any{"phone": buyer, "code": "111111", "full_name": "Шахзод Анваров"}), 200, "verify")
	d := ver.Body["debtor"].(map[string]any)
	if ver.Body["found"] != true || d["verified"] != true || d["limit"] != "500000.00" || d["full_name"] != "Шахзод Анваров" {
		t.Fatalf("verified = %v", ver.Body)
	}
	debtor := d["debtor_id"].(string)

	// Продажа: 30 000 = 10 000 наличными + 20 000 в долг.
	s1 := a.expect(posDo(a, "POST", "/pos/sales", dt, cashier, sale("sale-0001", 2,
		[]map[string]any{{"payment_method_id": cash, "amount": 10000}}, map[string]any{"phone": buyer, "amount": 20000})), 201, "debt sale")
	if s1.str("debt_amount") != "20000.00" || s1.str("debt_balance") != "20000.00" || s1.str("debtor_name") != "Шахзод Анваров" {
		t.Fatalf("debt sale = %v", s1.Body)
	}
	a.expect(posDo(a, "POST", "/pos/sales", dt, cashier, sale("sale-0002", 1,
		[]map[string]any{{"payment_method_id": cash, "amount": 1000}}, map[string]any{"phone": buyer, "amount": 1000})), 400, "sum mismatch")

	// Свой лимит 25 000: из панели сверх лимита — отказ, касса — помечает.
	a.expect(a.do("PATCH", "/store/debtors/"+debtor, tok, map[string]any{"credit_limit": 25000}), 200, "limit")
	lim := a.expect(a.do("POST", "/store/sales", tok, map[string]any{
		"client_uid": "panel-debt-1", "store_id": store, "items": []map[string]any{{"product_id": cola, "qty": 1}},
		"debt": map[string]any{"phone": buyer, "amount": 15000},
	}), 409, "over limit")
	if lim.Body["error"].(map[string]any)["details"].(map[string]any)["available"] != "5000.00" {
		t.Fatalf("limit error = %v", lim.Body)
	}
	s2 := a.expect(posDo(a, "POST", "/pos/sales", dt, cashier, sale("sale-0003", 1, nil, map[string]any{"phone": buyer, "amount": 15000})), 201, "pos over limit")
	if s2.Body["debt_over_limit"] != true || s2.str("debt_balance") != "35000.00" {
		t.Fatalf("pos over limit = %v", s2.Body)
	}

	// Возврат одной колы из первого чека: 15 000 уходят в счёт долга, денег не выдаём.
	ret := a.expect(posDo(a, "POST", "/pos/returns", dt, cashier, map[string]any{
		"sale_id": s1.str("id"), "payment_method_id": cash, "shift_id": shift, "items": []map[string]any{{"sale_line": 1, "qty": 1}},
	}), 201, "return")
	if ret.str("total") != "15000.00" || ret.str("debt_amount") != "15000.00" {
		t.Fatalf("return = %v", ret.Body)
	}

	// Погашение с кассы: повтор с тем же client_uid — та же запись; больше долга — нельзя.
	pay := a.expect(posDo(a, "POST", "/pos/debt-payments", dt, cashier, map[string]any{
		"client_uid": "dpay-0001", "shift_id": shift, "phone": buyer, "amount": 5000, "payment_method_id": cash,
	}), 201, "debt payment")
	if pay.str("balance") != "15000.00" || pay.str("payment_kind") != "cash" {
		t.Fatalf("payment = %v", pay.Body)
	}
	if again := a.expect(posDo(a, "POST", "/pos/debt-payments", dt, cashier, map[string]any{
		"client_uid": "dpay-0001", "shift_id": shift, "phone": buyer, "amount": 5000, "payment_method_id": cash,
	}), 200, "payment again"); again.str("id") != pay.str("id") {
		t.Fatal("payment duplicated")
	}
	a.expect(posDo(a, "POST", "/pos/debt-payments", dt, cashier, map[string]any{
		"client_uid": "dpay-0002", "shift_id": shift, "phone": buyer, "amount": 50000, "payment_method_id": card,
	}), 409, "payment exceeds")

	// X-отчёт: в долг 35 000 (2 чека), погашено наличными 5 000 — оно в ящике;
	// возврат в счёт долга наличные из ящика не уменьшает.
	x := a.expect(posDo(a, "GET", "/pos/shifts/"+shift, dt, cashier, nil), 200, "x report")
	rep := x.Body["report"].(map[string]any)
	if rep["debt_given"] != "35000.00" || rep["debt_given_count"].(float64) != 2 || rep["debt_paid_cash"] != "5000.00" ||
		rep["cash_returns"] != "0.00" || rep["expected_cash"] != "115000.00" {
		t.Fatalf("x report = %v", rep)
	}

	// Панель: список, итоги, карточка, списание.
	list := a.expect(a.do("GET", "/store/debtors?store_id="+store, tok, nil), 200, "list").items()
	if len(list) != 1 || list[0]["amount"] != "15000.00" || list[0]["limit"] != "25000.00" || list[0]["due_date"] == nil {
		t.Fatalf("list = %v", list)
	}
	sum := a.expect(a.do("GET", "/store/debtors/summary?store_id="+store, tok, nil), 200, "summary")
	if sum.str("total") != "15000.00" || sum.str("given_today") != "35000.00" || sum.str("paid_today_cash") != "5000.00" {
		t.Fatalf("summary = %v", sum.Body)
	}
	card1 := a.expect(a.do("GET", "/store/debtors/"+debtor, tok, nil), 200, "card")
	if n := len(card1.Body["entries"].([]any)); n != 4 || card1.Body["has_app"] != false {
		t.Fatalf("card = %v", card1.Body)
	}
	a.expect(a.do("POST", "/store/debt-writeoffs", tok, map[string]any{"debtor_id": debtor, "store_id": store, "amount": 1000}), 400, "writeoff no reason")
	wo := a.expect(a.do("POST", "/store/debt-writeoffs", tok, map[string]any{"debtor_id": debtor, "store_id": store, "amount": 1000, "reason": "Скидка за ожидание"}), 201, "writeoff")
	if wo.str("balance") != "14000.00" {
		t.Fatalf("writeoff = %v", wo.Body)
	}
	// Кассир без права debts.manage не может списывать (кассир входит и в панель).
	cashTok, _ := a.login("+998900000006", identity.AppStore)
	a.expect(a.do("POST", "/store/debt-writeoffs", cashTok, map[string]any{"debtor_id": debtor, "store_id": store, "amount": 1000, "reason": "x"}), 403, "cashier writeoff")

	// Напоминание вручную: у покупателя нет приложения.
	a.expect(a.do("POST", "/store/debtors/"+debtor+"/remind", tok, map[string]any{"store_id": store}), 409, "no app")

	// Покупатель входит в приложение — видит долг и магазин.
	clientTok, _ := a.login(buyer, identity.AppClient)
	var userID string
	if err := pool.QueryRow(ctx, `SELECT id FROM users WHERE phone = $1`, buyer).Scan(&userID); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO devices (user_id, token, platform, app) VALUES ($1, 'fcm-token-debts-0000000001', 'android', 'client')`, userID); err != nil {
		t.Fatal(err)
	}
	my := a.expect(a.do("GET", "/client/debts", clientTok, nil), 200, "my debts")
	stores := my.Body["stores"].([]any)
	if my.str("total") != "14000.00" || len(stores) != 1 || stores[0].(map[string]any)["name"] != "Магазин 1" || my.Body["next_due"] == nil {
		t.Fatalf("my debts = %v", my.Body)
	}
	if strings.Contains(jsonStr(my.Body), "debt_enabled") || strings.Contains(jsonStr(my.Body), "limit") {
		t.Fatalf("client sees store settings: %v", my.Body)
	}
	hist := a.expect(a.do("GET", "/client/debts/"+store, clientTok, nil), 200, "store debt")
	var saleEntry map[string]any
	for _, x := range hist.Body["entries"].([]any) {
		e := x.(map[string]any)
		if e["doc_type"] == "sale" && e["amount"] == "15000.00" {
			saleEntry = e
		}
	}
	if saleEntry == nil || saleEntry["sale"].(map[string]any)["items"].([]any)[0].(map[string]any)["name"] != "Coca-Cola 1,5 л" {
		t.Fatalf("history = %v", hist.Body)
	}

	// Напоминание вручную — теперь уходит, второе в те же сутки — нельзя.
	a.expect(a.do("POST", "/store/debtors/"+debtor+"/remind", tok, map[string]any{"store_id": store}), 201, "remind")
	a.expect(a.do("POST", "/store/debtors/"+debtor+"/remind", tok, map[string]any{"store_id": store}), 409, "remind too soon")

	// Автоматическое напоминание в день оплаты (10:00 по Ташкенту), один раз.
	due := list[0]["due_date"].(string)
	day, _ := time.Parse("2006-01-02", due)
	at := time.Date(day.Year(), day.Month(), day.Day(), 10, 30, 0, 0, time.FixedZone("UZT", 5*3600))
	rem := debts.NewService(pool, nil, "", "secret", nil, quietLog()).WithClock(func() time.Time { return at })
	for i := 0; i < 2; i++ {
		if err := rem.Tick(ctx); err != nil {
			t.Fatal(err)
		}
	}
	var dueCount int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM notifications_outbox WHERE user_id = $1 AND kind = 'debt_reminder'
		AND title LIKE 'Сегодня день оплаты%'`, userID).Scan(&dueCount); err != nil || dueCount != 1 {
		t.Fatalf("due reminders = %d, %v", dueCount, err)
	}
	var added int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM notifications_outbox WHERE user_id = $1 AND kind IN ('debt_added', 'debt_paid')`, userID).
		Scan(&added); err != nil || added != 0 {
		// Покупатель зарегистрировался после продаж — прошлые push ему не ставились.
		t.Fatalf("old pushes = %d, %v", added, err)
	}

	// «Это не я» по второй покупке; владелец принимает — долг списан.
	var entry2 string
	for _, x := range hist.Body["entries"].([]any) {
		e := x.(map[string]any)
		if e["doc_type"] == "sale" {
			entry2 = jsonStr(e["id"])
			break // новые сверху: вторая продажа
		}
	}
	a.expect(a.do("POST", "/client/debts/entries/"+entry2+"/dispute", clientTok, map[string]any{"comment": "В этот день я не был в магазине"}), 201, "dispute")
	a.expect(a.do("POST", "/client/debts/entries/"+entry2+"/dispute", clientTok, map[string]any{}), 409, "dispute again")
	disp := a.expect(a.do("GET", "/store/debt-disputes", tok, nil), 200, "disputes").items()
	if len(disp) != 1 || disp[0]["cashier"] != "Дилноза" || disp[0]["amount"] != "15000.00" {
		t.Fatalf("disputes = %v", disp)
	}
	a.expect(a.do("POST", "/store/debt-disputes/"+disp[0]["id"].(string)+"/resolve", tok, map[string]any{"status": "accepted"}), 200, "resolve")
	if after := a.expect(a.do("GET", "/client/debts", clientTok, nil), 200, "my debts after"); after.str("total") != "0.00" || len(after.Body["stores"].([]any)) != 0 {
		t.Fatalf("after dispute = %v", after.Body)
	}

	// Выключили «Даёт в долг»: продажа из панели — отказ, долги остаются видны в карточке.
	a.expect(a.do("PUT", "/store/debt-settings/stores/"+store, tok, map[string]any{"debt_enabled": false}), 200, "disable")
	a.expect(a.do("GET", "/store/debtors/"+debtor, tok, nil), 200, "card after disable")

	// P&L: списанные долги — расход.
	pl := a.expect(a.do("GET", "/store/reports/profit-loss?store_id="+store, tok, nil), 200, "pl")
	found := false
	for _, x := range pl.Body["expenses"].([]any) {
		e := x.(map[string]any)
		if e["name"] == "Списанные долги покупателей" && e["amount"] == "15000.00" {
			found = true
		}
	}
	if !found {
		t.Fatalf("pl expenses = %v", pl.Body["expenses"])
	}
}
