package server_test

import (
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// TestStaffAddProduct — «Проверка» в «SM Сотрудник» (Figma П3 / П4в): товара
// нет в магазине — сотрудник со «Складом» ставит цену, сколько есть,
// поставщика и цену закупки; одна кнопка — товар в «Моих товарах», цена на
// кассе, приход проведён. Повтор не создаёт второй приход.
func TestStaffAddProduct(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, sugar := catalogBasics(t, a, adminTok)
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
	supplier := a.expect(a.do("POST", "/store/finance/counterparties", tok, map[string]any{"name": "Coca-Cola Bottlers"}), 201, "supplier").str("id")

	role := func(name string, perms ...string) string {
		return a.expect(a.do("POST", "/store/roles", tok, map[string]any{"name": name, "permissions": perms}), 201, "role "+name).str("id")
	}
	emp := func(phone, name, role string) {
		a.expect(a.do("POST", "/store/employees", tok, map[string]any{"phone": phone, "full_name": name, "role_id": role, "store_ids": []string{store}}), 201, "employee "+name)
	}
	emp("+998900000080", "Кладовщик", role("Склад", identity.PermInventoryManage))
	emp("+998900000082", "Кассир", role("Кассир", identity.PermSalesPOS))
	kTok, _ := a.login("+998900000080", identity.AppStore)
	cTok, _ := a.login("+998900000082", identity.AppStore)

	g := a.expect(a.do("GET", "/store/staff/glance?store_id="+store+"&product_id="+cola, kTok, nil), 200, "glance")
	if g.Body["in_store"] != false {
		t.Fatalf("glance = %v", g.Body)
	}
	body := func(product string, qty any) map[string]any {
		return map[string]any{"store_id": store, "product_id": product, "price": 15000, "qty": qty, "counterparty_id": supplier, "cost": 11500}
	}
	a.expect(a.do("POST", "/store/staff/add-product", cTok, body(cola, 24)), 403, "кассир без «Склада»")
	a.expect(a.do("POST", "/store/staff/add-product", kTok, body(cola, 1.5)), 400, "штучный — дробное")
	noSupplier := body(cola, 24)
	delete(noSupplier, "counterparty_id")
	a.expect(a.do("POST", "/store/staff/add-product", kTok, noSupplier), 400, "без поставщика")
	noCost := body(cola, 24)
	noCost["cost"] = 0
	a.expect(a.do("POST", "/store/staff/add-product", kTok, noCost), 400, "без цены закупки")

	// Кладовщик без права «Цены» добавляет товар — цена ставится вместе с ним.
	r := a.expect(a.do("POST", "/store/staff/add-product", kTok, body(cola, 24)), 201, "add")
	pr := r.Body["product"].(map[string]any)
	if r.Body["created"] != true || r.str("total") != "276000.00" || pr["in_store"] != true || pr["price"] != "15000.00" || pr["qty"] != "24" || pr["uncounted"] != false {
		t.Fatalf("add = %v", r.Body)
	}
	if r.Body["document"].(map[string]any)["number"] == nil || r.Body["price_document"].(map[string]any)["number"] == nil {
		t.Fatalf("documents = %v", r.Body)
	}
	if qty, cost := stockOf(t, a, tok, wh, cola); qty != "24.000" || cost != "11500.00" {
		t.Fatalf("stock = %s × %s", qty, cost)
	}
	// Повтор (двойное нажатие) — второго прихода нет.
	a.expect(a.do("POST", "/store/staff/add-product", kTok, body(cola, 24)), 409, "already in store")
	// Весовой — дробное количество можно.
	w := a.expect(a.do("POST", "/store/staff/add-product", kTok, map[string]any{
		"store_id": store, "product_id": sugar, "price": 14000, "qty": 2.5, "counterparty_id": supplier, "cost": 10000}), 201, "add kg")
	if w.str("total") != "25000.00" || w.Body["product"].(map[string]any)["qty"] != "2.5" {
		t.Fatalf("add kg = %v", w.Body)
	}
	// Цену товара магазина «Склад» по-прежнему не меняет.
	if a.expect(a.do("GET", "/store/staff/glance?store_id="+store+"&product_id="+cola, kTok, nil), 200, "glance 2").Body["can_price"] != false {
		t.Fatal("can_price у кладовщика без «Цен»")
	}
}
