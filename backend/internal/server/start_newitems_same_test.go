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

// TestStartNewItemsSame — тот же товар или нет. Тот же штрихкод (с точностью
// до ведущих нулей) — тот же товар: добавляется сам, без распознавания.
// Штрихкоды разные — решают поля: другой объём или фасовка — новый товар
// встаёт в «Мои товары» сам; совпало всё — «Требуют внимания» («Это он»
// привязывает штрихкод). Штрихкод с неверной контрольной цифрой — к магазину.
func TestStartNewItemsSame(t *testing.T) {
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
	cfg.MediaBaseURL = "https://cdn.example"
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

	tea := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Чай"}), 201, "tea").str("id")
	bags := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Чёрный чай в пакетиках", "parent_id": tea}), 201, "bags").str("id")
	var pcs string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		if u["short_name"] == "шт" {
			pcs = u["id"].(string)
		}
	}
	piala25 := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{"name": "Чай Piala Gold черный кенийский, 25 пакетиков", "category_id": bags, "unit_id": pcs,
		"barcodes": []string{"4870001579999"}, "images": []string{"https://cdn.example/p25.png"}}), 201, "piala 25").str("id")
	upc := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{"name": "Напиток импортный, 355 мл", "category_id": bags, "unit_id": pcs,
		"barcodes": []string{"036000291452"}}), 201, "upc").str("id")
	a.expect(a.do("PUT", "/admin/ai", adminTok, map[string]any{"provider": "openai", "base_url": aisrv.URL + "/v1", "api_key": "sk-cat", "model": "gpt-4o"}), 200, "ai on")

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
	img := upload()
	recognize := func(name, conf, code string) resp {
		t.Helper()
		fai.set(`{"product":true,"name":"`+name+`","brand":"Piala","unit":"шт","confidence":"`+conf+`","match":"`+bags+`","alternatives":[]}`, `{"texts":["x"]}`)
		return a.expect(a.do("POST", "/store/start/new-items", ownerTok, map[string]any{"store_id": storeID, "barcode": code, "images": []string{img}}), 202, name)
	}
	match := func(r resp) map[string]any {
		res, _ := r.Body["result"].(map[string]any)
		m, _ := res["match"].(map[string]any)
		return m
	}

	// Тот же код в формате EAN-13 (с ведущим нулём) — тот же товар: добавлен сам.
	r := a.expect(a.do("POST", "/store/start/new-items", ownerTok, map[string]any{"store_id": storeID, "barcode": "0036000291452", "images": []string{img}}), 202, "upc as ean")
	if r.str("status") != "done" || r.str("product_id") != upc {
		t.Fatalf("upc as ean = %v", r.Body)
	}

	// Другая фасовка (10, а в базе 25 пакетиков) — точно другой товар: создан сам.
	r = recognize("Чай Piala Gold черный кенийский, 10 пакетиков", "high", "4870001578886")
	if r.str("status") != "done" || r.str("product_id") == "" || r.str("product_id") == piala25 {
		t.Fatalf("piala 10 = %v", r.Body)
	}

	// Всё совпало, а штрихкод другой — к магазину: «тот же товар, другой штрихкод?».
	r = recognize("Чай Piala Gold черный кенийский, 25 пакетиков", "high", "4870001577773")
	if m := match(r); r.str("status") != "ready" || m["product_id"] != piala25 || m["same_barcode"] == true {
		t.Fatalf("piala 25 other code = %v", r.Body)
	}
	// «Это он» — штрихкод привязан к товару базы.
	c := a.expect(a.do("POST", "/store/start/new-items/"+r.str("id")+"/confirm", ownerTok, map[string]any{"store_id": storeID, "product_id": piala25}), 200, "it is")
	if c.str("product_id") != piala25 {
		t.Fatalf("it is = %v", c.Body)
	}
	// Теперь этот код — тот же товар: следующая карточка с ним добавляется сама.
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM product_barcodes WHERE product_id = $1`, piala25).Scan(&n); err != nil || n != 2 {
		t.Fatalf("barcodes of piala 25 = %d, %v", n, err)
	}

	// Неверная контрольная цифра — к магазину, даже если распознано уверенно.
	r = recognize("Чай Piala Gold зелёный №110, 100 г", "high", "4870001576661")
	if r.str("status") != "ready" || r.Body["barcode_invalid"] != true {
		t.Fatalf("bad check digit = %v", r.Body)
	}

	// Очередь: та же карточка с другим кодом — похоже на дубль; другая фасовка — нет.
	first := recognize("Чай Piala Lux с бергамотом, 50 пакетиков", "check", "4870001575557")
	if first.str("status") != "ready" || first.Body["duplicate"] != nil {
		t.Fatalf("lux 50 = %v", first.Body)
	}
	dup := recognize("Чай Piala Lux с бергамотом, 50 пакетиков", "high", "4870001574444")
	if d, _ := dup.Body["duplicate"].(map[string]any); dup.str("status") != "ready" || d == nil || d["id"] != first.str("id") {
		t.Fatalf("lux 50 again = %v", dup.Body)
	}
	other := recognize("Чай Piala Lux с бергамотом, 100 пакетиков", "high", "")
	if other.str("status") != "done" || other.Body["duplicate"] != nil {
		t.Fatalf("lux 100 = %v", other.Body)
	}

	// «Провести все»: в «Требуют внимания» — неверный штрихкод, Lux 50 с
	// сомнениями и его дубль. Проводится только Lux 50; остальные остаются.
	bulk := func(dry bool) resp {
		t.Helper()
		return a.expect(a.do("POST", "/store/start/new-items/confirm-all", ownerTok, map[string]any{"store_id": storeID, "dry_run": dry}), 200, "confirm all")
	}
	num := func(r resp, k string) int { f, _ := r.Body[k].(float64); return int(f) }
	left := func(r resp, k string) int {
		l, _ := r.Body["left"].(map[string]any)
		f, _ := l[k].(float64)
		return int(f)
	}
	list := a.expect(a.do("GET", "/store/start/new-items?store_id="+storeID, ownerTok, nil), 200, "list")
	if cn, _ := list.Body["counts"].(map[string]any); cn["bulk"] != float64(1) {
		t.Fatalf("counts = %v", list.Body["counts"])
	}
	pre := bulk(true)
	if num(pre, "ready") != 1 || num(pre, "added") != 0 || left(pre, "barcode") != 1 || left(pre, "duplicate") != 1 {
		t.Fatalf("dry run = %v", pre.Body)
	}
	if st := a.expect(a.do("GET", "/store/start/new-items/"+first.str("id"), ownerTok, nil), 200, "lux 50").str("status"); st != "ready" {
		t.Fatalf("dry run changed card: %s", st)
	}
	run := bulk(false)
	if num(run, "added") != 1 || num(run, "remaining") != 0 {
		t.Fatalf("run = %v", run.Body)
	}
	lux := a.expect(a.do("GET", "/store/start/new-items/"+first.str("id"), ownerTok, nil), 200, "lux 50 after")
	if lux.str("status") != "done" || lux.str("product_id") == "" {
		t.Fatalf("lux 50 after = %v", lux.Body)
	}
	// Дубль не стал вторым товаром: остался магазину, а в карточке — товар Lux 50 («Это он»).
	d := a.expect(a.do("GET", "/store/start/new-items/"+dup.str("id"), ownerTok, nil), 200, "dup after")
	if m := match(d); d.str("status") != "ready" || m == nil || m["product_id"] != lux.str("product_id") {
		t.Fatalf("dup after = %v", d.Body)
	}
	again := bulk(true)
	if num(again, "ready") != 0 || left(again, "duplicate") != 1 || left(again, "barcode") != 1 {
		t.Fatalf("after run = %v", again.Body)
	}
	if r := bulk(false); num(r, "added") != 0 {
		t.Fatalf("nothing to run = %v", r.Body)
	}
}
