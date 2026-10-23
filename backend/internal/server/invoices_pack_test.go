package server_test

import (
	"bytes"
	"context"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// TestInvoicePacks — строки накладной в упаковках (Figma «Приход по фото
// накладной», Н1–Н9): весовой товар по сумме строки (1 коробка × цена за кг),
// «12 блоков или 12 штук?» по прошлой цене, запоминание блока для поставщика.
func TestInvoicePacks(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	s3 := &fakeS3{buckets: map[string]bool{}, objects: map[string][]byte{}, types: map[string]string{}}
	s3srv := httptest.NewServer(s3)
	t.Cleanup(s3srv.Close)
	fai := &fakeAI{key: "sk-test-key-9a1f"}
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
	a.expect(a.do("PUT", "/admin/ai", adminTok, map[string]any{"provider": "openai", "base_url": aisrv.URL + "/v1", "api_key": fai.key, "model": "gpt-4o"}), 200, "ai")

	upload := func() string {
		t.Helper()
		var body bytes.Buffer
		mw := multipart.NewWriter(&body)
		fw, _ := mw.CreateFormFile("file", "invoice.png")
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
	scan := func(reply string) resp {
		t.Helper()
		fai.set(reply)
		return a.expect(a.do("POST", "/store/invoice-scans", ownerTok, map[string]any{"store_id": storeID, "images": []string{upload()}}), 202, "scan")
	}
	line := func(r resp, i int) map[string]any { return r.Body["lines"].([]any)[i].(map[string]any) }

	cat := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Продукты"}), 201, "category").str("id")
	units := map[string]string{}
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		units[u["short_name"].(string)] = u["id"].(string)
	}
	product := func(name, unit, barcode string) string {
		body := map[string]any{"name": name, "category_id": cat, "unit_id": units[unit], "base_price": 10000}
		if barcode != "" {
			body["barcodes"] = []string{barcode}
		}
		return a.expect(a.do("POST", "/admin/products", adminTok, body), 201, "product "+name).str("id")
	}
	cola := product("Coca-Cola 1,5 л", "шт", "5449000000996")
	chicken := product("Окорочка куриные замороженные", "кг", "")
	supplier := a.expect(a.do("POST", "/store/finance/counterparties", ownerTok, map[string]any{"name": "Linko-SFA", "inn": "305 111 222"}), 201, "supplier").str("id")

	// Прошлый приход колы — 14 000 за штуку.
	first := scan(`{"supplier_name":"Linko-SFA","supplier_inn":"305111222","number":"1","currency":"UZS","total":140000,
	 "lines":[{"name":"Кока-кола 1.5","barcode":"5449000000996","unit":"шт","qty":10,"price":14000,"sum":140000}]}`)
	if l := line(first, 0); l["pack"] != "1.000" || l["stock_qty"] != "10.000" || l["cost"] != "14000.00" {
		t.Fatalf("plain line = %v", l)
	}
	a.expect(a.do("POST", "/store/invoice-scans/"+first.str("id")+"/document", ownerTok, map[string]any{"post": true}), 201, "first income")

	// Накладная № 347930: окорочка — 1 коробка по 12 кг, кола — 12 блоков.
	reply := `{"supplier_name":"Linko-SFA","supplier_inn":"305111222","number":"347930","currency":"UZS","total":1373400,
	 "lines":[{"name":"Окорочка с/з 12 кг мар","unit":"кор","qty":1,"price":30450,"sum":365400},
	          {"name":"Кола 1.5 ПЭТ 12","unit":"","qty":12,"price":84000,"sum":1008000}]}`
	sc := scan(reply)
	id := sc.str("id")
	l1 := line(sc, 0)
	if l1["pack"] != "12.000" || l1["pack_source"] != "sum" || l1["stock_qty"] != "12.000" || l1["cost"] != "30450.00" ||
		l1["sum"] != "365400.00" || l1["read_sum"] != "365400.00" {
		t.Fatalf("chicken line = %v", l1)
	}
	if sc.Body["total_matches"] != true || sc.str("lines_total") != "1373400.00" {
		t.Fatalf("total = %v / %v", sc.Body["total_matches"], sc.Body["lines_total"])
	}

	// Окорочка — выбрать товар (кг): упаковка по сумме остаётся.
	sc = a.expect(a.do("PUT", "/store/invoice-scans/"+id+"/lines/1", ownerTok, map[string]any{"product_id": chicken, "remember": true}), 200, "chicken")
	if l := line(sc, 0); l["state"] != "ok" || l["pack"] != "12.000" || l["unit_short"] != "кг" || l["fractional"] != true {
		t.Fatalf("chicken picked = %v", l)
	}
	// Кола — товар выбран, прошлая цена 14 000 → «12 блоков по 6?», без ответа не провести.
	sc = a.expect(a.do("PUT", "/store/invoice-scans/"+id+"/lines/2", ownerTok, map[string]any{"product_id": cola}), 200, "cola")
	if l := line(sc, 1); l["state"] != "pack" || l["pack"] != "6.000" || l["pack_source"] != "guess" || l["cost"] != "14000.00" {
		t.Fatalf("cola guess = %v", l)
	}
	if sc.Body["counts"].(map[string]any)["pack"] != 1.0 {
		t.Fatalf("counts = %v", sc.Body["counts"])
	}
	a.expect(a.do("POST", "/store/invoice-scans/"+id+"/document", ownerTok, map[string]any{"post": true}), 409, "pack not answered")
	a.expect(a.do("PUT", "/store/invoice-scans/"+id+"/lines/2", ownerTok, map[string]any{"pack": "0"}), 400, "bad pack")

	// «12 штук» — цена становится 84 000 за штуку; затем «12 блоков по 6» с запоминанием.
	sc = a.expect(a.do("PUT", "/store/invoice-scans/"+id+"/lines/2", ownerTok, map[string]any{"pack": "1"}), 200, "pieces")
	if l := line(sc, 1); l["state"] == "pack" || l["stock_qty"] != "12.000" || l["cost"] != "84000.00" {
		t.Fatalf("pieces = %v", l)
	}
	sc = a.expect(a.do("PUT", "/store/invoice-scans/"+id+"/lines/2", ownerTok, map[string]any{"pack": "6", "remember": true}), 200, "blocks")
	if l := line(sc, 1); l["state"] != "ok" || l["stock_qty"] != "72.000" || l["cost"] != "14000.00" || l["sum"] != "1008000.00" {
		t.Fatalf("blocks = %v", l)
	}
	done := a.expect(a.do("POST", "/store/invoice-scans/"+id+"/document", ownerTok, map[string]any{"post": true}), 201, "document")
	doc := a.expect(a.do("GET", "/store/inventory/documents/"+done.str("document_id"), ownerTok, nil), 200, "doc")
	if doc.str("total") != "1373400.00" {
		t.Fatalf("doc = %v", doc.Body)
	}
	for _, it := range doc.Body["items"].([]any) {
		m := it.(map[string]any)
		switch m["product_id"] {
		case cola:
			if m["qty"] != "72.000" || m["price"] != "14000.0000" {
				t.Fatalf("cola item = %v", m)
			}
		case chicken:
			if m["qty"] != "12.000" || m["price"] != "30450.0000" {
				t.Fatalf("chicken item = %v", m)
			}
		}
	}
	var netPack int
	if err := pool.QueryRow(ctx, `SELECT pack FROM network_product_packs WHERE product_id = $1`, cola).Scan(&netPack); err != nil || netPack != 6 {
		t.Fatalf("network pack = %d %v", netPack, err)
	}

	// Следующая накладная Linko-SFA: всё запомнено — товар и блок по 6.
	sc = scan(reply)
	if l := line(sc, 1); l["product_id"] != cola || l["match"] != "alias" || l["pack"] != "6.000" || l["pack_source"] != "remembered" || l["state"] != "ok" {
		t.Fatalf("remembered = %v", l)
	}
	if l := line(sc, 0); l["product_id"] != chicken || l["pack"] != "12.000" || l["pack_source"] != "sum" {
		t.Fatalf("chicken again = %v", l)
	}
	_ = supplier

	// Сумма строки не прочитана (как у накладных до обновления), строка одна —
	// сумма берётся из «Итого»; распознать заново можно, пока нет прихода.
	old := scan(`{"supplier_name":"Linko-SFA","supplier_inn":"305111222","number":"347931","currency":"UZS","total":365400,
	 "lines":[{"name":"Окорочка с/з 12 кг мар","qty":1,"price":30450}]}`)
	if l := line(old, 0); l["pack"] != "12.000" || l["pack_source"] != "sum" || l["stock_qty"] != "12.000" || l["read_sum"] != "365400.00" {
		t.Fatalf("one line without sum = %v", l)
	}
	// Миграция 0077 для старых: та же логика в SQL.
	if _, err := pool.Exec(ctx, `UPDATE invoice_scan_lines SET read_sum = NULL, pack = 1, pack_source = '', cost = NULL WHERE scan_id = $1`, old.str("id")); err != nil {
		t.Fatal(err)
	}
	mig, err := os.ReadFile("../../db/migrations/0077_invoice_old_sums.sql")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, string(mig)); err != nil {
		t.Fatal(err)
	}
	if l := line(a.expect(a.do("GET", "/store/invoice-scans/"+old.str("id"), ownerTok, nil), 200, "old"), 0); l["pack"] != "12.000" || l["cost"] != "30450.00" || l["sum"] != "365400.00" {
		t.Fatalf("migrated old line = %v", l)
	}
	fai.set(reply)
	again := a.expect(a.do("POST", "/store/invoice-scans/"+old.str("id")+"/retry", ownerTok, nil), 202, "retry ready")
	if again.str("status") != "ready" || len(again.Body["lines"].([]any)) != 2 {
		t.Fatalf("retry ready = %v", again.Body)
	}
	a.expect(a.do("POST", "/store/invoice-scans/"+id+"/retry", ownerTok, nil), 409, "retry with income")

	// Подсказки строки отдают, дробный ли товар.
	sug := a.expect(a.do("GET", "/store/invoice-scans/"+sc.str("id")+"/lines/1/suggestions?q=окорочка", ownerTok, nil), 200, "suggest").items()
	if len(sug) == 0 || sug[0]["product_id"] != chicken || sug[0]["fractional"] != true {
		t.Fatalf("suggestions = %v", sug)
	}
}
