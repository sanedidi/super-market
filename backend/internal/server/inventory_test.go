package server_test

import (
	"strings"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// catalogBasics создаёт категорию, единицы и два товара: штучный и весовой.
func catalogBasics(t *testing.T, a api, adminTok string) (pcsProduct, kgProduct string) {
	t.Helper()
	cat := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Продукты"}), 201, "category")
	var pcs, kg string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		switch u["short_name"] {
		case "шт":
			pcs = u["id"].(string)
		case "кг":
			kg = u["id"].(string)
		}
	}
	p1 := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
		"name": "Coca-Cola 1,5 л", "category_id": cat.str("id"), "unit_id": pcs, "base_price": 15000,
	}), 201, "product pcs")
	p2 := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
		"name": "Сахар", "category_id": cat.str("id"), "unit_id": kg, "base_price": 12000,
	}), 201, "product kg")
	return p1.str("id"), p2.str("id")
}

func stockOf(t *testing.T, a api, tok, warehouseID, productID string) (qty, avgCost string) {
	t.Helper()
	rows := a.expect(a.do("GET", "/store/inventory/stock?warehouse_id="+warehouseID+"&product_id="+productID, tok, nil),
		200, "stock").items()
	if len(rows) == 0 {
		return "0", ""
	}
	return rows[0]["qty"].(string), rows[0]["avg_cost"].(string)
}

