package server_test

import (
	"testing"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// TestDelete — «Удалить» в веб-панелях: неиспользуемое удаляется (204),
// используемое — 409 in_use с подсказкой «Отключить», служебное защищено.
func TestDelete(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)

	inUse := func(r resp, what string) {
		t.Helper()
		a.expect(r, 409, what)
		if r.str("error", "code") != "in_use" {
			t.Fatalf("%s: code = %v", what, r.Body)
		}
	}

	// Справочники платформы.
	brand := a.expect(a.do("POST", "/admin/catalog/brands", adminTok, map[string]any{"name": "Лишний бренд"}), 201, "brand").str("id")
	a.expect(a.do("DELETE", "/admin/catalog/brands/"+brand, adminTok, nil), 204, "delete brand")
	a.expect(a.do("DELETE", "/admin/catalog/brands/"+brand, adminTok, nil), 404, "delete brand twice")
	a.expect(a.do("DELETE", "/admin/catalog/nope/"+brand, adminTok, nil), 404, "unknown dict")
	drinks := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Напитки"}), 201, "category").str("id")
	a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Газировка", "parent_id": drinks}), 201, "subcategory")
	r := a.do("DELETE", "/admin/catalog/categories/"+drinks, adminTok, nil)
	inUse(r, "category with children")
	if d, _ := r.Body["error"].(map[string]any)["details"].(map[string]any); d["deactivate"] != true {
		t.Fatalf("deactivate hint = %v", r.Body)
	}
	var pcs string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		if u["short_name"] == "шт" {
			pcs = u["id"].(string)
		}
	}
	cola := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
		"name": "Cola", "category_id": drinks, "unit_id": pcs, "base_price": 15000,
	}), 201, "product").str("id")
	spare := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
		"name": "Ненужный товар", "category_id": drinks, "unit_id": pcs, "base_price": 1000,
	}), 201, "spare product").str("id")
	a.expect(a.do("DELETE", "/admin/products/"+spare, adminTok, nil), 204, "delete unused product")

	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	a.expect(a.do("DELETE", "/admin/products/"+spare, tok, nil), 403, "store token on admin")

	// Свой товар: с ценой в документе удалится только черновик документа, но не товар.
	own := a.expect(a.do("POST", "/store/products", tok, map[string]any{
		"name": "Лепёшка", "category_id": drinks, "unit_id": pcs, "base_price": "4000",
	}), 201, "own product").str("id")
	a.expect(a.do("DELETE", "/store/products/"+cola, tok, nil), 403, "global product from store")

	// Типы цен: основной защищён.
	var retail string
	for _, pt := range a.expect(a.do("GET", "/store/price-types", tok, nil), 200, "price types").items() {
		if pt["is_default"] == true {
			retail = pt["id"].(string)
		}
	}
	a.expect(a.do("DELETE", "/store/price-types/"+retail, tok, nil), 409, "default price type")
	extra := a.expect(a.do("POST", "/store/price-types", tok, map[string]any{"name": "Опт"}), 201, "price type").str("id")
	a.expect(a.do("DELETE", "/store/price-types/"+extra, tok, nil), 204, "delete price type")

	// Установка цен: черновик удаляется, проведённый — нет.
	draft := a.expect(a.do("POST", "/store/price-documents", tok, map[string]any{
		"price_type_id": retail, "items": []map[string]any{{"product_id": own, "new_price": "4500"}},
	}), 201, "price draft").str("id")
	a.expect(a.do("DELETE", "/store/price-documents/"+draft, tok, nil), 204, "delete price draft")
	posted := a.expect(a.do("POST", "/store/price-documents", tok, map[string]any{
		"price_type_id": retail, "items": []map[string]any{{"product_id": own, "new_price": "4500"}},
	}), 201, "price doc").str("id")
	a.expect(a.do("POST", "/store/price-documents/"+posted+"/post", tok, nil), 200, "post price doc")
	a.expect(a.do("DELETE", "/store/price-documents/"+posted, tok, nil), 409, "delete posted price doc")
	inUse(a.do("DELETE", "/store/products/"+own, tok, nil), "own product in price document")

	// Акция.
	now := time.Now()
	promo := a.expect(a.do("POST", "/store/promotions", tok, map[string]any{
		"name": "Скидки", "starts_at": now, "ends_at": now.Add(24 * time.Hour),
		"items": []map[string]any{{"product_id": cola, "price": 12000}},
	}), 201, "promotion").str("id")
	a.expect(a.do("DELETE", "/store/promotions/"+promo, tok, nil), 204, "delete promotion")

	// Склады: основной склад магазина используется, новый — удаляется.
	var mainWh string
	for _, w := range a.expect(a.do("GET", "/store/warehouses", tok, nil), 200, "warehouses").items() {
		mainWh = w["id"].(string)
	}
	inUse(a.do("DELETE", "/store/warehouses/"+mainWh, tok, nil), "default warehouse")
	wh := a.expect(a.do("POST", "/store/warehouses", tok, map[string]any{"store_id": store, "name": "Подсобка"}), 201, "warehouse").str("id")
	a.expect(a.do("DELETE", "/store/warehouses/"+wh, tok, nil), 204, "delete warehouse")

	// Контрагенты: с документом — 409, пустой — удаляется.
	supplier := a.expect(a.do("POST", "/store/finance/counterparties", tok, map[string]any{"name": "ООО Напитки"}), 201, "supplier").str("id")
	a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "income", "warehouse_id": mainWh, "counterparty_id": supplier,
		"items": []map[string]any{{"product_id": cola, "qty": 1, "price": 10000}},
	}), 201, "income draft")
	inUse(a.do("DELETE", "/store/finance/counterparties/"+supplier, tok, nil), "supplier with document")
	dup := a.expect(a.do("POST", "/store/finance/counterparties", tok, map[string]any{"name": "Дубль"}), 201, "duplicate").str("id")
	a.expect(a.do("DELETE", "/store/finance/counterparties/"+dup, tok, nil), 204, "delete counterparty")

	// Финансы: главная касса защищена, причина удаляется.
	for _, b := range a.expect(a.do("GET", "/store/finance/cashboxes", tok, nil), 200, "cashboxes").items() {
		if b["is_main"] == true {
			a.expect(a.do("DELETE", "/store/finance/cashboxes/"+b["id"].(string), tok, nil), 409, "main cashbox")
		}
	}
	reason := a.expect(a.do("POST", "/store/finance/reasons", tok, map[string]any{"name": "Аренда", "kind": "expense"}), 201, "reason").str("id")
	a.expect(a.do("DELETE", "/store/finance/reasons/"+reason, tok, nil), 204, "delete reason")

	// Роли и сотрудники: владельца не трогаем, новых — можно.
	var ownerRole, ownerEmp string
	for _, ro := range a.expect(a.do("GET", "/store/roles", tok, nil), 200, "roles").items() {
		if ro["is_owner"] == true {
			ownerRole = ro["id"].(string)
		}
	}
	for _, e := range a.expect(a.do("GET", "/store/employees", tok, nil), 200, "employees").items() {
		ownerEmp = e["id"].(string)
	}
	a.expect(a.do("DELETE", "/store/roles/"+ownerRole, tok, nil), 409, "owner role")
	a.expect(a.do("DELETE", "/store/employees/"+ownerEmp, tok, nil), 409, "owner employee")
	role := a.expect(a.do("POST", "/store/roles", tok, map[string]any{"name": "Кассир", "permissions": []string{identity.PermSalesPOS}}), 201, "role").str("id")
	emp := a.expect(a.do("POST", "/store/employees", tok, map[string]any{
		"phone": "+998900000071", "full_name": "Кассир", "role_id": role, "store_ids": []string{store},
	}), 201, "employee").str("id")
	inUse(a.do("DELETE", "/store/roles/"+role, tok, nil), "role with staff")
	a.expect(a.do("DELETE", "/store/employees/"+emp, tok, nil), 204, "delete employee")
	a.expect(a.do("DELETE", "/store/roles/"+role, tok, nil), 204, "delete role")

	// Касса POS, которую не подключали.
	dev := a.expect(a.do("POST", "/store/pos/devices", tok, map[string]any{"store_id": store, "name": "Касса 2"}), 201, "device").str("id")
	a.expect(a.do("DELETE", "/store/pos/devices/"+dev, tok, nil), 204, "delete device")

	// Супер-админ: тариф и рекламодатель.
	tariff := a.expect(a.do("POST", "/admin/billing/tariffs", adminTok, map[string]any{"name": "Большая сеть", "min_stores": 50, "price_per_store": 9}), 201, "tariff").str("id")
	a.expect(a.do("DELETE", "/admin/billing/tariffs/"+tariff, adminTok, nil), 204, "delete tariff")
	adv := a.expect(a.do("POST", "/admin/ads/advertisers", adminTok, map[string]any{"name": "ООО Реклама", "inn": "200000009"}), 201, "advertiser").str("id")
	a.expect(a.do("DELETE", "/admin/ads/advertisers/"+adv, adminTok, nil), 204, "delete advertiser")
}
