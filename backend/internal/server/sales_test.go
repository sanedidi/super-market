package server_test

import (
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

func TestSalesFlow(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, sugar := catalogBasics(t, a, adminTok)
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)

	// Остатки: 10 колы по 10 000 и 5 кг сахара по 8 000 (оприходование).
	doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "posting", "warehouse_id": wh,
		"items": []map[string]any{{"product_id": cola, "qty": 10, "price": 10000}, {"product_id": sugar, "qty": 5, "price": 8000}},
	}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post posting")

	methods := a.expect(a.do("GET", "/store/finance/payment-methods?store_id="+store, tok, nil), 200, "methods").items()
	var cash, card string
	for _, m := range methods {
		if m["name"] == "Наличные" {
			cash = m["id"].(string)
		} else {
			card = m["id"].(string)
		}
	}

	// Продажа: 2 колы по 15 000 (базовая цена) + 1,5 кг сахара по 12 000, скидка 1 000.
	// Итого 30 000 + 18 000 − 1 000 = 47 000, оплата наличными и картой.
	sale := map[string]any{
		"client_uid": "pos-1-000001", "store_id": store,
		"items": []map[string]any{
			{"product_id": cola, "qty": 2, "discount": 1000},
			{"product_id": sugar, "qty": "1.5"},
		},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 20000}, {"payment_method_id": card, "amount": 27000}},
	}
	s := a.expect(a.do("POST", "/store/sales", tok, sale), 201, "sale")
	if s.str("total") != "47000.00" || s.str("discount") != "1000.00" || s.str("fiscal_status") != "pending" {
		t.Fatalf("sale = %v", s.Body)
	}
	// Повторная отправка из офлайна — та же продажа, 200, товар не списан дважды.
	again := a.expect(a.do("POST", "/store/sales", tok, sale), 200, "duplicate sale")
	if again.str("id") != s.str("id") {
		t.Fatal("duplicate client_uid created a new sale")
	}
	if q, _ := stockOf(t, a, tok, wh, cola); q != "8.000" {
		t.Fatalf("cola after sale = %s", q)
	}

	// Ошибки: оплата не сходится, товара не хватает, дробная кола.
	bad := func(body map[string]any, status int, what string) {
		t.Helper()
		a.expect(a.do("POST", "/store/sales", tok, body), status, what)
	}
	bad(map[string]any{"client_uid": "pos-1-000002", "store_id": store,
		"items":    []map[string]any{{"product_id": cola, "qty": 1}},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 1000}}}, 400, "payment mismatch")
	bad(map[string]any{"client_uid": "pos-1-000003", "store_id": store,
		"items":    []map[string]any{{"product_id": cola, "qty": 100}},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 1500000}}}, 409, "insufficient stock")
	bad(map[string]any{"client_uid": "pos-1-000004", "store_id": store,
		"items":    []map[string]any{{"product_id": cola, "qty": 0.5}},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 7500}}}, 400, "fractional pcs")
	if q, _ := stockOf(t, a, tok, wh, cola); q != "8.000" {
		t.Fatalf("failed sales changed stock: %s", q)
	}

	// Контроль чеков: одна продажа без чека; касса регистрирует чек.
	fc := a.expect(a.do("GET", "/store/sales/fiscal-control", tok, nil), 200, "fiscal control")
	if fc.Body["pending_sales"].(float64) != 1 {
		t.Fatalf("fiscal control = %v", fc.Body)
	}
	a.expect(a.do("POST", "/store/sales/"+s.str("id")+"/fiscal", tok, map[string]any{
		"fiscal_number": "UZ000123", "fiscal_sign": "A1B2C3",
	}), 200, "register fiscal")
	a.expect(a.do("POST", "/store/sales/"+s.str("id")+"/fiscal", tok, map[string]any{
		"fiscal_number": "UZ000123", "fiscal_sign": "A1B2C3",
	}), 409, "register twice")
	if pending := a.expect(a.do("GET", "/store/sales?fiscal=pending", tok, nil), 200, "pending").items(); len(pending) != 0 {
		t.Fatalf("pending after register = %v", pending)
	}

	// Возврат 1 колы: 29 000 / 2 = 14 500 наличными, товар вернулся в партию.
	ret := a.expect(a.do("POST", "/store/sales/returns", tok, map[string]any{
		"sale_id": s.str("id"), "payment_method_id": cash, "reason": "Не подошло",
		"items": []map[string]any{{"sale_line": 1, "qty": 1}},
	}), 201, "return")
	if ret.str("total") != "14500.00" {
		t.Fatalf("return total = %s", ret.str("total"))
	}
	if q, c := stockOf(t, a, tok, wh, cola); q != "9.000" || c != "10000.00" {
		t.Fatalf("cola after return = %s @ %s", q, c)
	}
	// Вернуть больше, чем осталось в чеке, нельзя.
	a.expect(a.do("POST", "/store/sales/returns", tok, map[string]any{
		"sale_id": s.str("id"), "payment_method_id": cash,
		"items": []map[string]any{{"sale_line": 1, "qty": 2}},
	}), 409, "return exceeds sale")
	// Последняя кола — остаток суммы строки без копеечных хвостов.
	ret2 := a.expect(a.do("POST", "/store/sales/returns", tok, map[string]any{
		"sale_id": s.str("id"), "payment_method_id": cash,
		"items": []map[string]any{{"sale_line": 1, "qty": 1}},
	}), 201, "return rest")
	if ret2.str("total") != "14500.00" {
		t.Fatalf("second return = %s", ret2.str("total"))
	}
	got := a.expect(a.do("GET", "/store/sales/"+s.str("id"), tok, nil), 200, "sale").Body["items"].([]any)
	if got[0].(map[string]any)["returned_qty"] != "2.000" {
		t.Fatalf("returned_qty = %v", got)
	}

	// «Наличные» — в кассу магазина (ящик), «Терминал» — в «Терминал (банк)»:
	// наличными 20 000 − 14 500 − 14 500 = −9 000 (возврат отдали из размена,
	// которого учёт не знает), терминал 27 000.
	boxes := a.expect(a.do("GET", "/store/finance/cashboxes", tok, nil), 200, "boxes").items()
	for _, b := range boxes {
		want := map[string]string{"cash": "-9000.00", "bank": "27000.00"}[b["kind"].(string)]
		if b["is_main"] == false && b["balance"] != want {
			t.Fatalf("store cashbox %v balance = %v", b["kind"], b["balance"])
		}
	}

	// Продавцу без права скидок скидка запрещена, без права POS — продажа.
	role := a.expect(a.do("POST", "/store/roles", tok, map[string]any{
		"name": "Кассир", "permissions": []string{identity.PermSalesPOS},
	}), 201, "role").str("id")
	a.expect(a.do("POST", "/store/employees", tok, map[string]any{
		"phone": "+998900000006", "full_name": "Кассир", "role_id": role, "store_ids": []string{store},
	}), 201, "cashier")
	cashierTok, _ := a.login("+998900000006", identity.AppStore)
	a.expect(a.do("POST", "/store/sales", cashierTok, map[string]any{
		"client_uid": "pos-2-000001", "store_id": store,
		"items":    []map[string]any{{"product_id": cola, "qty": 1, "discount": 500}},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 14500}},
	}), 403, "discount without permission")
	a.expect(a.do("POST", "/store/sales", cashierTok, map[string]any{
		"client_uid": "pos-2-000002", "store_id": store,
		"items":    []map[string]any{{"product_id": cola, "qty": 1}},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 15000}},
	}), 201, "cashier sale")
	a.expect(a.do("POST", "/store/sales/returns", cashierTok, map[string]any{
		"sale_id": s.str("id"), "payment_method_id": cash, "items": []map[string]any{{"sale_line": 2, "qty": 1}},
	}), 403, "return without permission")
}
