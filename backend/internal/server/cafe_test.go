package server_test

import (
	"context"
	"fmt"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

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

	// Ресторан — кафе со столами: в списке сетей «restaurant», касса — на зале.
	rest := a.expect(a.do("POST", "/admin/networks", adminTok, map[string]any{
		"name": "Ресторан", "kind": "single", "owner_phone": "+998900000007", "owner_name": "Р", "business_type": "restaurant",
	}), 201, "restaurant network")
	if rest.str("business_type") != "restaurant" {
		t.Fatalf("restaurant = %v", rest.Body)
	}
	restTok, _ := a.login("+998900000007", identity.AppStore)
	if s := a.expect(a.do("GET", "/store/cafe/settings", restTok, nil), 200, "restaurant settings"); s.str("business_type") != "cafe" || s.str("cafe_mode") != "tables" {
		t.Fatalf("restaurant settings = %v", s.Body)
	}
	// «Столы + с собой» у владельца — всё ещё ресторан; «Сделать кафе» — у прилавка.
	a.expect(a.do("PATCH", "/store/cafe/settings", restTok, map[string]any{"cafe_mode": "both"}), 200, "restaurant both")
	if n := a.expect(a.do("PATCH", "/admin/networks/"+rest.str("id"), adminTok, map[string]any{"business_type": "restaurant"}), 200, "keep both"); n.str("business_type") != "restaurant" {
		t.Fatalf("keep both = %v", n.Body)
	}
	if s := a.expect(a.do("GET", "/store/cafe/settings", restTok, nil), 200, "both kept"); s.str("cafe_mode") != "both" {
		t.Fatalf("both kept = %v", s.Body)
	}
	if n := a.expect(a.do("PATCH", "/admin/networks/"+rest.str("id"), adminTok, map[string]any{"business_type": "cafe"}), 200, "to cafe"); n.str("business_type") != "cafe" {
		t.Fatalf("to cafe = %v", n.Body)
	}
	a.expect(a.do("POST", "/admin/networks", adminTok, map[string]any{
		"name": "Агент 2", "kind": "distributor", "owner_phone": "+998900000006", "owner_name": "А", "business_type": "restaurant",
	}), 400, "distributor restaurant")

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

// Этап 4: бегунки по цехам, экран кухни, экран выдачи, отмена при возврате,
// стоп-лист с кухни, состояние принтеров и ожидание событий.
func TestCafeKitchen(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	a.expect(a.do("POST", "/admin/networks", adminTok, map[string]any{
		"name": "Кафе", "kind": "single", "owner_phone": "+998900000002", "owner_name": "В", "business_type": "cafe",
	}), 201, "cafe")
	tok, _ := a.login("+998900000002", identity.AppStore)
	store := a.expect(a.do("POST", "/store/stores", tok, map[string]any{"name": "Кафе 1"}), 201, "store").str("id")
	hot := a.expect(a.do("POST", "/store/cafe/menu-groups", tok, map[string]any{"name": "Горячее"}), 201, "hot").str("id")
	drinks := a.expect(a.do("POST", "/store/cafe/menu-groups", tok, map[string]any{"name": "Напитки"}), 201, "drinks").str("id")
	a.expect(a.do("POST", "/store/cafe/workshops", tok, map[string]any{
		"name": "Бар", "icon": "bar", "group_ids": []string{drinks}, "printer_kind": "network",
	}), 400, "network printer without ip")
	bar := a.expect(a.do("POST", "/store/cafe/workshops", tok, map[string]any{
		"name": "Бар", "icon": "bar", "cook_minutes": 3, "group_ids": []string{drinks},
		"printer_kind": "network", "printer_host": "192.168.1.42", "printer_paper": 58,
	}), 201, "bar")
	if bar.str("printer_kind") != "network" || bar.Body["printer_paper"].(float64) != 58 || bar.Body["printer_port"].(float64) != 9100 {
		t.Fatalf("bar = %v", bar.Body)
	}
	var kitchenWS string
	for _, w := range a.expect(a.do("GET", "/store/cafe/workshops", tok, nil), 200, "workshops").items() {
		if w["is_default"] == true {
			kitchenWS = w["id"].(string)
		}
	}
	plov := a.expect(a.do("POST", "/store/cafe/dishes", tok, map[string]any{
		"kind": "dish", "name": "Плов", "price": 35000, "menu_code": 12, "menu_group_id": hot, "ikpu": "10202001001000000",
	}), 201, "plov").str("id")
	tea := a.expect(a.do("POST", "/store/cafe/dishes", tok, map[string]any{
		"kind": "dish", "name": "Чай", "price": 6000, "menu_code": 40, "menu_group_id": drinks, "ikpu": "10202001001000000",
	}), 201, "tea").str("id")
	mods := a.expect(a.do("POST", "/store/cafe/modifier-groups", tok, map[string]any{
		"name": "Острота", "options": []map[string]any{{"name": "острый", "action": "none"}},
	}), 201, "mods")
	noOnion := mods.Body["options"].([]any)[0].(map[string]any)["id"].(string)

	activate := func(body map[string]any) (string, resp) {
		d := a.expect(a.do("POST", "/store/pos/devices", tok, body), 201, "device")
		act := a.expect(a.do("POST", "/pos/activate", "", map[string]any{"code": d.str("activation_code")}), 200, "activate")
		return act.str("token"), act
	}
	posTok, _ := activate(map[string]any{"store_id": store, "name": "Касса 1"})
	kdsTok, kact := activate(map[string]any{"store_id": store, "name": "Экран кухни", "kind": "kitchen"})
	if kact.str("kind") != "kitchen" || kact.Body["workshop_id"] != nil {
		t.Fatalf("kitchen activation = %v", kact.Body)
	}
	dispTok, _ := activate(map[string]any{"store_id": store, "name": "ТВ в зале", "kind": "display"})
	// Экраны не в списке касс, но видны отдельно.
	if n := len(a.expect(a.do("GET", "/store/pos/devices", tok, nil), 200, "tills").items()); n != 1 {
		t.Fatalf("tills = %d", n)
	}
	a.expect(a.do("GET", "/store/pos/devices?kind=bad", tok, nil), 400, "bad kind")
	c := a.expect(posDo(a, "GET", "/pos/catalog", kdsTok, "", nil), 200, "kitchen catalog")
	if c.Body["settings"].(map[string]any)["device_kind"] != "kitchen" || c.Body["cafe"].(map[string]any)["kitchen_sound"] != true {
		t.Fatalf("kitchen catalog settings = %v", c.Body["settings"])
	}
	screens := a.expect(a.do("GET", "/store/pos/devices?kind=kitchen,display", tok, nil), 200, "screens").items()
	if len(screens) != 2 {
		t.Fatalf("screens = %v", screens)
	}
	for _, sc := range screens {
		if sc["kind"] == "kitchen" && sc["online"] != true {
			t.Fatalf("kitchen screen offline after catalog: %v", sc)
		}
	}

	pc := a.expect(posDo(a, "GET", "/pos/catalog", posTok, "", nil), 200, "pos catalog")
	var cash string
	for _, x := range pc.Body["payment_methods"].([]any) {
		if m := x.(map[string]any); m["kind"] == "cash" {
			cash = m["id"].(string)
		}
	}
	for _, w := range pc.Body["cafe"].(map[string]any)["workshops"].([]any) {
		if m := w.(map[string]any); m["id"] == bar.str("id") && (m["printer_host"] != "192.168.1.42" || m["printer_paper"].(float64) != 58) {
			t.Fatalf("pos workshop printer = %v", m)
		}
	}
	var owner string
	for _, e := range a.expect(a.do("GET", "/store/employees", tok, nil), 200, "employees").items() {
		owner = e["id"].(string)
	}
	a.expect(a.do("PUT", "/store/pos/pins/"+owner, tok, map[string]any{"pin": "9999"}), 200, "pin")
	shift := a.expect(posDo(a, "POST", "/pos/shifts", posTok, owner, map[string]any{"client_uid": "shift-kds-01"}), 201, "shift").str("id")
	// Экран кухни не продаёт, даже с кассиром в заголовке.
	if r := posDo(a, "POST", "/pos/shifts", kdsTok, owner, map[string]any{"client_uid": "shift-kds-02"}); r.Status < 400 {
		t.Fatalf("kitchen screen opened a shift: %d", r.Status)
	}

	// Экран ждёт изменений: продажа будит его сразу.
	v0 := int64(a.expect(posDo(a, "GET", "/pos/kitchen/wait?v=999999", kdsTok, "", nil), 200, "wait now").Body["version"].(float64))
	woke := make(chan int64, 1)
	go func() {
		r := posDo(a, "GET", "/pos/kitchen/wait?v="+strconv.FormatInt(v0, 10), kdsTok, "", nil)
		woke <- int64(r.Body["version"].(float64))
	}()
	time.Sleep(300 * time.Millisecond)
	start := time.Now()
	sale := a.expect(posDo(a, "POST", "/pos/sales", posTok, owner, map[string]any{
		"client_uid": "kds-sale-0001", "shift_id": shift, "order_type": "takeaway", "order_no": 47,
		"items": []map[string]any{
			{"product_id": plov, "qty": 2, "price": 35000, "modifiers": []map[string]any{{"option_id": noOnion}}, "note": "острое отдельно"},
			{"product_id": tea, "qty": 1, "price": 6000},
		},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 76000}},
	}), 201, "sale 47").str("id")
	select {
	case v := <-woke:
		if v <= v0 || time.Since(start) > 5*time.Second {
			t.Fatalf("wait woke with %d after %s", v, time.Since(start))
		}
	case <-time.After(10 * time.Second):
		t.Fatal("wait did not wake on sale")
	}

	board := func(token string) []map[string]any {
		b := a.expect(posDo(a, "GET", "/pos/kitchen/board", token, "", nil), 200, "board")
		var out []map[string]any
		for _, o := range b.Body["orders"].([]any) {
			out = append(out, o.(map[string]any))
		}
		return out
	}
	orders := board(kdsTok)
	if len(orders) != 1 || orders[0]["order_no"].(float64) != 47 || orders[0]["status"] != "new" || orders[0]["order_type"] != "takeaway" {
		t.Fatalf("board = %v", orders)
	}
	tickets := orders[0]["tickets"].([]any)
	if len(tickets) != 2 {
		t.Fatalf("tickets = %v", tickets)
	}
	var kitchenTicket, barTicket map[string]any
	for _, x := range tickets {
		tk := x.(map[string]any)
		if tk["workshop_id"] == bar.str("id") {
			barTicket = tk
		} else if tk["workshop_id"] == kitchenWS {
			kitchenTicket = tk
		}
	}
	if kitchenTicket == nil || barTicket == nil || barTicket["cook_minutes"].(float64) != 3 {
		t.Fatalf("tickets = %v", tickets)
	}
	pi := kitchenTicket["items"].([]any)[0].(map[string]any)
	if pi["qty"] != "2" || pi["note"] != "острое отдельно" || pi["mods"].([]any)[0].(map[string]any)["name"] != "острый" {
		t.Fatalf("plov item = %v", pi)
	}
	disp := a.expect(posDo(a, "GET", "/pos/kitchen/display", dispTok, "", nil), 200, "display")
	if len(disp.Body["cooking"].([]any)) != 1 || len(disp.Body["ready"].([]any)) != 0 || disp.Body["show_cooking"] != true {
		t.Fatalf("display = %v", disp.Body)
	}
	a.expect(posDo(a, "POST", "/pos/kitchen/orders/"+sale+"/action", dispTok, "", map[string]any{"action": "start"}), 403, "display acts")
	a.expect(posDo(a, "POST", "/pos/kitchen/orders/"+sale+"/action", kdsTok, "", map[string]any{"action": "cook"}), 400, "bad action")

	// Кухня начала и закончила свою часть — заказ ещё готовится (бар не готов).
	a.expect(posDo(a, "POST", "/pos/kitchen/orders/"+sale+"/action", kdsTok, "", map[string]any{"action": "start", "workshop_id": kitchenWS}), 200, "start")
	o := a.expect(posDo(a, "POST", "/pos/kitchen/orders/"+sale+"/action", kdsTok, "", map[string]any{"action": "ready", "workshop_id": kitchenWS}), 200, "ready kitchen")
	if st := o.Body["orders"].([]any)[0].(map[string]any)["status"]; st != "cooking" {
		t.Fatalf("after kitchen ready status = %v", st)
	}
	teaItem := barTicket["items"].([]any)[0].(map[string]any)["id"].(string)
	o = a.expect(posDo(a, "POST", "/pos/kitchen/items/"+teaItem+"/done", kdsTok, "", map[string]any{"done": true}), 200, "done")
	if o.Body["orders"].([]any)[0].(map[string]any)["status"] != "cooking" {
		t.Fatalf("done changed status: %v", o.Body)
	}
	o = a.expect(posDo(a, "POST", "/pos/kitchen/orders/"+sale+"/action", kdsTok, "", map[string]any{"action": "ready"}), 200, "ready all")
	if o.Body["orders"].([]any)[0].(map[string]any)["status"] != "ready" {
		t.Fatalf("ready status = %v", o.Body)
	}
	disp = a.expect(posDo(a, "GET", "/pos/kitchen/display", dispTok, "", nil), 200, "display ready")
	if len(disp.Body["ready"].([]any)) != 1 || disp.Body["ready"].([]any)[0].(float64) != 47 || len(disp.Body["cooking"].([]any)) != 0 {
		t.Fatalf("display ready = %v", disp.Body)
	}
	a.expect(posDo(a, "POST", "/pos/kitchen/orders/"+sale+"/action", kdsTok, "", map[string]any{"action": "served"}), 200, "served")
	if len(board(kdsTok)) != 0 {
		t.Fatal("served order still on board")
	}
	a.expect(posDo(a, "POST", "/pos/kitchen/orders/"+sale+"/action", kdsTok, "", map[string]any{"action": "served"}), 200, "served again")

	// Экран только у бара: бегунок кухни сразу «выдан» (его печатает касса).
	for _, s := range screens {
		if s["kind"] == "kitchen" {
			a.expect(a.do("POST", "/store/pos/devices/"+s["id"].(string)+"/revoke", tok, nil), 200, "revoke kitchen")
		}
	}
	barTok, bact := activate(map[string]any{"store_id": store, "name": "Экран бара", "kind": "kitchen", "workshop_id": bar.str("id")})
	if bact.Body["workshop_name"] != "Бар" {
		t.Fatalf("bar activation = %v", bact.Body)
	}
	s48 := a.expect(posDo(a, "POST", "/pos/sales", posTok, owner, map[string]any{
		"client_uid": "kds-sale-0002", "shift_id": shift, "order_type": "here", "order_no": 48,
		"items": []map[string]any{
			{"product_id": plov, "qty": 1, "price": 35000},
			{"product_id": tea, "qty": 2, "price": 6000},
		},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 47000}},
	}), 201, "sale 48").str("id")
	orders = board(barTok)
	if len(orders) != 1 || orders[0]["status"] != "new" || len(orders[0]["tickets"].([]any)) != 2 {
		t.Fatalf("bar board = %v", orders)
	}
	// Экран бара действует только на свой цех, даже если просит «все».
	a.expect(posDo(a, "POST", "/pos/kitchen/orders/"+s48+"/action", barTok, "", map[string]any{"action": "ready", "workshop_id": kitchenWS}), 200, "bar ready")
	var kst string
	if err := pool.QueryRow(context.Background(), `SELECT status FROM kitchen_tickets WHERE sale_id = $1 AND workshop_id = $2`, s48, kitchenWS).Scan(&kst); err != nil {
		t.Fatal(err)
	}
	if kst != "served" {
		t.Fatalf("kitchen ticket without screen = %s", kst)
	}
	a.expect(posDo(a, "POST", "/pos/kitchen/orders/"+s48+"/action", barTok, "", map[string]any{"action": "back"}), 200, "back")

	// Возврат чая: на экране бара — «ОТМЕНА», заказ отменён.
	a.expect(posDo(a, "POST", "/pos/returns", posTok, owner, map[string]any{
		"sale_id": s48, "payment_method_id": cash, "reason": "передумал", "shift_id": shift,
		"items": []map[string]any{{"sale_line": 2, "qty": 2}},
	}), 201, "return tea")
	orders = board(barTok)
	if len(orders) != 1 || orders[0]["status"] != "cancelled" {
		t.Fatalf("after return = %v", orders)
	}
	for _, x := range orders[0]["tickets"].([]any) {
		tk := x.(map[string]any)
		if tk["workshop_id"] == bar.str("id") && (tk["status"] != "cancelled" || tk["items"].([]any)[0].(map[string]any)["cancelled_qty"] != "2") {
			t.Fatalf("cancelled ticket = %v", tk)
		}
	}

	// Стоп-лист с кухни виден кассе.
	a.expect(posDo(a, "PUT", "/pos/kitchen/stop", dispTok, "", map[string]any{"product_id": plov, "stopped": true}), 403, "display stop")
	st := a.expect(posDo(a, "PUT", "/pos/kitchen/stop", barTok, "", map[string]any{"product_id": plov, "stopped": true}), 200, "stop")
	if len(st.Body["stop"].([]any)) != 1 {
		t.Fatalf("stop = %v", st.Body)
	}
	// Тест печати из панели и отчёт кассы о принтере.
	a.expect(a.do("POST", "/store/cafe/workshops/"+bar.str("id")+"/test-print", tok, nil), 200, "test print")
	status := a.expect(posDo(a, "GET", "/pos/kitchen/status", posTok, owner, nil), 200, "status")
	if status.Body["screens"].(map[string]any)[bar.str("id")] != true || len(status.Body["print_tests"].([]any)) != 1 ||
		len(status.Body["stop"].([]any)) != 1 {
		t.Fatalf("status = %v", status.Body)
	}
	a.expect(posDo(a, "POST", "/pos/kitchen/printers", posTok, owner, []map[string]any{{"workshop_id": bar.str("id"), "ok": false, "pending": 2}}), 200, "printers")
	for _, w := range a.expect(a.do("GET", "/store/cafe/workshops", tok, nil), 200, "workshops").items() {
		if w["id"] == bar.str("id") && (w["printer_ok"] != false || w["printer_pending"].(float64) != 2 || w["printer_seen_at"] == nil) {
			t.Fatalf("bar printer = %v", w)
		}
	}
	// Продажа, дошедшая через 5 часов (касса была без связи), на кухню не идёт.
	a.expect(posDo(a, "POST", "/pos/sales", posTok, owner, map[string]any{
		"client_uid": "kds-sale-0003", "shift_id": shift, "order_type": "here", "order_no": 49,
		"sold_at":  time.Now().Add(-5 * time.Hour).UTC().Format(time.RFC3339),
		"items":    []map[string]any{{"product_id": tea, "qty": 1, "price": 6000}},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 6000}},
	}), 201, "late sale")
	var late int
	if err := pool.QueryRow(context.Background(), `SELECT count(*) FROM kitchen_tickets WHERE order_no = 49`).Scan(&late); err != nil {
		t.Fatal(err)
	}
	if late != 0 {
		t.Fatalf("late sale tickets = %d", late)
	}
	// Настройки кухни.
	set := a.expect(a.do("PATCH", "/store/cafe/settings", tok, map[string]any{"display_hide_minutes": 7, "kitchen_sound": false}), 200, "settings")
	if set.Body["display_hide_minutes"].(float64) != 7 || set.Body["kitchen_sound"] != false {
		t.Fatalf("settings = %v", set.Body)
	}
	a.expect(a.do("PATCH", "/store/cafe/settings", tok, map[string]any{"display_hide_minutes": 0}), 400, "bad hide")
}

