package server_test

import (
	"context"
	"net/http/httptest"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// TestStartMode — «Как начнём?» (Figma «начало работы v5»): «Только товары и
// цены» записывается без количества — товары «Остаток не посчитан»;
// «Сразу с остатками» — «Остальное посчитаю потом»; подсчёт с главной снимает
// пометку; черновик, начатый до выбора режима, продолжает «Сразу с остатками».
func TestStartMode(t *testing.T) {
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
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	ownerTok, storeID := setupNetwork(t, a, adminTok, "+998900000002")
	stockTok, stockStore := setupNetwork(t, a, adminTok, "+998900000003")

	drinks := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Напитки"}), 201, "category").str("id")
	var pcs string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		if u["short_name"] == "шт" {
			pcs = u["id"].(string)
		}
	}
	product := func(name string, photo bool) string {
		body := map[string]any{"name": name, "category_id": drinks, "unit_id": pcs, "base_price": 10000}
		if photo {
			body["images"] = []string{"https://cdn.example/" + name + ".png"}
		}
		return a.expect(a.do("POST", "/admin/products", adminTok, body), 201, "product "+name).str("id")
	}
	cola := product("Напиток Cola 1 л", true)
	fanta := product("Напиток Fanta 1 л", false) // без фото — в режиме prices можно
	water := product("Вода Hydrolife 0,5 л", true)
	code := func(r resp) string { return r.str("error", "code") }
	lines := func(tok, store string, items ...map[string]any) resp {
		return a.do("POST", "/store/start/lines", tok, map[string]any{"store_id": store, "items": items})
	}

	// Новый магазин: режим ещё не выбран — показать «Как начнём?».
	d := a.expect(a.do("GET", "/store/start?store_id="+storeID, ownerTok, nil), 200, "draft")
	if d.Body["mode"] != nil {
		t.Fatalf("mode = %v", d.Body["mode"])
	}
	a.expect(a.do("POST", "/store/start/mode", ownerTok, map[string]any{"store_id": storeID, "mode": "half"}), 400, "bad mode")
	if d = a.expect(a.do("POST", "/store/start/mode", ownerTok, map[string]any{"store_id": storeID, "mode": "prices"}), 200, "prices"); d.str("mode") != "prices" || d.Body["id"] == nil {
		t.Fatalf("set mode = %v", d.Body)
	}

	// «Только товары и цены»: количество не нужно, обязательна только цена.
	for _, id := range []string{cola, fanta, water} {
		a.expect(lines(ownerTok, storeID, map[string]any{"product_id": id, "add": true, "source": "search"}), 200, "add")
	}
	r := a.expect(lines(ownerTok, storeID, map[string]any{"product_id": cola, "price": 12000}, map[string]any{"product_id": fanta, "price": 11000, "cost": 9000}), 200, "prices")
	if tot := r.Body["totals"].(map[string]any); tot["unfilled"] != 1.0 || tot["no_price"] != 1.0 || tot["no_qty"] != 3.0 {
		t.Fatalf("totals = %v", tot)
	}
	if un := a.expect(a.do("GET", "/store/start?store_id="+storeID+"&only=unfilled", ownerTok, nil), 200, "unfilled").Body["lines"].([]any); len(un) != 1 || un[0].(map[string]any)["product_id"] != water {
		t.Fatalf("unfilled = %v", un)
	}
	if p := a.expect(a.do("POST", "/store/start/post", ownerTok, map[string]any{"store_id": storeID}), 409, "no price"); code(p) != "lines_unfilled" {
		t.Fatalf("post no price = %v", p.Body)
	}
	// Количество у одного товара всё-таки ввели — он посчитан.
	a.expect(lines(ownerTok, storeID, map[string]any{"product_id": water, "price": 4000, "qty": 10}), 200, "water")
	res := a.expect(a.do("POST", "/store/start/post", ownerTok, map[string]any{"store_id": storeID}), 200, "post prices")
	if res.Body["products"] != 3.0 || res.Body["uncounted"] != 2.0 || len(res.Body["documents"].([]any)) != 1 {
		t.Fatalf("post = %v", res.Body)
	}

	// Главная: посчитано 1 из 3.
	sum := a.expect(a.do("GET", "/store/start/count?store_id="+storeID, ownerTok, nil), 200, "summary")
	if sum.Body["products"] != 3.0 || sum.Body["uncounted"] != 2.0 || sum.Body["counted"] != 1.0 || sum.Body["percent"] != 33.0 || sum.Body["negative"] != 0.0 {
		t.Fatalf("summary = %v", sum.Body)
	}
	items := a.expect(a.do("GET", "/store/start/count/items?store_id="+storeID+"&set=top", ownerTok, nil), 200, "top")
	if items.Body["total"] != 2.0 || len(items.items()) != 2 || items.items()[0]["uncounted"] != true || items.items()[0]["stock"] != "0" {
		t.Fatalf("top = %v", items.Body)
	}
	if cats := a.expect(a.do("GET", "/store/start/count/categories?store_id="+storeID, ownerTok, nil), 200, "categories").items(); len(cats) != 1 || cats[0]["id"] != drinks || cats[0]["uncounted"] != 2.0 || cats[0]["products"] != 3.0 {
		t.Fatalf("categories = %v", cats)
	}
	if one := a.expect(a.do("GET", "/store/start/count/items?store_id="+storeID+"&set=product&product_id="+water, ownerTok, nil), 200, "one").items(); len(one) != 1 || one[0]["uncounted"] != false || one[0]["stock"] != "10" {
		t.Fatalf("one = %v", one)
	}
	a.expect(a.do("GET", "/store/start/count/items?store_id="+storeID+"&set=all", ownerTok, nil), 400, "bad set")
	// Приход: из этих товаров непосчитан только один — его и спросить «Сколько на полке?».
	if in := a.expect(a.do("GET", "/store/start/count/items?store_id="+storeID+"&set=uncounted&product_ids="+cola+","+water, ownerTok, nil), 200, "by ids").items(); len(in) != 1 || in[0]["product_id"] != cola {
		t.Fatalf("by ids = %v", in)
	}
	a.expect(a.do("GET", "/store/start/count/items?store_id="+storeID+"&product_ids=x", ownerTok, nil), 400, "bad ids")
	a.expect(a.do("GET", "/store/start/count?store_id="+stockStore, ownerTok, nil), 404, "foreign summary")

	// Посчитали колу: 7 на полке — остаток 7, пометка снята.
	c := a.expect(a.do("POST", "/store/start/count", ownerTok, map[string]any{"store_id": storeID, "items": []map[string]any{{"product_id": cola, "qty": 7}}}), 200, "count")
	if c.Body["counted"] != 1.0 || c.Body["summary"].(map[string]any)["uncounted"] != 1.0 {
		t.Fatalf("count = %v", c.Body)
	}
	if one := a.expect(a.do("GET", "/store/start/count/items?store_id="+storeID+"&set=product&product_id="+cola, ownerTok, nil), 200, "cola").items(); one[0]["uncounted"] != false || one[0]["stock"] != "7" {
		t.Fatalf("cola = %v", one)
	}
	a.expect(a.do("POST", "/store/start/count", ownerTok, map[string]any{"store_id": storeID, "items": []map[string]any{{"product_id": fanta, "qty": -1}}}), 400, "negative qty")

	// Продажа из панели непосчитанного товара (остатка 0 по учёту) проходит —
	// недостача записывается, как с кассы; посчитанный в минус уйти не может.
	var cash string
	for _, m := range a.expect(a.do("GET", "/store/finance/payment-methods?store_id="+storeID, ownerTok, nil), 200, "methods").items() {
		if m["name"] == "Наличные" {
			cash = m["id"].(string)
		}
	}
	sell := func(uid, product string, qty int, price int) resp {
		return a.do("POST", "/store/sales", ownerTok, map[string]any{"client_uid": uid, "store_id": storeID,
			"items": []map[string]any{{"product_id": product, "qty": qty}}, "payments": []map[string]any{{"payment_method_id": cash, "amount": qty * price}}})
	}
	a.expect(sell("start-mode-sale-1", fanta, 2, 11000), 201, "sell uncounted")
	if r := sell("start-mode-sale-2", cola, 8, 12000); r.Status != 409 || code(r) != "insufficient_stock" {
		t.Fatalf("sell counted over stock = %v", r.Body)
	}
	cs := a.expect(sell("start-mode-sale-3", cola, 1, 12000), 201, "sell counted")
	if s := a.expect(a.do("GET", "/store/start/count?store_id="+storeID, ownerTok, nil), 200, "summary"); s.Body["negative"] != 0.0 {
		t.Fatalf("negative = %v", s.Body)
	}
	// С кассы без интернета продали больше, чем было после подсчёта, — «ушли в минус».
	if _, err := pool.Exec(ctx, `UPDATE sale_items SET short_qty = 1 WHERE sale_id = $1`, cs.str("id")); err != nil {
		t.Fatal(err)
	}
	if s := a.expect(a.do("GET", "/store/start/count?store_id="+storeID, ownerTok, nil), 200, "summary"); s.Body["negative"] != 1.0 {
		t.Fatalf("negative = %v", s.Body)
	}
	if neg := a.expect(a.do("GET", "/store/start/count/items?store_id="+storeID+"&set=negative", ownerTok, nil), 200, "negative").items(); len(neg) != 1 || neg[0]["product_id"] != cola || neg[0]["short"] != "1" {
		t.Fatalf("negative items = %v", neg)
	}
	if top := a.expect(a.do("GET", "/store/start/count/items?store_id="+storeID+"&set=top", ownerTok, nil), 200, "top").items(); len(top) != 1 || top[0]["product_id"] != fanta || top[0]["sold_30d"] != "2" {
		t.Fatalf("top after sale = %v", top)
	}

	// «Мои товары и остатки» в «SM Магазин»: все товары магазина и их остаток.
	my := a.expect(a.do("GET", "/store/inventory/my-products?store_id="+storeID, ownerTok, nil), 200, "my products")
	if c := my.Body["counts"].(map[string]any); c["all"] != 3.0 || c["ok"] != 2.0 || c["uncounted"] != 1.0 || c["out"] != 0.0 || my.str("warehouse_id") == "" || my.Body["stock_cost"] == nil || len(my.Body["categories"].([]any)) != 1 {
		t.Fatalf("my products = %v", my.Body)
	}
	if un := a.expect(a.do("GET", "/store/inventory/my-products?store_id="+storeID+"&status=unknown", ownerTok, nil), 200, "my unknown").items(); len(un) != 1 || un[0]["product_id"] != fanta || un[0]["uncounted"] != true || un[0]["days_left"] != nil {
		t.Fatalf("my unknown = %v", un)
	}
	if one := a.expect(a.do("GET", "/store/inventory/my-products?store_id="+storeID+"&product_id="+cola, ownerTok, nil), 200, "my cola").items(); len(one) != 1 || one[0]["qty"] != "6" || one[0]["status"] != "ok" || one[0]["price"] != "12000.00" {
		t.Fatalf("my cola = %v", one)
	}
	a.expect(a.do("GET", "/store/inventory/my-products?store_id="+storeID+"&status=bad", ownerTok, nil), 400, "my bad status")
	a.expect(a.do("GET", "/store/inventory/my-products?store_id="+stockStore, ownerTok, nil), 404, "my foreign")

	// «Сразу с остатками» и «Остальное посчитаю потом»: черновик начат до
	// выбора режима (старое приложение) — он stock, ничего не теряется.
	a.expect(lines(stockTok, stockStore, map[string]any{"product_id": cola, "add": true}), 200, "stock add cola")
	a.expect(lines(stockTok, stockStore, map[string]any{"product_id": water, "add": true}), 200, "stock add water")
	a.expect(lines(stockTok, stockStore, map[string]any{"product_id": cola, "qty": 5, "price": 12000}, map[string]any{"product_id": water, "price": 4000}), 200, "stock lines")
	if _, err := pool.Exec(ctx, `UPDATE start_drafts SET mode = 'stock' WHERE store_id = $1`, stockStore); err != nil {
		t.Fatal(err)
	}
	if p := a.expect(a.do("POST", "/store/start/post", stockTok, map[string]any{"store_id": stockStore}), 409, "qty needed"); code(p) != "lines_unfilled" {
		t.Fatalf("stock post = %v", p.Body)
	}
	res = a.expect(a.do("POST", "/store/start/post", stockTok, map[string]any{"store_id": stockStore, "rest_later": true}), 200, "rest later")
	if res.Body["products"] != 2.0 || res.Body["uncounted"] != 1.0 {
		t.Fatalf("rest later = %v", res.Body)
	}
	if s := a.expect(a.do("GET", "/store/start/count?store_id="+stockStore, stockTok, nil), 200, "stock summary"); s.Body["uncounted"] != 1.0 || s.Body["counted"] != 1.0 {
		t.Fatalf("stock summary = %v", s.Body)
	}
}
