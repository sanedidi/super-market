package server_test

import (
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// Касса: товар по штрихкоду, которого нет в её каталоге (Super Market без
// цены — поиск; нет нигде — «Неизвестный товар»), цена из очереди без связи и
// панель «Товары → Без карточки».
func TestUnknownGoods(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cat := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Продукты"}), 201, "category").str("id")
	var pcs string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		if u["short_name"] == "шт" {
			pcs = u["id"].(string)
		}
	}
	// Товар Super Market без цены — в каталоге кассы его нет.
	shampoo := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
		"name": "Шампунь 400 мл", "category_id": cat, "unit_id": pcs, "barcodes": []string{"4870205001123"},
	}), 201, "shampoo").str("id")
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	var owner string
	for _, e := range a.expect(a.do("GET", "/store/employees", tok, nil), 200, "employees").items() {
		owner = e["id"].(string)
	}
	a.expect(a.do("PUT", "/store/pos/pins/"+owner, tok, map[string]any{"pin": "9999"}), 200, "owner pin")
	dev := a.expect(a.do("POST", "/store/pos/devices", tok, map[string]any{"store_id": store, "name": "Касса 1"}), 201, "device")
	dt := a.expect(a.do("POST", "/pos/activate", "", map[string]any{"code": dev.str("activation_code")}), 200, "activate").str("token")
	catalog := a.expect(posDo(a, "GET", "/pos/catalog", dt, "", nil), 200, "catalog")
	for _, x := range catalog.Body["products"].([]any) {
		if x.(map[string]any)["id"] == shampoo {
			t.Fatal("unpriced platform product in pos catalog")
		}
	}
	var cash string
	for _, x := range catalog.Body["payment_methods"].([]any) {
		if m := x.(map[string]any); m["kind"] == "cash" {
			cash = m["id"].(string)
		}
	}

	// Поиск по штрихкоду: EAN-13 с ведущим нулём — тот же товар.
	if l := a.expect(posDo(a, "GET", "/pos/products/lookup?barcode=04870205001123", dt, "", nil), 200, "lookup"); l.str("id") != shampoo || l.str("price") != "0.00" {
		t.Fatalf("lookup = %v", l.Body)
	}
	a.expect(posDo(a, "GET", "/pos/products/lookup?barcode=4600123456789", dt, "", nil), 404, "lookup unknown")
	a.expect(a.do("GET", "/pos/products/lookup?barcode=4600123456789", tok, nil), 401, "lookup from panel")

	// Цена из очереди кассы: поставят, только если цены ещё нет.
	if r := a.expect(posDo(a, "PUT", "/pos/products/"+shampoo+"/price", dt, owner, map[string]any{"price": 42000, "if_unpriced": true}), 200, "queued price"); r.str("price") != "42000.00" {
		t.Fatalf("queued price = %v", r.Body)
	}
	if r := a.expect(posDo(a, "PUT", "/pos/products/"+shampoo+"/price", dt, owner, map[string]any{"price": 40000, "if_unpriced": true}), 200, "stale queued price"); r.str("price") != "42000.00" {
		t.Fatalf("stale queued price = %v", r.Body)
	}

	shift := a.expect(posDo(a, "POST", "/pos/shifts", dt, owner, map[string]any{"client_uid": "u-shift-1", "opening_cash": 0}), 201, "shift").str("id")
	sale := func(uid string, items []map[string]any, total int, status int) resp {
		return a.expect(posDo(a, "POST", "/pos/sales", dt, owner, map[string]any{
			"client_uid": uid, "shift_id": shift, "items": items,
			"payments": []map[string]any{{"payment_method_id": cash, "amount": total}},
		}), status, "sale "+uid)
	}
	// Неизвестный товар: цена обязательна, штрихкод — как у товаров.
	sale("u-bad-1", []map[string]any{{"unknown_barcode": "4600123456789", "qty": 1}}, 15000, 400)
	sale("u-bad-2", []map[string]any{{"unknown_barcode": "46", "qty": 1, "price": 15000}}, 15000, 400)
	a.expect(a.do("POST", "/store/sales", tok, map[string]any{
		"store_id": store, "items": []map[string]any{{"unknown_barcode": "4600123456789", "qty": 1, "price": 15000}},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 15000}},
	}), 400, "unknown from panel")
	// Два разных неизвестных товара в одном чеке и обычный товар.
	s1 := sale("u-sale-1", []map[string]any{
		{"unknown_barcode": "4600123456789", "qty": 2, "price": 15000},
		{"unknown_barcode": "8690526083411", "unknown_name": "Печенье Ülker", "qty": 1, "price": 7000},
		{"product_id": shampoo, "qty": 1, "price": 42000},
	}, 79000, 201)
	sale("u-sale-2", []map[string]any{{"unknown_barcode": "4600123456789", "unknown_name": "Сок Bliss 1 л", "qty": 1, "price": 16000}}, 16000, 201)
	items := s1.Body["items"].([]any)
	if items[0].(map[string]any)["product_name"] != "Неизвестный товар" || items[1].(map[string]any)["product_name"] != "Печенье Ülker" {
		t.Fatalf("sale items = %v", items)
	}

	// Служебный товар сети не виден в списках товаров.
	for _, x := range a.expect(a.do("GET", "/store/products?limit=200", tok, nil), 200, "products").items() {
		if x["kind"] == "unknown" || x["name"] == "Неизвестный товар" {
			t.Fatalf("unknown product in list: %v", x)
		}
	}

	// Возврат неизвестного товара — как любого.
	a.expect(posDo(a, "POST", "/pos/returns", dt, owner, map[string]any{
		"sale_id": s1.str("id"), "payment_method_id": cash, "shift_id": shift,
		"items": []map[string]any{{"sale_line": 2, "qty": 1}},
	}), 201, "return unknown")

	// Панель: «Без карточки» — по штрихкоду, последнее название, цены от–до.
	list := a.expect(a.do("GET", "/store/pos/unknown-goods?store_id="+store, tok, nil), 200, "unknown list").items()
	if len(list) != 2 {
		t.Fatalf("unknown list = %v", list)
	}
	byCode := map[string]map[string]any{}
	for _, r := range list {
		byCode[r["barcode"].(string)] = r
	}
	juice := byCode["4600123456789"]
	if juice["name"] != "Сок Bliss 1 л" || juice["qty"] != "3" || juice["price_min"] != "15000.00" || juice["price_max"] != "16000.00" ||
		juice["sales"].(float64) != 2 || juice["cashier"] == "" || juice["device"] != "Касса 1" || juice["found"] != nil {
		t.Fatalf("juice = %v", juice)
	}

	// Штрихкод появился в Super Market — «Завести товар» ставит цену магазина.
	cookie := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
		"name": "Печенье Ülker 82 г", "category_id": cat, "unit_id": pcs, "barcodes": []string{"8690526083411"},
	}), 201, "cookie").str("id")
	list = a.expect(a.do("GET", "/store/pos/unknown-goods?store_id="+store, tok, nil), 200, "unknown list 2").items()
	for _, r := range list {
		if r["barcode"] == "8690526083411" {
			if f, _ := r["found"].(map[string]any); f == nil || f["id"] != cookie {
				t.Fatalf("found = %v", r)
			}
		}
	}
	a.expect(a.do("POST", "/store/pos/unknown-goods/adopt", tok, map[string]any{"store_id": store, "product_id": cookie, "price": 0}), 400, "adopt without price")
	a.expect(a.do("POST", "/store/pos/unknown-goods/adopt", tok, map[string]any{"store_id": store, "product_id": cookie, "price": 7500}), 200, "adopt")
	list = a.expect(a.do("GET", "/store/pos/unknown-goods?store_id="+store, tok, nil), 200, "unknown list 3").items()
	if len(list) != 1 || list[0]["barcode"] != "4600123456789" {
		t.Fatalf("after adopt = %v", list)
	}
	// Касса теперь пробивает печенье обычным товаром.
	if l := a.expect(posDo(a, "GET", "/pos/products/lookup?barcode=8690526083411", dt, "", nil), 200, "lookup cookie"); l.str("price") != "7500.00" {
		t.Fatalf("cookie lookup = %v", l.Body)
	}
}
