package server_test

import (
	"bytes"
	"context"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// TestAssistantChat — помощник в панели (Figma «Super Market · Помощник»,
// «Веб-панель · тест», П1–П3): «пришли товары» → кнопка прикрепить, фото
// накладной → строки с кнопками, кнопка «выбрать товар», «Провести приход»
// только кнопкой, остатки таблицей, голосовое без Gemini — понятная ошибка.
func TestAssistantChat(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	s3 := &fakeS3{buckets: map[string]bool{}, objects: map[string][]byte{}, types: map[string]string{}}
	s3srv := httptest.NewServer(s3)
	t.Cleanup(s3srv.Close)
	fai := &fakeAI{key: "sk-test-key-9a1f", text: true}
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

	// Без функции в тарифе — замок.
	a.expect(a.do("GET", "/store/assistant/messages?store_id="+storeID, ownerTok, nil), 403, "no feature")
	a.expect(a.do("PATCH", "/admin/plans/network", adminTok, map[string]any{
		"features": []string{"debts", "promotions", "invoice_scans", "reports_pro", "crowd", "showcase_custom", "showcase_manual", "showcase_schedule",
			"showcase_per_store", "showcase_stats", "showcase_stats_full", "ads_off", "assistant"}}), 200, "assistant in plan")
	// Без ИИ-сервиса сообщение не принимается.
	a.expect(a.do("POST", "/store/assistant/messages", ownerTok, map[string]any{"store_id": storeID, "text": "привет"}), 409, "ai not configured")
	a.expect(a.do("PUT", "/admin/ai", adminTok, map[string]any{"provider": "openai", "base_url": aisrv.URL + "/v1", "api_key": fai.key, "model": "gpt-4o"}), 200, "ai")

	// Сотрудник без роли владельца — нет доступа.
	empTok, _ := employee(t, a, ownerTok, "+998900000003", "Склад", []string{identity.PermInventoryManage}, nil)
	a.expect(a.do("GET", "/store/assistant/messages?store_id="+storeID, empTok, nil), 403, "employee")

	messages := func() resp {
		t.Helper()
		return a.expect(a.do("GET", "/store/assistant/messages?store_id="+storeID, ownerTok, nil), 200, "messages")
	}
	last := func() map[string]any {
		t.Helper()
		items := messages().items()
		if len(items) == 0 {
			t.Fatal("no messages")
		}
		return items[len(items)-1]
	}
	blocks := func(m map[string]any, typ string) []map[string]any {
		out := []map[string]any{}
		for _, b := range m["blocks"].([]any) {
			if bm := b.(map[string]any); bm["type"] == typ {
				out = append(out, bm)
			}
		}
		return out
	}
	send := func(body map[string]any) resp {
		t.Helper()
		body["store_id"] = storeID
		return a.expect(a.do("POST", "/store/assistant/messages", ownerTok, body), 202, "send")
	}

	// «пришли товары» → помощник просит накладную, кнопка прикрепления.
	fai.set(`{"transcript":"","lang":"ru","intent":"income","args":{},"reply":"Прикрепите фото накладной.","buttons":[]}`)
	r := send(map[string]any{"text": "пришли товары"})
	if r.str("owner", "kind") != "text" || r.str("reply", "role") != "assistant" {
		t.Fatalf("send = %v", r.Body)
	}
	m := last()
	if m["role"] != "assistant" || m["text"] != "Прикрепите фото накладной." || m["intent"] == "income" {
		t.Fatalf("income reply = %v", m)
	}
	if bs := blocks(m, "buttons"); len(bs) != 1 || bs[0]["items"].([]any)[0].(map[string]any)["attach"] != true {
		t.Fatalf("attach button = %v", m["blocks"])
	}

	// Товары и поставщик.
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
	a.expect(a.do("POST", "/store/finance/counterparties", ownerTok, map[string]any{"name": "Linko-SFA", "inn": "305 111 222"}), 201, "supplier")

	// Фото накладной → распознано сразу (InvoicesSync): кола найдена по
	// штрихкоду, окорочка — нет → карточка с кнопками, «Провести» неактивна.
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
	up := map[string]any{}
	_ = json.NewDecoder(res.Body).Decode(&up)
	res.Body.Close()
	fai.set(`{"supplier_name":"Linko-SFA","supplier_inn":"305111222","number":"347930","currency":"UZS","total":1373400,
	 "lines":[{"name":"Окорочка с/з 12 кг мар","unit":"кор","qty":1,"price":30450,"sum":365400},
	          {"name":"Кока-кола 1.5","barcode":"5449000000996","unit":"шт","qty":12,"price":84000,"sum":1008000}]}`)
	r = send(map[string]any{"images": []string{up["url"].(string)}})
	if r.str("owner", "kind") != "image" {
		t.Fatalf("image send = %v", r.Body)
	}
	m = last()
	if m["status"] != "done" || !strings.Contains(m["text"].(string), "№ 347930") || !strings.Contains(m["text"].(string), "Linko-SFA") {
		t.Fatalf("scan reply = %v", m)
	}
	scanID, _ := m["scan_id"].(string)
	if scanID == "" {
		t.Fatalf("scan_id missing: %v", m)
	}
	cards := blocks(m, "card")
	if len(cards) != 1 || cards[0]["status_kind"] != "error" || cards[0]["line"] != 1.0 {
		t.Fatalf("cards = %v", cards)
	}
	if c := blocks(m, "confirm"); len(c) != 1 || c[0]["enabled"] != false {
		t.Fatalf("confirm = %v", blocks(m, "confirm"))
	}
	// Кнопка «Пропустить» есть всегда; товар выбираем кнопкой-действием.
	var skip map[string]any
	for _, b := range cards[0]["buttons"].([]any) {
		if bm := b.(map[string]any); strings.HasPrefix(bm["label"].(string), "Пропустить") {
			skip = bm["action"].(map[string]any)
		}
	}
	if skip == nil || skip["type"] != "scan_line" || skip["skip"] != true {
		t.Fatalf("skip action = %v", cards[0]["buttons"])
	}
	r = send(map[string]any{"action": map[string]any{"type": "scan_line", "scan_id": scanID, "line": 1, "product_id": chicken, "label": "Окорочка куриные"}})
	if r.str("owner", "kind") != "action" || r.str("owner", "text") != "Окорочка куриные" {
		t.Fatalf("action owner = %v", r.Body)
	}
	m = last()
	if !strings.HasPrefix(m["text"].(string), "Записал.") || len(blocks(m, "card")) != 0 {
		t.Fatalf("after pick = %v", m)
	}
	if c := blocks(m, "confirm"); len(c) != 1 || c[0]["enabled"] != true {
		t.Fatalf("confirm enabled = %v", blocks(m, "confirm"))
	}

	// «проведи» текстом — помощник не проводит, только напоминает про кнопку.
	fai.set(`{"transcript":"","lang":"ru","intent":"scan_post","args":{},"reply":"","buttons":[]}`)
	send(map[string]any{"text": "проведи"})
	m = last()
	if !strings.Contains(m["text"].(string), "только кнопкой") {
		t.Fatalf("post by text = %v", m)
	}
	a.expect(a.do("GET", "/store/invoice-scans/"+scanID, ownerTok, nil), 200, "scan still ready")

	// Кнопка «Провести приход» → документ проведён, строка «сделано» в журнале.
	send(map[string]any{"action": map[string]any{"type": "scan_post", "scan_id": scanID, "label": "Провести приход"}})
	m = last()
	if m["text"] != "Готово, остатки обновил." || len(blocks(m, "link")) != 1 {
		t.Fatalf("posted = %v", m)
	}
	sc := a.expect(a.do("GET", "/store/invoice-scans/"+scanID, ownerTok, nil), 200, "scan done")
	if sc.str("status") != "done" || sc.str("document_status") != "posted" {
		t.Fatalf("scan = %v", sc.Body)
	}
	today := a.expect(a.do("GET", "/store/assistant/today?store_id="+storeID, ownerTok, nil), 200, "today").items()
	if len(today) != 1 || !strings.Contains(today[0]["text"].(string), "проведён") {
		t.Fatalf("journal = %v", today)
	}

	// Остатки: таблица с колой (72 шт после прихода 12 блоков? нет — 12 шт, упаковка 1).
	fai.set(`{"transcript":"","lang":"ru","intent":"stock","args":{"query":"кола"},"reply":"Вот что нашёл:","buttons":[]}`)
	send(map[string]any{"text": "сколько колы осталось"})
	m = last()
	tbl := blocks(m, "table")
	if len(tbl) != 1 || !strings.HasPrefix(m["text"].(string), "Вот что нашёл:") {
		t.Fatalf("stock = %v", m)
	}
	row := tbl[0]["rows"].([]any)[0].([]any)
	if row[0] != "Coca-Cola 1,5 л" || row[1] != "12 шт" {
		t.Fatalf("stock row = %v", row)
	}
	_ = cola

	// Что заказать и продажи — отвечают без ошибок.
	fai.set(`{"transcript":"","lang":"ru","intent":"reorder","args":{},"reply":"","buttons":[]}`)
	send(map[string]any{"text": "что заказать"})
	if m = last(); m["status"] != "done" {
		t.Fatalf("reorder = %v", m)
	}
	fai.set(`{"transcript":"","lang":"ru","intent":"sales","args":{"date":""},"reply":"","buttons":[]}`)
	send(map[string]any{"text": "продажи за сегодня"})
	if m = last(); m["status"] != "done" || !strings.Contains(m["text"].(string), "Продажи сегодня") {
		t.Fatalf("sales = %v", m)
	}

	// Голосовое при OpenAI — понятная ошибка в чате, а не 500.
	var ab bytes.Buffer
	aw := multipart.NewWriter(&ab)
	_ = aw.WriteField("store_id", storeID)
	h := make(map[string][]string)
	h["Content-Disposition"] = []string{`form-data; name="audio"; filename="voice.webm"`}
	h["Content-Type"] = []string{"audio/webm;codecs=opus"}
	pw, _ := aw.CreatePart(h)
	_, _ = pw.Write([]byte("not-really-audio"))
	_ = aw.Close()
	req, _ = http.NewRequest(http.MethodPost, srv.URL+"/api/v1/store/assistant/messages", &ab)
	req.Header.Set("Content-Type", aw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+ownerTok)
	res, err = srv.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != 202 {
		t.Fatalf("audio status = %d", res.StatusCode)
	}
	m = last()
	if m["status"] != "failed" || !strings.Contains(m["text"].(string), "Gemini") {
		t.Fatalf("audio reply = %v", m)
	}
	items := messages().items()
	if own := items[len(items)-2]; own["kind"] != "audio" {
		t.Fatalf("audio owner = %v", own)
	}

	// after — только новее.
	after := a.expect(a.do("GET", "/store/assistant/messages?store_id="+storeID+"&after="+items[len(items)-2]["id"].(string), ownerTok, nil), 200, "after").items()
	if len(after) != 1 || after[0]["id"] != m["id"] {
		t.Fatalf("after = %v", after)
	}
}
