package server_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// fakeAI — ИИ-сервис с протоколами OpenAI и Anthropic; отвечает заданным текстом.
type fakeAI struct {
	mu    sync.Mutex
	key   string
	reply string
	calls int
	last  string // протокол последнего запроса: openai / anthropic
	// text — отвечать и на запросы без фото (помощник: текстовые сообщения).
	text bool
}

func (f *fakeAI) set(reply string) {
	f.mu.Lock()
	f.reply = reply
	f.mu.Unlock()
}

func (f *fakeAI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	anthropic := strings.HasPrefix(r.URL.Path, "/v1/models") && r.Header.Get("x-api-key") != "" || r.URL.Path == "/v1/messages"
	key := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if anthropic {
		key = r.Header.Get("x-api-key")
		if r.Header.Get("anthropic-version") == "" {
			w.WriteHeader(400)
			return
		}
	}
	if key != f.key {
		w.WriteHeader(401)
		_, _ = w.Write([]byte(`{"error":{"message":"Incorrect API key"}}`))
		return
	}
	switch {
	case r.Method == "GET" && (r.URL.Path == "/v1/models"):
		_, _ = w.Write([]byte(`{"data":[{"id":"text-embedding-3-small"},{"id":"gpt-4o"},{"id":"claude-sonnet-4-5"}]}`))
	case r.Method == "POST" && r.URL.Path == "/v1/chat/completions":
		var body struct {
			Messages []struct {
				Content any `json:"content"`
			} `json:"messages"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		raw, _ := json.Marshal(body.Messages)
		if !f.text && !strings.Contains(string(raw), "data:image/png;base64,") {
			w.WriteHeader(400)
			return
		}
		f.calls++
		f.last = "openai"
		out, _ := json.Marshal(map[string]any{"choices": []any{map[string]any{"message": map[string]any{"content": "```json\n" + f.reply + "\n```"}}},
			"usage": map[string]any{"prompt_tokens": 1200, "completion_tokens": 300}})
		_, _ = w.Write(out)
	case r.Method == "POST" && r.URL.Path == "/v1/messages":
		b, _ := io.ReadAll(r.Body)
		if !strings.Contains(string(b), `"media_type":"image/png"`) {
			w.WriteHeader(400)
			return
		}
		f.calls++
		f.last = "anthropic"
		out, _ := json.Marshal(map[string]any{"content": []any{map[string]any{"type": "text", "text": f.reply}},
			"usage": map[string]any{"input_tokens": 1000, "cache_read_input_tokens": 500, "output_tokens": 400}})
		_, _ = w.Write(out)
	default:
		w.WriteHeader(404)
	}
}

const testInvoiceReply = `{"supplier_name":"ООО «Тест Савдо»","supplier_inn":"123456789","number":"777","date":"2026-10-01","currency":"UZS","total":120000,
 "lines":[{"name":"Вода питьевая 1,5 л","qty":10,"price":4000,"sum":40000},{"name":"Хлеб белый","qty":5,"price":6000,"sum":30000},{"name":"Молоко 1 л","qty":4,"price":12500,"sum":50000}]}`

// TestInvoiceScan — супер-админ подключает ИИ (оба протокола), магазин
// фотографирует накладную: строки сопоставляются по штрихкоду, похожему
// названию и запомненному названию поставщика, затем создаётся приход.
func TestInvoiceScan(t *testing.T) {
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
		if res.StatusCode != 201 {
			t.Fatalf("upload: %d %v", res.StatusCode, out)
		}
		return out["url"].(string)
	}

	// ИИ ещё не подключён.
	img := upload()
	a.expect(a.do("POST", "/store/invoice-scans", ownerTok, map[string]any{"store_id": storeID, "images": []string{img}}), 409, "not configured")
	if a.expect(a.do("GET", "/admin/ai", adminTok, nil), 200, "ai settings").Body["configured"] != false {
		t.Fatal("must not be configured")
	}

	// Модели: без ключа — 400, с чужим ключом — понятная ошибка, с верным — список.
	base := aisrv.URL + "/v1"
	a.expect(a.do("POST", "/admin/ai/models", adminTok, map[string]any{"provider": "openai", "base_url": base}), 400, "no key")
	bad := a.expect(a.do("POST", "/admin/ai/models", adminTok, map[string]any{"provider": "openai", "base_url": base, "api_key": "sk-wrong"}), 502, "wrong key")
	if !strings.Contains(bad.str("error", "message"), "ключ не подходит") {
		t.Fatalf("wrong key = %v", bad.Body)
	}
	models := a.expect(a.do("POST", "/admin/ai/models", adminTok, map[string]any{"provider": "openai", "base_url": base, "api_key": fai.key}), 200, "models").items()
	if len(models) != 3 || models[0]["vision"] != true {
		t.Fatalf("models = %v", models)
	}
	a.expect(a.do("PUT", "/admin/ai", adminTok, map[string]any{"provider": "openai", "base_url": "ftp://x"}), 400, "bad url")

	st := a.expect(a.do("PUT", "/admin/ai", adminTok, map[string]any{"provider": "openai", "base_url": base + "/", "api_key": fai.key, "model": "gpt-4o"}), 200, "save")
	if st.Body["has_key"] != true || st.str("key_last4") != "9a1f" || st.str("base_url") != base || strings.Contains(st.str("api_key"), "sk-") {
		t.Fatalf("saved = %v", st.Body)
	}
	if raw, _ := json.Marshal(st.Body); strings.Contains(string(raw), fai.key) {
		t.Fatal("key leaked")
	}
	// Цена токенов: $3 / $15 за 1 млн, 1 $ = 12 650 сум.
	a.expect(a.do("PUT", "/admin/ai/prices", adminTok, map[string]any{"price_in": 3, "price_out": 15, "currency": "EUR", "rate_uzs": 12650}), 400, "bad currency")
	a.expect(a.do("PUT", "/admin/ai/prices", adminTok, map[string]any{"price_in": -1, "price_out": 15, "currency": "USD", "rate_uzs": 12650}), 400, "negative price")
	a.expect(a.do("PUT", "/admin/ai/prices", adminTok, map[string]any{"price_in": 3, "price_out": 15, "currency": "USD", "rate_uzs": 12650}), 200, "prices")

	// Ключ в базе зашифрован.
	var enc []byte
	if err := pool.QueryRow(ctx, `SELECT api_key_enc FROM ai_settings`).Scan(&enc); err != nil || bytes.Contains(enc, []byte(fai.key)) {
		t.Fatalf("key not encrypted: %v", err)
	}

	// Проверка подключения: тестовая накладная.
	fai.set(testInvoiceReply)
	tr := a.expect(a.do("POST", "/admin/ai/test", adminTok, map[string]any{}), 200, "test")
	if tr.Body["ok"] != true {
		t.Fatalf("test = %v", tr.Body)
	}
	fai.set(`{"lines":[{"name":"x","qty":1,"price":1}]}`)
	if tr := a.expect(a.do("POST", "/admin/ai/test", adminTok, map[string]any{}), 200, "test wrong"); tr.Body["ok"] != false {
		t.Fatalf("wrong read must fail: %v", tr.Body)
	}
	fai.set(testInvoiceReply)
	a.expect(a.do("POST", "/admin/ai/test", adminTok, map[string]any{}), 200, "test again")
	if s := a.expect(a.do("GET", "/admin/ai", adminTok, nil), 200, "ai").Body; s["check_ok"] != true || s["configured"] != true {
		t.Fatalf("after test = %v", s)
	}

	// Каталог и поставщик.
	cat := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Напитки"}), 201, "category").str("id")
	var pcs string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		if u["short_name"] == "шт" {
			pcs = u["id"].(string)
		}
	}
	product := func(name, barcode string) string {
		body := map[string]any{"name": name, "category_id": cat, "unit_id": pcs, "base_price": 10000}
		if barcode != "" {
			body["barcodes"] = []string{barcode}
		}
		return a.expect(a.do("POST", "/admin/products", adminTok, body), 201, "product "+name).str("id")
	}
	cola := product("Coca-Cola 1,5 л", "5449000000996")
	fanta := product("Fanta Апельсин 1 л", "")
	bonaqua := product("BonAqua газированная 1 л", "")
	supplier := a.expect(a.do("POST", "/store/finance/counterparties", ownerTok, map[string]any{
		"name": "Coca-Cola Bottlers Uzbekistan", "inn": "301 245 778"}), 201, "supplier").str("id")

	reply := `{"supplier_name":"ООО «Coca-Cola Bottlers Uzbekistan»","supplier_inn":"301245778","number":"4471","date":"02.10.2026","currency":"UZS","total":"651 600",
	 "lines":[{"name":"Кока-кола 1.5л ПЭТ","barcode":"5449000000996","unit":"шт","qty":24,"price":11200,"sum":268800},
	          {"name":"Фанта апельсин 1л","qty":"12","price":"8 400","sum":100800},
	          {"name":"Бонаква газ. 1л","qty":24,"price":4200,"sum":100800},
	          {"name":"Тара (ящик)","qty":1,"price":181200,"sum":181200}]}`
	fai.set(reply)
	sc := a.expect(a.do("POST", "/store/invoice-scans", ownerTok, map[string]any{"store_id": storeID, "images": []string{img}}), 202, "scan")
	id := sc.str("id")
	if sc.str("status") != "ready" || sc.str("counterparty_id") != supplier || sc.str("invoice_number") != "4471" ||
		sc.str("invoice_date") != "2026-10-02" || sc.str("invoice_total") != "651600.00" || sc.Body["total_matches"] != true {
		t.Fatalf("scan = %v", sc.Body)
	}
	lines := sc.Body["lines"].([]any)
	state := func(i int) (string, any, any) {
		l := lines[i].(map[string]any)
		return l["state"].(string), l["product_id"], l["match"]
	}
	if s, p, m := state(0); s != "ok" || p != cola || m != "barcode" {
		t.Fatalf("line 1 = %v", lines[0])
	}
	if _, p, m := state(1); p != fanta || m != "name" {
		t.Fatalf("line 2 = %v", lines[1])
	}
	if s, p, _ := state(2); s != "missing" || p != nil {
		t.Fatalf("line 3 = %v", lines[2])
	}
	if !strings.HasPrefix(sc.Body["images"].([]any)[0].(string), srv.URL+"/api/v1/media/") {
		t.Fatalf("images = %v", sc.Body["images"])
	}

	// Нельзя провести, пока есть несопоставленные строки.
	a.expect(a.do("POST", "/store/invoice-scans/"+id+"/document", ownerTok, map[string]any{"post": true}), 409, "unmatched")

	// Подсказки и ручной выбор с запоминанием; тару пропускаем.
	sug := a.expect(a.do("GET", "/store/invoice-scans/"+id+"/lines/3/suggestions?q=bonaqua", ownerTok, nil), 200, "suggest").items()
	if len(sug) == 0 || sug[0]["product_id"] != bonaqua {
		t.Fatalf("suggestions = %v", sug)
	}
	a.expect(a.do("PUT", "/store/invoice-scans/"+id+"/lines/3", ownerTok, map[string]any{"product_id": bonaqua, "remember": true}), 200, "pick")
	sc = a.expect(a.do("PUT", "/store/invoice-scans/"+id+"/lines/4", ownerTok, map[string]any{"skip": true}), 200, "skip")
	if c := sc.Body["counts"].(map[string]any); c["missing"].(float64) != 0 || c["skipped"].(float64) != 1 {
		t.Fatalf("counts = %v", c)
	}

	done := a.expect(a.do("POST", "/store/invoice-scans/"+id+"/document", ownerTok, map[string]any{"post": true}), 201, "document")
	if done.str("status") != "done" || done.str("document_status") != "posted" {
		t.Fatalf("done = %v", done.Body)
	}
	a.expect(a.do("POST", "/store/invoice-scans/"+id+"/document", ownerTok, map[string]any{"post": true}), 409, "twice")
	doc := a.expect(a.do("GET", "/store/inventory/documents/"+done.str("document_id"), ownerTok, nil), 200, "doc")
	if doc.str("counterparty_id") != supplier || doc.str("total") != "470400.00" || len(doc.Body["items"].([]any)) != 3 {
		t.Fatalf("doc = %v", doc.Body)
	}

	// Следующая накладная того же поставщика: название запомнено.
	fai.set(reply)
	sc2 := a.expect(a.do("POST", "/store/invoice-scans", ownerTok, map[string]any{"store_id": storeID, "images": []string{upload()}}), 202, "scan 2")
	l3 := sc2.Body["lines"].([]any)[2].(map[string]any)
	if l3["product_id"] != bonaqua || l3["match"] != "alias" {
		t.Fatalf("alias = %v", l3)
	}
	// Цена совпала с прошлым приходом — изменения нет.
	if l1 := sc2.Body["lines"].([]any)[0].(map[string]any); l1["last_price"] != "11200.0000" || l1["price_change"] != nil {
		t.Fatalf("last price = %v", l1)
	}

	// Ошибка сервиса — накладная «не удалось», можно повторить.
	fai.set(`не JSON`)
	sc3 := a.expect(a.do("POST", "/store/invoice-scans", ownerTok, map[string]any{"store_id": storeID, "images": []string{upload()}}), 202, "scan 3")
	if sc3.str("status") != "failed" || sc3.str("error") == "" {
		t.Fatalf("failed = %v", sc3.Body)
	}
	fai.set(reply)
	if r := a.expect(a.do("POST", "/store/invoice-scans/"+sc3.str("id")+"/retry", ownerTok, nil), 202, "retry"); r.str("status") != "ready" {
		t.Fatalf("retry = %v", r.Body)
	}
	if n := len(a.expect(a.do("GET", "/store/invoice-scans?store_id="+storeID, ownerTok, nil), 200, "list").items()); n != 3 {
		t.Fatalf("list = %d", n)
	}

	// Anthropic: свой формат запроса, ключ в x-api-key.
	a.expect(a.do("PUT", "/admin/ai", adminTok, map[string]any{"provider": "anthropic", "base_url": aisrv.URL, "model": "claude-sonnet-4-5"}), 400, "new provider needs key")
	a.expect(a.do("PUT", "/admin/ai", adminTok, map[string]any{"provider": "anthropic", "base_url": aisrv.URL, "api_key": fai.key, "model": "claude-sonnet-4-5"}), 200, "anthropic")
	fai.set(testInvoiceReply)
	if tr := a.expect(a.do("POST", "/admin/ai/test", adminTok, map[string]any{}), 200, "anthropic test"); tr.Body["ok"] != true || fai.last != "anthropic" {
		t.Fatalf("anthropic test = %v (%s)", tr.Body, fai.last)
	}
	if s := a.expect(a.do("GET", "/admin/ai", adminTok, nil), 200, "ai").Body; s["month_scans"].(float64) != 3 || s["month_failed"].(float64) != 0 {
		t.Fatalf("usage = %v", s)
	}

	// Расход: 3 проверки и 4 накладные через OpenAI (1200 + 300 токенов),
	// проверка Anthropic (1000 + 500 из кэша, 400). Ошибки: неверная проверка и «не JSON».
	use := a.expect(a.do("GET", "/admin/ai/usage", adminTok, nil), 200, "usage")
	tot := use.Body["totals"].(map[string]any)
	if tot["requests"] != 8.0 || tot["invoices"] != 4.0 || tot["tests"] != 4.0 || tot["errors"] != 2.0 ||
		tot["input_tokens"] != 9900.0 || tot["output_tokens"] != 2500.0 || tot["cost_uzs"] != 850.12 {
		t.Fatalf("totals = %v", tot)
	}
	items := use.items()
	if len(items) != 2 || items[0]["id"] != "" || items[0]["name"] != "Проверки подключения" || items[1]["invoices"] != 4.0 ||
		items[1]["cost_uzs"] != 409.88 || items[1]["stores"] != 1.0 || items[1]["share"] != 48.2 {
		t.Fatalf("by network = %v", items)
	}
	days := use.Body["days"].([]any)
	if last := days[len(days)-1].(map[string]any); last["requests"] != 8.0 {
		t.Fatalf("days = %v", days)
	}
	netID := items[1]["id"].(string)
	byEmp := a.expect(a.do("GET", "/admin/ai/usage?group=employee&network_id="+netID, adminTok, nil), 200, "by employee").items()
	if len(byEmp) != 1 || byEmp[0]["name"] != "Владелец" || byEmp[0]["requests"] != 4.0 {
		t.Fatalf("by employee = %v", byEmp)
	}
	a.expect(a.do("GET", "/admin/ai/usage?group=x", adminTok, nil), 400, "bad group")
	a.expect(a.do("GET", "/admin/ai/usage?from=2026-13-01", adminTok, nil), 400, "bad date")

	// Чужое приложение — нет доступа.
	a.expect(a.do("GET", "/admin/ai", ownerTok, nil), 403, "store token on admin")
	a.expect(a.do("GET", "/admin/ai/usage", ownerTok, nil), 403, "store token on usage")
}
