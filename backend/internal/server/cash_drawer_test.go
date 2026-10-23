package server_test

import (
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// TestCashDrawer — «Финансы понятно» (Figma Ф1–Ф4): терминал — в отдельную
// кассу «Терминал (банк)», в ящике = размен + наличные ± внесения/изъятия,
// сдача кассы с разменом и недостачей, размен подставляется следующей смене,
// прибыль без цен закупки и цена закупки задним числом.
func TestCashDrawer(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, sugar := catalogBasics(t, a, adminTok)
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
	// Колу оприходовали с ценой закупки, сахар — без (как остаток «Начала работы»).
	doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "posting", "warehouse_id": wh,
		"items": []map[string]any{{"product_id": cola, "qty": 10, "price": 10000}, {"product_id": sugar, "qty": 5, "price": 0}},
	}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post posting")

	dev := a.expect(a.do("POST", "/store/pos/devices", tok, map[string]any{"store_id": store, "name": "Касса 4"}), 201, "device")
	dt := a.expect(a.do("POST", "/pos/activate", "", map[string]any{"code": dev.str("activation_code"), "app_version": "0.1.0"}), 200, "activate").str("token")
	role := a.expect(a.do("POST", "/store/roles", tok, map[string]any{"name": "Кассир", "permissions": []string{identity.PermSalesPOS}}), 201, "role").str("id")
	cashier := a.expect(a.do("POST", "/store/employees", tok, map[string]any{
		"phone": "+998900000006", "full_name": "Кассир", "role_id": role, "store_ids": []string{store},
	}), 201, "cashier").str("id")
	a.expect(a.do("PUT", "/store/pos/pins/"+cashier, tok, map[string]any{"pin": "1234"}), 200, "pin")
	a.expect(posDo(a, "POST", "/pos/login", dt, "", map[string]any{"employee_id": cashier, "pin": "1234"}), 200, "login")
	cat := a.expect(posDo(a, "GET", "/pos/catalog", dt, "", nil), 200, "catalog")
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

	// Смена №1: размен 1 229 000, продажи: 2 колы наличными (30 000), 1 кола
	// картой (15 000), 1 кг сахара наличными (12 000), изъятие 7 000.
	shift := a.expect(posDo(a, "POST", "/pos/shifts", dt, cashier, map[string]any{"client_uid": "drawer-shift-1", "opening_cash": 1229000}), 201, "open").str("id")
	sale := func(uid, product string, qty any, method string, amount int) {
		t.Helper()
		a.expect(posDo(a, "POST", "/pos/sales", dt, cashier, map[string]any{"client_uid": uid, "shift_id": shift,
			"items":    []map[string]any{{"product_id": product, "qty": qty}},
			"payments": []map[string]any{{"payment_method_id": method, "amount": amount}}}), 201, "sale "+uid)
	}
	sale("drawer-sale-1", cola, 2, cash, 30000)
	sale("drawer-sale-2", cola, 1, card, 15000)
	sale("drawer-sale-3", sugar, 1, cash, 12000)
	move := map[string]any{"client_uid": "drawer-move-1", "kind": "out", "amount": 7000, "reason": "Инкассация"}
	a.expect(posDo(a, "POST", "/pos/shifts/"+shift+"/cash-moves", dt, cashier, move), 200, "cash out")
	a.expect(posDo(a, "POST", "/pos/shifts/"+shift+"/cash-moves", dt, cashier, move), 200, "cash out again")

	// В ящике: 1 229 000 + 42 000 − 7 000 = 1 264 000; терминал отдельно.
	d := a.expect(a.do("GET", "/store/pos/drawer?store_id="+store, tok, nil), 200, "drawer")
	if d.str("amount") != "1264000.00" || d.str("card") != "15000.00" || d.str("ledger") != "35000.00" || len(d.Body["shifts"].([]any)) != 1 {
		t.Fatalf("drawer = %v", d.Body)
	}
	if sh := d.Body["shifts"].([]any)[0].(map[string]any); sh["sales_count"].(float64) != 3 || sh["sales_total"] != "57000.00" {
		t.Fatalf("drawer shift = %v", sh)
	}
	boxes := map[string]map[string]any{}
	for _, b := range a.expect(a.do("GET", "/store/finance/cashboxes", tok, nil), 200, "boxes").items() {
		boxes[b["kind"].(string)+map[bool]string{true: ":main"}[b["is_main"] == true]] = b
	}
	if boxes["bank"]["balance"] != "15000.00" || boxes["cash"]["balance"] != "35000.00" {
		t.Fatalf("boxes = %v", boxes)
	}

	// Терминал не сдают; сдача: забрали 1 055 000, оставили 200 000 →
	// недостача 1 264 000 − 1 255 000 = 9 000.
	a.expect(a.do("POST", "/store/finance/handovers", tok, map[string]any{"from_id": boxes["bank"]["id"], "amount": 1000}), 400, "bank handover")
	h := a.expect(a.do("POST", "/store/finance/handovers", tok, map[string]any{"from_id": d.str("cashbox_id"), "amount": 1055000, "leave": 200000}), 201, "handover")
	if h.str("left_amount") != "200000.00" || h.str("shortage") != "9000.00" || h.str("amount_from") != "1055000.00" {
		t.Fatalf("handover = %v", h.Body)
	}
	d = a.expect(a.do("GET", "/store/pos/drawer?store_id="+store, tok, nil), 200, "drawer after")
	if d.str("amount") != "200000.00" || d.str("ledger") != "200000.00" {
		t.Fatalf("drawer after handover = %v", d.Body)
	}
	// Кассир закрывает смену: в ящике ровно 200 000 — расхождения нет.
	closed := a.expect(posDo(a, "POST", "/pos/shifts/"+shift+"/close", dt, cashier, map[string]any{"counted_cash": 200000}), 200, "close")
	if closed.str("diff") != "0.00" {
		t.Fatalf("closed = %v", closed.Body)
	}
	// Следующая смена: касса подставит размен 200 000.
	cur := a.expect(posDo(a, "GET", "/pos/shifts/current", dt, cashier, nil), 200, "current")
	if cur.Body["shift"] != nil || cur.str("left_in_drawer") != "200000" {
		t.Fatalf("current = %v", cur.Body)
	}
	d = a.expect(a.do("GET", "/store/pos/drawer?store_id="+store, tok, nil), 200, "drawer no shift")
	if d.str("amount") != "200000.00" || len(d.Body["shifts"].([]any)) != 0 {
		t.Fatalf("drawer without shift = %v", d.Body)
	}
	// Смену закрыли с недостачей 5 000 — касса магазина тоже.
	shift = a.expect(posDo(a, "POST", "/pos/shifts", dt, cashier, map[string]any{"client_uid": "drawer-shift-2", "opening_cash": 200000}), 201, "open 2").str("id")
	a.expect(posDo(a, "POST", "/pos/shifts/"+shift+"/close", dt, cashier, map[string]any{"counted_cash": 195000, "diff_reason": "Сдача"}), 200, "close 2")
	if l := a.expect(a.do("GET", "/store/pos/drawer?store_id="+store, tok, nil), 200, "drawer 2").str("ledger"); l != "195000.00" {
		t.Fatalf("ledger after short close = %s", l)
	}
	if hs := a.expect(a.do("GET", "/store/finance/handovers", tok, nil), 200, "handovers").items(); len(hs) != 1 || hs[0]["left_amount"] != "200000.00" {
		t.Fatalf("handovers = %v", hs)
	}

	// Прибыль: сахар продан без цены закупки.
	pl := a.expect(a.do("GET", "/store/reports/profit-loss?store_id="+store, tok, nil), 200, "p&l")
	if pl.Body["sold_products"].(float64) != 2 || pl.Body["no_cost_products"].(float64) != 1 || pl.str("gross_profit") != "27000.00" {
		t.Fatalf("p&l = %v", pl.Body)
	}
	nc := a.expect(a.do("GET", "/store/reports/no-cost?store_id="+store, tok, nil), 200, "no cost").items()
	if len(nc) != 1 || nc[0]["product_id"] != sugar || nc[0]["qty"] != "1.000" || nc[0]["revenue"] != "12000.00" {
		t.Fatalf("no cost = %v", nc)
	}
	a.expect(a.do("POST", "/store/reports/no-cost", tok, map[string]any{"store_id": store, "product_id": sugar, "cost": 0}), 400, "zero cost")
	if r := a.expect(a.do("POST", "/store/reports/no-cost", tok, map[string]any{"store_id": store, "product_id": sugar, "cost": 8000}), 200, "set cost"); r.Body["lines"].(float64) != 1 {
		t.Fatalf("set cost = %v", r.Body)
	}
	pl = a.expect(a.do("GET", "/store/reports/profit-loss?store_id="+store, tok, nil), 200, "p&l after")
	if pl.Body["no_cost_products"].(float64) != 0 || pl.str("gross_profit") != "19000.00" {
		t.Fatalf("p&l after cost = %v", pl.Body)
	}
	// Остаток сахара тоже получил цену: следующая продажа — с себестоимостью.
	var cost string
	if err := pool.QueryRow(t.Context(), `SELECT min(unit_cost)::text FROM batches WHERE product_id = $1`, sugar).Scan(&cost); err != nil || cost != "8000.0000" {
		t.Fatalf("batch cost = %s %v", cost, err)
	}
}
