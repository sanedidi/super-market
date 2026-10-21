package server_test

import (
	"context"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// TestCafeFlow — этап 1 модуля кафе: тип бизнеса, цеха, группы меню, блюда
// и заготовки с техкартами, модификаторы, списание продуктов при продаже
// («без лука», «+ сыр»), «минус» и его закрытие приходом и инвентаризацией,
// производство заготовки (самса через тесто), возврат блюда.
func TestCafeFlow(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	ctx := context.Background()
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)

	// Продукты общего каталога.
	cat := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Продукты"}), 201, "category")
	var kg, pcs string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		switch u["short_name"] {
		case "кг":
			kg = u["id"].(string)
		case "шт":
			pcs = u["id"].(string)
		}
	}
	product := func(name string) string {
		return a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
			"name": name, "category_id": cat.str("id"), "unit_id": kg,
		}), 201, "product "+name).str("id")
	}
	rice, meat, oil, onion, flour, cheese, potato := product("Рис"), product("Говядина"), product("Масло"), product("Лук"),
		product("Мука"), product("Сыр"), product("Картофель")

	// Тип бизнеса — только у супер-админа; агент кафе быть не может.
	a.expect(a.do("POST", "/admin/networks", adminTok, map[string]any{
		"name": "Агент", "kind": "distributor", "owner_phone": "+998900000009", "owner_name": "А", "business_type": "cafe",
	}), 400, "distributor cafe")
	a.expect(a.do("POST", "/admin/networks", adminTok, map[string]any{
		"name": "X", "kind": "single", "owner_phone": "+998900000008", "owner_name": "А", "business_type": "bar",
	}), 400, "bad business type")
	net := a.expect(a.do("POST", "/admin/networks", adminTok, map[string]any{
		"name": "Кафе Плов", "kind": "single", "owner_phone": "+998900000002", "owner_name": "Владелец", "business_type": "cafe",
	}), 201, "cafe network")
	if net.str("business_type") != "cafe" {
		t.Fatalf("network = %v", net.Body)
	}
	tok, _ := a.login("+998900000002", identity.AppStore)
	store := a.expect(a.do("POST", "/store/stores", tok, map[string]any{"name": "Кафе 1"}), 201, "store").str("id")
	whs := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "warehouses").items()
	wh := whs[0]["id"].(string)
	if n := whs[0]["name"]; n != "Кухня" && n != "Oshxona" {
		t.Fatalf("cafe warehouse = %v", n)
	}
	if s := a.expect(a.do("GET", "/store/cafe/settings", tok, nil), 200, "settings"); s.str("business_type") != "cafe" || s.str("cafe_mode") != "counter" {
		t.Fatalf("settings = %v", s.Body)
	}
	a.expect(a.do("PATCH", "/store/cafe/settings", tok, map[string]any{"cafe_mode": "tables", "service_percent": 10}), 200, "settings")

	// Магазину разделы кафе закрыты.
	shopTok, _ := setupNetwork(t, a, adminTok, "+998900000003")
	if r := a.expect(a.do("GET", "/store/cafe/dishes", shopTok, nil), 403, "shop dishes"); r.Body["error"].(map[string]any)["code"] != "not_cafe" {
		t.Fatalf("shop = %v", r.Body)
	}
	if s := a.expect(a.do("GET", "/store/cafe/settings", shopTok, nil), 200, "shop settings"); s.str("business_type") != "store" {
		t.Fatalf("shop settings = %v", s.Body)
	}

	// Цеха: «Кухня» есть сразу; «Гриль» забирает группу «Шашлык».
	ws := a.expect(a.do("GET", "/store/cafe/workshops", tok, nil), 200, "workshops").items()
	if len(ws) != 1 || ws[0]["is_default"] != true {
		t.Fatalf("workshops = %v", ws)
	}
	kitchen := ws[0]["id"].(string)
	plovGroup := a.expect(a.do("POST", "/store/cafe/menu-groups", tok, map[string]any{"name": "Плов и вторые", "name_uz": "Palov", "color": "#E8A33D"}), 201, "group").str("id")
	bakery := a.expect(a.do("POST", "/store/cafe/menu-groups", tok, map[string]any{"name": "Выпечка"}), 201, "group 2").str("id")
	grillGroup := a.expect(a.do("POST", "/store/cafe/menu-groups", tok, map[string]any{"name": "Шашлык"}), 201, "group 3").str("id")
	a.expect(a.do("POST", "/store/cafe/menu-groups", tok, map[string]any{"name": "шашлык"}), 409, "dup group")
	a.expect(a.do("POST", "/store/cafe/menu-groups", tok, map[string]any{"name": "Z", "color": "red"}), 400, "bad color")
	grill := a.expect(a.do("POST", "/store/cafe/workshops", tok, map[string]any{"name": "Гриль", "group_ids": []string{grillGroup}}), 201, "grill")
	if grill.Body["group_count"].(float64) != 1 {
		t.Fatalf("grill = %v", grill.Body)
	}
	a.expect(a.do("DELETE", "/store/cafe/workshops/"+kitchen, tok, nil), 409, "delete default")

	// Модификаторы.
	size := a.expect(a.do("POST", "/store/cafe/modifier-groups", tok, map[string]any{
		"name": "Размер", "min_select": 1, "max_select": 1,
		"options": []map[string]any{{"name": "Обычная"}, {"name": "Двойная", "action": "factor", "factor": 2, "price": 30000}},
	}), 201, "size")
	addons := a.expect(a.do("POST", "/store/cafe/modifier-groups", tok, map[string]any{
		"name": "Добавить", "options": []map[string]any{{"name": "+ сыр", "action": "add", "product_id": cheese, "qty": 0.03, "price": 5000}},
	}), 201, "addons")
	remove := a.expect(a.do("POST", "/store/cafe/modifier-groups", tok, map[string]any{
		"name": "Убрать", "options": []map[string]any{{"name": "Без лука", "action": "remove", "product_id": onion}},
	}), 201, "remove")
	a.expect(a.do("POST", "/store/cafe/modifier-groups", tok, map[string]any{
		"name": "Плохая", "min_select": 2, "max_select": 1, "options": []map[string]any{{"name": "a"}},
	}), 400, "max < min")
	opt := func(g resp, i int) string { return g.Body["options"].([]any)[i].(map[string]any)["id"].(string) }
	normal, double, withCheese, noOnion := opt(size, 0), opt(size, 1), opt(addons, 0), opt(remove, 0)

	// Блюдо «Плов»: техкарта на порцию, себестоимость по цене последнего прихода.
	doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "posting", "warehouse_id": wh, "items": []map[string]any{
			{"product_id": rice, "qty": 10, "price": 12000}, {"product_id": meat, "qty": 5, "price": 90000},
			{"product_id": oil, "qty": 5, "price": 20000}, {"product_id": onion, "qty": 3, "price": 5000},
			{"product_id": flour, "qty": 10, "price": 8000},
		},
	}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post")

	plov := a.expect(a.do("POST", "/store/cafe/dishes", tok, map[string]any{
		"kind": "dish", "name": "Плов", "name_uz": "Palov", "menu_code": 12, "menu_group_id": plovGroup, "price": 35000,
		"cook_minutes": 12, "ikpu": "10202001001000000",
		"recipe": []map[string]any{
			{"ingredient_id": rice, "qty": 0.15}, {"ingredient_id": meat, "qty": 0.1},
			{"ingredient_id": oil, "qty": 0.03}, {"ingredient_id": onion, "qty": 0.05},
		},
		"modifier_group_ids": []string{size.str("id"), addons.str("id"), remove.str("id")},
	}), 201, "plov")
	if plov.str("cost") != "11650.00" || plov.str("markup") != "23350.00" || plov.str("food_cost") != "33.3" ||
		plov.Body["cost_complete"] != true || plov.str("kitchen_workshop_id") != kitchen || plov.str("unit_short") == "" ||
		len(plov.Body["store_ids"].([]any)) != 1 || len(plov.Body["recipe"].([]any)) != 4 {
		t.Fatalf("plov = %v", plov.Body)
	}
	a.expect(a.do("POST", "/store/cafe/dishes", tok, map[string]any{"kind": "dish", "name": "Ещё", "menu_code": 12}), 409, "code taken")
	shashlik := a.expect(a.do("POST", "/store/cafe/dishes", tok, map[string]any{
		"kind": "dish", "name": "Шашлык", "menu_group_id": grillGroup, "price": 25000,
		"recipe": []map[string]any{{"ingredient_id": meat, "qty": 0.2}},
	}), 201, "shashlik")
	if shashlik.str("kitchen_workshop_id") != grill.str("id") {
		t.Fatalf("shashlik workshop = %v", shashlik.Body)
	}
	if found := a.expect(a.do("GET", "/store/cafe/dishes?q=12", tok, nil), 200, "by code").items(); len(found) != 1 || found[0]["id"] != plov.str("id") {
		t.Fatalf("by code = %v", found)
	}
	a.expect(a.do("POST", "/store/cafe/dishes", tok, map[string]any{
		"kind": "dish", "name": "Плов с шашлыком", "recipe": []map[string]any{{"ingredient_id": plov.str("id"), "qty": 1}},
	}), 400, "dish in recipe")

	// Заготовка «Тесто»: 3 кг муки на 5 кг теста; цикл запрещён.
	a.expect(a.do("POST", "/store/cafe/dishes", tok, map[string]any{"kind": "prep", "name": "Без единицы"}), 400, "prep needs unit")
	dough := a.expect(a.do("POST", "/store/cafe/dishes", tok, map[string]any{
		"kind": "prep", "name": "Тесто", "unit_id": kg, "yield_qty": 5, "shelf_hours": 24,
		"recipe": []map[string]any{{"ingredient_id": flour, "qty": 3}},
	}), 201, "dough")
	if dough.str("cost") != "4800.00" || dough.str("stock") != "0" {
		t.Fatalf("dough = %v", dough.Body)
	}
	puff := a.expect(a.do("POST", "/store/cafe/dishes", tok, map[string]any{
		"kind": "prep", "name": "Тесто слоёное", "unit_id": kg,
		"recipe": []map[string]any{{"ingredient_id": dough.str("id"), "qty": 1}, {"ingredient_id": oil, "qty": 0.2}},
	}), 201, "puff")
	a.expect(a.do("PATCH", "/store/cafe/dishes/"+dough.str("id"), tok, map[string]any{
		"recipe": []map[string]any{{"ingredient_id": puff.str("id"), "qty": 1}},
	}), 400, "cycle")
	a.expect(a.do("PATCH", "/store/cafe/dishes/"+dough.str("id"), tok, map[string]any{
		"recipe": []map[string]any{{"ingredient_id": dough.str("id"), "qty": 1}},
	}), 400, "self")
	a.expect(a.do("PATCH", "/store/cafe/dishes/"+dough.str("id"), tok, map[string]any{"kind": "dish"}), 400, "kind change")

	samsa := a.expect(a.do("POST", "/store/cafe/dishes", tok, map[string]any{
		"kind": "dish", "name": "Самса", "menu_group_id": bakery, "price": 8000, "unit_id": pcs,
		"recipe": []map[string]any{{"ingredient_id": dough.str("id"), "qty": 0.1}, {"ingredient_id": meat, "qty": 0.05}},
	}), 201, "samsa")
	if samsa.str("cost") != "4980.00" {
		t.Fatalf("samsa = %v", samsa.Body)
	}
	if list := a.expect(a.do("GET", "/store/cafe/dishes?group_id="+bakery, tok, nil), 200, "bakery").items(); len(list) != 1 {
		t.Fatalf("bakery = %v", list)
	}

	var cash string
	for _, m := range a.expect(a.do("GET", "/store/finance/payment-methods?store_id="+store, tok, nil), 200, "methods").items() {
		if m["name"] == "Наличные" {
			cash = m["id"].(string)
		}
	}

	// Продажа: размер обязателен.
	a.expect(a.do("POST", "/store/sales", tok, map[string]any{
		"client_uid": "cafe-sale-0000", "store_id": store,
		"items":    []map[string]any{{"product_id": plov.str("id"), "qty": 1}},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 35000}},
	}), 400, "size required")
	a.expect(a.do("POST", "/store/sales", tok, map[string]any{
		"client_uid": "cafe-sale-0000", "store_id": store,
		"items":    []map[string]any{{"product_id": rice, "qty": 1, "modifiers": []map[string]any{{"option_id": normal}}}},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 12000}},
	}), 400, "modifiers on goods")

	// 2 плова «без лука» + двойной плов с сыром (сыра на складе нет — «минус»).
	sale := a.expect(a.do("POST", "/store/sales", tok, map[string]any{
		"client_uid": "cafe-sale-0001", "store_id": store,
		"items": []map[string]any{
			{"product_id": plov.str("id"), "qty": 2, "modifiers": []map[string]any{{"option_id": normal}, {"option_id": noOnion}}},
			{"product_id": plov.str("id"), "qty": 1, "modifiers": []map[string]any{{"option_id": double}, {"option_id": withCheese}}},
		},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 140000}},
	}), 201, "cafe sale")
	if sale.str("total") != "140000.00" {
		t.Fatalf("sale = %v", sale.Body)
	}
	items := sale.Body["items"].([]any)
	if mods := items[0].(map[string]any)["modifiers"].([]any); len(mods) != 2 {
		t.Fatalf("modifiers = %v", items[0])
	}
	if q, _ := stockOf(t, a, tok, wh, rice); q != "9.400" {
		t.Fatalf("rice = %s", q)
	}
	if q, _ := stockOf(t, a, tok, wh, onion); q != "2.900" {
		t.Fatalf("onion = %s (без лука не списывается)", q)
	}
	if q, _ := stockOf(t, a, tok, wh, meat); q != "4.600" {
		t.Fatalf("meat = %s", q)
	}
	saleCost := func() string {
		var c string
		if err := pool.QueryRow(ctx, `SELECT cost::text FROM sales WHERE id = $1`, sale.str("id")).Scan(&c); err != nil {
			t.Fatal(err)
		}
		return c
	}
	// 2 × (11 650 − 250 лука) + 2 × 11 650 = 46 100; сыр пока без цены.
	if c := saleCost(); c != "46100.00" {
		t.Fatalf("sale cost = %s", c)
	}
	sf := a.expect(a.do("GET", "/store/cafe/shortfalls?store_id="+store, tok, nil), 200, "shortfalls").items()
	if len(sf) != 1 || sf[0]["product_id"] != cheese || sf[0]["qty"] != "0.03" {
		t.Fatalf("shortfalls = %v", sf)
	}

	// Приход сыра закрывает «минус» и уточняет себестоимость продажи.
	doc = a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "posting", "warehouse_id": wh, "items": []map[string]any{{"product_id": cheese, "qty": 1, "price": 100000}},
	}), 201, "cheese posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post cheese")
	if c := saleCost(); c != "49100.00" {
		t.Fatalf("sale cost after cheese = %s", c)
	}
	if q, _ := stockOf(t, a, tok, wh, cheese); q != "0.970" {
		t.Fatalf("cheese = %s", q)
	}
	if sf := a.expect(a.do("GET", "/store/cafe/shortfalls", tok, nil), 200, "shortfalls").items(); len(sf) != 0 {
		t.Fatalf("shortfalls after posting = %v", sf)
	}

	// Возврат плова: деньги вернули, продукты остаются списанными.
	ret := a.expect(a.do("POST", "/store/sales/returns", tok, map[string]any{
		"sale_id": sale.str("id"), "payment_method_id": cash, "reason": "Остыл",
		"items": []map[string]any{{"sale_line": 1, "qty": 1}},
	}), 201, "return dish")
	if ret.str("total") != "35000.00" {
		t.Fatalf("return = %v", ret.Body)
	}
	if q, _ := stockOf(t, a, tok, wh, rice); q != "9.400" {
		t.Fatalf("rice after return = %s", q)
	}

	// Производство теста: 5 кг из 3 кг муки (24 000) → 4 800 за кг. Повтор по client_uid — тот же документ.
	a.expect(a.do("POST", "/store/cafe/production", tok, map[string]any{
		"store_id": store, "product_id": plov.str("id"), "qty": 1,
	}), 400, "produce dish")
	prod := a.expect(a.do("POST", "/store/cafe/production", tok, map[string]any{
		"client_uid": "prod-0000001", "store_id": store, "product_id": dough.str("id"), "qty": 5,
	}), 201, "production")
	if prod.str("cost") != "24000.00" || prod.str("unit_cost") != "4800.00" || prod.Body["expires_at"] == nil {
		t.Fatalf("production = %v", prod.Body)
	}
	again := a.expect(a.do("POST", "/store/cafe/production", tok, map[string]any{
		"client_uid": "prod-0000001", "store_id": store, "product_id": dough.str("id"), "qty": 5,
	}), 200, "production repeat")
	if again.str("id") != prod.str("id") {
		t.Fatalf("repeat = %v", again.Body)
	}
	if q, _ := stockOf(t, a, tok, wh, dough.str("id")); q != "5.000" {
		t.Fatalf("dough = %s", q)
	}
	if q, _ := stockOf(t, a, tok, wh, flour); q != "7.000" {
		t.Fatalf("flour = %s", q)
	}

	// 10 самс: 1 кг теста (4 800) + 0,5 кг мяса (45 000).
	s2 := a.expect(a.do("POST", "/store/sales", tok, map[string]any{
		"client_uid": "cafe-sale-0002", "store_id": store,
		"items":    []map[string]any{{"product_id": samsa.str("id"), "qty": 10}},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 80000}},
	}), 201, "samsa sale")
	var c2 string
	if err := pool.QueryRow(ctx, `SELECT cost::text FROM sales WHERE id = $1`, s2.str("id")).Scan(&c2); err != nil {
		t.Fatal(err)
	}
	if c2 != "49800.00" {
		t.Fatalf("samsa cost = %s", c2)
	}
	if q, _ := stockOf(t, a, tok, wh, dough.str("id")); q != "4.000" {
		t.Fatalf("dough after samsa = %s", q)
	}

	// «Минус» картофеля закрывает инвентаризация (посчитан факт).
	fries := a.expect(a.do("POST", "/store/cafe/dishes", tok, map[string]any{
		"kind": "dish", "name": "Фри", "price": 15000, "recipe": []map[string]any{{"ingredient_id": potato, "qty": 0.2}},
	}), 201, "fries")
	a.expect(a.do("POST", "/store/sales", tok, map[string]any{
		"client_uid": "cafe-sale-0003", "store_id": store,
		"items":    []map[string]any{{"product_id": fries.str("id"), "qty": 1}},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 15000}},
	}), 201, "fries sale")
	if sf := a.expect(a.do("GET", "/store/cafe/shortfalls", tok, nil), 200, "shortfalls").items(); len(sf) != 1 || sf[0]["qty"] != "0.2" {
		t.Fatalf("potato shortfall = %v", sf)
	}
	inv := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "inventory", "warehouse_id": wh, "items": []map[string]any{{"product_id": potato, "qty": 0}},
	}), 201, "inventory")
	a.expect(a.do("POST", "/store/inventory/documents/"+inv.str("id")+"/post", tok, nil), 200, "post inventory")
	if sf := a.expect(a.do("GET", "/store/cafe/shortfalls", tok, nil), 200, "shortfalls").items(); len(sf) != 0 {
		t.Fatalf("shortfalls after inventory = %v", sf)
	}

	// Тип бизнеса меняет супер-админ: магазин стал кафе — получил цех «Кухня».
	shop := a.expect(a.do("GET", "/admin/networks?q=%2B998900000003", adminTok, nil), 200, "find shop").items()
	if len(shop) != 1 {
		t.Fatalf("shop = %v", shop)
	}
	a.expect(a.do("PATCH", "/admin/networks/"+shop[0]["id"].(string), adminTok, map[string]any{"business_type": "cafe"}), 200, "to cafe")
	if ws := a.expect(a.do("GET", "/store/cafe/workshops", shopTok, nil), 200, "shop workshops").items(); len(ws) != 1 {
		t.Fatalf("shop workshops = %v", ws)
	}
}
