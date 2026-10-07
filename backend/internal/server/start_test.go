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

	// Пустой черновик: товаров на складе нет.
	d := a.expect(a.do("GET", "/store/start?store_id="+storeID, ownerTok, nil), 200, "empty draft")
	if d.Body["id"] != nil || d.Body["stock_products"] != 0.0 || d.str("warehouse_name") == "" || len(d.Body["lines"].([]any)) != 0 {
		t.Fatalf("empty = %v", d.Body)
	}
	a.expect(a.do("GET", "/store/start?store_id="+otherStore, ownerTok, nil), 404, "foreign store")
	a.expect(a.do("POST", "/store/start/post", ownerTok, map[string]any{"store_id": storeID}), 409, "post empty")

	lines := func(items ...map[string]any) resp {
		return a.do("POST", "/store/start/lines", ownerTok, map[string]any{"store_id": storeID, "items": items})
	}
	// Штрихкод: количество, закупка и своя цена продажи.
	r := a.expect(lines(map[string]any{"product_id": cola, "qty": 24, "cost": 11200, "price": 16000, "source": "barcode"}), 200, "cola")
	if l := r.Body["lines"].([]any)[0].(map[string]any); l["qty"] != "24" || l["cost"] != "11200" || l["price"] != "16000.00" ||
		l["current_price"] != "15000.00" || l["barcode"] != "5449000000996" || l["source"] != "barcode" {
		t.Fatalf("cola line = %v", l)
	}
	// Повторный скан — +1 штука; поля, которых нет, не меняются.
	a.expect(lines(map[string]any{"product_id": cola, "add": true}), 200, "scan again")
	// Каталог: сразу несколько; дробное количество — только для весовых.
	a.expect(lines(map[string]any{"product_id": fanta, "qty": 1.5}), 400, "fractional pcs")
	a.expect(lines(map[string]any{"product_id": fanta, "qty": 0}), 400, "zero qty")
	a.expect(lines(map[string]any{"product_id": zero}), 400, "no qty for new line")
	r = a.expect(lines(
		map[string]any{"product_id": fanta, "qty": 12, "cost": 9800, "source": "catalog"},
		map[string]any{"product_id": apples, "qty": 3.25, "source": "catalog"},
		map[string]any{"product_id": zero, "qty": 6, "source": "search"},
	), 200, "catalog")
	if tot := r.Body["totals"].(map[string]any); tot["products"] != 4.0 || tot["qty"] != "46.25" || tot["no_cost"] != 2.0 ||
		tot["cost_total"] != "397600.00" || tot["price_total"] != "687320.00" {
		t.Fatalf("totals = %v", tot)
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
	// Убрать и вернуть; сброс закупки null.
	a.expect(a.do("DELETE", "/store/start/lines/"+zero+"?store_id="+storeID, ownerTok, nil), 200, "delete line")
	a.expect(a.do("DELETE", "/store/start/lines/"+zero+"?store_id="+storeID, ownerTok, nil), 404, "delete twice")
	a.expect(lines(map[string]any{"product_id": fanta, "cost": nil}), 200, "clear cost")

	d = a.expect(a.do("GET", "/store/start?store_id="+storeID+"&only=no_cost", ownerTok, nil), 200, "no cost filter")
	if n := len(d.Body["lines"].([]any)); n != 2 {
		t.Fatalf("no_cost lines = %d %v", n, d.Body["lines"])
	}
	d = a.expect(a.do("GET", "/store/start?store_id="+storeID+"&q=coca", ownerTok, nil), 200, "search")
	if ls := d.Body["lines"].([]any); len(ls) != 1 || ls[0].(map[string]any)["qty"] != "25" {
		t.Fatalf("search lines = %v", ls)
	}
	// Другая сеть не видит черновик.
	a.expect(a.do("GET", "/store/start?store_id="+storeID, otherTok, nil), 404, "other network")

	// Каталог с галочками: группа «Напитки · Coca-Cola», 3 из 4 уже в черновике.
	cat := a.expect(a.do("GET", "/store/start/catalog?store_id="+storeID, ownerTok, nil), 200, "catalog")
	if gs := cat.Body["groups"].([]any); len(gs) != 1 || cat.Body["total"] != 4.0 || cat.Body["selected"] != 3.0 ||
		gs[0].(map[string]any)["brand_id"] != brand || gs[0].(map[string]any)["category_names"].([]any)[0] != "Напитки" {
		t.Fatalf("catalog = %v", cat.Body)
	}
	citems := a.expect(a.do("GET", "/store/start/catalog/items?store_id="+storeID+"&category_id="+drinks+"&brand_id="+brand, ownerTok, nil), 200, "catalog items").items()
	sel := 0
	for _, it := range citems {
		if it["selected"] == true {
			sel++
		} else if it["product_id"] != zero {
			t.Fatalf("unselected = %v", it)
		}
	}
	if len(citems) != 4 || sel != 3 {
		t.Fatalf("items = %v", citems)
	}
	a.expect(a.do("GET", "/store/start/catalog/items?store_id="+storeID+"&category_id=bad", ownerTok, nil), 400, "bad category")
	a.expect(a.do("POST", "/store/start/catalog/select", ownerTok, map[string]any{"store_id": storeID, "selected": true}), 400, "select nothing")
	selected := a.expect(a.do("POST", "/store/start/catalog/select", ownerTok, map[string]any{"store_id": storeID, "category_id": drinks, "selected": true}), 200, "select all")
	if selected.Body["changed"] != 1.0 || selected.Body["totals"].(map[string]any)["products"] != 4.0 {
		t.Fatalf("select = %v", selected.Body)
	}
	unselected := a.expect(a.do("POST", "/store/start/catalog/select", ownerTok, map[string]any{"store_id": storeID, "category_id": drinks, "exact": true, "brand_id": brand, "q": "zero", "selected": false}), 200, "unselect")
	if unselected.Body["changed"] != 1.0 || unselected.Body["totals"].(map[string]any)["products"] != 3.0 {
		t.Fatalf("unselect = %v", unselected.Body)
	}
	a.expect(a.do("GET", "/store/start/catalog?store_id="+storeID, otherTok, nil), 404, "foreign catalog")

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
	// Найденное — в черновик одним запросом.
	a.expect(lines(map[string]any{"product_id": zero, "qty": 3, "add": true, "source": "photo"}), 200, "photo lines")

	// Новый товар сети (нет в каталоге) — на модерацию, но в черновик можно.
	kvass := a.expect(a.do("POST", "/store/products", ownerTok, map[string]any{"name": "Квас Navruz 1,5 л", "category_id": drinks, "unit_id": pcs,
		"base_price": 12000, "barcodes": []string{"4780098765432"}}), 201, "own product").str("id")
	a.expect(lines(map[string]any{"product_id": kvass, "qty": 2, "cost": 9500, "source": "new"}), 200, "kvass line")

	// Проведение.
	res := a.expect(a.do("POST", "/store/start/post", ownerTok, map[string]any{"store_id": storeID}), 200, "post")
	if res.Body["products"] != 5.0 || res.str("qty") != "45.25" || len(res.Body["documents"].([]any)) != 1 || res.Body["price_document"] == nil ||
		res.Body["visible"] != 4.0 || res.Body["pending"] != 1.0 || res.str("cost_total") != "299000.00" {
		t.Fatalf("post = %v", res.Body)
	}
	a.expect(a.do("POST", "/store/start/post", ownerTok, map[string]any{"store_id": storeID}), 409, "post twice")
	doc := a.expect(a.do("GET", "/store/inventory/documents/"+res.Body["documents"].([]any)[0].(map[string]any)["id"].(string), ownerTok, nil), 200, "posting")
	if doc.str("type") != "posting" || doc.str("status") != "posted" || len(doc.Body["items"].([]any)) != 5 {
		t.Fatalf("doc = %v", doc.Body)
	}
	// Остатки и цена магазина.
	stock := a.expect(a.do("GET", "/store/inventory/stock?store_id="+storeID+"&product_id="+cola, ownerTok, nil), 200, "stock").items()
	if len(stock) != 1 || stock[0]["qty"] != "25.000" {
		t.Fatalf("stock = %v", stock)
	}
	sp := a.expect(a.do("GET", "/store/products?store_id="+storeID+"&q="+url.QueryEscape("Coca-Cola 1,5"), ownerTok, nil), 200, "price").items()
	if len(sp) == 0 || sp[0]["price"] != "16000.00" {
		t.Fatalf("store price = %v", sp)
	}
	// Новый черновик пустой, на складе уже есть товары.
	d = a.expect(a.do("GET", "/store/start?store_id="+storeID, ownerTok, nil), 200, "after post")
	if d.Body["id"] != nil || d.Body["stock_products"] != 5.0 || d.Body["last_posted_at"] == nil {
		t.Fatalf("after = %v", d.Body)
	}
	// Расход ИИ записан как «фото полок».
	var shelves int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM ai_usage WHERE kind = 'shelf' AND photo_id IS NOT NULL`).Scan(&shelves); err != nil || shelves != 3 {
		t.Fatalf("ai usage shelves = %d %v", shelves, err)
	}
}
