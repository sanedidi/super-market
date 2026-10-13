package server_test

import (
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/variants"
)

// TestVariantsNetwork — вариации своих товаров магазина (вкладка «Вариации»):
// Super Market предлагает свои товары сети в подтверждённую группу общего
// каталога и отдельную группу своих товаров со своими переключателями
// (у кружек — только «Цвет»); магазин подтверждает сам, товары общего
// каталога и их группа не меняются, другая сеть группы не видит, правка
// группы супер-админом не снимает свои товары, «Отклонить» — снимает.
func TestVariantsNetwork(t *testing.T) {
	variants.SuggestSync = true
	t.Cleanup(func() { variants.SuggestSync = false })
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)

	lays := a.expect(a.do("POST", "/admin/catalog/brands", adminTok, map[string]any{"name": "Lay's"}), 201, "brand").str("id")
	lum := a.expect(a.do("POST", "/admin/catalog/brands", adminTok, map[string]any{"name": "Luminarc"}), 201, "brand 2").str("id")
	chips := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Чипсы"}), 201, "category").str("id")
	mugs := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Кружки"}), 201, "category 2").str("id")
	var pcs string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		if u["short_name"] == "шт" {
			pcs = u["id"].(string)
		}
	}
	central := func(name string) string {
		return a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
			"name": name, "brand_id": lays, "category_id": chips, "unit_id": pcs, "base_price": 18000,
		}), 201, "product "+name).str("id")
	}
	sour := central("Чипсы Lay's Сметана и лук, 150 г")
	cheese := central("Чипсы Lay's Сыр, 150 г")
	a.expect(a.do("POST", "/admin/variant-groups/suggest", adminTok, map[string]any{}), 200, "admin suggest")
	base := a.expect(a.do("GET", "/admin/variant-groups?status=proposed", adminTok, nil), 200, "admin proposed").items()[0]["id"].(string)
	a.expect(a.do("POST", "/admin/variant-groups/"+base+"/confirm", adminTok, nil), 200, "admin confirm")

	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	own := func(name, brand, cat string) string {
		return a.expect(a.do("POST", "/store/products", tok, map[string]any{
			"name": name, "brand_id": brand, "category_id": cat, "unit_id": pcs, "base_price": 20000,
		}), 201, "own "+name).str("id")
	}
	crab := own("Чипсы Lay's Краб, 150 г", lays, chips)
	bacon := own("Чипсы Lay's Бекон, 90 г", lays, chips)
	white := own("Кружка Luminarc белая, 350 мл", lum, mugs)
	black := own("Кружка Luminarc чёрная, 350 мл", lum, mugs)

	// Найти группы среди своих товаров: вход в группу общего каталога и своя группа.
	sg := a.expect(a.do("POST", "/store/own-variant-groups/suggest", tok, map[string]any{}), 200, "suggest")
	if sg.Body["created"] != float64(2) {
		t.Fatalf("suggest = %v", sg.Body)
	}
	if again := a.expect(a.do("POST", "/store/own-variant-groups/suggest", tok, map[string]any{}), 200, "suggest again"); again.Body["created"] != float64(0) {
		t.Fatalf("suggest again = %v", again.Body)
	}
	list := a.expect(a.do("GET", "/store/own-variant-groups?status=proposed", tok, nil), 200, "proposed")
	if list.Body["counts"].(map[string]any)["proposed"] != float64(2) {
		t.Fatalf("counts = %v", list.Body["counts"])
	}
	var join, mine map[string]any
	for _, g := range list.items() {
		if g["base_group_id"] == base {
			join = g
		} else {
			mine = g
		}
	}
	if join == nil || mine == nil || join["base_name"] != "Чипсы Lay's" {
		t.Fatalf("proposed = %v", list.Body)
	}
	items := join["items"].([]any)
	if len(items) != 4 {
		t.Fatalf("join items = %v", items)
	}
	for _, x := range items {
		it := x.(map[string]any)
		isOwn := it["product_id"] == crab || it["product_id"] == bacon
		if it["locked"] == isOwn || it["own"] != isOwn {
			t.Fatalf("join item = %v", it)
		}
	}
	if mine["weight_label"] != "" || mine["flavor_label"] != "Цвет" || mine["base_group_id"] != nil {
		t.Fatalf("mugs labels = %v / %v", mine["weight_label"], mine["flavor_label"])
	}
	// Супер-админ своих групп сетей не видит.
	if adm := a.expect(a.do("GET", "/admin/variant-groups?status=proposed", adminTok, nil), 200, "admin list"); len(adm.items()) != 0 {
		t.Fatalf("admin sees network groups: %v", adm.Body)
	}
	a.expect(a.do("GET", "/admin/variant-groups/"+join["id"].(string), adminTok, nil), 404, "admin get network group")

	// Название и переключатели группы общего каталога меняет только супер-админ.
	jid := join["id"].(string)
	a.expect(a.do("PATCH", "/store/own-variant-groups/"+jid, tok, map[string]any{"name": "Мои чипсы"}), 400, "rename base")
	// Свой товар с теми же вкусом и весом, что у товара общего каталога, — не подтвердить.
	a.expect(a.do("PATCH", "/store/own-variant-groups/"+jid, tok, map[string]any{
		"items": []map[string]any{{"product_id": crab, "flavor": "Сыр"}},
	}), 200, "dup flavor")
	a.expect(a.do("POST", "/store/own-variant-groups/"+jid+"/confirm", tok, nil), 400, "dup with base")
	a.expect(a.do("PATCH", "/store/own-variant-groups/"+jid, tok, map[string]any{
		"items": []map[string]any{{"product_id": crab, "flavor": "Краб"}},
	}), 200, "fix flavor")
	a.expect(a.do("POST", "/store/own-variant-groups/"+jid+"/confirm", tok, nil), 200, "confirm join")
	for _, id := range []string{crab, bacon} {
		var g *string
		if err := pool.QueryRow(t.Context(), `SELECT variant_group_id::text FROM products WHERE id = $1`, id).Scan(&g); err != nil || g == nil || *g != base {
			t.Fatalf("own product %s group = %v, %v", id, g, err)
		}
	}
	// Группа в «Товарах» магазина — вместе со своими; у супер-админа состав прежний.
	sgr := a.expect(a.do("GET", "/store/variant-groups/"+base+"?store_id="+store, tok, nil), 200, "store group")
	n := 0
	for _, w := range sgr.Body["weights"].([]any) {
		n += len(w.(map[string]any)["items"].([]any))
	}
	if n != 4 {
		t.Fatalf("store group = %v", sgr.Body)
	}
	if adm := a.expect(a.do("GET", "/admin/variant-groups/"+base, adminTok, nil), 200, "admin group"); len(adm.Body["items"].([]any)) != 2 {
		t.Fatalf("admin group items = %v", adm.Body["items"])
	}
	// Правка группы супер-админом свои товары сети не снимает.
	a.expect(a.do("PATCH", "/admin/variant-groups/"+base, adminTok, map[string]any{
		"items": []map[string]any{{"product_id": cheese, "flavor": "Сыр"}, {"product_id": sour, "flavor": "Сметана и лук"}},
	}), 200, "admin patch")
	var cnt int
	if err := pool.QueryRow(t.Context(), `SELECT count(*)::int FROM products WHERE variant_group_id = $1`, base).Scan(&cnt); err != nil || cnt != 4 {
		t.Fatalf("group size after admin patch = %d, %v", cnt, err)
	}

	// Своя группа кружек: переключатель «Цвет», подтверждает магазин.
	mid := mine["id"].(string)
	g := a.expect(a.do("POST", "/store/own-variant-groups/"+mid+"/confirm", tok, nil), 200, "confirm mugs")
	if g.str("status") != "confirmed" {
		t.Fatalf("mugs = %v", g.Body)
	}
	var wg, bg *string
	if err := pool.QueryRow(t.Context(), `SELECT (SELECT variant_group_id::text FROM products WHERE id = $1),
		(SELECT variant_group_id::text FROM products WHERE id = $2)`, white, black).Scan(&wg, &bg); err != nil || wg == nil || *wg != mid || bg == nil || *bg != mid {
		t.Fatalf("mugs group = %v %v %v", wg, bg, err)
	}

	// Инвентаризация: строки групп — сначала, группа за группой; цена — на вес.
	a.expect(a.do("POST", "/store/start/lines", tok, map[string]any{"store_id": store, "items": []map[string]any{
		{"product_id": sour, "add": true}, {"product_id": cheese, "add": true}, {"product_id": crab, "add": true},
		{"product_id": bacon, "add": true}, {"product_id": white, "add": true}, {"product_id": black, "add": true},
	}}), 200, "lines")
	d := a.expect(a.do("GET", "/store/start?store_id="+store+"&order=groups", tok, nil), 200, "draft")
	lines := d.Body["lines"].([]any)
	if len(lines) != 6 {
		t.Fatalf("lines = %v", lines)
	}
	for _, x := range lines {
		if x.(map[string]any)["variant"] == nil {
			t.Fatalf("line without group: %v", x)
		}
	}
	price := func(id string) any {
		t.Helper()
		for _, x := range a.expect(a.do("GET", "/store/start?store_id="+store, tok, nil), 200, "draft").Body["lines"].([]any) {
			if l := x.(map[string]any); l["product_id"] == id {
				return l["price"]
			}
		}
		t.Fatalf("no line %s", id)
		return nil
	}
	r := a.expect(a.do("POST", "/store/start/group-price", tok, map[string]any{"store_id": store, "group_id": base, "weight": "150 г", "price": 18000}), 200, "weight price")
	if len(r.Body["lines"].([]any)) != 3 || price(bacon) != nil || price(crab) != "18000.00" {
		t.Fatalf("weight price = %v; bacon %v crab %v", r.Body["lines"], price(bacon), price(crab))
	}
	a.expect(a.do("POST", "/store/start/lines/"+crab+"/own-price", tok, map[string]any{"store_id": store, "own": true, "price": 19000}), 200, "own price")
	a.expect(a.do("POST", "/store/start/group-price", tok, map[string]any{"store_id": store, "group_id": base, "weight": "150 г", "price": 18500}), 200, "weight price 2")
	if price(crab) != "19000.00" || price(sour) != "18500.00" {
		t.Fatalf("own price kept? crab %v sour %v", price(crab), price(sour))
	}
	a.expect(a.do("POST", "/store/start/lines/"+crab+"/own-price", tok, map[string]any{"store_id": store, "own": false}), 200, "own off")
	if price(crab) != "18500.00" {
		t.Fatalf("crab back to weight price = %v", price(crab))
	}
	// Кружки — переключателя веса нет: цена одна на группу.
	a.expect(a.do("POST", "/store/start/group-price", tok, map[string]any{"store_id": store, "group_id": mid, "weight": "", "price": 35000}), 200, "group price")
	if price(white) != "35000.00" || price(black) != "35000.00" {
		t.Fatalf("mugs price = %v %v", price(white), price(black))
	}
	a.expect(a.do("POST", "/store/start/lines/"+sour+"/own-price", tok, map[string]any{"store_id": store, "own": true}), 200, "own on central")
	a.expect(a.do("GET", "/store/start?store_id="+store+"&order=nope", tok, nil), 400, "bad order")

	// Другая сеть групп этой сети не видит.
	tok2, _ := setupNetwork(t, a, adminTok, "+998900000003")
	a.expect(a.do("GET", "/store/own-variant-groups/"+mid, tok2, nil), 404, "other network")
	if l := a.expect(a.do("GET", "/store/own-variant-groups?status=confirmed", tok2, nil), 200, "other list"); len(l.items()) != 0 {
		t.Fatalf("other network sees = %v", l.Body)
	}

	// «Отклонить» — свои товары выходят из группы общего каталога, её товары остаются.
	a.expect(a.do("POST", "/store/own-variant-groups/"+jid+"/reject", tok, nil), 200, "reject join")
	if err := pool.QueryRow(t.Context(), `SELECT count(*)::int FROM products WHERE variant_group_id = $1`, base).Scan(&cnt); err != nil || cnt != 2 {
		t.Fatalf("group size after reject = %d, %v", cnt, err)
	}
	if l := a.expect(a.do("GET", "/store/own-variant-groups?status=rejected", tok, nil), 200, "rejected"); len(l.items()) != 1 {
		t.Fatalf("rejected = %v", l.Body)
	}
}
