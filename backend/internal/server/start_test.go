package server_test

import (
	"bytes"
	"context"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// TestStart — «Начало работы»: магазин добавляет товары, которые у него есть
// (штрихкод, каталог, фото полки), правит цены и проводит — товары на складе,
// цены магазина установлены, покупатель их видит.
func TestStart(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	s3 := &fakeS3{buckets: map[string]bool{}, objects: map[string][]byte{}, types: map[string]string{}}
	s3srv := httptest.NewServer(s3)
	t.Cleanup(s3srv.Close)
	fai := &fakeAI{key: "sk-start-key"}
	aisrv := httptest.NewServer(fai)
	t.Cleanup(aisrv.Close)

	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	cfg.S3Endpoint, cfg.S3AccessKey, cfg.S3SecretKey, cfg.S3Bucket = s3srv.URL, "minio", "secret", "media"
	server.InvoicesSync = true
	t.Cleanup(func() { server.InvoicesSync = false })
	app, err := server.Build(ctx, cfg, pool, &fakeTelegram{}, quietLog())
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app.Handler)
	t.Cleanup(srv.Close)
	a := api{t: t, srv: srv, pool: pool}
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	ownerTok, storeID := setupNetwork(t, a, adminTok, "+998900000002")
	otherTok, otherStore := setupNetwork(t, a, adminTok, "+998900000003")

	// Каталог платформы.
	brand := a.expect(a.do("POST", "/admin/catalog/brands", adminTok, map[string]any{"name": "Coca-Cola"}), 201, "brand").str("id")
	drinks := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Напитки"}), 201, "category").str("id")
	var pcs, kg string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		switch u["short_name"] {
		case "шт":
			pcs = u["id"].(string)
		case "кг":
			kg = u["id"].(string)
		}
	}
	product := func(name, unit string, price int, barcode string) string {
		body := map[string]any{"name": name, "category_id": drinks, "unit_id": unit, "base_price": price, "brand_id": brand,
			"images": []string{"https://cdn.example/" + name + ".png"}}
		if barcode != "" {
			body["barcodes"] = []string{barcode}
		}
		return a.expect(a.do("POST", "/admin/products", adminTok, body), 201, "product "+name).str("id")
	}
	cola := product("Напиток Coca-Cola 1,5 л", pcs, 15000, "5449000000996")
	zero := product("Напиток Coca-Cola Zero 1 л", pcs, 11990, "")
	fanta := product("Напиток Fanta Апельсин 1 л", pcs, 11990, "")
	apples := product("Яблоки Голден", kg, 22000, "")
	pepsi := product("Напиток Pepsi 1 л", pcs, 9000, "")

	// Пустой черновик: товаров на складе нет, «Начало работы» открыто.
	d := a.expect(a.do("GET", "/store/start?store_id="+storeID, ownerTok, nil), 200, "empty draft")
	if d.Body["id"] != nil || d.Body["stock_products"] != 0.0 || d.str("warehouse_name") == "" || len(d.Body["lines"].([]any)) != 0 || d.Body["closed"] != false {
		t.Fatalf("empty = %v", d.Body)
	}
	a.expect(a.do("GET", "/store/start?store_id="+otherStore, ownerTok, nil), 404, "foreign store")
	a.expect(a.do("POST", "/store/start/post", ownerTok, map[string]any{"store_id": storeID}), 409, "post empty")

	lines := func(items ...map[string]any) resp {
		return a.do("POST", "/store/start/lines", ownerTok, map[string]any{"store_id": storeID, "items": items})
	}
	code := func(r resp) string { return r.str("error", "code") }
	search := func(q string) []map[string]any {
		t.Helper()
		return a.expect(a.do("GET", "/store/start/search?store_id="+storeID+"&q="+url.QueryEscape(q), ownerTok, nil), 200, "search "+q).items()
	}

	// Шаг 1 — поиск по центральной базе: каждое слово запроса или штрихкод.
	if s := search("c"); len(s) != 0 {
		t.Fatalf("short query = %v", s)
	}
	if s := search("coca 1,5"); len(s) != 1 || s[0]["product_id"] != cola || s[0]["added"] != false {
		t.Fatalf("search = %v", s)
	}
	if s := search("5449000000996"); len(s) != 1 || s[0]["product_id"] != cola || s[0]["barcode"] != "5449000000996" {
		t.Fatalf("by barcode = %v", s)
	}
	// Латиница кириллицей, не та раскладка, начало названия выше.
	if s := search("кока кола 1,5"); len(s) != 1 || s[0]["product_id"] != cola {
		t.Fatalf("translit = %v", s)
	}
	if s := search("yfgbnjr"); len(s) != 4 || s[0]["product_id"] != cola {
		t.Fatalf("layout = %v", s)
	}
	if s := search("zero"); len(s) != 1 || s[0]["product_id"] != zero {
		t.Fatalf("zero = %v", s)
	}
	a.expect(a.do("GET", "/store/start/search?store_id="+otherStore+"&q=coca", ownerTok, nil), 404, "foreign search")

	// Добавить в «Мои товары»: количества и цены ещё нет.
	r := a.expect(lines(map[string]any{"product_id": cola, "add": true, "source": "barcode"}), 200, "cola")
	if l := r.Body["lines"].([]any)[0].(map[string]any); l["qty"] != nil || l["price"] != nil || l["barcode"] != "5449000000996" || l["source"] != "barcode" {
		t.Fatalf("cola line = %v", l)
	}
	if tot := r.Body["totals"].(map[string]any); tot["products"] != 1.0 || tot["unfilled"] != 1.0 {
		t.Fatalf("totals = %v", tot)
	}
	// Тот же товар второй раз — ошибка, ничего не добавлено.
	if dup := a.expect(lines(map[string]any{"product_id": cola, "add": true, "source": "barcode"}), 409, "duplicate"); code(dup) != "already_added" || dup.str("error", "details", "product_id") != cola {
		t.Fatalf("duplicate = %v", dup.Body)
	}
	if s := search("coca 1,5"); s[0]["added"] != true {
		t.Fatalf("added flags = %v", s)
	}
	// Фото полки: ИИ ещё не подключён.
	upload := func() string {
		t.Helper()
		var body bytes.Buffer
		mw := multipart.NewWriter(&body)
		fw, _ := mw.CreateFormFile("file", "shelf.png")
		_, _ = fw.Write(tinyPNG)
		_ = mw.Close()
		req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/v1/store/uploads", &body)
		req.Header.Set("Content-Type", mw.FormDataContentType())
		req.Header.Set("Authorization", "Bearer "+ownerTok)
		res, err := srv.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		out := map[string]any{}
		_ = json.NewDecoder(res.Body).Decode(&out)
		return out["url"].(string)
	}
	img := upload()
	a.expect(a.do("POST", "/store/start/photos", ownerTok, map[string]any{"store_id": storeID, "images": []string{img}}), 409, "ai off")
	a.expect(a.do("PUT", "/admin/ai", adminTok, map[string]any{"provider": "openai", "base_url": aisrv.URL + "/v1", "api_key": fai.key, "model": "gpt-4o"}), 200, "ai on")

	fai.set(`{"items":[{"name":"Напиток Coca-Cola 1,5 л","brand":"Coca-Cola","qty":6},
	 {"name":"Fanta","brand":"Fanta","barcode":"","qty":"4"},
	 {"name":"Напиток Coca-Cola Zero 1 л","brand":"Coca-Cola","barcode":"5449000054227","qty":3},
	 {"name":"Квас Navruz 1,5 л","brand":"Navruz","qty":2},
	 {"name":"Напиток Coca-Cola 1,5 л","qty":2}]}`)
	ph := a.expect(a.do("POST", "/store/start/photos", ownerTok, map[string]any{"store_id": storeID, "images": []string{img}}), 202, "photo")
	if ph.str("status") != "ready" {
		t.Fatalf("photo = %v", ph.Body)
	}
	items := ph.Body["items"].([]any)
	item := func(i int) map[string]any { return items[i].(map[string]any) }
	if len(items) != 4 {
		t.Fatalf("items = %v", items)
	}
	if it := item(0); it["state"] != "found" || it["product"].(map[string]any)["product_id"] != cola || it["qty"] != "8" || it["in_draft"] != true {
		t.Fatalf("cola item = %v", it)
	}
	if it := item(2); it["state"] != "found" || it["product"].(map[string]any)["product_id"] != zero || it["in_draft"] != false {
		t.Fatalf("zero by barcode = %v", it)
	}
	if it := item(3); it["state"] != "missing" || it["product"] != nil {
		t.Fatalf("kvass = %v", it)
	}
	if it := item(1); it["state"] != "found" || it["product"].(map[string]any)["product_id"] != fanta || it["category_id"] != drinks {
		t.Fatalf("fanta = %v", it)
	}
	if c := ph.Body["counts"].(map[string]any); c["found"] != 3.0 || c["missing"] != 1.0 {
		t.Fatalf("counts = %v", c)
	}
	a.expect(a.do("GET", "/store/start/photos/"+ph.str("id"), otherTok, nil), 404, "foreign photo")
	// Ошибка модели — можно повторить.
	fai.set(`{"items":[]}`)
	bad := a.expect(a.do("POST", "/store/start/photos", ownerTok, map[string]any{"store_id": storeID, "images": []string{upload()}}), 202, "empty photo")
	if bad.str("status") != "failed" || bad.str("error") == "" {
		t.Fatalf("failed photo = %v", bad.Body)
	}
	fai.set(`{"items":[{"name":"Напиток Coca-Cola Zero 1 л","qty":3}]}`)
	if rr := a.expect(a.do("POST", "/store/start/photos/"+bad.str("id")+"/retry", ownerTok, nil), 202, "retry"); rr.str("status") != "ready" {
		t.Fatalf("retry = %v", rr.Body)
	}
	// Найденное на фото — одним запросом; то, что уже в списке, пропускается.
	r = a.expect(lines(
		map[string]any{"product_id": cola, "add": true, "qty": 8, "source": "photo"},
		map[string]any{"product_id": fanta, "add": true, "qty": 4, "source": "photo"},
		map[string]any{"product_id": zero, "add": true, "qty": 3, "source": "photo"},
	), 200, "photo lines")
	if sk := r.Body["skipped"].([]any); len(sk) != 1 || sk[0] != cola || len(r.Body["lines"].([]any)) != 2 {
		t.Fatalf("photo add = %v", r.Body)
	}
	a.expect(lines(map[string]any{"product_id": apples, "add": true, "source": "search"}), 200, "apples")
	// Один товар с фото, который уже в списке, — тоже пропуск, без ошибки.
	if r := a.expect(lines(map[string]any{"product_id": fanta, "add": true, "qty": 2, "source": "photo"}), 200, "photo single"); len(r.Body["skipped"].([]any)) != 1 {
		t.Fatalf("photo single = %v", r.Body)
	}

	colaPet := product("Напиток Coca-Cola 1,5 л ПЭТ", pcs, 15000, "")
	if s := search("coca 1,5"); len(s) != 2 || s[0]["added"] != true || s[1]["product_id"] != colaPet || s[1]["added"] != false {
		t.Fatalf("search with pet = %v", s)
	}
	// Похожий товар (тот же бренд и объём) — спросить; «всё равно добавить» —
	// для этой пары больше не спрашиваем.
	sim := a.expect(lines(map[string]any{"product_id": colaPet, "add": true}), 409, "similar")
	if code(sim) != "similar_exists" || sim.str("error", "details", "similar", "product_id") != cola || sim.str("error", "details", "similar", "barcode") != "5449000000996" {
		t.Fatalf("similar = %v", sim.Body)
	}
	a.expect(lines(map[string]any{"product_id": colaPet, "add": true, "confirm_similar": true}), 200, "add anyway")
	a.expect(a.do("DELETE", "/store/start/lines/"+colaPet+"?store_id="+storeID, ownerTok, nil), 200, "remove similar")
	a.expect(lines(map[string]any{"product_id": colaPet, "add": true}), 200, "similar asked once")
	a.expect(a.do("DELETE", "/store/start/lines/"+colaPet+"?store_id="+storeID, ownerTok, nil), 200, "remove similar again")
	a.expect(a.do("DELETE", "/store/start/lines/"+colaPet+"?store_id="+storeID, ownerTok, nil), 404, "delete twice")

	// Шаг 2 — «Инвентаризация: Начало работы».
	a.expect(lines(map[string]any{"product_id": cola, "qty": 1.5}), 400, "fractional pcs")
	a.expect(lines(map[string]any{"product_id": cola, "qty": -1}), 400, "negative qty")
	a.expect(lines(map[string]any{"product_id": cola, "price": -5}), 400, "negative price")
	r = a.expect(lines(map[string]any{"product_id": cola, "qty": 24, "cost": 11200, "price": 16000}), 200, "cola step 2")
	if l := r.Body["lines"].([]any)[0].(map[string]any); l["qty"] != "24" || l["cost"] != "11200" || l["price"] != "16000.00" || l["current_price"] != "15000.00" {
		t.Fatalf("cola filled = %v", l)
	}
	// Привязать штрихкод к товару без штрихкода; чужой штрихкод — 409.
	a.expect(lines(map[string]any{"product_id": zero, "barcode": "5449000054227"}), 200, "bind barcode")
	conf := a.expect(lines(map[string]any{"product_id": fanta, "barcode": "5449000000996"}), 409, "taken barcode")
	if conf.str("error", "details", "product_id") != cola {
		t.Fatalf("conflict = %v", conf.Body)
	}
	if found := a.expect(a.do("GET", "/store/products?barcode=5449000054227", ownerTok, nil), 200, "by barcode").items(); len(found) != 1 || found[0]["id"] != zero {
		t.Fatalf("bound barcode = %v", found)
	}
	// Очистить количество — строка снова не заполнена.
	a.expect(lines(map[string]any{"product_id": fanta, "qty": nil}), 200, "clear qty")
	d = a.expect(a.do("GET", "/store/start?store_id="+storeID+"&only=unfilled", ownerTok, nil), 200, "unfilled")
	if n := len(d.Body["lines"].([]any)); n != 3 || d.Body["totals"].(map[string]any)["unfilled"] != 3.0 {
		t.Fatalf("unfilled = %d %v", n, d.Body["totals"])
	}
	d = a.expect(a.do("GET", "/store/start?store_id="+storeID+"&q=coca", ownerTok, nil), 200, "search lines")
	if ls := d.Body["lines"].([]any); len(ls) != 2 {
		t.Fatalf("search lines = %v", ls)
	}
	// Другая сеть не видит черновик.
	a.expect(a.do("GET", "/store/start?store_id="+storeID, otherTok, nil), 404, "other network")

	// «Записать и закрыть» — только когда у всех строк есть количество и цена.
	if p := a.expect(a.do("POST", "/store/start/post", ownerTok, map[string]any{"store_id": storeID}), 409, "post unfilled"); code(p) != "lines_unfilled" || p.Body["error"].(map[string]any)["details"].(map[string]any)["count"] != 3.0 {
		t.Fatalf("unfilled post = %v", p.Body)
	}
	a.expect(lines(map[string]any{"product_id": zero, "qty": 0, "price": 0}), 200, "zero: 0 pcs, price 0")
	a.expect(lines(map[string]any{"product_id": fanta, "qty": 12, "cost": 9800, "price": 11990}), 200, "fanta")
	a.expect(lines(map[string]any{"product_id": apples, "qty": 3.25, "price": 22000}), 200, "apples: no cost")

	// Новый товар сети (нет в базе) — на модерацию, но в «Мои товары» можно.
	kvass := a.expect(a.do("POST", "/store/products", ownerTok, map[string]any{"name": "Квас Navruz 1,5 л", "category_id": drinks, "unit_id": pcs,
		"base_price": 12000, "barcodes": []string{"4780098765432"}, "images": []string{"https://cdn.example/kvass.png"}}), 201, "own product").str("id")
	a.expect(lines(map[string]any{"product_id": kvass, "add": true, "qty": 2, "cost": 9500, "price": 12000, "source": "new"}), 200, "kvass line")
	// Свой товар, похожий на уже добавленный: из поиска — вопрос, только что созданный — без вопроса.
	glass := a.expect(a.do("POST", "/store/products", ownerTok, map[string]any{"name": "Напиток Coca-Cola 1,5 л стекло", "category_id": drinks, "unit_id": pcs,
		"base_price": 15000}), 201, "own similar").str("id")
	if c := a.expect(lines(map[string]any{"product_id": glass, "add": true, "source": "search"}), 409, "own similar asked"); code(c) != "similar_exists" {
		t.Fatalf("own similar = %v", c.Body)
	}
	a.expect(lines(map[string]any{"product_id": glass, "add": true, "source": "new"}), 200, "new: no question")
	a.expect(a.do("DELETE", "/store/start/lines/"+glass+"?store_id="+storeID, ownerTok, nil), 200, "remove glass")

	// Записать и закрыть.
	res := a.expect(a.do("POST", "/store/start/post", ownerTok, map[string]any{"store_id": storeID}), 200, "post")
	if res.Body["products"] != 5.0 || res.str("qty") != "41.25" || len(res.Body["documents"].([]any)) != 1 || res.Body["price_document"] == nil ||
		res.Body["visible"] != 4.0 || res.Body["pending"] != 1.0 || res.str("cost_total") != "405400.00" {
		t.Fatalf("post = %v", res.Body)
	}
	a.expect(a.do("POST", "/store/start/post", ownerTok, map[string]any{"store_id": storeID}), 409, "post twice")
	doc := a.expect(a.do("GET", "/store/inventory/documents/"+res.Body["documents"].([]any)[0].(map[string]any)["id"].(string), ownerTok, nil), 200, "posting")
	if doc.str("type") != "posting" || doc.str("status") != "posted" || len(doc.Body["items"].([]any)) != 4 {
		t.Fatalf("doc = %v", doc.Body)
	}
	// Остатки и цены магазина (в том числе 0).
	stock := a.expect(a.do("GET", "/store/inventory/stock?store_id="+storeID+"&product_id="+cola, ownerTok, nil), 200, "stock").items()
	if len(stock) != 1 || stock[0]["qty"] != "24.000" {
		t.Fatalf("stock = %v", stock)
	}
	priceOf := func(q string) string {
		t.Helper()
		sp := a.expect(a.do("GET", "/store/products?store_id="+storeID+"&q="+url.QueryEscape(q), ownerTok, nil), 200, "price "+q).items()
		if len(sp) == 0 {
			t.Fatalf("no product %q", q)
		}
		return sp[0]["price"].(string)
	}
	if p := priceOf("Coca-Cola 1,5 л"); p != "16000.00" {
		t.Fatalf("cola price = %s", p)
	}
	if p := priceOf("Zero"); p != "0.00" {
		t.Fatalf("zero price = %s", p)
	}
	// «Начало работы» закрыто: больше не показывается, добавить нельзя.
	d = a.expect(a.do("GET", "/store/start?store_id="+storeID, ownerTok, nil), 200, "after post")
	if d.Body["id"] != nil || d.Body["closed"] != true || d.Body["stock_products"] != 4.0 || d.Body["last_posted_at"] == nil {
		t.Fatalf("after = %v", d.Body)
	}
	if c := a.expect(lines(map[string]any{"product_id": pepsi, "add": true}), 409, "closed"); code(c) != "start_closed" {
		t.Fatalf("closed = %v", c.Body)
	}

	// Раздел «Товары» — только «Мои товары» магазина (scope=mine).
	mine := func(extra string) map[string]bool {
		t.Helper()
		out := map[string]bool{}
		for _, it := range a.expect(a.do("GET", "/store/products?scope=mine&limit=100"+extra, ownerTok, nil), 200, "mine"+extra).items() {
			out[it["id"].(string)] = true
		}
		return out
	}
	if m := mine("&store_id=" + storeID); len(m) != 5 || !m[cola] || !m[zero] || !m[fanta] || !m[apples] || !m[kvass] || m[pepsi] || m[colaPet] {
		t.Fatalf("mine = %v", m)
	}
	if m := mine(""); len(m) != 5 {
		t.Fatalf("mine in network = %v", m)
	}
	if all := a.expect(a.do("GET", "/store/products?store_id="+storeID+"&q=pepsi", ownerTok, nil), 200, "all").items(); len(all) != 1 {
		t.Fatalf("central base = %v", all)
	}
	a.expect(a.do("GET", "/store/products?scope=bad", ownerTok, nil), 400, "bad scope")
	if g := a.expect(a.do("GET", "/store/products/groups?scope=mine&store_id="+storeID, ownerTok, nil), 200, "mine groups"); g.Body["total"] != 5.0 {
		t.Fatalf("mine groups = %v", g.Body)
	}
	a.expect(a.do("GET", "/store/products/groups?scope=mine&store_id="+otherStore, ownerTok, nil), 404, "foreign groups")
	if m := a.expect(a.do("GET", "/store/products?scope=mine&store_id="+otherStore, otherTok, nil), 200, "other mine").items(); len(m) != 0 {
		t.Fatalf("other store mine = %v", m)
	}
	// Свой товар из раздела «Товары» сразу в «Моих товарах».
	own := a.expect(a.do("POST", "/store/products", ownerTok, map[string]any{"name": "Лимонад домашний 1 л", "category_id": drinks, "unit_id": pcs,
		"base_price": 8000, "store_id": storeID}), 201, "own product in store").str("id")
	a.expect(a.do("POST", "/store/products", ownerTok, map[string]any{"name": "Лимонад 2 л", "category_id": drinks, "unit_id": pcs,
		"store_id": otherStore}), 404, "own product foreign store")
	// Цена магазина на товар — он тоже в «Моих товарах».
	var retail string
	for _, pt := range a.expect(a.do("GET", "/store/price-types", ownerTok, nil), 200, "price types").items() {
		if pt["is_default"] == true {
			retail = pt["id"].(string)
		}
	}
	pdoc := a.expect(a.do("POST", "/store/price-documents", ownerTok, map[string]any{"price_type_id": retail, "store_id": storeID,
		"items": []map[string]any{{"product_id": pepsi, "new_price": "9500"}}}), 201, "price doc").str("id")
	a.expect(a.do("POST", "/store/price-documents/"+pdoc+"/post", ownerTok, nil), 200, "post price doc")
	if m := mine("&store_id=" + storeID); len(m) != 7 || !m[own] || !m[pepsi] {
		t.Fatalf("mine after = %v", m)
	}
	// Расход ИИ записан как «фото полок».
	var shelves int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM ai_usage WHERE kind = 'shelf' AND photo_id IS NOT NULL`).Scan(&shelves); err != nil || shelves != 3 {
		t.Fatalf("ai usage shelves = %d %v", shelves, err)
	}
}
