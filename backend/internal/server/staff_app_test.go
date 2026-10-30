package server_test

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// TestStaffApp — «SM Сотрудник» (Figma «Super Market · SM Сотрудник»):
// сборка заказа (взять, скан, «Нет на полке» → убрать, пакеты, передал
// курьеру), цена и остаток по скану, списание с фото, автозадачи и «Мой день».
func TestStaffApp(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	app, err := server.Build(ctx, cfg, pool, &fakeTelegram{}, quietLog())
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app.Handler)
	t.Cleanup(srv.Close)
	a := api{t: t, srv: srv, pool: pool}
	code := func(r resp) string { return r.str("error", "code") }

	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, sugar := catalogBasics(t, a, adminTok)
	if _, err := pool.Exec(ctx, `INSERT INTO product_barcodes (product_id, barcode) VALUES ($1, '4780069000154')`, cola); err != nil {
		t.Fatal(err)
	}
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	const lat, lng = 41.2995, 69.2401
	a.expect(a.do("PATCH", "/store/stores/"+store, tok, map[string]any{"lat": lat, "lng": lng, "phone": "+998712000000"}), 200, "store")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
	doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{"type": "posting", "warehouse_id": wh,
		"items": []map[string]any{{"product_id": cola, "qty": 20, "price": 10000}, {"product_id": sugar, "qty": 10, "price": 9000}}}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post")
	a.expect(a.do("PUT", "/store/stores/"+store+"/delivery", tok, map[string]any{
		"accepts_online": true, "delivery_radius_m": 5000,
		"rules": []map[string]any{{"type": "fixed", "params": map[string]any{"price": 5000}}},
	}), 200, "delivery")

	// Сотрудники: продавец-кладовщик-сборщик, второй сборщик, кассир.
	role := func(name string, perms ...string) string {
		return a.expect(a.do("POST", "/store/roles", tok, map[string]any{"name": name, "permissions": perms}), 201, "role "+name).str("id")
	}
	emp := func(phone, name, role string) string {
		return a.expect(a.do("POST", "/store/employees", tok, map[string]any{
			"phone": phone, "full_name": name, "role_id": role, "store_ids": []string{store},
		}), 201, "employee "+name).str("id")
	}
	seller := role("Продавец", identity.PermOrdersManage, identity.PermInventoryManage, identity.PermSalesPOS)
	picker := role("Сборщик", identity.PermOrdersManage)
	cashier := role("Кассир", identity.PermSalesPOS)
	dilshod := emp("+998900000080", "Дилшод", seller)
	emp("+998900000081", "Азиз", picker)
	emp("+998900000082", "Нигора", cashier)
	dTok, _ := a.login("+998900000080", identity.AppStore)
	aTok, _ := a.login("+998900000081", identity.AppStore)
	nTok, _ := a.login("+998900000082", identity.AppStore)

	// Заказ покупателя: 2 колы и 1,5 кг сахара, наличными курьеру.
	client, _ := a.login("+998900000050", identity.AppClient)
	addr := a.expect(a.do("POST", "/client/addresses", client, map[string]any{"address": "Юнусабад", "lat": lat + 0.018, "lng": lng}), 201, "address").str("id")
	newOrder := func(items ...map[string]any) string {
		return a.expect(a.do("POST", "/client/orders", client, map[string]any{"store_id": store, "address_id": addr, "payment_provider": "cash",
			"items": items}), 201, "order").str("order", "id")
	}
	id := newOrder(map[string]any{"product_id": cola, "qty": 2}, map[string]any{"product_id": sugar, "qty": 1.5})
	path := "/store/orders/" + id

	// «Взять в сборку» прямо из новых: заказ принят и закреплён за Дилшодом.
	o := a.expect(a.do("POST", path+"/take", dTok, nil), 200, "take")
	if o.str("status") != "picking" || o.str("picker_id") != dilshod || o.str("picker_name") != "Дилшод" || o.Body["items_count"] != 2.0 || o.Body["picked_count"] != 0.0 {
		t.Fatalf("take = %v", o.Body)
	}
	if r := a.do("POST", path+"/take", aTok, nil); r.Status != 409 || code(r) != "taken" || r.str("error", "details", "picker_name") != "Дилшод" {
		t.Fatalf("second take = %d %v", r.Status, r.Body)
	}
	a.expect(a.do("POST", path+"/take", nTok, nil), 403, "cashier take")
	if r := a.do("POST", path+"/lines/1/pick", aTok, map[string]any{"qty": 2}); r.Status != 409 || code(r) != "taken" {
		t.Fatalf("other picks = %d %v", r.Status, r.Body)
	}
	a.expect(a.do("POST", path+"/take", dTok, nil), 200, "take again — same picker")

	// Скан колы — строка собрана; в строках штрихкоды для сканера.
	o = a.expect(a.do("POST", path+"/lines/1/pick", dTok, map[string]any{"qty": 5}), 200, "pick")
	items := o.Body["items"].([]any)
	l1 := items[0].(map[string]any)
	if o.Body["picked_count"] != 1.0 || l1["picked_qty"] != "2" || len(l1["barcodes"].([]any)) != 1 || items[1].(map[string]any)["is_fractional"] != true {
		t.Fatalf("pick = %v", o.Body)
	}
	a.expect(a.do("POST", path+"/lines/9/pick", dTok, map[string]any{"qty": 1}), 404, "no line")
	a.expect(a.do("POST", path+"/lines/1/pick", dTok, map[string]any{"qty": -1}), 400, "bad qty")
	if l := a.expect(a.do("GET", "/store/orders?store_id="+store+"&status=picking", tok, nil), 200, "list").items(); len(l) != 1 || l[0]["picked_count"] != 1.0 || l[0]["picker_name"] != "Дилшод" {
		t.Fatalf("list = %v", l)
	}

	// Сахара нет на полке — убрать из заказа и обнулить остаток.
	before := sqlStr(t, pool, `SELECT total::text FROM orders WHERE id = $1`, id)
	rm := a.expect(a.do("POST", path+"/lines/2/remove", dTok, map[string]any{"zero_stock": true}), 200, "remove")
	if rm.Body["zero_stocked"] != true || rm.str("order", "total") != "35000.00" || rm.str("order", "subtotal") != "30000.00" || len(rm.Body["order"].(map[string]any)["items"].([]any)) != 1 {
		t.Fatalf("remove = %v (before %s)", rm.Body, before)
	}
	if q, _ := stockOf(t, a, tok, wh, sugar); q != "0" && q != "0.000" {
		t.Fatalf("sugar stock = %s", q)
	}
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM stock_reservations WHERE order_id = $1`, id); n != "1" {
		t.Fatalf("reservations = %s", n)
	}
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM notifications_outbox WHERE title LIKE '%изменён%'`); n != "1" {
		t.Fatalf("customer push = %s", n)
	}
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM order_removed_items WHERE order_id = $1`, id); n != "1" {
		t.Fatalf("removed = %s", n)
	}
	if r := a.do("POST", path+"/lines/1/remove", dTok, map[string]any{}); r.Status != 409 || code(r) != "last_line" {
		t.Fatalf("last line = %d %v", r.Status, r.Body)
	}

	// Собран → 2 пакета → передал курьеру.
	o = a.expect(a.do("POST", path+"/picked", dTok, map[string]any{"bags": 2}), 200, "picked")
	if o.str("status") != "picked" || o.Body["bags"] != 2.0 {
		t.Fatalf("picked = %v", o.Body)
	}
	if o = a.expect(a.do("POST", path+"/handed", dTok, nil), 200, "handed"); o.str("handed_at") == "" {
		t.Fatalf("handed = %v", o.Body)
	}
	a.expect(a.do("POST", path+"/handed", dTok, nil), 200, "handed twice")
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM order_status_history WHERE order_id = $1 AND note = 'передал курьеру'`, id); n != "1" {
		t.Fatalf("handed history = %s", n)
	}

	// Сахара больше нет — покупатель его не закажет.
	if r := a.do("POST", "/client/orders", client, map[string]any{"store_id": store, "address_id": addr, "payment_provider": "cash",
		"items": []map[string]any{{"product_id": sugar, "qty": 1}}}); r.Status != 409 {
		t.Fatalf("order zero stock = %d %v", r.Status, r.Body)
	}
	// Оплачен картой — убрать товар пока нельзя.
	card := newOrder(map[string]any{"product_id": cola, "qty": 1})
	a.expect(a.do("POST", "/store/orders/"+card+"/take", aTok, nil), 200, "take card")
	if _, err := pool.Exec(ctx, `UPDATE orders SET payment_provider = 'payme' WHERE id = $1`, card); err != nil {
		t.Fatal(err)
	}
	if r := a.do("POST", "/store/orders/"+card+"/lines/1/remove", aTok, map[string]any{}); r.Status != 409 || code(r) != "card_paid" {
		t.Fatalf("card remove = %d %v", r.Status, r.Body)
	}

	// Цена и остаток по скану: кассир видит цену продажи, но не закупку.
	g := a.expect(a.do("GET", "/store/staff/glance?store_id="+store+"&code=4780069000154", nTok, nil), 200, "glance")
	if g.str("product_id") != cola || g.str("price") != "15000.00" || g.str("qty") != "18" || g.str("sold_7d") != "2" ||
		g.Body["can_price"] != false || g.Body["can_count"] != false || g.Body["in_store"] != true || hasCostKey(g.Body) {
		t.Fatalf("glance = %v", g.Body)
	}
	a.expect(a.do("GET", "/store/staff/glance?store_id="+store+"&code=000", nTok, nil), 404, "unknown code")
	a.expect(a.do("GET", "/store/staff/glance?store_id="+store, nTok, nil), 400, "no code")
	// Наклейка весов: префикс 22, номер 00012, 1,250 кг.
	if _, err := pool.Exec(ctx, `UPDATE networks SET scales_enabled = true, pos_weight_prefixes = '{22}' WHERE id = (SELECT network_id FROM stores WHERE id = $1)`, store); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pos_plu (network_id, product_id, plu) SELECT network_id, $2, 12 FROM stores WHERE id = $1`, store, sugar); err != nil {
		t.Fatal(err)
	}
	sticker := ean13("220001201250")
	if g := a.expect(a.do("GET", "/store/staff/glance?store_id="+store+"&code="+sticker, dTok, nil), 200, "sticker"); g.str("product_id") != sugar || g.str("weight") != "1.250" || g.Body["can_count"] != true {
		t.Fatalf("sticker glance = %v", g.Body)
	}

	// Списание: причина и фото обязательны, проводится сразу.
	wo := map[string]any{"store_id": store, "product_id": cola, "qty": 2, "reason": "broken", "photos": []string{}}
	a.expect(a.do("POST", "/store/staff/write-off", dTok, wo), 400, "no photo")
	wo["photos"] = []string{"https://cdn.example/broken.jpg"}
	wo["reason"] = "lost"
	a.expect(a.do("POST", "/store/staff/write-off", dTok, wo), 400, "bad reason")
	wo["reason"] = "other"
	a.expect(a.do("POST", "/store/staff/write-off", dTok, wo), 400, "other without comment")
	wo["reason"] = "broken"
	a.expect(a.do("POST", "/store/staff/write-off", nTok, wo), 403, "cashier write-off")
	w := a.expect(a.do("POST", "/store/staff/write-off", dTok, wo), 201, "write-off")
	if w.str("product", "qty") != "16" || w.str("document", "id") == "" {
		t.Fatalf("write-off = %v", w.Body)
	}
	if d := a.expect(a.do("GET", "/store/inventory/documents/"+w.str("document", "id"), tok, nil), 200, "doc"); d.str("status") != "posted" || d.str("reason") != "Разбилось" || len(d.Body["photos"].([]any)) != 1 {
		t.Fatalf("write-off doc = %v", d.Body)
	}

	// Автозадачи: цена колы поменялась — поменять ценник; сахар «не посчитан».
	pts := a.expect(a.do("GET", "/store/price-types", tok, nil), 200, "price types").items()
	setPrice := func(price int) {
		pd := a.expect(a.do("POST", "/store/price-documents", tok, map[string]any{"price_type_id": pts[0]["id"], "store_id": store,
			"items": []map[string]any{{"product_id": cola, "new_price": price}}}), 201, "price doc")
		a.expect(a.do("POST", "/store/price-documents/"+pd.str("id")+"/post", tok, nil), 200, "post price")
	}
	setPrice(15000) // первая цена магазина — не в счёт
	if tk := a.expect(a.do("GET", "/store/staff/tasks?store_id="+store, dTok, nil), 200, "tasks"); tk.Body["price_tags"] != 0.0 {
		t.Fatalf("tasks before = %v", tk.Body)
	}
	setPrice(16000)
	if _, err := pool.Exec(ctx, `UPDATE store_products SET uncounted_since = now() WHERE store_id = $1 AND product_id = $2`, store, sugar); err != nil {
		t.Fatal(err)
	}
	tk := a.expect(a.do("GET", "/store/staff/tasks?store_id="+store, dTok, nil), 200, "tasks")
	if tk.Body["price_tags"] != 1.0 || tk.Body["uncounted"] != 1.0 || tk.Body["negative"] != 0.0 || tk.Body["open"] != 2.0 || len(tk.Body["done"].([]any)) < 2 {
		t.Fatalf("tasks = %v", tk.Body)
	}
	if tk := a.expect(a.do("GET", "/store/staff/tasks?store_id="+store, nTok, nil), 200, "cashier tasks"); tk.Body["open"] != 0.0 {
		t.Fatalf("cashier tasks = %v", tk.Body)
	}
	tags := a.expect(a.do("GET", "/store/staff/price-tags?store_id="+store, dTok, nil), 200, "tags").items()
	if len(tags) != 1 || tags[0]["old_price"] != "15000" || tags[0]["price"] != "16000" {
		t.Fatalf("tags = %v", tags)
	}
	a.expect(a.do("GET", "/store/staff/price-tags?store_id="+store, nTok, nil), 403, "cashier tags")
	if m := a.expect(a.do("POST", "/store/staff/price-tags", dTok, map[string]any{"store_id": store, "product_ids": []string{cola}}), 200, "mark"); m.Body["marked"] != 1.0 {
		t.Fatalf("mark = %v", m.Body)
	}
	if tk := a.expect(a.do("GET", "/store/staff/tasks?store_id="+store, dTok, nil), 200, "tasks after"); tk.Body["price_tags"] != 0.0 {
		t.Fatalf("tasks after mark = %v", tk.Body)
	}
	// Пересчитали сахар — задача «Не посчитаны» закрылась сама.
	a.expect(a.do("POST", "/store/start/count", dTok, map[string]any{"store_id": store, "items": []map[string]any{{"product_id": sugar, "qty": 3}}}), 200, "count")
	if tk := a.expect(a.do("GET", "/store/staff/tasks?store_id="+store, dTok, nil), 200, "tasks counted"); tk.Body["uncounted"] != 0.0 || tk.Body["open"] != 0.0 {
		t.Fatalf("tasks counted = %v", tk.Body)
	}

	// Цена закупки (С5б/С5в): у колы она есть — строки нет; товар без цены
	// закупки (остаток с «Начала работы») — «не задана», ставит кладовщик.
	if g := a.expect(a.do("GET", "/store/staff/glance?store_id="+store+"&product_id="+cola, dTok, nil), 200, "cola cost"); g.Body["no_cost"] != nil {
		t.Fatalf("cola no_cost = %v", g.Body)
	}
	if _, err := pool.Exec(ctx, `UPDATE batches SET unit_cost = 0, unit_cost_usd = 0 WHERE product_id = $1 AND warehouse_id = $2`, sugar, wh); err != nil {
		t.Fatal(err)
	}
	g = a.expect(a.do("GET", "/store/staff/glance?store_id="+store+"&product_id="+sugar, dTok, nil), 200, "sugar cost")
	if nc, _ := g.Body["no_cost"].(map[string]any); nc == nil || nc["stock"] != "3" {
		t.Fatalf("sugar no_cost = %v", g.Body)
	}
	if g := a.expect(a.do("GET", "/store/staff/glance?store_id="+store+"&product_id="+sugar, nTok, nil), 200, "cashier cost"); hasCostKey(g.Body) {
		t.Fatalf("cashier sees cost = %v", g.Body)
	}
	cost := map[string]any{"store_id": store, "product_id": sugar, "cost": 9500}
	a.expect(a.do("POST", "/store/staff/cost", nTok, cost), 403, "cashier cost")
	a.expect(a.do("POST", "/store/staff/cost", aTok, cost), 403, "picker cost")
	a.expect(a.do("POST", "/store/staff/cost", dTok, map[string]any{"store_id": store, "product_id": sugar, "cost": 0}), 400, "zero cost")
	a.expect(a.do("POST", "/store/staff/cost", dTok, cost), 200, "set cost")
	if g := a.expect(a.do("GET", "/store/staff/glance?store_id="+store+"&product_id="+sugar, dTok, nil), 200, "sugar after"); g.Body["no_cost"] != nil {
		t.Fatalf("sugar after = %v", g.Body)
	}
	if c := sqlStr(t, pool, `SELECT trim_scale(min(unit_cost))::text FROM batches WHERE product_id = $1 AND warehouse_id = $2 AND qty_remaining > 0`, sugar, wh); c != "9500" {
		t.Fatalf("sugar batch cost = %s", c)
	}
	// Уже заданную цену «Поставить» не меняет — её меняет приход.
	a.expect(a.do("POST", "/store/staff/cost", dTok, map[string]any{"store_id": store, "product_id": sugar, "cost": 1}), 200, "set again")
	if c := sqlStr(t, pool, `SELECT trim_scale(max(unit_cost))::text FROM batches WHERE product_id = $1 AND warehouse_id = $2`, sugar, wh); c != "9500" {
		t.Fatalf("cost overwritten = %s", c)
	}

	// Мой день.
	day := a.expect(a.do("GET", "/store/staff/day?store_id="+store, dTok, nil), 200, "day")
	if day.Body["orders_picked"] != 1.0 || day.Body["write_offs"] != 1.0 || day.Body["counted"] != 2.0 || day.Body["receipts"] != 0.0 {
		t.Fatalf("day = %v", day.Body)
	}
	a.expect(a.do("GET", "/store/staff/day?store_id="+store, client, nil), 403, "client")

	// «SM Сотрудник» в версиях приложений.
	if _, err := pool.Exec(ctx, `INSERT INTO app_versions (app, platform, latest) VALUES ('employee', 'android', '1.0.0')`); err != nil {
		t.Fatal(err)
	}
}

func hasCostKey(m map[string]any) bool {
	for k := range m {
		if strings.Contains(k, "cost") {
			return true
		}
	}
	return false
}

// ean13 — 12 цифр + контрольная.
func ean13(s string) string {
	sum := 0
	for i := 0; i < 12; i++ {
		d := int(s[i] - '0')
		if i%2 == 1 {
			d *= 3
		}
		sum += d
	}
	return s + string(rune('0'+(10-sum%10)%10))
}
