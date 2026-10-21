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

// TestCafePanel — данные для панели кафе (этап 2): цеха со значком и
// бегунком, стоп-лист, поиск продуктов для техкарты, «не учитываем» (вода),
// скидка у «0,5 порции», «+ блюдо» в модификаторе, остатки склада продуктов
// с минусом и «хватит на», предпросмотр производства.
func TestCafePanel(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cat := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Продукты"}), 201, "category")
	var kg, l string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		switch u["short_name"] {
		case "кг":
			kg = u["id"].(string)
		case "л":
			l = u["id"].(string)
		}
	}
	product := func(name, unit string) string {
		return a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{"name": name, "category_id": cat.str("id"), "unit_id": unit}), 201, name).str("id")
	}
	flour, water, onion, cucumber := product("Мука пшеничная", kg), product("Вода питьевая", l), product("Лук репчатый", kg), product("Огурцы", kg)

	a.expect(a.do("POST", "/admin/networks", adminTok, map[string]any{
		"name": "Кафе", "kind": "single", "owner_phone": "+998900000002", "owner_name": "В", "business_type": "cafe",
	}), 201, "cafe")
	tok, _ := a.login("+998900000002", identity.AppStore)
	store := a.expect(a.do("POST", "/store/stores", tok, map[string]any{"name": "Кафе 1"}), 201, "store").str("id")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)

	// Цех со значком, нормой и бегунком; группа уходит в него и обратно в «Кухню».
	g := a.expect(a.do("POST", "/store/cafe/menu-groups", tok, map[string]any{"name": "Самса"}), 201, "group").str("id")
	a.expect(a.do("POST", "/store/cafe/workshops", tok, map[string]any{"name": "Самса", "icon": "rocket"}), 400, "bad icon")
	ws := a.expect(a.do("POST", "/store/cafe/workshops", tok, map[string]any{
		"name": "Самса", "name_uz": "Somsaxona", "icon": "bakery", "cook_minutes": 5, "ticket_print": "always", "group_ids": []string{g},
	}), 201, "workshop")
	if ws.str("icon") != "bakery" || ws.Body["cook_minutes"].(float64) != 5 || ws.str("ticket_print") != "always" || len(ws.Body["group_names"].([]any)) != 1 {
		t.Fatalf("workshop = %v", ws.Body)
	}
	a.expect(a.do("PATCH", "/store/cafe/workshops/"+ws.str("id"), tok, map[string]any{"group_ids": []string{}}), 200, "unassign")
	kitchen := a.expect(a.do("GET", "/store/cafe/workshops", tok, nil), 200, "workshops").items()[0]
	if kitchen["is_default"] != true || len(kitchen["group_names"].([]any)) != 1 {
		t.Fatalf("kitchen = %v", kitchen)
	}

	// Продукты для техкарты: поиск по каталогу с ценой последнего прихода.
	doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "posting", "warehouse_id": wh, "items": []map[string]any{
			{"product_id": flour, "qty": 10, "price": 8000}, {"product_id": onion, "qty": 1, "price": 5000},
		},
	}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post")
	found := a.expect(a.do("GET", "/store/cafe/ingredients?q=мука", tok, nil), 200, "ingredients").items()
	if len(found) != 1 || found[0]["id"] != flour || found[0]["cost"] != "8000.00" {
		t.Fatalf("ingredients = %v", found)
	}

	// Тесто: мука и вода «не учитываем» — вода не списывается и не в себестоимости.
	dough := a.expect(a.do("POST", "/store/cafe/dishes", tok, map[string]any{
		"kind": "prep", "name": "Тесто", "unit_id": kg, "yield_qty": 1, "shelf_hours": 24,
		"recipe": []map[string]any{{"ingredient_id": flour, "qty": 0.6}, {"ingredient_id": water, "qty": 0.32, "not_tracked": true}},
	}), 201, "dough")
	if dough.str("cost") != "4800.00" || dough.Body["cost_complete"] != true {
		t.Fatalf("dough = %v", dough.Body)
	}
	if preps := a.expect(a.do("GET", "/store/cafe/ingredients", tok, nil), 200, "preps").items(); len(preps) != 1 || preps[0]["kind"] != "prep" {
		t.Fatalf("preps = %v", preps)
	}

	// Предпросмотр: 20 кг теста — муки 12 кг, на складе 10 → не хватает 2.
	pv := a.expect(a.do("GET", "/store/cafe/production-preview?store_id="+store+"&product_id="+dough.str("id")+"&qty=20", tok, nil), 200, "preview")
	lines := pv.Body["lines"].([]any)
	if len(lines) != 1 || lines[0].(map[string]any)["short"] != "2.000" || lines[0].(map[string]any)["enough"] != false ||
		pv.str("cost") != "96000.00" || len(pv.Body["not_tracked"].([]any)) != 1 {
		t.Fatalf("preview = %v", pv.Body)
	}
	var cook string
	for _, e := range a.expect(a.do("GET", "/store/employees", tok, nil), 200, "employees").items() {
		cook = e["id"].(string)
	}
	prod := a.expect(a.do("POST", "/store/cafe/production", tok, map[string]any{
		"store_id": store, "product_id": dough.str("id"), "qty": 20, "cook_id": cook,
	}), 201, "production")
	if prod.str("cook") == "" {
		t.Fatalf("production = %v", prod.Body)
	}

	// Салат, плов с «0,5 порции» (дешевле) и «+ салат × 0,5».
	salad := a.expect(a.do("POST", "/store/cafe/dishes", tok, map[string]any{
		"kind": "dish", "name": "Ачичук", "price": 12000, "recipe": []map[string]any{{"ingredient_id": cucumber, "qty": 0.2}},
	}), 201, "salad")
	mods := a.expect(a.do("POST", "/store/cafe/modifier-groups", tok, map[string]any{
		"name": "К плову", "options": []map[string]any{
			{"name": "0,5 порции", "action": "factor", "factor": 0.5, "price": -15000},
			{"name": "+ салат", "action": "add", "product_id": salad.str("id"), "qty": 0.5, "price": 6000},
		},
	}), 201, "mods")
	a.expect(a.do("POST", "/store/cafe/modifier-groups", tok, map[string]any{
		"name": "Плохо", "options": []map[string]any{{"name": "x", "price": -1}},
	}), 400, "negative price without factor")
	plov := a.expect(a.do("POST", "/store/cafe/dishes", tok, map[string]any{
		"kind": "dish", "name": "Плов", "price": 35000, "portion": "350 г", "menu_group_id": g,
		"recipe":             []map[string]any{{"ingredient_id": onion, "qty": 0.1}},
		"modifier_group_ids": []string{mods.str("id")},
	}), 201, "plov")
	if plov.str("portion") != "350 г" {
		t.Fatalf("plov = %v", plov.Body)
	}
	half, withSalad := mods.Body["options"].([]any)[0].(map[string]any)["id"], mods.Body["options"].([]any)[1].(map[string]any)["id"]
	var cash string
	for _, m := range a.expect(a.do("GET", "/store/finance/payment-methods?store_id="+store, tok, nil), 200, "methods").items() {
		if m["name"] == "Наличные" {
			cash = m["id"].(string)
		}
	}
	// 0,5 порции (35 000 − 15 000) + салат × 0,5 (6 000) = 26 000; лук 0,05, огурцы 0,1 — в минус.
	a.expect(a.do("POST", "/store/sales", tok, map[string]any{
		"client_uid": "panel-sale-01", "store_id": store,
		"items":    []map[string]any{{"product_id": plov.str("id"), "qty": 1, "modifiers": []map[string]any{{"option_id": half}, {"option_id": withSalad}}}},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 26000}},
	}), 201, "sale")

	st := a.expect(a.do("GET", "/store/cafe/stock?store_id="+store, tok, nil), 200, "stock")
	rows := map[string]map[string]any{}
	for _, x := range st.Body["items"].([]any) {
		r := x.(map[string]any)
		rows[r["product_id"].(string)] = r
	}
	if rows[cucumber]["qty"] != "-0.1" || rows[cucumber]["status"] != "minus" || rows[onion]["qty"] != "0.95" ||
		rows[flour]["qty"] != "-2" || st.Body["minus"].(float64) != 2 || rows[dough.str("id")]["qty"] != "20" {
		t.Fatalf("stock = %v", st.Body)
	}
	if _, ok := rows[water]; ok {
		t.Fatalf("water must not be in stock: %v", rows[water])
	}
	if only := a.expect(a.do("GET", "/store/cafe/stock?store_id="+store+"&status=minus", tok, nil), 200, "minus").Body["items"].([]any); len(only) != 2 {
		t.Fatalf("minus = %v", only)
	}

	// Стоп-лист точки.
	a.expect(a.do("PUT", "/store/cafe/stop-list", tok, map[string]any{"store_id": store, "product_id": plov.str("id"), "stopped": true}), 200, "stop")
	if d := a.expect(a.do("GET", "/store/cafe/dishes/"+plov.str("id"), tok, nil), 200, "plov"); len(d.Body["stop_store_ids"].([]any)) != 1 {
		t.Fatalf("stop = %v", d.Body)
	}
	if sl := a.expect(a.do("GET", "/store/cafe/stop-list?store_id="+store, tok, nil), 200, "stop list").items(); len(sl) != 1 {
		t.Fatalf("stop list = %v", sl)
	}
	a.expect(a.do("PUT", "/store/cafe/stop-list", tok, map[string]any{"store_id": store, "product_id": plov.str("id"), "stopped": false}), 200, "unstop")
	if d := a.expect(a.do("GET", "/store/cafe/dishes/"+dough.str("id"), tok, nil), 200, "dough"); d.Body["used_in"] != nil {
		t.Fatalf("dough used_in = %v", d.Body["used_in"])
	}
}