// Этап 5: залы и столы, открытый счёт — операции (идемпотентные), кухня,
// перенос, объединение, отмена с ПИНом старшего, разделение оплаты,
// закрыть без оплаты.
func TestCafeTables(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	a.expect(a.do("POST", "/admin/networks", adminTok, map[string]any{
		"name": "Кафе", "kind": "single", "owner_phone": "+998900000002", "owner_name": "В", "business_type": "cafe",
	}), 201, "cafe")
	tok, _ := a.login("+998900000002", identity.AppStore)
	store := a.expect(a.do("POST", "/store/stores", tok, map[string]any{"name": "Кафе 1"}), 201, "store").str("id")
	hot := a.expect(a.do("POST", "/store/cafe/menu-groups", tok, map[string]any{"name": "Горячее"}), 201, "hot").str("id")
	drinks := a.expect(a.do("POST", "/store/cafe/menu-groups", tok, map[string]any{"name": "Напитки"}), 201, "drinks").str("id")
	a.expect(a.do("POST", "/store/cafe/workshops", tok, map[string]any{"name": "Бар", "group_ids": []string{drinks}}), 201, "bar")
	plov := a.expect(a.do("POST", "/store/cafe/dishes", tok, map[string]any{
		"kind": "dish", "name": "Плов", "price": 35000, "menu_code": 12, "menu_group_id": hot, "ikpu": "10202001001000000",
	}), 201, "plov").str("id")
	tea := a.expect(a.do("POST", "/store/cafe/dishes", tok, map[string]any{
		"kind": "dish", "name": "Чай", "price": 6000, "menu_code": 40, "menu_group_id": drinks, "ikpu": "10202001001000000",
	}), 201, "tea").str("id")
	a.expect(a.do("PATCH", "/store/cafe/settings", tok, map[string]any{"cafe_mode": "both", "service_percent": "10", "service_ikpu": "123"}), 400, "bad ikpu")
	set := a.expect(a.do("PATCH", "/store/cafe/settings", tok, map[string]any{"cafe_mode": "both", "service_percent": "10", "precheck_required": true}), 200, "settings")
	if set.str("cafe_mode") != "both" || set.Body["precheck_required"] != true || set.Body["void_senior_only"] != true {
		t.Fatalf("settings = %v", set.Body)
	}

	// Схема зала (П9).
	table := func(n string, seats, x int) map[string]any {
		return map[string]any{"number": n, "seats": seats, "shape": "rect", "x": x, "y": 0, "w": 2, "h": 2}
	}
	a.expect(a.do("PUT", "/store/cafe/halls", tok, map[string]any{"store_id": store, "halls": []map[string]any{
		{"name": "Зал", "tables": []map[string]any{table("1", 2, 0), table("1", 4, 3)}},
	}}), 400, "duplicate number")
	lay := a.expect(a.do("PUT", "/store/cafe/halls", tok, map[string]any{"store_id": store, "halls": []map[string]any{
		{"name": "Зал", "name_uz": "Zal", "tables": []map[string]any{table("1", 2, 0), table("7", 4, 3)}},
		{"name": "Терраса", "tables": []map[string]any{table("Т3", 6, 0)}},
	}}), 200, "layout").items()
	if len(lay) != 2 || len(lay[0]["tables"].([]any)) != 2 {
		t.Fatalf("layout = %v", lay)
	}
	tid := map[string]string{}
	for _, h := range lay {
		for _, x := range h["tables"].([]any) {
			tt := x.(map[string]any)
			tid[tt["number"].(string)] = tt["id"].(string)
		}
	}

	d := a.expect(a.do("POST", "/store/pos/devices", tok, map[string]any{"store_id": store, "name": "Касса"}), 201, "device")
	posTok := a.expect(a.do("POST", "/pos/activate", "", map[string]any{"code": d.str("activation_code")}), 200, "activate").str("token")
	k := a.expect(a.do("POST", "/store/pos/devices", tok, map[string]any{"store_id": store, "name": "Кухня", "kind": "kitchen"}), 201, "kds")
	kdsTok := a.expect(a.do("POST", "/pos/activate", "", map[string]any{"code": k.str("activation_code")}), 200, "activate kds").str("token")
	var owner string
	for _, e := range a.expect(a.do("GET", "/store/employees", tok, nil), 200, "employees").items() {
		owner = e["id"].(string)
	}
	a.expect(a.do("PUT", "/store/pos/pins/"+owner, tok, map[string]any{"pin": "9999"}), 200, "pin")
	cat := a.expect(posDo(a, "GET", "/pos/catalog", posTok, "", nil), 200, "catalog")
	var cash string
	for _, x := range cat.Body["payment_methods"].([]any) {
		if m := x.(map[string]any); m["kind"] == "cash" {
			cash = m["id"].(string)
		}
	}
	shift := a.expect(posDo(a, "POST", "/pos/shifts", posTok, owner, map[string]any{"client_uid": "shift-tables-01"}), 201, "shift").str("id")

	hall := a.expect(posDo(a, "GET", "/pos/hall", posTok, owner, nil), 200, "hall")
	if hall.str("mode") != "both" || len(hall.Body["halls"].([]any)) != 2 || len(hall.Body["tables"].([]any)) != 3 || len(hall.Body["bills"].([]any)) != 0 {
		t.Fatalf("hall = %v", hall.Body)
	}

	n := 0
	uid := func() string {
		n++
		return fmt.Sprintf("00000000-0000-4000-8000-%012d", n)
	}
	op := func(body map[string]any, want int, what string) resp {
		if _, ok := body["id"]; !ok {
			body["id"] = uid()
		}
		return a.expect(posDo(a, "POST", "/pos/bills/ops", posTok, owner, body), want, what)
	}
	b1 := "11111111-0000-4000-8000-000000000001"
	open := map[string]any{"id": uid(), "bill_id": b1, "kind": "open", "table_id": tid["7"], "guests": 4}
	bill := op(open, 200, "open")
	if bill.str("status") != "open" || bill.str("table_number") != "7" || bill.str("service_percent") != "10" || bill.Body["guests"].(float64) != 4 {
		t.Fatalf("bill = %v", bill.Body)
	}
	op(open, 200, "open again (same op)")
	op(map[string]any{"bill_id": "11111111-0000-4000-8000-000000000009", "kind": "open", "table_id": tid["7"]}, 409, "table busy")
	// Кассир без кассы (без X-Cashier-ID) не может.
	a.expect(posDo(a, "POST", "/pos/bills/ops", posTok, "", map[string]any{"id": uid(), "bill_id": b1, "kind": "guests", "guests": 3}), 403, "no cashier")

	item := func(id, product string, qty, price int, course string, guest int) map[string]any {
		return map[string]any{"bill_id": b1, "kind": "add", "item": map[string]any{
			"id": id, "product_id": product, "qty": qty, "price": price, "course": course, "guest": guest, "note": "без зелени"}}
	}
	plovItem, teaItem, extra := uid(), uid(), uid()
	op(item(plovItem, plov, 2, 35000, "now", 1), 200, "add plov")
	op(item(teaItem, tea, 1, 6000, "later", 2), 200, "add tea")
	op(item(extra, plov, 1, 35000, "now", 0), 400, "bad guest")
	op(item(extra, plov, 1, 35000, "now", 3), 200, "add extra")
	op(map[string]any{"bill_id": b1, "kind": "remove", "item_id": extra}, 200, "remove new")
	bill = op(map[string]any{"bill_id": b1, "kind": "update", "item_id": teaItem, "qty": 2}, 200, "tea qty")
	if len(bill.Body["items"].([]any)) != 2 || bill.str("subtotal") != "82000.00" || bill.str("service") != "8200.00" || bill.str("total") != "90200.00" {
		t.Fatalf("bill after add = %v", bill.Body)
	}

	// На кухню: плов — сразу, чай — «по команде».
	bill = op(map[string]any{"bill_id": b1, "kind": "send"}, 200, "send")
	op(map[string]any{"bill_id": b1, "kind": "remove", "item_id": plovItem}, 409, "remove sent")
	board := a.expect(posDo(a, "GET", "/pos/kitchen/board", kdsTok, "", nil), 200, "board").Body["orders"].([]any)
	if len(board) != 2 {
		t.Fatalf("board = %v", board)
	}
	statuses := map[string]string{}
	var plovOrder string
	for _, x := range board {
		o := x.(map[string]any)
		if o["table_label"] != "7" || o["order_no"] != nil {
			t.Fatalf("bill order = %v", o)
		}
		statuses[o["status"].(string)] = o["id"].(string)
		if o["status"] == "new" {
			plovOrder = o["id"].(string)
		}
	}
	if statuses["new"] == "" || statuses["waiting"] == "" {
		t.Fatalf("statuses = %v", statuses)
	}
	op(map[string]any{"bill_id": b1, "kind": "fire"}, 200, "fire")
	a.expect(posDo(a, "POST", "/pos/kitchen/orders/"+plovOrder+"/action", kdsTok, "", map[string]any{"action": "start"}), 200, "start plov")

	// Отмена плова — только со старшим и причиной; кухня видит «ОТМЕНА».
	op(map[string]any{"bill_id": b1, "kind": "cancel", "item_id": plovItem, "qty": 1, "reason": "гость передумал"}, 403, "cancel without senior")
	op(map[string]any{"bill_id": b1, "kind": "cancel", "item_id": plovItem, "qty": 3, "reason": "x", "approver_id": owner}, 409, "cancel too many")
	bill = op(map[string]any{"bill_id": b1, "kind": "cancel", "item_id": plovItem, "qty": 1, "reason": "гость передумал", "approver_id": owner, "spoil": true}, 200, "cancel")
	for _, x := range bill.Body["items"].([]any) {
		it := x.(map[string]any)
		if it["id"] == plovItem && (it["cancelled_qty"] != "1" || it["kitchen"] != "cooking") {
			t.Fatalf("cancelled item = %v", it)
		}
	}
	if bill.str("subtotal") != "47000.00" {
		t.Fatalf("subtotal after cancel = %s", bill.str("subtotal"))
	}
	var kc string
	if err := pool.QueryRow(context.Background(), `SELECT trim_scale(cancelled_qty)::text FROM kitchen_ticket_items WHERE bill_item_id = $1`, plovItem).Scan(&kc); err != nil || kc != "1" {
		t.Fatalf("kitchen cancelled = %s %v", kc, err)
	}

	// Перенос на свободный стол 1; объединение со столом Т3.
	op(map[string]any{"bill_id": b1, "kind": "move", "to_table_id": tid["Т3"]}, 200, "move to T3")
	b2 := "11111111-0000-4000-8000-000000000002"
	op(map[string]any{"bill_id": b2, "kind": "open", "table_id": tid["7"], "guests": 2}, 200, "open b2 on 7")
	op(map[string]any{"bill_id": b1, "kind": "move", "to_table_id": tid["7"]}, 409, "move to busy")
	op(map[string]any{"bill_id": b2, "kind": "add", "item": map[string]any{"id": uid(), "product_id": tea, "qty": 1, "price": 6000}}, 200, "add tea b2")
	merged := op(map[string]any{"bill_id": b2, "kind": "merge", "to_bill_id": b1}, 200, "merge b2 → b1")
	if merged.str("id") != b1 || len(merged.Body["items"].([]any)) != 3 || merged.Body["guests"].(float64) != 6 {
		t.Fatalf("merged = %v", merged.Body)
	}
	op(map[string]any{"bill_id": b2, "kind": "guests", "guests": 2}, 409, "op on merged bill")

	// Часть блюд — за стол 1 (новый счёт).
	b3 := "11111111-0000-4000-8000-000000000003"
	moved := op(map[string]any{"bill_id": b1, "kind": "move_items", "to_table_id": tid["1"], "new_bill_id": b3,
		"items": []map[string]any{{"id": plovItem, "qty": 1}}}, 200, "move items")
	for _, x := range moved.Body["items"].([]any) {
		if it := x.(map[string]any); it["id"] == plovItem && it["qty"] != "1" {
			t.Fatalf("source after move = %v", it)
		}
	}
	h := a.expect(posDo(a, "GET", "/pos/hall", posTok, owner, nil), 200, "hall 2")
	bills := map[string]map[string]any{}
	for _, x := range h.Body["bills"].([]any) {
		b := x.(map[string]any)
		bills[b["id"].(string)] = b
	}
	if len(bills) != 2 || bills[b3] == nil || bills[b3]["table_number"] != "1" || bills[b3]["subtotal"] != "35000.00" {
		t.Fatalf("hall bills = %v", bills)
	}

	// Оплата счёта стола 1 целиком (с обслуживанием).
	pay := func(billID, client string, lines []map[string]any, service, total string, want int) resp {
		items := []map[string]any{}
		for _, l := range lines {
			items = append(items, l)
		}
		return a.expect(posDo(a, "POST", "/pos/sales", posTok, owner, map[string]any{
			"client_uid": client, "shift_id": shift, "bill_id": billID, "service_amount": service,
			"items": items, "payments": []map[string]any{{"payment_method_id": cash, "amount": total}},
		}), want, "pay "+client)
	}
	b3item := bills[b3]["items"].([]any)[0].(map[string]any)["id"].(string)
	line := func(id, product string, qty, price int) map[string]any {
		return map[string]any{"product_id": product, "qty": qty, "price": price, "bill_item_id": id}
	}
	pay(b3, "bill-pay-0001", []map[string]any{line(b3item, plov, 1, 35000)}, "9999.00", "44999.00", 400)
	pay(b3, "bill-pay-0002", []map[string]any{line(b3item, plov, 2, 35000)}, "7000.00", "77000.00", 409)
	s := pay(b3, "bill-pay-0003", []map[string]any{line(b3item, plov, 1, 35000)}, "3500.00", "38500.00", 201)
	if s.str("service_amount") != "3500.00" || s.str("total") != "38500.00" || s.str("bill_id") != b3 {
		t.Fatalf("sale = %v", s.Body)
	}
	pay(b3, "bill-pay-0004", []map[string]any{line(b3item, plov, 1, 35000)}, "3500.00", "38500.00", 409)

	// Счёт b1: разделить — гость платит за чай, остаток — второй гость.
	var teaB2 string
	for _, x := range bills[b1]["items"].([]any) {
		it := x.(map[string]any)
		if it["id"] != teaItem && it["id"] != plovItem {
			teaB2 = it["id"].(string)
		}
	}
	pay(b1, "bill-pay-0005", []map[string]any{line(teaItem, tea, 2, 6000)}, "1200.00", "13200.00", 201)
	h = a.expect(posDo(a, "GET", "/pos/hall", posTok, owner, nil), 200, "hall 3")
	if len(h.Body["bills"].([]any)) != 1 {
		t.Fatalf("bill closed too early: %v", h.Body["bills"])
	}
	op(map[string]any{"bill_id": b1, "kind": "void", "reason": "ушли", "approver_id": owner}, 409, "void partly paid")
	pay(b1, "bill-pay-0006", []map[string]any{line(teaB2, tea, 1, 6000)}, "600.00", "6600.00", 201)
	h = a.expect(posDo(a, "GET", "/pos/hall", posTok, owner, nil), 200, "hall 4")
	if len(h.Body["bills"].([]any)) != 0 {
		t.Fatalf("bills left = %v", h.Body["bills"])
	}

	// Закрыть без оплаты — старший и причина.
	b4 := "11111111-0000-4000-8000-000000000004"
	op(map[string]any{"bill_id": b4, "kind": "open", "table_id": tid["7"]}, 200, "open b4")
	op(map[string]any{"bill_id": b4, "kind": "add", "item": map[string]any{"id": uid(), "product_id": plov, "qty": 1, "price": 35000}}, 200, "add b4")
	op(map[string]any{"bill_id": b4, "kind": "send"}, 200, "send b4")
	op(map[string]any{"bill_id": b4, "kind": "void", "reason": "ушли"}, 403, "void without senior")
	v := op(map[string]any{"bill_id": b4, "kind": "void", "reason": "гость ушёл", "approver_id": owner}, 200, "void")
	if v.str("status") != "void" {
		t.Fatalf("void = %v", v.Body)
	}
	var cancelled int
	if err := pool.QueryRow(context.Background(), `SELECT count(*) FROM kitchen_tickets WHERE bill_id = $1 AND status = 'cancelled'`, b4).Scan(&cancelled); err != nil || cancelled != 1 {
		t.Fatalf("void kitchen = %d %v", cancelled, err)
	}
	// Пустой стол (на кухню ничего не ушло) закрывает сам официант, без причины.
	b7 := "11111111-0000-4000-8000-000000000007"
	op(map[string]any{"bill_id": b7, "kind": "open", "table_id": tid["7"]}, 200, "open b7")
	op(map[string]any{"bill_id": b7, "kind": "add", "item": map[string]any{"id": uid(), "product_id": plov, "qty": 1, "price": 35000}}, 200, "add b7")
	if v := op(map[string]any{"bill_id": b7, "kind": "void"}, 200, "void empty"); v.str("status") != "void" {
		t.Fatalf("void empty = %v", v.Body)
	}
	// Стол с открытым счётом не удалить.
	b5 := "11111111-0000-4000-8000-000000000005"
	op(map[string]any{"bill_id": b5, "kind": "open", "table_id": tid["1"]}, 200, "open b5")
	a.expect(a.do("PUT", "/store/cafe/halls", tok, map[string]any{"store_id": store, "halls": []map[string]any{
		{"id": lay[0]["id"], "name": "Зал", "tables": []map[string]any{}},
	}}), 409, "delete busy table")

	// Нагрузка: три кассы одновременно дописывают один счёт, каждая шлёт
	// каждую операцию дважды (повтор после обрыва) — ничего не теряется и не
	// дублируется.
	b6 := "11111111-0000-4000-8000-000000000006"
	op(map[string]any{"bill_id": b6, "kind": "open", "table_id": tid["Т3"]}, 200, "open b6")
	var wg sync.WaitGroup
	var mu sync.Mutex
	failed := []int{}
	for dev := 0; dev < 3; dev++ {
		wg.Add(1)
		go func(dev int) {
			defer wg.Done()
			for i := 0; i < 15; i++ {
				opID := fmt.Sprintf("00000000-0000-4000-9%03d-%012d", dev, i)
				itemID := fmt.Sprintf("00000000-0000-4000-a%03d-%012d", dev, i)
				body := map[string]any{"id": opID, "bill_id": b6, "kind": "add",
					"item": map[string]any{"id": itemID, "product_id": tea, "qty": 1, "price": 6000}}
				for rep := 0; rep < 2; rep++ {
					r := posDo(a, "POST", "/pos/bills/ops", posTok, owner, body)
					if r.Status != 200 {
						mu.Lock()
						failed = append(failed, r.Status)
						mu.Unlock()
					}
				}
			}
		}(dev)
	}
	wg.Wait()
	if len(failed) > 0 {
		t.Fatalf("concurrent ops failed: %v", failed)
	}
	var items, seqs int
	if err := pool.QueryRow(context.Background(), `SELECT count(*), count(DISTINCT seq) FROM bill_items WHERE bill_id = $1`, b6).Scan(&items, &seqs); err != nil {
		t.Fatal(err)
	}
	if items != 45 || seqs != 45 {
		t.Fatalf("items = %d, distinct seq = %d", items, seqs)
	}
}

