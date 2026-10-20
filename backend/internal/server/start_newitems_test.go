package server_test

import (
	"bytes"
	"context"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// TestStartNewItems — новый товар по фото: магазин фотографирует товар,
// которого нет в базе, и работает дальше; Super Market заполняет карточку,
// магазин подтверждает. Свои новые товары уходят на модерацию при
// «Записать и закрыть».
func TestStartNewItems(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	s3 := &fakeS3{buckets: map[string]bool{}, objects: map[string][]byte{}, types: map[string]string{}}
	s3srv := httptest.NewServer(s3)
	t.Cleanup(s3srv.Close)
	fai := &fakeCategoryAI{}
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
	otherTok, _ := setupNetwork(t, a, adminTok, "+998900000003")

	drinks := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Напитки"}), 201, "drinks").str("id")
	juices := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Соки и нектары", "parent_id": drinks}), 201, "juices").str("id")
	var pcs string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		if u["short_name"] == "шт" {
			pcs = u["id"].(string)
		}
	}
	known := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{"name": "Сок Bliss яблочный, 1 л", "category_id": juices, "unit_id": pcs,
		"images": []string{"https://cdn.example/bliss.png"}}), 201, "known").str("id")

	upload := func() string {
		t.Helper()
		var body bytes.Buffer
		mw := multipart.NewWriter(&body)
		fw, _ := mw.CreateFormFile("file", "item.png")
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
	list := func() resp {
		return a.expect(a.do("GET", "/store/start/new-items?store_id="+storeID, ownerTok, nil), 200, "list")
	}
	img := upload()

	// ИИ не подключён: карточка сразу «не удалось» — фото и штрихкод есть, остальное магазин заполняет сам.
	a.expect(a.do("POST", "/store/start/new-items", ownerTok, map[string]any{"store_id": storeID, "images": []string{}}), 400, "no photos")
	a.expect(a.do("POST", "/store/start/new-items", ownerTok, map[string]any{"store_id": storeID, "images": []string{"https://evil.example/x.png"}}), 400, "foreign photo")
	off := a.expect(a.do("POST", "/store/start/new-items", ownerTok, map[string]any{"store_id": storeID, "barcode": "4780098765432", "images": []string{img}}), 202, "ai off")
	imgs, _ := off.Body["images"].([]any)
	if off.str("status") != "failed" || off.str("error") == "" || len(imgs) != 1 || off.str("barcode") != "4780098765432" {
		t.Fatalf("ai off = %v", off.Body)
	}
	a.expect(a.do("GET", "/store/start/new-items/"+off.str("id"), otherTok, nil), 404, "foreign item")
	if l := list(); len(l.items()) != 1 || l.Body["counts"].(map[string]any)["failed"] != 1.0 {
		t.Fatalf("list = %v", l.Body)
	}
	// Заполнили сами — свой товар сети в статусе draft, в «Моих товарах».
	a.expect(a.do("POST", "/store/start/new-items/"+off.str("id")+"/confirm", ownerTok, map[string]any{"store_id": storeID, "name": "Квас Navruz, 1,5 л"}), 400, "no category")
	c := a.expect(a.do("POST", "/store/start/new-items/"+off.str("id")+"/confirm", ownerTok, map[string]any{
		"store_id": storeID, "name": "Квас Navruz, 1,5 л", "brand_name": "Navruz", "category_id": juices, "unit_id": pcs, "images": []string{img},
	}), 200, "confirm manual")
	kvass := c.str("product_id")
	if c.Body["created"] != true || c.str("line", "source") != "new" || c.str("line", "barcode") != "4780098765432" || c.str("line", "moderation") != "draft" {
		t.Fatalf("confirm manual = %v", c.Body)
	}
	a.expect(a.do("POST", "/store/start/new-items/"+off.str("id")+"/confirm", ownerTok, map[string]any{"store_id": storeID, "product_id": known}), 409, "again")
	if l := list(); len(l.items()) != 0 {
		t.Fatalf("list after confirm = %v", l.Body)
	}
	// Черновой свой товар не в очереди модерации.
	if q := a.expect(a.do("GET", "/admin/products?status=pending", adminTok, nil), 200, "moderation").items(); len(q) != 0 {
		t.Fatalf("pending = %v", q)
	}

	// ИИ подключён: карточка готова, похожий товар базы найден.
	a.expect(a.do("PUT", "/admin/ai", adminTok, map[string]any{"provider": "openai", "base_url": aisrv.URL + "/v1", "api_key": "sk-cat", "model": "gpt-4o"}), 200, "ai on")
	fai.set(`{"product":true,"name":"Сок Bliss яблочный, 1 л","name_uz":"Bliss olma sharbati, 1 l","brand":"Bliss","unit":"шт",
		"description":"Яблочный сок прямого отжима","match":"`+juices+`","alternatives":[]}`, `{"texts":["x"]}`)
	r := a.expect(a.do("POST", "/store/start/new-items", ownerTok, map[string]any{"store_id": storeID, "barcode": "4780011223344", "images": []string{img, img}}), 202, "recognize")
	res, _ := r.Body["result"].(map[string]any)
	sg, _ := res["suggestion"].(map[string]any)
	cat, _ := sg["category"].(map[string]any)
	match, _ := res["match"].(map[string]any)
	if r.str("status") != "ready" || res["name"] != "Сок Bliss яблочный, 1 л" || res["unit_id"] != pcs || cat["id"] != juices || match["product_id"] != known {
		t.Fatalf("recognized = %v", r.Body)
	}
	// «Это он» — добавлен товар базы, штрихкод привязан к нему.
	c = a.expect(a.do("POST", "/store/start/new-items/"+r.str("id")+"/confirm", ownerTok, map[string]any{"store_id": storeID, "product_id": known}), 200, "it is")
	if c.Body["created"] != false || c.str("product_id") != known || c.str("line", "barcode") != "4780011223344" {
		t.Fatalf("it is = %v", c.Body)
	}

	// Новый товар с новой категорией по предложению Super Market.
	fai.set(`{"product":true,"name":"Печенье Юбилейное, 112 г","name_uz":"Yubileynoe pechenyesi, 112 g","brand":"Юбилейное","unit":"шт",
		"match":"","new":{"parent_name":"Сладости","parent_name_uz":"Shirinliklar","name":"Печенье","name_uz":"Pechenye"}}`, `{"texts":["x"]}`)
	r = a.expect(a.do("POST", "/store/start/new-items", ownerTok, map[string]any{"store_id": storeID, "images": []string{img}}), 202, "cookies")
	res, _ = r.Body["result"].(map[string]any)
	sg, _ = res["suggestion"].(map[string]any)
	nc, _ := sg["new"].(map[string]any)
	if r.str("status") != "ready" || nc["name"] != "Печенье" || nc["parent_id"] != nil || res["match"] != nil {
		t.Fatalf("cookies = %v", r.Body)
	}
	c = a.expect(a.do("POST", "/store/start/new-items/"+r.str("id")+"/confirm", ownerTok, map[string]any{
		"store_id": storeID, "name": res["name"], "name_uz": res["name_uz"], "brand_name": res["brand"], "new_category": nc, "unit_id": res["unit_id"],
		"images": []string{img},
	}), 200, "cookies confirm")
	cookies := c.str("product_id")

	// Не товар на фото — «не удалось», можно повторить или удалить.
	fai.set(`{"product":false,"problem":"на фото не видно товара"}`, `{"texts":["x"]}`)
	r = a.expect(a.do("POST", "/store/start/new-items", ownerTok, map[string]any{"store_id": storeID, "images": []string{img}}), 202, "blurry")
	if r.str("status") != "failed" || r.str("error") == "" {
		t.Fatalf("blurry = %v", r.Body)
	}
	a.expect(a.do("POST", "/store/start/new-items/"+r.str("id")+"/retry", ownerTok, nil), 202, "retry")
	// «Распознать заново» — все нераспознанные разом; снова не вышло — опять «не удалось».
	if ra := a.expect(a.do("POST", "/store/start/new-items/retry-all", ownerTok, map[string]any{"store_id": storeID}), 202, "retry all"); ra.Body["count"] != 1.0 {
		t.Fatalf("retry all = %v", ra.Body)
	}
	if g := a.expect(a.do("GET", "/store/start/new-items/"+r.str("id"), ownerTok, nil), 200, "after retry all"); g.str("status") != "failed" {
		t.Fatalf("after retry all = %v", g.Body)
	}
	a.expect(a.do("POST", "/store/start/new-items/retry-all", otherTok, map[string]any{"store_id": storeID}), 404, "retry all foreign store")
	a.expect(a.do("DELETE", "/store/start/new-items/"+r.str("id"), ownerTok, nil), 200, "delete")
	if ra := a.expect(a.do("POST", "/store/start/new-items/retry-all", ownerTok, map[string]any{"store_id": storeID}), 202, "retry all empty"); ra.Body["count"] != 0.0 {
		t.Fatalf("retry all empty = %v", ra.Body)
	}
	a.expect(a.do("GET", "/store/start/new-items/"+r.str("id"), ownerTok, nil), 404, "deleted")

	// Без дублей: тот же штрихкод второй раз в «Новые» не попадает — сканер
	// узнаёт карточку по штрихкоду; тот же товар без штрихкода помечается
	// «похоже на дубль», «Это он» объединяет карточки.
	fai.set(`{"product":true,"name":"Лапша Биг Ланч, 75 г","name_uz":"Big Lanch lapshasi, 75 g","brand":"Биг Ланч","unit":"шт","match":"`+juices+`"}`, `{"texts":["x"]}`)
	first := a.expect(a.do("POST", "/store/start/new-items", ownerTok, map[string]any{"store_id": storeID, "barcode": "4780022223333", "images": []string{img}}), 202, "noodles")
	again := a.expect(a.do("POST", "/store/start/new-items", ownerTok, map[string]any{"store_id": storeID, "barcode": "4780022223333", "images": []string{img}}), 409, "same barcode")
	if det, _ := again.Body["error"].(map[string]any)["details"].(map[string]any); det["item_id"] != first.str("id") {
		t.Fatalf("same barcode = %v", again.Body)
	}
	if lk := a.expect(a.do("GET", "/store/start/new-items/by-barcode?store_id="+storeID+"&code=4780022223333", ownerTok, nil), 200, "by barcode"); lk.str("item", "id") != first.str("id") {
		t.Fatalf("by barcode = %v", lk.Body)
	}
	if lk := a.expect(a.do("GET", "/store/start/new-items/by-barcode?store_id="+storeID+"&code=4780000000000", ownerTok, nil), 200, "by barcode none"); lk.Body["item"] != nil {
		t.Fatalf("by barcode none = %v", lk.Body)
	}
	a.expect(a.do("GET", "/store/start/new-items/by-barcode?store_id="+storeID+"&code=4780022223333", otherTok, nil), 404, "foreign store")
	img2, img3 := upload(), upload()
	dupA := a.expect(a.do("POST", "/store/start/new-items", ownerTok, map[string]any{"store_id": storeID, "images": []string{img2}}), 202, "dup a")
	dupB := a.expect(a.do("POST", "/store/start/new-items", ownerTok, map[string]any{"store_id": storeID, "images": []string{img3}}), 202, "dup b")
	// Страницы: в очереди 3 карточки; счётчики и total — по всей очереди.
	pg := func(q string) resp {
		return a.expect(a.do("GET", "/store/start/new-items?store_id="+storeID+q, ownerTok, nil), 200, "page"+q)
	}
	p1, p2, p3 := pg("&limit=2"), pg("&limit=2&offset=2"), pg("&limit=2&offset=4")
	if len(p1.items()) != 2 || len(p2.items()) != 1 || len(p3.items()) != 0 || p1.Body["total"] != 3.0 || p3.Body["total"] != 3.0 {
		t.Fatalf("pages = %v | %v | %v", p1.Body, p2.Body, p3.Body)
	}
	if c := p2.Body["counts"].(map[string]any); c["ready"].(float64)+c["failed"].(float64)+c["processing"].(float64) != 3 {
		t.Fatalf("page counts = %v", p2.Body)
	}
	if seen := map[any]bool{p1.items()[0]["id"]: true, p1.items()[1]["id"]: true}; seen[p2.items()[0]["id"]] {
		t.Fatalf("page overlap = %v | %v", p1.Body, p2.Body)
	}
	marks := map[string]any{}
	for _, it := range list().items() {
		marks[it["id"].(string)] = it["duplicate"]
	}
	// Помечается только более поздняя карточка; ранняя — нет (её штрихкодом тоже).
	if d, _ := marks[dupB.str("id")].(map[string]any); d["id"] != first.str("id") && d["id"] != dupA.str("id") {
		t.Fatalf("dup b mark = %v", marks)
	}
	if marks[first.str("id")] != nil {
		t.Fatalf("first marked = %v", marks)
	}
	a.expect(a.do("POST", "/store/start/new-items/"+dupB.str("id")+"/merge", ownerTok, map[string]any{"store_id": storeID, "into": dupB.str("id")}), 400, "merge self")
	a.expect(a.do("POST", "/store/start/new-items/"+dupB.str("id")+"/merge", otherTok, map[string]any{"store_id": storeID, "into": dupA.str("id")}), 404, "merge foreign")
	m := a.expect(a.do("POST", "/store/start/new-items/"+dupB.str("id")+"/merge", ownerTok, map[string]any{"store_id": storeID, "into": dupA.str("id")}), 200, "merge")
	if mi, _ := m.Body["images"].([]any); m.str("id") != dupA.str("id") || len(mi) != 2 {
		t.Fatalf("merged = %v", m.Body)
	}
	a.expect(a.do("GET", "/store/start/new-items/"+dupB.str("id"), ownerTok, nil), 404, "merged away")
	for _, id := range []string{first.str("id"), dupA.str("id")} {
		a.expect(a.do("DELETE", "/store/start/new-items/"+id, ownerTok, nil), 200, "cleanup")
	}

	var usage int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM ai_usage WHERE kind = 'product' AND store_id = $1`, storeID).Scan(&usage); err != nil || usage != 8 {
		t.Fatalf("product usage = %d %v", usage, err)
	}

	// Ручная форма «Нового товара» в «Начале работы» — тоже draft.
	manual := a.expect(a.do("POST", "/store/products", ownerTok, map[string]any{"name": "Чай Ахмад, 100 г", "category_id": juices, "unit_id": pcs, "start_draft": true}), 201, "manual draft")
	if manual.str("moderation_status") != "draft" {
		t.Fatalf("manual = %v", manual.Body)
	}
	a.expect(a.do("POST", "/store/start/lines", ownerTok, map[string]any{"store_id": storeID, "items": []map[string]any{{"product_id": manual.str("id"), "add": true, "source": "new"}}}), 200, "manual line")

	// «Записать и закрыть» — новые товары уходят на модерацию.
	d := a.expect(a.do("GET", "/store/start?store_id="+storeID, ownerTok, nil), 200, "draft")
	items := []map[string]any{}
	for _, l := range d.Body["lines"].([]any) {
		items = append(items, map[string]any{"product_id": l.(map[string]any)["product_id"], "qty": 1, "price": 1000})
	}
	a.expect(a.do("POST", "/store/start/lines", ownerTok, map[string]any{"store_id": storeID, "items": items}), 200, "fill")

	// Фото не обязательно, но счётчик «Без фото» его видит.
	if d := a.expect(a.do("GET", "/store/start?store_id="+storeID, ownerTok, nil), 200, "no photo"); d.Body["totals"].(map[string]any)["no_photo"] != 1.0 {
		t.Fatalf("no_photo = %v", d.Body["totals"])
	}
	a.expect(a.do("POST", "/store/start/lines/"+manual.str("id")+"/photo", ownerTok, map[string]any{"store_id": storeID, "images": []string{img}}), 200, "line photo")
	if d := a.expect(a.do("GET", "/store/start?store_id="+storeID, ownerTok, nil), 200, "no photo gone"); d.Body["totals"].(map[string]any)["no_photo"] != 0.0 {
		t.Fatalf("no_photo = %v", d.Body["totals"])
	}
	a.expect(a.do("POST", "/store/start/post", ownerTok, map[string]any{"store_id": storeID}), 200, "post")
	for _, id := range []string{kvass, cookies, manual.str("id")} {
		var st string
		if err := pool.QueryRow(ctx, `SELECT moderation_status FROM products WHERE id = $1`, id).Scan(&st); err != nil || st != "pending" {
			t.Fatalf("product %s status = %q %v", id, st, err)
		}
	}
	if q := a.expect(a.do("GET", "/admin/products?status=pending", adminTok, nil), 200, "moderation after post").items(); len(q) != 3 {
		t.Fatalf("pending after post = %d", len(q))
	}
}
