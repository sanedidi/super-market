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

// TestInvoiceDiscount — скидка поставщика (Figma «SM Магазин · Скидка
// поставщика», С1–С3): накладная SAYONAR — «Сумма» строк без скидки, к оплате
// со скидкой; УТММ-878576 — позиция со скидкой 100% и «48*20гр» штуками.
func TestInvoiceDiscount(t *testing.T) {
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
		fai.set(reply)
		return a.expect(a.do("POST", "/store/invoice-scans", ownerTok, map[string]any{"store_id": storeID, "images": []string{upload()}}), 202, "scan")
	}
	line := func(r resp, i int) map[string]any { return r.Body["lines"].([]any)[i].(map[string]any) }
	cat := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Бытовое"}), 201, "category").str("id")
	units := map[string]string{}
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		units[u["short_name"].(string)] = u["id"].(string)
	}
	product := func(name, barcode string) string {
		return a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{"name": name, "category_id": cat, "unit_id": units["шт"], "base_price": 10000, "barcodes": []string{barcode}}), 201, name).str("id")
	}
	soap := product("Мыло Palmolive ромашка 150 г", "8693495032001")
	paste := product("Зубная паста Triple Action 50 мл", "8714789990001")
	chips := product("Чипсы Lay's зелёный лук 140 г", "4690388110001")
	product("Чипсы Lay's сметана и зелень 225 г", "4690388110002")
	sup := a.expect(a.do("POST", "/store/finance/counterparties", ownerTok, map[string]any{"name": "SAYONAR"}), 201, "supplier").str("id")

	// С1: мыло — 1 блок по 6, «Сумма» 63 601 без скидки 6%; паста — 12 шт со скидкой 5%.
	sc := scan(`{"supplier_name":"SAYONAR","number":"СРТТ1-Н076743","currency":"UZS","total":145341.94,
	 "lines":[{"name":"BS PO Nat Chamomile 6*150g","barcode":"8693495032001","unit":"шт","qty_unit":"упак","qty":1,"price":63601,"discount":6,"net_price":59784.94,"sum":63601},
	          {"name":"TP Triple Action 50ml","barcode":"8714789990001","unit":"шт","qty_unit":"шт","qty":12,"price":7505,"discount":5,"net_price":7129.75,"sum":90060}]}`)
	id := sc.str("id")
	if sc.Body["total_matches"] != true || sc.str("discount_total") != "8319.06" || sc.str("gross_total") != "153661.02" {
		t.Fatalf("totals: matches=%v discount=%v gross=%v lines=%v", sc.Body["total_matches"], sc.Body["discount_total"], sc.Body["gross_total"], sc.Body["lines_total"])
	}
	if l := line(sc, 1); l["discount"] != "5" || l["list_price"] != "7505.0000" || l["list_cost"] != "7505.00" || l["cost"] != "7129.75" || l["discount_sum"] != "4503.00" {
		t.Fatalf("paste = %v", l)
	}
	// Мыло: «блоки или штуки?» — блок по 6 (по названию), цена за кусок со скидкой.
	sc = a.expect(a.do("PUT", "/store/invoice-scans/"+id+"/lines/1", ownerTok, map[string]any{"pack": "6"}), 200, "soap pack")
	if l := line(sc, 0); l["stock_qty"] != "6.000" || l["cost"] != "9964.16" || l["list_cost"] != "10600.17" || l["discount"] != "6" {
		t.Fatalf("soap = %v", l)
	}
	// С2: скидку поправили — 10% к цене без скидки 63 601.
	sc = a.expect(a.do("PUT", "/store/invoice-scans/"+id+"/lines/1", ownerTok, map[string]any{"price": "57240.9", "list_price": "63601"}), 200, "soap 10%")
	if l := line(sc, 0); l["discount"] != "10" || l["cost"] != "9540.15" {
		t.Fatalf("soap 10%% = %v", l)
	}
	sc = a.expect(a.do("PUT", "/store/invoice-scans/"+id+"/lines/1", ownerTok, map[string]any{"price": "59784.94", "list_price": "63601"}), 200, "soap 6%")
	a.expect(a.do("PUT", "/store/invoice-scans/"+id+"/supplier", ownerTok, map[string]any{"counterparty_id": sup}), 200, "supplier")
	done := a.expect(a.do("POST", "/store/invoice-scans/"+id+"/document", ownerTok, map[string]any{"post": true}), 201, "post")

	// С3: в приходе — скидка и цена без скидки у строк; у поставщика — скидки за месяц.
	doc := a.expect(a.do("GET", "/store/inventory/documents/"+done.str("document_id"), ownerTok, nil), 200, "doc")
	if doc.str("total") != "145341.96" || doc.str("discount") != "8319.06" {
		t.Fatalf("doc total=%v discount=%v", doc.Body["total"], doc.Body["discount"])
	}
	for _, it := range doc.Body["items"].([]any) {
		m := it.(map[string]any)
		if m["product_id"] == soap && m["list_price"] != "10600.1700" || m["product_id"] == paste && m["list_price"] != "7505.0000" {
			t.Fatalf("item = %v", m)
		}
	}
	st := a.expect(a.do("GET", "/store/finance/counterparties/"+sup+"/statement", ownerTok, nil), 200, "statement")
	if st.str("discount") != "8319.06" || st.Body["counterparty"].(map[string]any)["balance"] != "145341.96" {
		t.Fatalf("statement discount=%v cp=%v", st.Body["discount"], st.Body["counterparty"])
	}

	// УТММ-878576: «Зелёный лук 19*140гр» — скидка 100% (бонус), «48*20гр» штуками,
	// а не пачка 225 г по похожему названию.
	sc = scan(`{"supplier_name":"Сельхоз","number":"УТММ-878576","currency":"UZS","total":12600,
	 "lines":[{"name":"Lay's - Сметана зелень 48*20гр","qty_unit":"шт","qty":3,"price":4200,"sum":12600},
	          {"name":"Lay's - Зелёный лук 19*140гр","barcode":"4690388110001","qty_unit":"шт","qty":1,"price":20850,"discount":100}]}`)
	if l := line(sc, 0); l["product_id"] != nil || l["pack"] != "1.000" || l["state"] != "missing" {
		t.Fatalf("lays 20g = %v", l)
	}
	if l := line(sc, 1); l["product_id"] != chips || l["cost"] != "0.00" || l["discount"] != "100" || l["list_cost"] != "20850.00" || l["discount_sum"] != "20850.00" {
		t.Fatalf("free = %v", l)
	}
	if sc.Body["total_matches"] != true {
		t.Fatalf("total = %v %v", sc.Body["lines_total"], sc.Body["invoice_total"])
	}
}
