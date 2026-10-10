package server_test

import (
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/variants"
)

// TestVariants — группы вариаций: Super Market предлагает группу по
// названиям (ИИ не подключён), супер-админ правит и подтверждает; карточка
// товара в приложении получает переключатели «Вес» и «Вкус» только по
// вариациям в наличии; магазин ставит цену на вес, «своя цена» вкуса её
// не меняет; расформированная группа снимается с товаров.
func TestVariants(t *testing.T) {
	variants.SuggestSync = true
	t.Cleanup(func() { variants.SuggestSync = false })
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)

	brand := a.expect(a.do("POST", "/admin/catalog/brands", adminTok, map[string]any{"name": "Lay's"}), 201, "brand").str("id")
	cat := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Чипсы"}), 201, "category").str("id")
	var pcs string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		if u["short_name"] == "шт" {
			pcs = u["id"].(string)
		}
	}
	product := func(name string, price int) string {
		return a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
			"name": name, "brand_id": brand, "category_id": cat, "unit_id": pcs, "base_price": price,
		}), 201, "product "+name).str("id")
	}
	sour150 := product("Чипсы Lay's Сметана и лук, 150 г", 18000)
	cheese150 := product("Чипсы Lay's Сыр, 150 г", 18000)
	pizza150 := product("Чипсы Lay's Пицца Пепперони, 150 г", 18000)
	sour90 := product("Чипсы Lay's Сметана и лук, 90 г", 12000)

	// Без ИИ Super Market собирает группу по названиям.
	sg := a.expect(a.do("POST", "/admin/variant-groups/suggest", adminTok, map[string]any{}), 200, "suggest")
	if sg.Body["created"] != float64(1) || sg.Body["ai"] != false || sg.Body["running"] != false {
		t.Fatalf("suggest = %v", sg.Body)
	}
	if again := a.expect(a.do("POST", "/admin/variant-groups/suggest", adminTok, map[string]any{}), 200, "suggest again"); again.Body["created"] != float64(0) {
		t.Fatalf("suggest again = %v", again.Body)
	}
	list := a.expect(a.do("GET", "/admin/variant-groups?status=proposed", adminTok, nil), 200, "proposed")
	groups := list.items()
	if len(groups) != 1 || groups[0]["name"] != "Чипсы Lay's" || len(groups[0]["items"].([]any)) != 4 {
		t.Fatalf("proposed = %v", list.Body)
	}
	gid := groups[0]["id"].(string)
	first := groups[0]["items"].([]any)[0].(map[string]any)
	if first["product_id"] != sour90 || first["weight"] != "90 г" || first["weight_uz"] != "90 g" || first["flavor"] != "Сметана и лук" {
		t.Fatalf("first item = %v", first)
	}
	a.expect(a.do("GET", "/admin/variant-groups?status=nope", adminTok, nil), 400, "bad status")

	// Дубль веса и вкуса не подтверждается.
	a.expect(a.do("PATCH", "/admin/variant-groups/"+gid, adminTok, map[string]any{
		"items": []map[string]any{{"product_id": cheese150, "flavor": "Сметана и лук"}},
	}), 200, "make duplicate")
	a.expect(a.do("POST", "/admin/variant-groups/"+gid+"/confirm", adminTok, nil), 400, "duplicate flavor")
	g := a.expect(a.do("PATCH", "/admin/variant-groups/"+gid, adminTok, map[string]any{
		"name_uz": "Lay's chipslari",
		"items":   []map[string]any{{"product_id": cheese150, "flavor": "Сыр", "flavor_uz": "Pishloq"}},
	}), 200, "fix flavor")
	if g.str("name_uz") != "Lay's chipslari" {
		t.Fatalf("patched = %v", g.Body)
	}
	g = a.expect(a.do("POST", "/admin/variant-groups/"+gid+"/confirm", adminTok, nil), 200, "confirm")
	if g.str("status") != "confirmed" {
		t.Fatalf("confirmed = %v", g.Body)
	}
	p := a.expect(a.do("GET", "/admin/products/"+cheese150, adminTok, nil), 200, "product")
	if p.str("variant_group_id") != gid || p.str("variant_weight") != "150 г" || p.str("variant_flavor") != "Сыр" || p.str("variant_group_name") != "Чипсы Lay's" {
		t.Fatalf("product variant = %v", p.Body)
	}

	// Магазин: в наличии все вкусы 150 г и 90 г, кроме пиццы.
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
	doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{"type": "posting", "warehouse_id": wh,
		"items": []map[string]any{
			{"product_id": sour150, "qty": 10, "price": 10000}, {"product_id": cheese150, "qty": 5, "price": 10000},
			{"product_id": sour90, "qty": 3, "price": 7000},
		}}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post")

	card := a.expect(a.do("GET", "/client/stores/"+store+"/products/"+cheese150, "", nil), 200, "card")
	v, _ := card.Body["variants"].(map[string]any)
	if v == nil || v["group_id"] != gid || v["weight"] != "150 г" || v["flavor"] != "Сыр" || len(v["options"].([]any)) != 3 {
		t.Fatalf("variants = %v", card.Body["variants"])
	}
	if w := v["weights"].([]any); len(w) != 2 || w[0] != "90 г" || w[1] != "150 г" {
		t.Fatalf("weights = %v", v["weights"])
	}
	for _, o := range v["options"].([]any) {
		if o.(map[string]any)["product_id"] == pizza150 {
			t.Fatalf("pizza is out of stock but offered: %v", v["options"])
		}
	}
	uz := a.doLang("uz", "GET", "/client/stores/"+store+"/products/"+cheese150, "", nil)
	if uv := uz.Body["variants"].(map[string]any); uv["flavor"] != "Pishloq" || uv["weight"] != "150 g" || uv["name"] != "Lay's chipslari" {
		t.Fatalf("uz variants = %v", uv)
	}

	// Цена веса: все вкусы 150 г, кроме «своей цены».
	sgr := a.expect(a.do("GET", "/store/variant-groups/"+gid+"?store_id="+store, tok, nil), 200, "store group")
	if ws := sgr.Body["weights"].([]any); len(ws) != 2 || sgr.str("stock") != "18" {
		t.Fatalf("store group = %v", sgr.Body)
	}
	a.expect(a.do("POST", "/store/variant-groups/"+gid+"/own-price", tok, map[string]any{
		"store_id": store, "product_id": pizza150, "own": true, "price": 21000,
	}), 200, "own price")
	sgr = a.expect(a.do("POST", "/store/variant-groups/"+gid+"/weight-price", tok, map[string]any{
		"store_id": store, "weight": "150 г", "price": 19000,
	}), 200, "weight price")
	w150 := sgr.Body["weights"].([]any)[1].(map[string]any)
	if w150["weight"] != "150 г" || w150["price"] != "19000.00" {
		t.Fatalf("weight 150 = %v", w150)
	}
	for _, it := range w150["items"].([]any) {
		m := it.(map[string]any)
		want := "19000.00"
		if m["product_id"] == pizza150 {
			want = "21000.00"
			if m["own_price"] != true {
				t.Fatalf("pizza own price flag = %v", m)
			}
		}
		if m["price"] != want {
			t.Fatalf("price of %v = %v, want %s", m["flavor"], m["price"], want)
		}
	}
	// Своя цена снята — вкус снова по цене веса.
	sgr = a.expect(a.do("POST", "/store/variant-groups/"+gid+"/own-price", tok, map[string]any{
		"store_id": store, "product_id": pizza150, "own": false,
	}), 200, "own price off")
	for _, it := range sgr.Body["weights"].([]any)[1].(map[string]any)["items"].([]any) {
		if m := it.(map[string]any); m["price"] != "19000.00" {
			t.Fatalf("after own off %v = %v", m["flavor"], m["price"])
		}
	}
	a.expect(a.do("POST", "/store/variant-groups/"+gid+"/weight-price", tok, map[string]any{
		"store_id": store, "weight": "1 кг", "price": 19000,
	}), 400, "unknown weight")
	_, other := setupNetwork(t, a, adminTok, "+998900000003")
	a.expect(a.do("GET", "/store/variant-groups/"+gid+"?store_id="+other, tok, nil), 404, "foreign store")

	// Расформировать: товары снова отдельно, карточка без переключателей.
	a.expect(a.do("POST", "/admin/variant-groups/"+gid+"/reject", adminTok, nil), 200, "reject")
	if p := a.expect(a.do("GET", "/admin/products/"+cheese150, adminTok, nil), 200, "product after reject"); p.Body["variant_group_id"] != nil {
		t.Fatalf("after reject = %v", p.Body)
	}
	if c := a.expect(a.do("GET", "/client/stores/"+store+"/products/"+cheese150, "", nil), 200, "card after reject"); c.Body["variants"] != nil {
		t.Fatalf("variants after reject = %v", c.Body["variants"])
	}

	// Группа руками и «Разбить».
	mg := a.expect(a.do("POST", "/admin/variant-groups", adminTok, map[string]any{
		"name": "Чипсы Lay's", "product_ids": []string{sour150, cheese150, sour90},
	}), 201, "manual group")
	if mg.str("source") != "manual" || len(mg.Body["items"].([]any)) != 3 {
		t.Fatalf("manual = %v", mg.Body)
	}
	sp := a.expect(a.do("POST", "/admin/variant-groups/"+mg.str("id")+"/split", adminTok, map[string]any{
		"product_ids": []string{sour90},
	}), 200, "split")
	if len(sp.Body["group"].(map[string]any)["items"].([]any)) != 2 || len(sp.Body["new_group"].(map[string]any)["items"].([]any)) != 1 {
		t.Fatalf("split = %v", sp.Body)
	}
	a.expect(a.do("POST", "/admin/variant-groups/"+sp.Body["new_group"].(map[string]any)["id"].(string)+"/confirm", adminTok, nil), 400, "one item")
}
