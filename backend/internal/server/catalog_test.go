package server_test

import (
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// setupNetwork: супер-админ, сеть с владельцем и одним магазином.
func setupNetwork(t *testing.T, a api, adminTok, ownerPhone string) (ownerTok, storeID string) {
	t.Helper()
	a.expect(a.do("POST", "/admin/networks", adminTok, map[string]string{
		"name": "Сеть " + ownerPhone, "kind": "chain", "owner_phone": ownerPhone, "owner_name": "Владелец",
	}), 201, "create network")
	ownerTok, _ = a.login(ownerPhone, identity.AppStore)
	st := a.expect(a.do("POST", "/store/stores", ownerTok, map[string]any{"name": "Магазин 1"}), 201, "store")
	return ownerTok, st.str("id")
}

func TestCatalogFlow(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)

	// Справочники.
	brand := a.expect(a.do("POST", "/admin/catalog/brands", adminTok, map[string]any{"name": "Coca-Cola"}), 201, "brand")
	a.expect(a.do("POST", "/admin/catalog/brands", adminTok, map[string]any{"name": "coca-cola"}), 409, "duplicate brand")
	drinks := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Напитки"}), 201, "category")
	soda := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{
		"name": "Газировка", "parent_id": drinks.str("id"),
	}), 201, "subcategory")
	a.expect(a.do("POST", "/admin/catalog/colors", adminTok, map[string]any{"name": "Красный", "hex": "red"}), 400, "bad hex")
	a.expect(a.do("POST", "/admin/catalog/nope", adminTok, map[string]any{"name": "x"}), 404, "unknown dict")
	a.expect(a.do("POST", "/admin/catalog/brands", adminTok, map[string]any{"name": "X", "extra": 1}), 400, "unknown field")
	units := a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items()
	var pcs string
	for _, u := range units {
		if u["short_name"] == "шт" {
			pcs = u["id"].(string)
		}
	}
	if pcs == "" {
		t.Fatalf("seed units missing: %v", units)
	}

	// Товар общего каталога.
	cola := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
		"name": "Coca-Cola 1,5 л", "brand_id": brand.str("id"), "category_id": soda.str("id"),
		"unit_id": pcs, "base_price": 15000, "barcodes": []string{"5449000000996"},
	}), 201, "global product")
	if cola.str("moderation_status") != "approved" || cola.str("base_price") != "15000.00" {
		t.Fatalf("cola = %v", cola.Body)
	}

	ownerTok, store1 := setupNetwork(t, a, adminTok, "+998900000002")
	otherTok, _ := setupNetwork(t, a, adminTok, "+998900000003")

	// Сеть видит общий товар, ищет по штрихкоду и по подкатегории родителя.
	found := a.expect(a.do("GET", "/store/products?barcode=5449000000996", ownerTok, nil), 200, "by barcode").items()
	if len(found) != 1 {
		t.Fatalf("by barcode = %v", found)
	}
	found = a.expect(a.do("GET", "/store/products?category_id="+drinks.str("id"), ownerTok, nil), 200, "by parent category").items()
	if len(found) != 1 {
		t.Fatalf("by parent category = %v", found)
	}

	// Свой товар сети — на модерацию, дубль штрихкода запрещён.
	a.expect(a.do("POST", "/store/products", ownerTok, map[string]any{
		"name": "Дубль", "category_id": soda.str("id"), "unit_id": pcs, "barcodes": []string{"5449000000996"},
	}), 409, "duplicate barcode")
	own := a.expect(a.do("POST", "/store/products", ownerTok, map[string]any{
		"name": "Лепёшка домашняя", "category_id": drinks.str("id"), "unit_id": pcs, "base_price": "4000",
	}), 201, "own product")
	if own.str("moderation_status") != "pending" {
		t.Fatalf("own product status = %q", own.str("moderation_status"))
	}
	// Чужая сеть не видит товар на модерации.
	a.expect(a.do("GET", "/store/products/"+own.str("id"), otherTok, nil), 404, "foreign pending product")
	a.expect(a.do("PATCH", "/store/products/"+cola.str("id"), ownerTok, map[string]any{"name": "x"}), 403, "edit global product")

	// Модерация: отказ → правка → снова на модерации → одобрение.
	pending := a.expect(a.do("GET", "/admin/products?status=pending", adminTok, nil), 200, "pending list").items()
	if len(pending) != 1 {
		t.Fatalf("pending = %v", pending)
	}
	a.expect(a.do("POST", "/admin/products/"+own.str("id")+"/reject", adminTok, map[string]any{"reason": ""}), 400, "reject without reason")
	rej := a.expect(a.do("POST", "/admin/products/"+own.str("id")+"/reject", adminTok, map[string]any{"reason": "Нет фото"}), 200, "reject")
	if rej.str("moderation_status") != "rejected" {
		t.Fatalf("rejected = %v", rej.Body)
	}
	re := a.expect(a.do("PATCH", "/store/products/"+own.str("id"), ownerTok, map[string]any{
		"images": []string{"https://cdn.example.com/lepyoshka.jpg"},
	}), 200, "fix rejected")
	if re.str("moderation_status") != "pending" || re.str("rejection_reason") != "" {
		t.Fatalf("resubmitted = %v", re.Body)
	}
	ok := a.expect(a.do("POST", "/admin/products/"+own.str("id")+"/approve", adminTok, nil), 200, "approve")
	if ok.Body["network_id"] != nil {
		t.Fatalf("approved product must become global: %v", ok.Body)
	}
	a.expect(a.do("GET", "/store/products/"+own.str("id"), otherTok, nil), 200, "approved product is global")
	a.expect(a.do("POST", "/admin/products/"+own.str("id")+"/approve", adminTok, nil), 409, "approve twice")

	// Типы цен: у сети уже есть «Розничная».
	types := a.expect(a.do("GET", "/store/price-types", ownerTok, nil), 200, "price types").items()
	if len(types) != 1 || types[0]["is_default"] != true {
		t.Fatalf("price types = %v", types)
	}
	retail := types[0]["id"].(string)
	online := a.expect(a.do("POST", "/store/price-types", ownerTok, map[string]any{"name": "Онлайн"}), 201, "online type")

	// Без документов цена — базовая из каталога.
	priceOf := func(query string) (string, string) {
		t.Helper()
		items := a.expect(a.do("GET", "/store/products?barcode=5449000000996&store_id="+store1+query, ownerTok, nil), 200, "prices").items()
		if len(items) != 1 {
			t.Fatalf("items = %v", items)
		}
		return items[0]["price"].(string), items[0]["price_source"].(string)
	}
	if p, src := priceOf(""); p != "15000.00" || src != "base" {
		t.Fatalf("base price = %s %s", p, src)
	}

	// Документ по сети.
	doc := a.expect(a.do("POST", "/store/price-documents", ownerTok, map[string]any{
		"price_type_id": retail, "note": "Новые цены",
		"items": []map[string]any{{"product_id": cola.str("id"), "new_price": "15500"}},
	}), 201, "network doc")
	if doc.Body["number"].(float64) != 1 || doc.str("status") != "draft" {
		t.Fatalf("doc = %v", doc.Body)
	}
	if p, _ := priceOf(""); p != "15000.00" {
		t.Fatalf("draft must not change price, got %s", p)
	}
	// Черновик показывает действующую цену строки.
	draft := a.expect(a.do("GET", "/store/price-documents/"+doc.str("id"), ownerTok, nil), 200, "draft doc")
	if cur := draft.Body["items"].([]any)[0].(map[string]any)["current_price"]; cur != "15000.00" {
		t.Fatalf("draft current_price = %v", cur)
	}
	a.expect(a.do("POST", "/store/price-documents/"+doc.str("id")+"/post", ownerTok, nil), 200, "post network doc")
	a.expect(a.do("POST", "/store/price-documents/"+doc.str("id")+"/post", ownerTok, nil), 409, "post twice")
	a.expect(a.do("PATCH", "/store/price-documents/"+doc.str("id"), ownerTok, map[string]any{"note": "x"}), 409, "edit posted")
	if p, src := priceOf(""); p != "15500.00" || src != "network" {
		t.Fatalf("network price = %s %s", p, src)
	}

	// Документ по магазину перекрывает цену сети и помнит прежнюю цену.
	sdoc := a.expect(a.do("POST", "/store/price-documents", ownerTok, map[string]any{
		"price_type_id": retail, "store_id": store1,
		"items": []map[string]any{{"product_id": cola.str("id"), "new_price": 16000}},
	}), 201, "store doc")
	posted := a.expect(a.do("POST", "/store/price-documents/"+sdoc.str("id")+"/post", ownerTok, nil), 200, "post store doc")
	if p, src := priceOf(""); p != "16000.00" || src != "store" {
		t.Fatalf("store price = %s %s", p, src)
	}
	items := posted.Body["items"].([]any)
	if items[0].(map[string]any)["previous_price"] != nil {
		t.Fatalf("store level had no price before: %v", items)
	}
	sdoc2 := a.expect(a.do("POST", "/store/price-documents", ownerTok, map[string]any{
		"price_type_id": retail, "store_id": store1,
		"items": []map[string]any{{"product_id": cola.str("id"), "new_price": 16500}},
	}), 201, "store doc 2")
	posted = a.expect(a.do("POST", "/store/price-documents/"+sdoc2.str("id")+"/post", ownerTok, nil), 200, "post store doc 2")
	if prev := posted.Body["items"].([]any)[0].(map[string]any)["previous_price"]; prev != "16000.00" {
		t.Fatalf("previous_price = %v", prev)
	}
	if cur := posted.Body["items"].([]any)[0].(map[string]any)["current_price"]; cur != "16500.00" {
		t.Fatalf("store doc current_price = %v", cur)
	}

	// Магазин переключает приложение на тип «Онлайн»: там цены ещё нет — базовая.
	a.expect(a.do("PATCH", "/store/stores/"+store1, ownerTok, map[string]any{"online_price_type_id": online.str("id")}),
		200, "set online price type")
	if p, src := priceOf(""); p != "15000.00" || src != "base" {
		t.Fatalf("online type price = %s %s", p, src)
	}
	if p, _ := priceOf("&price_type_id=" + retail); p != "16500.00" {
		t.Fatalf("explicit retail price = %s", p)
	}

	// Права: кассир без prices.manage не создаёт документы.
	role := a.expect(a.do("POST", "/store/roles", ownerTok, map[string]any{"name": "Кассир"}), 201, "role")
	a.expect(a.do("POST", "/store/employees", ownerTok, map[string]any{
		"phone": "+998900000004", "full_name": "Кассир", "role_id": role.str("id"), "store_ids": []string{store1},
	}), 201, "cashier")
	cashierTok, _ := a.login("+998900000004", identity.AppStore)
	a.expect(a.do("POST", "/store/price-documents", cashierTok, map[string]any{"price_type_id": retail}), 403, "cashier doc")
	a.expect(a.do("PATCH", "/store/roles/"+role.str("id"), ownerTok, map[string]any{
		"permissions": []string{identity.PermPricesManage},
	}), 200, "grant prices.manage")
	a.expect(a.do("POST", "/store/price-documents", cashierTok, map[string]any{"price_type_id": retail}), 403, "cashier network-wide doc")
	a.expect(a.do("POST", "/store/price-documents", cashierTok, map[string]any{"price_type_id": retail, "store_id": store1}),
		201, "cashier store doc")
	if docs := a.expect(a.do("GET", "/store/price-documents", cashierTok, nil), 200, "cashier docs").items(); len(docs) != 3 {
		t.Fatalf("cashier sees %d docs, want 3 store-level", len(docs))
	}

	// Тип по умолчанию нельзя отключить; смена типа по умолчанию.
	a.expect(a.do("PATCH", "/store/price-types/"+retail, ownerTok, map[string]any{"is_active": false}), 409, "disable default")
	a.expect(a.do("PATCH", "/store/price-types/"+online.str("id"), ownerTok, map[string]any{"is_default": true}), 200, "switch default")
	types = a.expect(a.do("GET", "/store/price-types", ownerTok, nil), 200, "price types").items()
	if types[0]["id"] != online.str("id") || types[1]["is_default"] != false {
		t.Fatalf("after switch = %v", types)
	}
}