func TestInventoryAndFinanceFlow(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, sugar := catalogBasics(t, a, adminTok)
	tok, store1 := setupNetwork(t, a, adminTok, "+998900000002")

	whs := a.expect(a.do("GET", "/store/warehouses?store_id="+store1, tok, nil), 200, "warehouses").items()
	wh1 := whs[0]["id"].(string)
	wh2 := a.expect(a.do("POST", "/store/warehouses", tok, map[string]any{"store_id": store1, "name": "Подсобка"}), 201, "wh2").str("id")

	// Магазин получил кассу наличных, «Терминал (банк)» и способы оплаты,
	// сеть — главную кассу.
	boxes := a.expect(a.do("GET", "/store/finance/cashboxes", tok, nil), 200, "cashboxes").items()
	if len(boxes) != 3 || boxes[0]["is_main"] != true || boxes[1]["kind"] != "cash" || boxes[2]["kind"] != "bank" {
		t.Fatalf("cashboxes = %v", boxes)
	}
	mainBox, storeBox := boxes[0]["id"].(string), boxes[1]["id"].(string)
	if methods := a.expect(a.do("GET", "/store/finance/payment-methods?store_id="+store1, tok, nil), 200, "methods").items(); len(methods) != 2 {
		t.Fatalf("payment methods = %v", methods)
	}

	supplier := a.expect(a.do("POST", "/store/finance/counterparties", tok, map[string]any{
		"name": "ООО Напитки", "phone": "+998712000000",
	}), 201, "supplier").str("id")

	// Приход в USD без курса невозможен.
	inc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "income", "warehouse_id": wh1, "counterparty_id": supplier, "currency": "USD",
		"items": []map[string]any{{"product_id": cola, "qty": 10, "price": 1}},
	}), 201, "income usd draft")
	a.expect(a.do("POST", "/store/inventory/documents/"+inc.str("id")+"/post", tok, nil), 409, "post usd without rate")

	a.expect(a.do("POST", "/store/finance/rates", tok, map[string]any{"rate": 12700}), 201, "set rate")
	posted := a.expect(a.do("POST", "/store/inventory/documents/"+inc.str("id")+"/post", tok, nil), 200, "post income usd")
	if posted.str("total") != "10.00" || posted.str("rate") != "12700.0000" {
		t.Fatalf("income = %v", posted.Body)
	}
	if q, c := stockOf(t, a, tok, wh1, cola); q != "10.000" || c != "12700.00" {
		t.Fatalf("stock after usd income = %s @ %s", q, c)
	}

	// Второй приход в сумах, дробное количество для штучного товара запрещено.
	a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "income", "warehouse_id": wh1, "counterparty_id": supplier,
		"items": []map[string]any{{"product_id": cola, "qty": 1.5, "price": 13000}},
	}), 400, "fractional pcs")
	inc2 := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "income", "warehouse_id": wh1, "counterparty_id": supplier,
		"items": []map[string]any{
			{"product_id": cola, "qty": 5, "price": 13000},
			{"product_id": sugar, "qty": "2.5", "price": 10000},
		},
	}), 201, "income uzs")
	a.expect(a.do("POST", "/store/inventory/documents/"+inc2.str("id")+"/post", tok, nil), 200, "post income uzs")
	if q, _ := stockOf(t, a, tok, wh1, sugar); q != "2.500" {
		t.Fatalf("sugar = %s", q)
	}

	// Долг поставщику: 10 × 12 700 + 5 × 13 000 + 2,5 × 10 000 = 217 000.
	cp := a.expect(a.do("GET", "/store/finance/counterparties/"+supplier, tok, nil), 200, "supplier")
	if cp.str("balance") != "217000.00" {
		t.Fatalf("supplier balance = %s", cp.str("balance"))
	}

	// Списание 3 шт — из старой партии (FIFO), остаток по-прежнему в разных партиях.
	wo := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "write_off", "warehouse_id": wh1, "reason": "Бой",
		"items": []map[string]any{{"product_id": cola, "qty": 3}},
	}), 201, "write-off")
	wo = a.expect(a.do("POST", "/store/inventory/documents/"+wo.str("id")+"/post", tok, nil), 200, "post write-off")
	if wo.str("total") != "38100.00" {
		t.Fatalf("write-off cost = %s (want 3 × 12700)", wo.str("total"))
	}

	// Не хватает товара — документ не проводится и остаётся черновиком.
	big := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "write_off", "warehouse_id": wh1, "reason": "Тест",
		"items": []map[string]any{{"product_id": cola, "qty": 100}},
	}), 201, "big write-off")
	fail := a.expect(a.do("POST", "/store/inventory/documents/"+big.str("id")+"/post", tok, nil), 409, "insufficient")
	if fail.str("error", "code") != "insufficient_stock" {
		t.Fatalf("error = %v", fail.Body)
	}
	if q, _ := stockOf(t, a, tok, wh1, cola); q != "12.000" {
		t.Fatalf("failed post changed stock: %s", q)
	}
	a.expect(a.do("DELETE", "/store/inventory/documents/"+big.str("id"), tok, nil), 204, "delete draft")

	// Перемещение 9 шт на второй склад: 7 из партии по 12 700 и 2 по 13 000.
	tr := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "transfer", "warehouse_id": wh1, "to_warehouse_id": wh2,
		"items": []map[string]any{{"product_id": cola, "qty": 9}},
	}), 201, "transfer")
	a.expect(a.do("POST", "/store/inventory/documents/"+tr.str("id")+"/post", tok, nil), 200, "post transfer")
	if q, c := stockOf(t, a, tok, wh2, cola); q != "9.000" || c != "12766.67" {
		t.Fatalf("wh2 = %s @ %s", q, c)
	}
	if q, c := stockOf(t, a, tok, wh1, cola); q != "3.000" || c != "13000.00" {
		t.Fatalf("wh1 = %s @ %s", q, c)
	}

	// Инвентаризация: по учёту 3, по факту 2 — недостача 1.
	inv := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "inventory", "warehouse_id": wh1,
		"items": []map[string]any{{"product_id": cola, "qty": 2}, {"product_id": sugar, "qty": 3}},
	}), 201, "inventory")
	inv = a.expect(a.do("POST", "/store/inventory/documents/"+inv.str("id")+"/post", tok, nil), 200, "post inventory")
	items := inv.Body["items"].([]any)
	if items[0].(map[string]any)["expected_qty"] != "3.000" {
		t.Fatalf("expected_qty = %v", items)
	}
	if q, _ := stockOf(t, a, tok, wh1, cola); q != "2.000" {
		t.Fatalf("after inventory cola = %s", q)
	}
	if q, c := stockOf(t, a, tok, wh1, sugar); q != "3.000" || c != "10000.00" {
		t.Fatalf("after inventory sugar = %s @ %s (surplus at last cost)", q, c)
	}

	// Возврат поставщику 1 шт без цены — по себестоимости, долг уменьшается.
	ret := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "supplier_return", "warehouse_id": wh1, "counterparty_id": supplier,
		"items": []map[string]any{{"product_id": cola, "qty": 1}},
	}), 201, "supplier return")
	a.expect(a.do("POST", "/store/inventory/documents/"+ret.str("id")+"/post", tok, nil), 200, "post return")
	if b := a.expect(a.do("GET", "/store/finance/counterparties/"+supplier, tok, nil), 200, "supplier").str("balance"); b != "204000.00" {
		t.Fatalf("supplier balance after return = %s", b)
	}

	// Финансы: приход по причине, оплата поставщику, сдача кассы.
	incomeReason := a.expect(a.do("POST", "/store/finance/reasons", tok, map[string]any{"name": "Выручка вне POS", "kind": "income"}), 201, "reason").str("id")
	a.expect(a.do("POST", "/store/finance/operations", tok, map[string]any{
		"kind": "income", "cashbox_id": storeBox, "amount": 500000, "reason_id": incomeReason,
	}), 201, "cash income")
	a.expect(a.do("POST", "/store/finance/operations", tok, map[string]any{
		"kind": "expense", "cashbox_id": storeBox, "amount": 900000, "counterparty_id": supplier,
	}), 409, "expense over balance")
	a.expect(a.do("POST", "/store/finance/operations", tok, map[string]any{
		"kind": "expense", "cashbox_id": storeBox, "amount": 200000, "counterparty_id": supplier,
	}), 201, "pay supplier")
	if b := a.expect(a.do("GET", "/store/finance/counterparties/"+supplier, tok, nil), 200, "supplier").str("balance"); b != "4000.00" {
		t.Fatalf("supplier balance after payment = %s", b)
	}
	// Долги поставщикам и акт сверки (приложение магазина).
	debts := a.expect(a.do("GET", "/store/finance/debts", tok, nil), 200, "debts")
	if debts.str("we_owe") != "4000.00" || debts.Body["we_owe_count"].(float64) != 1 {
		t.Fatalf("debts = %v", debts.Body)
	}
	if it := debts.Body["items"].([]any); len(it) != 1 || it[0].(map[string]any)["id"] != supplier ||
		it[0].(map[string]any)["last_payment_at"] == nil || it[0].(map[string]any)["days_unpaid"] != float64(0) {
		t.Fatalf("debt items = %v", it)
	}
	a.expect(a.do("GET", "/store/finance/debts?side=wrong", tok, nil), 400, "debts side")
	if n := len(a.expect(a.do("GET", "/store/finance/debts?side=they_owe", tok, nil), 200, "they owe").Body["items"].([]any)); n != 0 {
		t.Fatalf("they owe = %d", n)
	}
	act := a.expect(a.do("GET", "/store/finance/counterparties/"+supplier+"/statement", tok, nil), 200, "statement")
	lines := act.Body["items"].([]any)
	if act.str("closing") != "4000.00" || len(lines) != 4 {
		t.Fatalf("statement = %v", act.Body)
	}
	first, last := lines[0].(map[string]any), lines[len(lines)-1].(map[string]any)
	if first["kind"] != "payment" || first["amount"] != "-200000.00" || first["balance"] != "4000.00" ||
		last["kind"] != "income" || !strings.HasPrefix(last["title"].(string), "Приход № ") || last["note"] != "1 позиция" {
		t.Fatalf("statement lines = %v … %v", first, last)
	}
	if ret := lines[1].(map[string]any); ret["kind"] != "supplier_return" || ret["balance"] != "204000.00" {
		t.Fatalf("statement return = %v", ret)
	}
	a.expect(a.do("POST", "/store/finance/operations", tok, map[string]any{
		"kind": "expense", "cashbox_id": storeBox, "amount": 1000, "reason_id": incomeReason,
	}), 400, "income reason on expense")

	a.expect(a.do("POST", "/store/finance/handovers", tok, map[string]any{"from_id": storeBox, "amount": 250000}), 201, "handover")
	a.expect(a.do("POST", "/store/finance/handovers", tok, map[string]any{"from_id": mainBox, "amount": 1}), 400, "handover from main")

	// Долларовая главная касса и перевод по курсу.
	usdBox := a.expect(a.do("POST", "/store/finance/cashboxes", tok, map[string]any{"name": "Главная USD", "currency": "USD"}), 201, "usd box").str("id")
	tr2 := a.expect(a.do("POST", "/store/finance/transfers", tok, map[string]any{
		"from_id": mainBox, "to_id": usdBox, "amount": 127000,
	}), 201, "uzs to usd")
	if tr2.str("amount_to") != "10.00" {
		t.Fatalf("amount_to = %s", tr2.str("amount_to"))
	}
	boxes = a.expect(a.do("GET", "/store/finance/cashboxes", tok, nil), 200, "cashboxes").items()
	balances := map[string]string{}
	for _, b := range boxes {
		balances[b["id"].(string)] = b["balance"].(string)
	}
	if balances[storeBox] != "50000.00" || balances[mainBox] != "123000.00" || balances[usdBox] != "10.00" {
		t.Fatalf("balances = %v", balances)
	}

	// Сотрудник без прав склада и финансов.
	role := a.expect(a.do("POST", "/store/roles", tok, map[string]any{"name": "Продавец"}), 201, "role").str("id")
	a.expect(a.do("POST", "/store/employees", tok, map[string]any{
		"phone": "+998900000005", "full_name": "Продавец", "role_id": role, "store_ids": []string{store1},
	}), 201, "seller")
	sellerTok, _ := a.login("+998900000005", identity.AppStore)
	a.expect(a.do("POST", "/store/inventory/documents", sellerTok, map[string]any{
		"type": "posting", "warehouse_id": wh1, "items": []map[string]any{{"product_id": cola, "qty": 1, "price": 1}},
	}), 403, "seller creates doc")
	a.expect(a.do("POST", "/store/finance/handovers", sellerTok, map[string]any{"from_id": storeBox, "amount": 1}), 403, "seller handover")
	// Кассы без finance.manage не видны; остатки видны, но без себестоимости.
	a.expect(a.do("GET", "/store/finance/cashboxes", sellerTok, nil), 403, "seller boxes")
	stock := a.expect(a.do("GET", "/store/inventory/stock?store_id="+store1, sellerTok, nil), 200, "seller sees stock").items()
	if len(stock) == 0 || stock[0]["qty"] == nil || stock[0]["avg_cost"] != nil || stock[0]["total_cost"] != nil {
		t.Fatalf("seller stock must hide cost: %v", stock)
	}

	// Кассир с finance.manage и доступом к одному магазину видит только его
	// кассы: наличные и «Терминал (банк)», без главной.
	a.expect(a.do("PATCH", "/store/roles/"+role, tok, map[string]any{"permissions": []string{identity.PermFinanceManage}}), 200, "grant finance")
	if boxes := a.expect(a.do("GET", "/store/finance/cashboxes", sellerTok, nil), 200, "seller boxes").items(); len(boxes) != 2 || boxes[0]["is_main"] != false || boxes[1]["is_main"] != false {
		t.Fatalf("seller must see only store cashbox: %v", boxes)
	}
}
