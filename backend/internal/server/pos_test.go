package server_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/pos"
	"github.com/sanedidi/super-market/backend/internal/summary"
)

// posDo — запрос кассы: токен устройства и (если есть) кассир в заголовке.
func posDo(a api, method, path, token, cashier string, body any) resp {
	a.t.Helper()
	var rdr io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rdr = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, a.srv.URL+"/api/v1"+path, rdr)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if cashier != "" {
		req.Header.Set("X-Cashier-ID", cashier)
	}
	res, err := a.srv.Client().Do(req)
	if err != nil {
		a.t.Fatal(err)
	}
	defer res.Body.Close()
	out := resp{Status: res.StatusCode, Body: map[string]any{}}
	_ = json.NewDecoder(res.Body).Decode(&out.Body)
	return out
}

func TestPOS(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, sugar := catalogBasics(t, a, adminTok)
	// Товар центральной базы с базовой ценой, которого магазин не добавлял, — не на кассе.
	foreign := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
		"name": "Fanta 1 л", "category_id": a.expect(a.do("GET", "/admin/products/"+cola, adminTok, nil), 200, "cola").str("category_id"),
		"unit_id": a.expect(a.do("GET", "/admin/products/"+cola, adminTok, nil), 200, "cola").str("unit_id"), "base_price": 9000,
	}), 201, "foreign product").str("id")
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
	doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "posting", "warehouse_id": wh,
		"items": []map[string]any{{"product_id": cola, "qty": 10, "price": 10000}, {"product_id": sugar, "qty": 5, "price": 8000}},
	}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post posting")

	// Налоговые поля: общий товар правит супер-админ, сеть — только свои.
	a.expect(a.do("PUT", "/admin/pos/products/"+cola+"/tax", adminTok, map[string]any{
		"ikpu": "02202001001000000", "vat_rate": 12, "marked": true,
	}), 200, "admin tax")
	a.expect(a.do("PUT", "/store/pos/products/"+cola+"/tax", tok, map[string]any{"ikpu": "1"}), 400, "bad ikpu")
	a.expect(a.do("PUT", "/store/pos/products/"+cola+"/tax", tok, map[string]any{"vat_rate": 0}), 404, "network edits platform product")
	// Короткий код: бананы/сахар — 10; тот же код второму товару нельзя.
	a.expect(a.do("PUT", "/store/pos/products/"+sugar+"/plu", tok, map[string]any{"plu": 10}), 200, "plu")
	a.expect(a.do("PUT", "/store/pos/products/"+cola+"/plu", tok, map[string]any{"plu": 10}), 409, "plu taken")

	// Касса: создаём в панели, активируем кодом.
	dev := a.expect(a.do("POST", "/store/pos/devices", tok, map[string]any{"store_id": store, "name": "Касса 1"}), 201, "device")
	code := dev.str("activation_code")
	if len(code) != 9 || dev.str("status") != "waiting" {
		t.Fatalf("device = %v", dev.Body)
	}
	a.expect(a.do("POST", "/pos/activate", "", map[string]any{"code": "2222-2222"}), 400, "wrong code")
	act := a.expect(a.do("POST", "/pos/activate", "", map[string]any{"code": code, "app_version": "0.1.0"}), 200, "activate")
	dt := act.str("token")
	if act.str("store_id") != store || dt == "" {
		t.Fatalf("activation = %v", act.Body)
	}
	a.expect(a.do("POST", "/pos/activate", "", map[string]any{"code": code}), 400, "code reused")
	a.expect(posDo(a, "GET", "/pos/catalog", "pd_wrong", "", nil), 401, "wrong device token")
	a.expect(posDo(a, "GET", "/pos/catalog", tok, "", nil), 401, "store token on pos")

	// Каталог: цены, ИКПУ, маркировка, PLU, способы оплаты; кассиров с ПИНом пока нет.
	cat := a.expect(posDo(a, "GET", "/pos/catalog", dt, "", nil), 200, "catalog")
	prods := map[string]map[string]any{}
	for _, x := range cat.Body["products"].([]any) {
		m := x.(map[string]any)
		prods[m["id"].(string)] = m
	}
	if p := prods[cola]; p["price"] != "15000.00" || p["ikpu"] != "02202001001000000" || p["marked"] != true || p["vat_rate"] != "12.00" {
		t.Fatalf("cola in catalog = %v", p)
	}
	if p := prods[sugar]; p["plu"].(float64) != 10 || p["fractional"] != true {
		t.Fatalf("sugar in catalog = %v", p)
	}
	if _, ok := prods[foreign]; ok {
		t.Fatalf("central product the store never added is on the register: %v", prods[foreign])
	}
	if len(cat.Body["cashiers"].([]any)) != 0 {
		t.Fatalf("cashiers without pin = %v", cat.Body["cashiers"])
	}
	var cash, card string
	for _, x := range cat.Body["payment_methods"].([]any) {
		m := x.(map[string]any)
		switch m["kind"] {
		case "cash":
			cash = m["id"].(string)
		case "card":
			card = m["id"].(string)
		}
	}
	if cash == "" || card == "" {
		t.Fatalf("payment methods = %v", cat.Body["payment_methods"])
	}
	// Дельта: ничего не менялось — пусто; поменяли цену — пришёл только этот товар.
	ver := cat.str("version")
	time.Sleep(10 * time.Millisecond)
	// Делаем вид, что каталог менялся давно (триггеры updated_at на время выключаем).
	for _, q := range []string{
		`ALTER TABLE products DISABLE TRIGGER products_updated_at`,
		`UPDATE products SET updated_at = now() - interval '2 hours'`,
		`ALTER TABLE products ENABLE TRIGGER products_updated_at`,
		`ALTER TABLE units DISABLE TRIGGER units_updated_at`,
		`UPDATE units SET updated_at = now() - interval '2 hours'`,
		`ALTER TABLE units ENABLE TRIGGER units_updated_at`,
		`ALTER TABLE pos_plu DISABLE TRIGGER pos_plu_updated_at`,
		`UPDATE pos_plu SET updated_at = now() - interval '2 hours'`,
		`ALTER TABLE pos_plu ENABLE TRIGGER pos_plu_updated_at`,
		`UPDATE store_products SET added_at = now() - interval '2 hours'`,
		`UPDATE prices SET updated_at = now() - interval '2 hours'`,
	} {
		if _, err := pool.Exec(context.Background(), q); err != nil {
			t.Fatal(err)
		}
	}
	if d := a.expect(posDo(a, "GET", "/pos/catalog?since="+ver, dt, "", nil), 200, "delta"); len(d.Body["products"].([]any)) != 0 || d.Body["full"] != false {
		t.Fatalf("empty delta = %v", d.Body["products"])
	}
	// Лёгкая проверка: ничего не менялось — false.
	if c := a.expect(posDo(a, "GET", "/pos/catalog/changed?since="+ver, dt, "", nil), 200, "changed: nothing"); c.Body["changed"] != false {
		t.Fatalf("changed without changes = %v", c.Body)
	}
	a.expect(posDo(a, "GET", "/pos/catalog/changed?since=bad", dt, "", nil), 400, "changed: bad since")
	a.expect(a.do("PUT", "/admin/pos/products/"+sugar+"/tax", adminTok, map[string]any{"package_code": "1500"}), 200, "touch sugar")
	if d := a.expect(posDo(a, "GET", "/pos/catalog?epoch=1&since="+ver, dt, "", nil), 200, "old epoch"); d.Body["full"] != true || d.Body["epoch"] != float64(pos.CatalogEpoch) {
		t.Fatalf("old epoch = %v", d.Body["full"])
	}
	if d := a.expect(posDo(a, "GET", "/pos/catalog?since="+ver, dt, "", nil), 200, "delta"); len(d.Body["products"].([]any)) != 1 {
		t.Fatalf("delta after change = %v", d.Body["products"])
	}
	if c := a.expect(posDo(a, "GET", "/pos/catalog/changed?since="+ver, dt, "", nil), 200, "changed: product"); c.Body["changed"] != true {
		t.Fatalf("changed after product touch = %v", c.Body)
	}
	// Цену колы поменяли в панели магазина («Установка цен») — касса узнаёт
	// об этом лёгкой проверкой и получает новую цену в изменениях.
	for _, q := range []string{
		`ALTER TABLE products DISABLE TRIGGER products_updated_at`,
		`UPDATE products SET updated_at = now() - interval '2 hours'`,
		`ALTER TABLE products ENABLE TRIGGER products_updated_at`,
		`UPDATE prices SET updated_at = now() - interval '2 hours'`,
	} {
		if _, err := pool.Exec(context.Background(), q); err != nil {
			t.Fatal(err)
		}
	}
	if c := a.expect(posDo(a, "GET", "/pos/catalog/changed?since="+ver, dt, "", nil), 200, "changed: aged"); c.Body["changed"] != false {
		t.Fatalf("changed after aging = %v", c.Body)
	}
	pts := a.expect(a.do("GET", "/store/price-types", tok, nil), 200, "price types").items()
	pd := a.expect(a.do("POST", "/store/price-documents", tok, map[string]any{
		"price_type_id": pts[0]["id"], "store_id": store, "items": []map[string]any{{"product_id": cola, "new_price": 16500}},
	}), 201, "price doc")
	a.expect(a.do("POST", "/store/price-documents/"+pd.str("id")+"/post", tok, nil), 200, "post price")
	if c := a.expect(posDo(a, "GET", "/pos/catalog/changed?since="+ver, dt, "", nil), 200, "changed: price"); c.Body["changed"] != true {
		t.Fatalf("changed after price doc = %v", c.Body)
	}
	if d := a.expect(posDo(a, "GET", "/pos/catalog?since="+ver, dt, "", nil), 200, "delta: price"); len(d.Body["products"].([]any)) != 1 ||
		d.Body["products"].([]any)[0].(map[string]any)["price"] != "16500.00" {
		t.Fatalf("delta after price doc = %v", d.Body["products"])
	}
	pd = a.expect(a.do("POST", "/store/price-documents", tok, map[string]any{
		"price_type_id": pts[0]["id"], "store_id": store, "items": []map[string]any{{"product_id": cola, "new_price": 15000}},
	}), 201, "price doc back")
	a.expect(a.do("POST", "/store/price-documents/"+pd.str("id")+"/post", tok, nil), 200, "post price back")

	// Кассир с ПИНом. Одинаковый ПИН второму сотруднику не дадим.
	role := a.expect(a.do("POST", "/store/roles", tok, map[string]any{
		"name": "Кассир", "permissions": []string{identity.PermSalesPOS},
	}), 201, "role").str("id")
	cashier := a.expect(a.do("POST", "/store/employees", tok, map[string]any{
		"phone": "+998900000006", "full_name": "Дилноза", "role_id": role, "store_ids": []string{store},
	}), 201, "cashier").str("id")
	var owner string
	for _, e := range a.expect(a.do("GET", "/store/employees", tok, nil), 200, "employees").items() {
		if e["id"] != cashier {
			owner = e["id"].(string)
		}
	}
	a.expect(a.do("PUT", "/store/pos/pins/"+cashier, tok, map[string]any{"pin": "12a4"}), 400, "bad pin")
	a.expect(a.do("PUT", "/store/pos/pins/"+cashier, tok, map[string]any{"pin": "12345"}), 400, "pin longer than 4")
	a.expect(a.do("PUT", "/store/pos/pins/"+cashier, tok, map[string]any{"pin": "123"}), 400, "pin shorter than 4")
	a.expect(a.do("PUT", "/store/pos/pins/"+cashier, tok, map[string]any{"pin": "1234"}), 200, "pin")
	a.expect(a.do("PUT", "/store/pos/pins/"+owner, tok, map[string]any{"pin": "1234"}), 409, "pin taken")
	a.expect(a.do("PUT", "/store/pos/pins/"+owner, tok, map[string]any{"pin": "9999"}), 200, "owner pin")
	pins := a.expect(a.do("GET", "/store/pos/pins?store_id="+store, tok, nil), 200, "list pins").items()
	withPin := 0
	for _, r := range pins {
		if r["has_pin"] == true {
			withPin++
		}
		if r["employee_id"] == cashier && (r["can_pos"] != true || r["can_return"] == true) {
			t.Fatalf("cashier pin row = %v", r)
		}
	}
	if withPin != 2 {
		t.Fatalf("pins = %v", pins)
	}
	cat = a.expect(posDo(a, "GET", "/pos/catalog", dt, "", nil), 200, "catalog with cashiers")
	found := false
	for _, x := range cat.Body["cashiers"].([]any) {
		m := x.(map[string]any)
		if m["id"] == cashier && m["pin_hash"] == pos.PinHash(cashier, "1234") {
			found = true
		}
	}
	if !found || len(cat.Body["cashiers"].([]any)) != 2 {
		t.Fatalf("cashiers = %v", cat.Body["cashiers"])
	}
	wrong := a.expect(posDo(a, "POST", "/pos/login", dt, "", map[string]any{"employee_id": cashier, "pin": "0000"}), 401, "wrong pin")
	if wrong.Body["error"].(map[string]any)["details"].(map[string]any)["attempts_left"].(float64) != 4 {
		t.Fatalf("wrong pin = %v", wrong.Body)
	}
	a.expect(posDo(a, "POST", "/pos/login", dt, "", map[string]any{"employee_id": cashier, "pin": "1234"}), 200, "login")

	// Смена: без кассира нельзя, повтор — та же смена, вторая открытая — нельзя.
	a.expect(posDo(a, "POST", "/pos/shifts", dt, "", map[string]any{"client_uid": "shift-0001"}), 401, "shift without cashier")
	sh := a.expect(posDo(a, "POST", "/pos/shifts", dt, cashier, map[string]any{"client_uid": "shift-0001", "opening_cash": 200000}), 201, "open shift")
	shift := sh.str("id")
	if again := a.expect(posDo(a, "POST", "/pos/shifts", dt, cashier, map[string]any{"client_uid": "shift-0001"}), 200, "open again"); again.str("id") != shift {
		t.Fatal("repeat open created another shift")
	}
	a.expect(posDo(a, "POST", "/pos/shifts", dt, cashier, map[string]any{"client_uid": "shift-0002"}), 409, "second open shift")

	// Продажа: маркированной коле нужен код на каждую штуку; чек уже подписан ФМ.
	sale := func(uid string, items []map[string]any, pays []map[string]any, extra map[string]any) map[string]any {
		b := map[string]any{"client_uid": uid, "shift_id": shift, "items": items, "payments": pays}
		for k, v := range extra {
			b[k] = v
		}
		return b
	}
	a.expect(posDo(a, "POST", "/pos/sales", dt, cashier, sale("sale-0001",
		[]map[string]any{{"product_id": cola, "qty": 2, "marking_codes": []string{"0104780069000017215Ab7xQ"}}},
		[]map[string]any{{"payment_method_id": cash, "amount": 30000}}, nil)), 400, "marking count")
	s1 := a.expect(posDo(a, "POST", "/pos/sales", dt, cashier, sale("sale-0001",
		[]map[string]any{
			{"product_id": cola, "qty": 2, "marking_codes": []string{"0104780069000017215Ab7xQ", "0104780069000017215Kp2Lm"}},
			{"product_id": sugar, "qty": "1.5"},
		},
		[]map[string]any{{"payment_method_id": cash, "amount": 48000}},
		map[string]any{"fiscal": map[string]any{"number": "000231", "sign": "304812935521", "qr": "https://ofd.soliq.uz/check?t=1", "module": "UZ170201234567"}})), 201, "pos sale")
	if s1.str("total") != "48000.00" || s1.str("fiscal_status") != "registered" || s1.str("shift_id") != shift {
		t.Fatalf("pos sale = %v", s1.Body)
	}
	// Без интернета продали больше, чем было, и по старой цене: чек уже у
	// покупателя — продажа проходит по цене кассы, недостача записана.
	// Офлайн-продажа «час назад», но не раньше полуночи по Ташкенту: ниже контроль
	// кассиров и итоги дня берут «сегодня», и с 00:00 до 01:00 тест иначе падал.
	nowT := time.Now().In(time.FixedZone("Asia/Tashkent", 5*60*60))
	pastT := nowT.Add(-time.Hour)
	if midnight := time.Date(nowT.Year(), nowT.Month(), nowT.Day(), 0, 0, 0, 0, nowT.Location()); pastT.Before(midnight) {
		pastT = midnight
	}
	past := pastT.UTC().Format(time.RFC3339)
	// «Непробитый чек» попадает в контроль кассиров только через час после продажи
	// (fiscalGrace). С 00:00 до 01:00 продажа упёрлась в полночь и состариться не
	// успела — тогда флага «fiscal» ещё нет, и проверять его нечестно.
	fiscalSeen := pastT.Before(nowT.Add(-time.Hour))
	s2 := a.expect(posDo(a, "POST", "/pos/sales", dt, cashier, sale("sale-0002",
		[]map[string]any{{"product_id": cola, "qty": 10, "price": 14000}},
		[]map[string]any{{"payment_method_id": card, "amount": 140000}},
		map[string]any{"sold_at": past})), 201, "offline oversell")
	if s2.str("total") != "140000.00" {
		t.Fatalf("offline price sale = %v", s2.Body)
	}
	a.expect(a.do("POST", "/store/sales", tok, map[string]any{
		"client_uid": "panel-price-1", "items": []map[string]any{{"product_id": cola, "qty": 1, "price": 1}},
	}), 400, "panel sale with price")
	var short string
	if err := pool.QueryRow(context.Background(), `SELECT i.short_qty::text FROM sale_items i JOIN sales s ON s.id = i.sale_id
		WHERE s.client_uid = 'sale-0002'`).Scan(&short); err != nil || short != "2.000" {
		t.Fatalf("short_qty = %q, %v", short, err)
	}
	if q, _ := stockOf(t, a, tok, wh, cola); q != "0" && q != "0.000" {
		t.Fatalf("cola stock = %s", q)
	}

	// Быстрые кнопки: самые продаваемые — по чекам магазина, закрепляет кассир
	// с правом «Настройка кассы». Товар общего каталога без цены на кассу не идёт.
	unitID := a.expect(a.do("GET", "/admin/products/"+cola, adminTok, nil), 200, "cola").str("unit_id")
	catID := a.expect(a.do("GET", "/admin/products/"+cola, adminTok, nil), 200, "cola").str("category_id")
	noPrice := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
		"name": "Товар без цены", "category_id": catID, "unit_id": unitID, "base_price": 0,
	}), 201, "no price product").str("id")
	cat = a.expect(posDo(a, "GET", "/pos/catalog", dt, "", nil), 200, "catalog quick")
	quick := cat.Body["quick"].(map[string]any)
	if top := quick["top"].([]any); len(top) == 0 || top[0] != cola || len(quick["pinned"].([]any)) != 0 {
		t.Fatalf("quick = %v", quick)
	}
	for _, x := range cat.Body["products"].([]any) {
		pm := x.(map[string]any)
		if pm["id"] == noPrice {
			t.Fatal("product without price on pos")
		}
		if pm["id"] == cola && pm["category"] == "" {
			t.Fatalf("cola category = %v", pm)
		}
	}
	a.expect(posDo(a, "PUT", "/pos/quick-keys", dt, "", map[string]any{"product_ids": []string{cola}}), 401, "quick keys no cashier")
	a.expect(posDo(a, "PUT", "/pos/quick-keys", dt, cashier, map[string]any{"product_ids": []string{cola}}), 403, "quick keys no perm")
	a.expect(posDo(a, "PUT", "/pos/quick-keys", dt, owner, map[string]any{"product_ids": []string{cola, cola}}), 400, "quick keys twice")
	pinned := a.expect(posDo(a, "PUT", "/pos/quick-keys", dt, owner, map[string]any{"product_ids": []string{sugar, cola}}), 200, "quick keys")
	if fmt.Sprint(pinned.Body["pinned"]) != fmt.Sprint([]any{sugar, cola}) {
		t.Fatalf("pinned = %v", pinned.Body)
	}
	quick = a.expect(posDo(a, "GET", "/pos/catalog", dt, "", nil), 200, "catalog pinned").Body["quick"].(map[string]any)
	if fmt.Sprint(quick["pinned"]) != fmt.Sprint([]any{sugar, cola}) {
		t.Fatalf("catalog pinned = %v", quick)
	}

	// Изъятие наличных (инкассация); повтор не задваивает.
	mv := a.expect(posDo(a, "POST", "/pos/shifts/"+shift+"/cash-moves", dt, cashier, map[string]any{
		"client_uid": "move-0001", "kind": "out", "amount": 30000, "reason": "Инкассация",
	}), 200, "cash out")
	if again := a.expect(posDo(a, "POST", "/pos/shifts/"+shift+"/cash-moves", dt, cashier, map[string]any{
		"client_uid": "move-0001", "kind": "out", "amount": 30000,
	}), 200, "cash out again"); again.str("id") != mv.str("id") {
		t.Fatal("cash move duplicated")
	}

	// Возврат с кассы: у кассира нет права — отказ; владелец на кассе — можно.
	a.expect(posDo(a, "POST", "/pos/returns", dt, cashier, map[string]any{
		"sale_id": s1.str("id"), "payment_method_id": cash, "shift_id": shift,
		"items": []map[string]any{{"sale_line": 1, "qty": 1}},
	}), 403, "return without permission")
	found2 := a.expect(posDo(a, "GET", "/pos/sales?q="+jsonStr(s1.Body["number"]), dt, owner, nil), 200, "find sale").items()
	if len(found2) != 1 || found2[0]["id"] != s1.str("id") {
		t.Fatalf("find sale = %v", found2)
	}
	// QR на чеке кассы — client_uid продажи.
	if byUID := a.expect(posDo(a, "GET", "/pos/sales?q=sale-0001", dt, owner, nil), 200, "find by uid").items(); len(byUID) != 1 || byUID[0]["id"] != s1.str("id") {
		t.Fatalf("find by uid = %v", byUID)
	}
	ret := a.expect(posDo(a, "POST", "/pos/returns", dt, owner, map[string]any{
		"sale_id": s1.str("id"), "payment_method_id": cash, "shift_id": shift,
		"items": []map[string]any{{"sale_line": 1, "qty": 1}},
	}), 201, "pos return")
	// Чек возврата пробит на фискальном модуле кассы.
	a.expect(posDo(a, "POST", "/pos/returns/"+ret.str("id")+"/fiscal", dt, owner, map[string]any{"fiscal_number": "000232"}), 400, "return fiscal without sign")
	a.expect(posDo(a, "POST", "/pos/returns/"+ret.str("id")+"/fiscal", dt, owner, map[string]any{
		"fiscal_number": "000232", "fiscal_sign": "304812991044", "fiscal_qr": "https://ofd.soliq.uz/check?t=2", "fiscal_module": "UZ170201234567",
	}), 200, "return fiscal")
	if q := sqlStr(t, pool, `SELECT fiscal_status || '|' || fiscal_qr || '|' || fiscal_module FROM customer_returns WHERE id = $1`, ret.str("id")); q != "registered|https://ofd.soliq.uz/check?t=2|UZ170201234567" {
		t.Fatalf("return fiscal = %s", q)
	}

	// X-отчёт: 200 000 + 48 000 − 15 000 − 30 000 = 203 000 наличными.
	rep := a.expect(posDo(a, "GET", "/pos/shifts/"+shift, dt, cashier, nil), 200, "report").Body["report"].(map[string]any)
	if rep["expected_cash"] != "203000.00" || rep["sales_count"].(float64) != 2 || rep["fiscal_pending"].(float64) != 1 ||
		rep["returns_total"] != "15000.00" || rep["sales_total"] != "188000.00" {
		t.Fatalf("report = %v", rep)
	}

	// Смена дольше 24 часов: продажи и возвраты не принимаются, пока её не закроют.
	if _, err := pool.Exec(context.Background(), `UPDATE pos_shifts SET opened_at = opened_at - interval '25 hours' WHERE id = $1`, shift); err != nil {
		t.Fatal(err)
	}
	if r := a.expect(posDo(a, "POST", "/pos/sales", dt, cashier, sale("sale-0003",
		[]map[string]any{{"product_id": sugar, "qty": 1}},
		[]map[string]any{{"payment_method_id": cash, "amount": 12000}}, nil)), 409, "sale in expired shift"); !strings.Contains(r.str("error", "code"), "shift_expired") {
		t.Fatalf("expired shift = %v", r.Body)
	}
	a.expect(posDo(a, "POST", "/pos/returns", dt, owner, map[string]any{
		"sale_id": s1.str("id"), "payment_method_id": cash, "shift_id": shift,
		"items": []map[string]any{{"sale_line": 2, "qty": "0.5"}},
	}), 409, "return in expired shift")
	if _, err := pool.Exec(context.Background(), `UPDATE pos_shifts SET opened_at = opened_at + interval '25 hours' WHERE id = $1`, shift); err != nil {
		t.Fatal(err)
	}

	// Закрытие: расхождение без причины не принимаем.
	a.expect(posDo(a, "POST", "/pos/shifts/"+shift+"/close", dt, cashier, map[string]any{"counted_cash": 200000}), 400, "diff without reason")
	cl := a.expect(posDo(a, "POST", "/pos/shifts/"+shift+"/close", dt, cashier, map[string]any{
		"counted_cash": 200000, "diff_reason": "сдача без мелочи",
	}), 200, "close")
	if cl.str("diff") != "-3000.00" || cl.str("expected_cash") != "203000.00" || cl.Body["closed_at"] == nil {
		t.Fatalf("closed = %v", cl.Body)
	}
	a.expect(posDo(a, "POST", "/pos/shifts/"+shift+"/close", dt, cashier, map[string]any{"counted_cash": 1}), 200, "close again")
	if cur := a.expect(posDo(a, "GET", "/pos/shifts/current", dt, "", nil), 200, "current"); cur.Body["shift"] != nil {
		t.Fatalf("current after close = %v", cur.Body)
	}

	// Панель: смена с расхождением, касса активна.
	shifts := a.expect(a.do("GET", "/store/pos/shifts", tok, nil), 200, "shifts").items()
	if len(shifts) != 1 || shifts[0]["diff"] != "-3000.00" || shifts[0]["diff_reason"] != "сдача без мелочи" {
		t.Fatalf("shifts = %v", shifts)
	}
	devs := a.expect(a.do("GET", "/store/pos/devices", tok, nil), 200, "devices").items()
	if len(devs) != 1 || devs[0]["status"] != "active" || devs[0]["app_version"] != "0.1.0" {
		t.Fatalf("devices = %v", devs)
	}

	// Контроль кассиров: недостача и непробитый чек у кассира, возврат — у владельца.
	ctl := a.expect(a.do("GET", "/store/pos/cashiers?store_id="+store, tok, nil), 200, "cashiers")
	var dil, own map[string]any
	for _, x := range ctl.Body["items"].([]any) {
		m := x.(map[string]any)
		switch m["employee_id"] {
		case cashier:
			dil = m
		case owner:
			own = m
		}
	}
	if dil == nil || dil["sales_count"].(float64) != 2 || dil["revenue"] != "188000.00" || dil["shortage"] != "3000.00" ||
		!strings.Contains(fmt.Sprint(dil["flags"]), "shortage") || (fiscalSeen && !strings.Contains(fmt.Sprint(dil["flags"]), "fiscal")) ||
		len(dil["shifts"].([]any)) != 1 {
		t.Fatalf("cashier stat = %v", dil)
	}
	if own == nil || own["returns_count"].(float64) != 1 || own["returns_total"] != "15000.00" {
		t.Fatalf("owner stat = %v", own)
	}
	if sig := fmt.Sprint(ctl.Body["signals"]); !strings.Contains(sig, "Недостача 3 000 сум в смене Дилноза") {
		t.Fatalf("signals = %v", sig)
	}
	evs := a.expect(a.do("GET", "/store/pos/shifts/"+shift+"/events", tok, nil), 200, "events").items()
	var kinds []string
	for _, e := range evs {
		kinds = append(kinds, e["kind"].(string))
	}
	if got := strings.Join(kinds, ","); got != "open,cash_out,return,close" ||
		evs[1]["title"] != "Изъятие 30 000" || evs[3]["title"] != "Смена закрыта: недостача 3 000" || evs[3]["note"] != "сдача без мелочи" {
		t.Fatalf("events = %s %v", got, evs)
	}
	cashierTok, _ := a.login("+998900000006", identity.AppStore)
	a.expect(a.do("GET", "/store/pos/cashiers", cashierTok, nil), 403, "cashier sees control")

	// Итоги дня владельцу: выручка кассы минус возврат, недостача в «требует внимания».
	day := a.expect(a.do("GET", "/store/summary", tok, nil), 200, "summary")
	if day.str("revenue") != "173000.00" || day.Body["sales_count"].(float64) != 2 || !strings.Contains(fmt.Sprint(day.Body["alerts"]), "Недостача 3 000 сум") {
		t.Fatalf("summary = %v", day.Body)
	}
	a.expect(a.do("GET", "/store/summary?date=02.10.2026", tok, nil), 400, "summary date")
	a.expect(a.do("GET", "/store/summary", cashierTok, nil), 403, "cashier summary")
	if st := a.expect(a.do("GET", "/store/summary/settings", tok, nil), 200, "settings"); st.Body["enabled"] != true || st.Body["hour"].(float64) != 21 {
		t.Fatalf("settings = %v", st.Body)
	}
	a.expect(a.do("PUT", "/store/summary/settings", tok, map[string]any{"enabled": true, "hour": 24}), 400, "bad hour")
	a.expect(a.do("PUT", "/store/summary/settings", tok, map[string]any{"enabled": true, "hour": 0}), 200, "settings save")
	sumSvc := summary.NewService(pool, quietLog())
	if err := sumSvc.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM notifications_outbox WHERE kind = 'owner_summary'`); n != "0" {
		t.Fatalf("summary without device = %s", n)
	}
	a.expect(a.do("POST", "/store/devices", tok, map[string]any{"token": "owner-fcm-token-0123456789-abcdef", "platform": "ios"}), 204, "owner device")
	for i := 0; i < 2; i++ {
		if err := sumSvc.Tick(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	body := sqlStr(t, pool, `SELECT string_agg(title || '|' || body, ';') FROM notifications_outbox WHERE kind = 'owner_summary' AND app = 'store'`)
	if strings.Count(body, "Итоги дня · ") != 1 || !strings.Contains(body, "Выручка 173 000") || !strings.Contains(body, "Недостача 3 000 сум у кассира") {
		t.Fatalf("summary push = %q", body)
	}

	// Смену и чек ФМ передаёт только касса.
	a.expect(a.do("POST", "/store/sales", tok, map[string]any{
		"client_uid": "panel-0001", "store_id": store, "shift_id": shift,
		"items":    []map[string]any{{"product_id": sugar, "qty": 1}},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 12000}},
	}), 400, "shift from panel")

	// Цена товара прямо с кассы: только кассир с правом «Установка цен».
	a.expect(posDo(a, "PUT", "/pos/products/"+sugar+"/price", dt, "", map[string]any{"price": 13000}), 401, "price no cashier")
	a.expect(posDo(a, "PUT", "/pos/products/"+sugar+"/price", dt, cashier, map[string]any{"price": 13000}), 403, "price no perm")
	a.expect(posDo(a, "PUT", "/pos/products/"+sugar+"/price", dt, owner, map[string]any{"price": 0}), 400, "price zero")
	a.expect(posDo(a, "PUT", "/pos/products/00000000-0000-0000-0000-000000000000/price", dt, owner, map[string]any{"price": 13000}), 404, "price unknown product")
	if pp := a.expect(posDo(a, "PUT", "/pos/products/"+sugar+"/price", dt, owner, map[string]any{"price": 13000}), 200, "price"); pp.str("price") != "13000.00" {
		t.Fatalf("price = %v", pp.Body)
	}
	for _, x := range a.expect(posDo(a, "GET", "/pos/catalog", dt, "", nil), 200, "catalog priced").Body["products"].([]any) {
		if m := x.(map[string]any); m["id"] == sugar && m["price"] != "13000.00" {
			t.Fatalf("sugar in catalog = %v", m)
		}
	}

	// Зависшая смена: Z-отчёт не дошёл, сервер не принимает новую смену.
	// Касса закрывает старую сама (по расчёту), владелец — в панели.
	stale := a.expect(posDo(a, "POST", "/pos/shifts", dt, cashier, map[string]any{"client_uid": "stale-shift-0001", "opening_cash": 50000}), 201, "open stale").str("id")
	if r := a.expect(posDo(a, "POST", "/pos/shifts", dt, cashier, map[string]any{"client_uid": "stale-shift-0002"}), 409, "second open"); r.str("error", "code") != "shift_open" ||
		r.Body["error"].(map[string]any)["details"].(map[string]any)["shift_id"] != stale {
		t.Fatalf("second open = %v", r.Body)
	}
	if cur := a.expect(posDo(a, "GET", "/pos/shifts/current", dt, cashier, nil), 200, "current stale"); cur.str("shift", "id") != stale ||
		cur.Body["shift"].(map[string]any)["report"].(map[string]any)["expected_cash"] != "50000.00" {
		t.Fatalf("current stale = %v", cur.Body)
	}
	a.expect(posDo(a, "POST", "/pos/shifts/"+stale+"/close", dt, cashier, map[string]any{}), 400, "close without count")
	sc := a.expect(posDo(a, "POST", "/pos/shifts/"+stale+"/close", dt, cashier, map[string]any{"stale": true}), 200, "close stale")
	if sc.str("closed_via") != "pos_stale" || sc.str("counted_cash") != "50000.00" || sc.str("diff") != "0.00" {
		t.Fatalf("close stale = %v", sc.Body)
	}
	fresh := a.expect(posDo(a, "POST", "/pos/shifts", dt, cashier, map[string]any{"client_uid": "stale-shift-0002"}), 201, "open after stale").str("id")
	if ev := a.expect(a.do("GET", "/store/pos/shifts/"+stale+"/events", tok, nil), 200, "stale events").items(); !strings.Contains(fmt.Sprint(ev[len(ev)-1]["note"]), "закрыта с кассы") {
		t.Fatalf("stale events = %v", ev)
	}
	// Панель: только право «Финансы»; расхождение — с причиной; повтор безопасен.
	a.expect(a.do("POST", "/store/pos/shifts/"+fresh+"/close", cashierTok, map[string]any{"counted_cash": 0}), 403, "cashier closes in panel")
	a.expect(a.do("POST", "/store/pos/shifts/"+fresh+"/close", tok, map[string]any{"counted_cash": 1000}), 400, "panel diff without reason")
	pc := a.expect(a.do("POST", "/store/pos/shifts/"+fresh+"/close", tok, map[string]any{"counted_cash": 0, "stale": true}), 200, "panel close")
	if pc.str("closed_via") != "panel" || pc.str("diff") != "0.00" || pc.Body["closed_by_name"] == nil {
		t.Fatalf("panel close = %v", pc.Body)
	}
	a.expect(a.do("POST", "/store/pos/shifts/"+fresh+"/close", tok, map[string]any{"counted_cash": 0}), 200, "panel close again")
	if cur := a.expect(posDo(a, "GET", "/pos/shifts/current", dt, "", nil), 200, "current after panel"); cur.Body["shift"] != nil {
		t.Fatalf("current after panel close = %v", cur.Body)
	}
	if first := a.expect(a.do("GET", "/store/pos/shifts/"+shift, tok, nil), 200, "first shift"); first.str("closed_via") != "pos" {
		t.Fatalf("first shift closed_via = %v", first.Body["closed_via"])
	}

	// Отключённая касса больше не работает.
	a.expect(a.do("POST", "/store/pos/devices/"+dev.str("id")+"/revoke", tok, nil), 200, "revoke")
	a.expect(posDo(a, "GET", "/pos/catalog", dt, "", nil), 401, "revoked device")
}

func jsonStr(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}