// TestCafePOS — касса кафе (этап 3): меню кафе в каталоге кассы, продажа
// блюда с модификаторами, комментарием, типом и номером заказа.
func TestCafePOS(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cat := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Продукты"}), 201, "category")
	var kg string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		if u["short_name"] == "кг" {
			kg = u["id"].(string)
		}
	}
	rice := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{"name": "Рис", "category_id": cat.str("id"), "unit_id": kg}), 201, "rice").str("id")
	onion := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{"name": "Лук", "category_id": cat.str("id"), "unit_id": kg}), 201, "onion").str("id")
	a.expect(a.do("POST", "/admin/networks", adminTok, map[string]any{
		"name": "Кафе", "kind": "single", "owner_phone": "+998900000002", "owner_name": "В", "business_type": "cafe",
	}), 201, "cafe")
	tok, _ := a.login("+998900000002", identity.AppStore)
	store := a.expect(a.do("POST", "/store/stores", tok, map[string]any{"name": "Кафе 1"}), 201, "store").str("id")
	g := a.expect(a.do("POST", "/store/cafe/menu-groups", tok, map[string]any{"name": "Горячее", "color": "#E8A33D"}), 201, "group").str("id")
	rm := a.expect(a.do("POST", "/store/cafe/modifier-groups", tok, map[string]any{
		"name": "Убрать", "options": []map[string]any{{"name": "без лука", "action": "remove", "product_id": onion}},
	}), 201, "mods")
	noOnion := rm.Body["options"].([]any)[0].(map[string]any)["id"].(string)
	plov := a.expect(a.do("POST", "/store/cafe/dishes", tok, map[string]any{
		"kind": "dish", "name": "Плов", "price": 35000, "menu_code": 12, "menu_group_id": g, "ikpu": "10202001001000000",
		"recipe":             []map[string]any{{"ingredient_id": rice, "qty": 0.15}, {"ingredient_id": onion, "qty": 0.05}},
		"modifier_group_ids": []string{rm.str("id")}, "portion": "350 г",
	}), 201, "plov").str("id")
	a.expect(a.do("PUT", "/store/cafe/stop-list", tok, map[string]any{"store_id": store, "product_id": plov, "stopped": true}), 200, "stop")

	dev := a.expect(a.do("POST", "/store/pos/devices", tok, map[string]any{"store_id": store, "name": "Касса 1"}), 201, "device")
	dt := a.expect(a.do("POST", "/pos/activate", "", map[string]any{"code": dev.str("activation_code")}), 200, "activate").str("token")
	c := a.expect(posDo(a, "GET", "/pos/catalog", dt, "", nil), 200, "catalog")
	menu, ok := c.Body["cafe"].(map[string]any)
	if !ok || menu["mode"] != "counter" || len(menu["groups"].([]any)) != 1 || len(menu["modifier_groups"].([]any)) != 1 ||
		len(menu["stop"].([]any)) != 1 || len(menu["workshops"].([]any)) != 1 {
		t.Fatalf("cafe menu = %v", c.Body["cafe"])
	}
	d := menu["dishes"].([]any)[0].(map[string]any)
	if d["product_id"] != plov || d["menu_code"].(float64) != 12 || d["on_sale"] != true || d["workshop_id"] == nil || len(d["modifier_group_ids"].([]any)) != 1 {
		t.Fatalf("dish = %v", d)
	}
	var cash string
	for _, x := range c.Body["payment_methods"].([]any) {
		if m := x.(map[string]any); m["kind"] == "cash" {
			cash = m["id"].(string)
		}
	}
	var owner string
	for _, e := range a.expect(a.do("GET", "/store/employees", tok, nil), 200, "employees").items() {
		owner = e["id"].(string)
	}
	a.expect(a.do("PUT", "/store/pos/pins/"+owner, tok, map[string]any{"pin": "9999"}), 200, "pin")
	shift := a.expect(posDo(a, "POST", "/pos/shifts", dt, owner, map[string]any{"client_uid": "shift-cafe-01"}), 201, "shift").str("id")
	a.expect(posDo(a, "POST", "/pos/sales", dt, owner, map[string]any{
		"client_uid": "cafe-pos-0001", "shift_id": shift, "order_type": "inside",
		"items":    []map[string]any{{"product_id": plov, "qty": 1, "price": 35000}},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 35000}},
	}), 400, "bad order type")
	s := a.expect(posDo(a, "POST", "/pos/sales", dt, owner, map[string]any{
		"client_uid": "cafe-pos-0002", "shift_id": shift, "order_type": "takeaway", "order_no": 47,
		"items": []map[string]any{
			{"product_id": plov, "qty": 2, "price": 35000, "modifiers": []map[string]any{{"option_id": noOnion}}, "note": "рис помягче"},
			{"product_id": plov, "qty": 1, "price": 35000},
		},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 105000}},
	}), 201, "cafe pos sale")
	items := s.Body["items"].([]any)
	if s.Body["order_no"].(float64) != 47 || s.str("order_type") != "takeaway" || len(items) != 2 ||
		items[0].(map[string]any)["note"] != "рис помягче" || len(items[0].(map[string]any)["modifiers"].([]any)) != 1 {
		t.Fatalf("sale = %v", s.Body)
	}
	// Рис списан на 3 порции, лук — только на одну (две «без лука») — в минус.
	var short string
	if err := pool.QueryRow(context.Background(), `SELECT trim_scale(sum(qty))::text FROM stock_shortfalls WHERE product_id = $1`, onion).Scan(&short); err != nil {
		t.Fatal(err)
	}
	if short != "0.05" {
		t.Fatalf("onion shortfall = %s", short)
	}
}