// Этап 6: официант в телефоне — право cafe.waiter, свои столы, приём заказа
// с гостями и «по команде», печать бегунка через кассу, «Несу», передача
// стола (принять / отклонить / просрочено), зоны на смену, «Мои продажи»,
// push-уведомления, конфликт версий.
func TestCafeWaiter(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	a.expect(a.do("POST", "/admin/networks", adminTok, map[string]any{
		"name": "Кафе", "kind": "single", "owner_phone": "+998900000002", "owner_name": "В", "business_type": "cafe",
	}), 201, "cafe")
	tok, _ := a.login("+998900000002", identity.AppStore)
	store := a.expect(a.do("POST", "/store/stores", tok, map[string]any{"name": "Кафе 1"}), 201, "store").str("id")
	hot := a.expect(a.do("POST", "/store/cafe/menu-groups", tok, map[string]any{"name": "Горячее"}), 201, "hot").str("id")
	plov := a.expect(a.do("POST", "/store/cafe/dishes", tok, map[string]any{
		"kind": "dish", "name": "Плов", "price": 35000, "menu_code": 12, "menu_group_id": hot, "ikpu": "10202001001000000",
	}), 201, "plov").str("id")
	tea := a.expect(a.do("POST", "/store/cafe/dishes", tok, map[string]any{
		"kind": "dish", "name": "Чай", "price": 6000, "menu_code": 40, "menu_group_id": hot, "ikpu": "10202001001000000",
	}), 201, "tea").str("id")
	a.expect(a.do("PATCH", "/store/cafe/settings", tok, map[string]any{"cafe_mode": "tables", "service_percent": "10", "waiter_own_tables": true}), 200, "settings")
	table := func(n string, x int) map[string]any {
		return map[string]any{"number": n, "seats": 4, "shape": "rect", "x": x, "y": 0, "w": 2, "h": 2}
	}
	lay := a.expect(a.do("PUT", "/store/cafe/halls", tok, map[string]any{"store_id": store, "halls": []map[string]any{
		{"name": "Зал", "tables": []map[string]any{table("1", 0), table("2", 3), table("3", 6)}},
	}}), 200, "layout").items()
	tid := map[string]string{}
	for _, x := range lay[0]["tables"].([]any) {
		tt := x.(map[string]any)
		tid[tt["number"].(string)] = tt["id"].(string)
	}

	// Официанты: Азиз и Дилноза (право cafe.waiter), продавец без права.
	roleW := a.expect(a.do("POST", "/store/roles", tok, map[string]any{"name": "Официант", "permissions": []string{identity.PermCafeWaiter}}), 201, "role").str("id")
	roleS := a.expect(a.do("POST", "/store/roles", tok, map[string]any{"name": "Продавец", "permissions": []string{identity.PermSalesPOS}}), 201, "role seller").str("id")
	aziz := a.expect(a.do("POST", "/store/employees", tok, map[string]any{"phone": "+998900000301", "full_name": "Азиз", "role_id": roleW, "store_ids": []string{store}}), 201, "aziz").str("id")
	dil := a.expect(a.do("POST", "/store/employees", tok, map[string]any{"phone": "+998900000302", "full_name": "Дилноза", "role_id": roleW, "store_ids": []string{store}}), 201, "dil").str("id")
	a.expect(a.do("POST", "/store/employees", tok, map[string]any{"phone": "+998900000303", "full_name": "Продавец", "role_id": roleS, "store_ids": []string{store}}), 201, "seller")
	azizTok, _ := a.login("+998900000301", identity.AppStore)
	dilTok, _ := a.login("+998900000302", identity.AppStore)
	sellerTok, _ := a.login("+998900000303", identity.AppStore)
	for _, e := range []string{aziz, dil} {
		if _, err := pool.Exec(context.Background(), `INSERT INTO devices (user_id, token, platform, app)
			SELECT user_id, 'waiter-'||$1::text, 'android', 'store' FROM employees WHERE id = $1::uuid`, e); err != nil {
			t.Fatal(err)
		}
	}
	pushes := func(employee string) []string {
		rows, err := pool.Query(context.Background(), `SELECT o.title FROM notifications_outbox o JOIN employees e ON e.user_id = o.user_id
			WHERE e.id = $1 AND o.kind = 'staff_notice' ORDER BY o.created_at, o.title`, employee)
		if err != nil {
			t.Fatal(err)
		}
		list, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			t.Fatal(err)
		}
		return list
	}

	a.expect(a.do("GET", "/store/cafe/waiter/hall", sellerTok, nil), 403, "no permission")
	hall := a.expect(a.do("GET", "/store/cafe/waiter/hall", azizTok, nil), 200, "hall")
	if hall.str("store_id") != store || hall.str("me") != aziz || hall.Body["senior"] != false || hall.Body["waiter_own_tables"] != true ||
		len(hall.Body["tables"].([]any)) != 3 || len(hall.Body["bills"].([]any)) != 0 {
		t.Fatalf("hall = %v", hall.Body)
	}
	menu := a.expect(a.do("GET", "/store/cafe/waiter/menu?store_id="+store, azizTok, nil), 200, "menu")
	if len(menu.Body["dishes"].([]any)) != 2 || menu.str("mode") != "tables" || len(menu.Body["items"].([]any)) != 2 {
		t.Fatalf("menu = %v", menu.Body)
	}
	for _, x := range menu.Body["items"].([]any) {
		it := x.(map[string]any)
		if (it["product_id"] == plov && (it["name"] != "Плов" || it["price"] != "35000.00")) || (it["product_id"] == tea && it["price"] != "6000.00") {
			t.Fatalf("menu item = %v", it)
		}
	}
	ws := a.expect(a.do("GET", "/store/cafe/waiter/waiters", azizTok, nil), 200, "waiters").items()
	if len(ws) != 3 { // владелец + два официанта
		t.Fatalf("waiters = %v", ws)
	}

	n := 0
	uid := func() string {
		n++
		return fmt.Sprintf("00000000-0000-4000-8000-%012d", n)
	}
	op := func(tok string, body map[string]any, want int, what string) resp {
		if _, ok := body["id"]; !ok {
			body["id"] = uid()
		}
		return a.expect(a.do("POST", "/store/cafe/waiter/ops?store_id="+store, tok, body), want, what)
	}
	// Зоны на смену: только старший (владелец).
	a.expect(a.do("PUT", "/store/cafe/waiter/zones", azizTok, map[string]any{"store_id": store,
		"assignments": []map[string]any{{"table_id": tid["2"], "waiter_id": dil}}}), 403, "zones by waiter")
	a.expect(a.do("PUT", "/store/cafe/waiter/zones", tok, map[string]any{"store_id": store,
		"assignments": []map[string]any{{"table_id": tid["2"], "waiter_id": "x"}}}), 400, "zones bad waiter")
	// Владелец — без права cafe.waiter в роли, но владелец может всё.
	z := a.expect(a.do("PUT", "/store/cafe/waiter/zones", tok, map[string]any{"store_id": store,
		"assignments": []map[string]any{{"table_id": tid["2"], "waiter_id": dil}, {"table_id": tid["3"], "waiter_id": dil}}}), 200, "zones")
	if z.Body["senior"] != true {
		t.Fatalf("owner senior = %v", z.Body)
	}
	for _, x := range z.Body["tables"].([]any) {
		tt := x.(map[string]any)
		if (tt["number"] == "2" || tt["number"] == "3") && tt["waiter_id"] != dil {
			t.Fatalf("zone table = %v", tt)
		}
	}

	// Азиз открывает стол 1 — стол его (О5); стол 2 — кассир на Дилнозу (push ей).
	b1, b2 := "11111111-0000-4000-8000-000000000001", "11111111-0000-4000-8000-000000000002"
	open := map[string]any{"id": uid(), "bill_id": b1, "kind": "open", "table_id": tid["1"], "guests": 3, "comment": " детский стул "}
	bill := op(azizTok, open, 200, "open")
	if bill.str("waiter_id") != aziz || bill.Body["mine"] != true || bill.Body["guests"].(float64) != 3 || bill.str("comment") != "детский стул" {
		t.Fatalf("bill = %v", bill.Body)
	}
	op(azizTok, open, 200, "open again")
	d := a.expect(a.do("POST", "/store/pos/devices", tok, map[string]any{"store_id": store, "name": "Касса"}), 201, "device")
	posTok := a.expect(a.do("POST", "/pos/activate", "", map[string]any{"code": d.str("activation_code")}), 200, "activate").str("token")
	var owner string
	for _, e := range a.expect(a.do("GET", "/store/employees", tok, nil), 200, "employees").items() {
		if e["full_name"] == "В" {
			owner = e["id"].(string)
		}
	}
	a.expect(a.do("PUT", "/store/pos/pins/"+owner, tok, map[string]any{"pin": "9999"}), 200, "pin")
	a.expect(posDo(a, "POST", "/pos/shifts", posTok, owner, map[string]any{"client_uid": "shift-w-01"}), 201, "shift")
	// Касса открывает стол 2: официант — Дилноза из зоны на смену.
	pb := a.expect(posDo(a, "POST", "/pos/bills/ops", posTok, owner, map[string]any{"id": uid(), "bill_id": b2, "kind": "open", "table_id": tid["2"], "guests": 2}), 200, "pos open")
	if pb.str("waiter_id") != dil {
		t.Fatalf("pos bill waiter = %v", pb.Body)
	}
	if got := pushes(dil); len(got) != 1 || got[0] != "Стол 2 открыт" {
		t.Fatalf("dil pushes = %v", got)
	}

	// Азизу чужой стол 2 — серый: без позиций, нельзя добавить; «попросить» — push Дилнозе.
	hall = a.expect(a.do("GET", "/store/cafe/waiter/hall", azizTok, nil), 200, "hall 2")
	for _, x := range hall.Body["bills"].([]any) {
		b := x.(map[string]any)
		if b["id"] == b2 && (b["mine"] != false || b["subtotal"] != "" || len(b["items"].([]any)) != 0) {
			t.Fatalf("foreign bill = %v", b)
		}
	}
	// guest 0 — «Всем»: поле не передаётся (блюдо на стол).
	add := func(billID, id, product string, qty int, course string, guest int) map[string]any {
		item := map[string]any{"id": id, "product_id": product, "qty": qty, "price": 35000, "course": course}
		if guest > 0 {
			item["guest"] = guest
		}
		return map[string]any{"bill_id": billID, "kind": "add", "item": item}
	}
	op(azizTok, add(b2, uid(), plov, 1, "now", 1), 403, "add to foreign")
	op(azizTok, map[string]any{"bill_id": b2, "kind": "cancel", "item_id": uid()}, 403, "cancel from phone")
	op(azizTok, map[string]any{"bill_id": b2, "kind": "request"}, 200, "request table")
	if got := pushes(dil); len(got) != 2 || got[1] != "Азиз просит стол 2" {
		t.Fatalf("dil pushes = %v", got)
	}

	// Приём заказа: плов Г1 и Г2 сразу, чай — всем, по команде.
	plovItem, teaItem := uid(), uid()
	op(azizTok, add(b1, plovItem, plov, 2, "now", 1), 200, "add plov")
	op(azizTok, add(b1, teaItem, tea, 3, "later", 0), 200, "add tea")
	bill = op(azizTok, map[string]any{"bill_id": b1, "kind": "update", "item_id": teaItem, "guest": 2}, 200, "tea guest")
	v := int(bill.Body["version"].(float64))
	stale := v - 1
	op(azizTok, map[string]any{"bill_id": b1, "kind": "guests", "guests": 4, "expected_version": stale}, 409, "stale version")
	bill = op(azizTok, map[string]any{"bill_id": b1, "kind": "guests", "guests": 4, "expected_version": v}, 200, "fresh version")
	op(azizTok, map[string]any{"bill_id": b1, "kind": "serve", "item_id": plovItem}, 409, "serve before send")
	bill = op(azizTok, map[string]any{"bill_id": b1, "kind": "send"}, 200, "send")
	// Экрана кухни нет — бегунок ждёт печати на кассе.
	st := a.expect(posDo(a, "GET", "/pos/kitchen/status", posTok, owner, nil), 200, "status")
	// Две отправки: «сразу» и «по команде» — по бегунку в каждой.
	pr := st.Body["print"].([]any)
	if len(pr) != 2 {
		t.Fatalf("print = %v", pr)
	}
	var ticketIDs []string
	for _, o := range pr {
		for _, x := range o.(map[string]any)["tickets"].([]any) {
			tk := x.(map[string]any)
			// Плов — сразу (выдан, печатает касса), чай — «по команде» (ждёт).
			if tk["print_pending"] != true || tk["print_kind"] != "send" || (tk["status"] != "served" && tk["status"] != "waiting") {
				t.Fatalf("print ticket = %v", tk)
			}
			ticketIDs = append(ticketIDs, tk["id"].(string))
		}
	}
	if len(ticketIDs) != 2 {
		t.Fatalf("print tickets = %v", ticketIDs)
	}
	a.expect(posDo(a, "POST", "/pos/kitchen/printed", posTok, owner, map[string]any{"ticket_ids": ticketIDs}), 200, "printed")
	if st = a.expect(posDo(a, "GET", "/pos/kitchen/status", posTok, owner, nil), 200, "status 2"); len(st.Body["print"].([]any)) != 0 {
		t.Fatalf("print after = %v", st.Body["print"])
	}
	// Без экрана «по команде» всё равно ждёт команды — у официанта виден «Подать горячее».
	bill = a.expect(a.do("GET", "/store/cafe/waiter/hall", azizTok, nil), 200, "hall waiting")
	waitingSeen := false
	for _, x := range bill.Body["bills"].([]any) {
		if bb := x.(map[string]any); bb["id"] == b1 {
			for _, y := range bb["items"].([]any) {
				if it := y.(map[string]any); it["id"] == teaItem && it["kitchen"] == "waiting" {
					waitingSeen = true
				}
			}
		}
	}
	if !waitingSeen {
		t.Fatalf("tea not waiting: %v", bill.Body["bills"])
	}
	op(azizTok, map[string]any{"bill_id": b1, "kind": "fire"}, 200, "fire")
	// «ПОДАВАТЬ» — снова в очередь печати кассы.
	st = a.expect(posDo(a, "GET", "/pos/kitchen/status", posTok, owner, nil), 200, "status fire")
	pr = st.Body["print"].([]any)
	if len(pr) != 1 {
		t.Fatalf("print fire = %v", pr)
	}
	fireTk := pr[0].(map[string]any)["tickets"].([]any)
	if len(fireTk) != 1 || fireTk[0].(map[string]any)["print_kind"] != "fire" || fireTk[0].(map[string]any)["status"] != "served" {
		t.Fatalf("fire ticket = %v", fireTk)
	}
	a.expect(posDo(a, "POST", "/pos/kitchen/printed", posTok, owner, map[string]any{"ticket_ids": []string{fireTk[0].(map[string]any)["id"].(string)}}), 200, "printed fire")
	bill = op(azizTok, map[string]any{"bill_id": b1, "kind": "serve", "item_id": plovItem}, 200, "serve")
	for _, x := range bill.Body["items"].([]any) {
		it := x.(map[string]any)
		if it["id"] == plovItem && (it["served_at"] == nil || it["kitchen"] != "served") {
			t.Fatalf("served item = %v", it)
		}
	}

	// Готово на кухне → push официанту стола.
	k := a.expect(a.do("POST", "/store/pos/devices", tok, map[string]any{"store_id": store, "name": "Кухня", "kind": "kitchen"}), 201, "kds")
	kdsTok := a.expect(a.do("POST", "/pos/activate", "", map[string]any{"code": k.str("activation_code")}), 200, "activate kds").str("token")
	b3 := "11111111-0000-4000-8000-000000000003"
	op(dilTok, map[string]any{"id": uid(), "bill_id": b3, "kind": "open", "table_id": tid["3"]}, 200, "dil opens 3")
	op(dilTok, add(b3, uid(), plov, 1, "now", 1), 200, "dil adds")
	op(dilTok, map[string]any{"bill_id": b3, "kind": "send"}, 200, "dil sends")
	board := a.expect(posDo(a, "GET", "/pos/kitchen/board", kdsTok, "", nil), 200, "board").Body["orders"].([]any)
	var key string
	for _, x := range board {
		if o := x.(map[string]any); o["bill_id"] == b3 {
			key = o["id"].(string)
		}
	}
	if key == "" {
		t.Fatalf("board = %v", board)
	}
	a.expect(posDo(a, "POST", "/pos/kitchen/orders/"+key+"/action", kdsTok, "", map[string]any{"action": "ready"}), 200, "ready")
	if got := pushes(dil); len(got) != 3 || got[2] != "Стол 3: готово — заберите" {
		t.Fatalf("dil pushes = %v", got)
	}

	// Передача стола 1 Дилнозе: отклонила → стол у Азиза; снова → приняла.
	op(dilTok, map[string]any{"bill_id": b1, "kind": "transfer", "to_waiter_id": aziz}, 403, "transfer foreign")
	op(azizTok, map[string]any{"bill_id": b1, "kind": "transfer", "to_waiter_id": aziz}, 400, "transfer to self")
	bill = op(azizTok, map[string]any{"bill_id": b1, "kind": "transfer", "to_waiter_id": dil, "reason": "ухожу на перерыв"}, 200, "transfer")
	if bill.str("transfer_to") != dil || bill.str("transfer_from") != aziz || bill.str("transfer_reason") != "ухожу на перерыв" || bill.str("waiter_id") != aziz {
		t.Fatalf("transfer = %v", bill.Body)
	}
	op(azizTok, map[string]any{"bill_id": b1, "kind": "accept"}, 409, "accept by sender")
	bill = op(dilTok, map[string]any{"bill_id": b1, "kind": "decline"}, 200, "decline")
	if bill.Body["transfer_to"] != nil || bill.str("waiter_id") != aziz {
		t.Fatalf("after decline = %v", bill.Body)
	}
	op(azizTok, map[string]any{"bill_id": b1, "kind": "transfer", "to_waiter_id": dil}, 200, "transfer 2")
	// Просрочено — 3 минуты прошли.
	if _, err := pool.Exec(context.Background(), `UPDATE bills SET transfer_at = now() - interval '4 minutes' WHERE id = $1`, b1); err != nil {
		t.Fatal(err)
	}
	op(dilTok, map[string]any{"bill_id": b1, "kind": "accept"}, 409, "accept expired")
	op(azizTok, map[string]any{"bill_id": b1, "kind": "transfer", "to_waiter_id": dil}, 200, "transfer 3")
	bill = op(dilTok, map[string]any{"bill_id": b1, "kind": "accept"}, 200, "accept")
	if bill.str("waiter_id") != dil || bill.Body["mine"] != true || bill.Body["transfer_to"] != nil {
		t.Fatalf("after accept = %v", bill.Body)
	}
	if got := pushes(aziz); len(got) != 2 || got[0] != "Стол 1 остался у вас" || got[1] != "Стол 1 передан" {
		t.Fatalf("aziz pushes = %v", got)
	}
	op(azizTok, add(b1, uid(), plov, 1, "now", 1), 403, "add after handover")

	// Пустой стол без официанта: «взять» и закрыть без оплаты самому.
	b4 := "11111111-0000-4000-8000-000000000004"
	a.expect(posDo(a, "POST", "/pos/bills/ops", posTok, owner, map[string]any{"id": uid(), "bill_id": b4, "kind": "open", "table_id": tid["1"]}), 409, "table 1 busy")
	op(dilTok, map[string]any{"bill_id": b1, "kind": "void"}, 400, "void with sent items needs reason")
	op(dilTok, map[string]any{"bill_id": b1, "kind": "void", "reason": "гости ушли"}, 403, "void with sent items needs senior")
	bill = op(tok, map[string]any{"bill_id": b1, "kind": "void", "reason": "гости ушли"}, 200, "owner voids")
	if bill.str("status") != "void" {
		t.Fatalf("void = %v", bill.Body)
	}
	a.expect(posDo(a, "POST", "/pos/bills/ops", posTok, owner, map[string]any{"id": uid(), "bill_id": b4, "kind": "open", "table_id": tid["1"], "waiter_id": ""}), 200, "open without waiter")
	bill = op(azizTok, map[string]any{"bill_id": b4, "kind": "take"}, 200, "take")
	if bill.str("waiter_id") != aziz {
		t.Fatalf("take = %v", bill.Body)
	}
	op(dilTok, map[string]any{"bill_id": b4, "kind": "take"}, 409, "take taken")
	bill = op(azizTok, map[string]any{"bill_id": b4, "kind": "void"}, 200, "void empty")
	if bill.str("status") != "void" {
		t.Fatalf("void empty = %v", bill.Body)
	}

	// Ожидание событий: версия уже больше — ответ сразу.
	w := a.expect(a.do("GET", "/store/cafe/waiter/wait?store_id="+store+"&v=0", azizTok, nil), 200, "wait")
	if w.Body["version"].(float64) < 1 {
		t.Fatalf("wait = %v", w.Body)
	}

	// Мои продажи: оплата стола 3 на кассе — в отчёте Дилнозы.
	cat := a.expect(posDo(a, "GET", "/pos/catalog", posTok, "", nil), 200, "catalog")
	var cash string
	for _, x := range cat.Body["payment_methods"].([]any) {
		if m := x.(map[string]any); m["kind"] == "cash" {
			cash = m["id"].(string)
		}
	}
	shift := sqlStr(t, pool, `SELECT id::text FROM pos_shifts WHERE closed_at IS NULL LIMIT 1`)
	b3bill := a.expect(a.do("GET", "/store/cafe/waiter/hall", dilTok, nil), 200, "hall dil")
	var b3item string
	for _, x := range b3bill.Body["bills"].([]any) {
		if b := x.(map[string]any); b["id"] == b3 {
			b3item = b["items"].([]any)[0].(map[string]any)["id"].(string)
		}
	}
	a.expect(posDo(a, "POST", "/pos/sales", posTok, owner, map[string]any{
		"client_uid": "w-pay-0001", "shift_id": shift, "bill_id": b3, "service_amount": "3500.00",
		"items":    []map[string]any{{"product_id": plov, "qty": 1, "price": 35000, "bill_item_id": b3item}},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": "38500.00"}},
	}), 201, "pay b3")
	ms := a.expect(a.do("GET", "/store/cafe/waiter/my-sales?store_id="+store, dilTok, nil), 200, "my sales")
	if ms.Body["bills"].(float64) != 1 || ms.str("total") != "38500.00" || ms.str("service") != "3500.00" || ms.Body["open"].(float64) != 1 {
		t.Fatalf("my sales = %v", ms.Body)
	}
	a.expect(a.do("GET", "/store/cafe/waiter/my-sales?store_id="+store+"&date=2026-1-1", dilTok, nil), 400, "bad date")

	// «Как вчера»: вчерашние зоны → сегодня.
	if _, err := pool.Exec(context.Background(), `UPDATE cafe_shift_waiters SET day = day - 1`); err != nil {
		t.Fatal(err)
	}
	z = a.expect(a.do("PUT", "/store/cafe/waiter/zones", tok, map[string]any{"store_id": store, "like_yesterday": true}), 200, "like yesterday")
	zones := 0
	for _, x := range z.Body["tables"].([]any) {
		if x.(map[string]any)["waiter_id"] == dil {
			zones++
		}
	}
	if zones != 2 {
		t.Fatalf("like yesterday tables = %v", z.Body["tables"])
	}
}
