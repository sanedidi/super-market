package server_test

import (
	"strconv"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// Правки 10 нояб 2026: тип способа оплаты в API, бонус поставщика отдельной
// строкой прихода, оплата поставщику своими деньгами владельца.
func TestOwnerFundsBonusLineAndMethodKind(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, _ := catalogBasics(t, a, adminTok)
	tok, store1 := setupNetwork(t, a, adminTok, "+998900000002")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store1, tok, nil), 200, "warehouses").items()[0]["id"].(string)

	// Способы оплаты отдают вид — приложение находит «Наличные» и «Терминал».
	kinds := map[string]bool{}
	for _, m := range a.expect(a.do("GET", "/store/finance/payment-methods?store_id="+store1, tok, nil), 200, "methods").items() {
		kinds[m["kind"].(string)] = true
	}
	if !kinds["cash"] || !kinds["card"] {
		t.Fatalf("method kinds = %v", kinds)
	}

	supplier := a.expect(a.do("POST", "/store/finance/counterparties", tok, map[string]any{"name": "Lay's дистрибьютор"}), 201, "supplier").str("id")

	// Тот же товар с той же ценой дважды — ошибка.
	a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "income", "warehouse_id": wh, "counterparty_id": supplier,
		"items": []map[string]any{{"product_id": cola, "qty": 3, "price": 20850}, {"product_id": cola, "qty": 1, "price": "20850.00"}},
	}), 400, "same line twice")
	// Бонус со скидкой 100% — отдельной строкой: можно.
	inc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "income", "warehouse_id": wh, "counterparty_id": supplier,
		"items": []map[string]any{
			{"product_id": cola, "qty": 3, "price": 20850},
			{"product_id": cola, "qty": 1, "price": 0, "list_price": 20850},
		},
	}), 201, "income with bonus line")
	posted := a.expect(a.do("POST", "/store/inventory/documents/"+inc.str("id")+"/post", tok, nil), 200, "post income")
	if posted.str("total") != "62550.00" {
		t.Fatalf("total = %s", posted.str("total"))
	}
	if q, c := stockOf(t, a, tok, wh, cola); q != "4.000" || c != "15637.50" {
		t.Fatalf("stock = %s @ %s", q, c)
	}

	balance := func(id string) string {
		return a.expect(a.do("GET", "/store/finance/counterparties/"+id, tok, nil), 200, "counterparty").str("balance")
	}
	mainBalance := func() string {
		for _, b := range a.expect(a.do("GET", "/store/finance/cashboxes", tok, nil), 200, "cashboxes").items() {
			if b["is_main"] == true {
				f, _ := strconv.ParseFloat(b["balance"].(string), 64)
				return strconv.FormatFloat(f, 'f', 2, 64)
			}
		}
		t.Fatal("no main cashbox")
		return ""
	}
	main0 := mainBalance()
	if balance(supplier) != "62550.00" {
		t.Fatalf("before: supplier %s, main %s", balance(supplier), mainBalance())
	}

	// В кассах пусто — обычная оплата не проходит.
	a.expect(a.do("POST", "/store/finance/operations", tok, map[string]any{
		"kind": "expense", "cashbox_id": "00000000-0000-0000-0000-000000000000", "amount": 50000, "counterparty_id": supplier, "owner_funds": "gift",
	}), 400, "wrong owner_funds")
	// Вклад владельца: долг поставщику уменьшился, касса не изменилась.
	a.expect(a.do("POST", "/store/finance/operations", tok, map[string]any{
		"kind": "expense", "amount": 50000, "counterparty_id": supplier, "owner_funds": "contribution",
	}), 201, "owner contribution")
	if balance(supplier) != "12550.00" || mainBalance() != main0 {
		t.Fatalf("after contribution: supplier %s, main %s", balance(supplier), mainBalance())
	}
	// «Вернуть мне позже»: магазин должен владельцу.
	a.expect(a.do("POST", "/store/finance/operations", tok, map[string]any{
		"kind": "expense", "amount": 12550, "counterparty_id": supplier, "owner_funds": "loan",
	}), 201, "owner loan")
	a.expect(a.do("POST", "/store/finance/operations", tok, map[string]any{
		"kind": "expense", "amount": 1000, "counterparty_id": supplier, "owner_funds": "loan",
	}), 201, "owner loan 2")
	if mainBalance() != main0 {
		t.Fatalf("main after loan = %s", mainBalance())
	}
	debts := a.expect(a.do("GET", "/store/finance/debts", tok, nil), 200, "debts")
	var owner map[string]any
	for _, it := range debts.Body["items"].([]any) {
		if it.(map[string]any)["id"] != supplier {
			owner = it.(map[string]any)
		}
	}
	if owner == nil || owner["balance"] != "13550.00" {
		t.Fatalf("debts = %v", debts.Body)
	}
	if b := balance(supplier); b != "-1000.00" {
		t.Fatalf("supplier after overpay = %s", b)
	}

	// «Товары на складе» другого склада (у агента складов несколько).
	wh2 := a.expect(a.do("POST", "/store/warehouses", tok, map[string]any{"store_id": store1, "name": "Склад 2"}), 201, "wh2").str("id")
	inc2 := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "income", "warehouse_id": wh2, "counterparty_id": supplier,
		"items": []map[string]any{{"product_id": cola, "qty": 7, "price": 4000}},
	}), 201, "income wh2")
	a.expect(a.do("POST", "/store/inventory/documents/"+inc2.str("id")+"/post", tok, nil), 200, "post wh2")
	mp := a.expect(a.do("GET", "/store/inventory/my-products?store_id="+store1+"&warehouse_id="+wh2, tok, nil), 200, "my products wh2")
	if mp.str("warehouse_id") != wh2 {
		t.Fatalf("warehouse = %v", mp.Body["warehouse_id"])
	}
	var row map[string]any
	for _, it := range mp.Body["items"].([]any) {
		if it.(map[string]any)["product_id"] == cola {
			row = it.(map[string]any)
		}
	}
	if row == nil || row["qty"] != "7" || row["avg_cost"] != "4000.00" {
		t.Fatalf("wh2 row = %v", row)
	}
	a.expect(a.do("GET", "/store/inventory/my-products?store_id="+store1+"&warehouse_id="+supplier, tok, nil), 400, "foreign warehouse")
}
