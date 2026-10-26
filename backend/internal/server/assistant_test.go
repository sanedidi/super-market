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
// «Веб-панель · тест», П1–П3): агент с инструментами (search_docs,
// list_routes, call_api). «пришли товары» → кнопка прикрепить, фото накладной
// → строки с кнопками, «Провести приход» и удаление — только после кнопки
// подтверждения, обычная запись — сразу с заметкой в журнал, чтение — таблицей,
// чужие пути закрыты, голосовое без Gemini — понятная ошибка.
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

	// «пришли товары» → помощник просит накладную, кнопка прикрепления (из ответа модели).
	fai.play(fakeTurn{text: `{"transcript":"","lang":"ru","reply":"Прикрепите фото накладной.","buttons":[{"label":"Прикрепить накладную","attach":true}]}`})
	r := send(map[string]any{"text": "пришли товары"})
	if r.str("owner", "kind") != "text" || r.str("reply", "role") != "assistant" {
		t.Fatalf("send = %v", r.Body)
	}
	m := last()
	if m["role"] != "assistant" || m["text"] != "Прикрепите фото накладной." {
		t.Fatalf("income reply = %v", m)
	}
	if bs := blocks(m, "buttons"); len(bs) != 1 || bs[0]["items"].([]any)[0].(map[string]any)["attach"] != true {
		t.Fatalf("attach button = %v", m["blocks"])
	}
	if req := fai.lastRequest(); !strings.Contains(req, `"tools"`) || !strings.Contains(req, "call_api") || !strings.Contains(req, "пришли товары") {
		t.Fatalf("model request = %s", req)
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

	// «проведи» текстом — агент пробует провести через API, сервер не даёт:
	// needs_confirmation → кнопка подтверждения, накладная не тронута.
	fai.play(
		fakeTurn{tool: "call_api", args: map[string]any{"method": "POST", "path": "/store/invoice-scans/" + scanID + "/document",
			"body": map[string]any{"post": true}, "note": "Приход № 347930 проведён", "button": "Провести приход № 347930"}},
		fakeTurn{text: `{"reply":"Нажмите кнопку — и я проведу приход.","lang":"ru","scan_id":"` + scanID + `","buttons":[{"label":"Провести приход","send":"провести приход"},{"label":"Что заказать?","send":"Что заказать?"}]}`},
	)
	send(map[string]any{"text": "проведи"})
	m = last()
	if m["text"] != "Нажмите кнопку — и я проведу приход." {
		t.Fatalf("post by text = %v", m)
	}
	if req := fai.lastRequest(); !strings.Contains(req, "needs_confirmation") {
		t.Fatalf("tool result not passed to model: %s", req)
	}
	a.expect(a.do("GET", "/store/invoice-scans/"+scanID, ownerTok, nil), 200, "scan still ready")
	confirms := blocks(m, "confirm")
	var apiConfirm map[string]any
	for _, c := range confirms {
		if act := c["action"].(map[string]any); act["type"] == "api" {
			apiConfirm = c
		}
	}
	if apiConfirm == nil || apiConfirm["enabled"] != true || apiConfirm["label"] != "Провести приход № 347930" {
		t.Fatalf("api confirm = %v", confirms)
	}
	// Кнопка модели «Провести приход» (текстом) убрана — остаётся только подтверждение.
	if bs := blocks(m, "buttons"); len(bs) != 1 || len(bs[0]["items"].([]any)) != 1 {
		t.Fatalf("model confirm-like button not dropped: %v", bs)
	}

	// Кнопка подтверждения → запрос выполнен, строка «сделано», помощник рассказывает результат.
	fai.play(fakeTurn{text: `{"reply":"Готово, приход проведён.","lang":"ru","links":[{"label":"Открыть приход","href":"/purchases/income"}]}`})
	send(map[string]any{"action": apiConfirm["action"]})
	m = last()
	if m["text"] != "Готово, приход проведён." || len(blocks(m, "link")) != 1 {
		t.Fatalf("posted = %v", m)
	}
	if req := fai.lastRequest(); !strings.Contains(req, "HTTP 201") {
		t.Fatalf("confirm result not passed to model: %s", req)
	}
	sc := a.expect(a.do("GET", "/store/invoice-scans/"+scanID, ownerTok, nil), 200, "scan done")
	if sc.str("status") != "done" || sc.str("document_status") != "posted" {
		t.Fatalf("scan = %v", sc.Body)
	}
	today := a.expect(a.do("GET", "/store/assistant/today?store_id="+storeID, ownerTok, nil), 200, "today").items()
	if len(today) != 1 || today[0]["text"] != "Приход № 347930 проведён" {
		t.Fatalf("journal = %v", today)
	}

	// Остатки: агент сам читает my-products и показывает таблицу; результат
	// запроса доходит до модели.
	fai.play(
		fakeTurn{tool: "call_api", args: map[string]any{"method": "GET", "path": "/store/inventory/my-products", "query": map[string]any{"store_id": storeID, "q": "кола"}}},
		fakeTurn{text: `{"reply":"Вот что нашёл:","lang":"ru","table":{"columns":["Товар","Остаток"],"rows":[["Coca-Cola 1,5 л","12 шт"]]}}`},
	)
	send(map[string]any{"text": "сколько колы осталось"})
	m = last()
	tbl := blocks(m, "table")
	if len(tbl) != 1 || m["text"] != "Вот что нашёл:" {
		t.Fatalf("stock = %v", m)
	}
	if req := fai.lastRequest(); !strings.Contains(req, "Coca-Cola 1,5 л") || !strings.Contains(req, `\"qty\":\"12`) {
		t.Fatalf("my-products result not passed to model: %s", req)
	}
	_ = cola

	// Документация и маршруты; чужие пути (не /store/) закрыты.
	fai.play(
		fakeTurn{tool: "list_routes", args: map[string]any{"prefix": "/store/inventory"}},
		fakeTurn{tool: "search_docs", args: map[string]any{"query": "остатки склад"}},
		fakeTurn{tool: "call_api", args: map[string]any{"method": "GET", "path": "/admin/ai"}},
		fakeTurn{text: `{"reply":"ок","lang":"ru"}`},
	)
	send(map[string]any{"text": "что умеешь"})
	if m = last(); m["status"] != "done" {
		t.Fatalf("docs = %v", m)
	}
	modelReq := fai.lastRequest()
	if !strings.Contains(modelReq, `\"warehouses\":[{\"default\":true`) || !strings.Contains(modelReq, "Откуда и куда") {
		t.Fatalf("warehouses / from-to rule not in model request")
	}
	for _, want := range []string{"GET /store/inventory/my-products", "## ", "только /store/"} {
		if !strings.Contains(modelReq, want) {
			t.Fatalf("tools: %q not in model request: %s", want, modelReq)
		}
	}
	// Запись без подтверждения: контрагент создаётся сразу, с заметкой в журнале.
	fai.play(
		fakeTurn{tool: "call_api", args: map[string]any{"method": "POST", "path": "/store/finance/counterparties",
			"body": map[string]any{"name": "Абдуллаев ЧП"}, "note": "Завёл поставщика «Абдуллаев ЧП»"}},
		fakeTurn{text: `{"reply":"Завёл поставщика.","lang":"ru"}`},
	)
	send(map[string]any{"text": "заведи поставщика Абдуллаев ЧП"})
	if m = last(); m["text"] != "Завёл поставщика." {
		t.Fatalf("create = %v", m)
	}
	if req := fai.lastRequest(); !strings.Contains(req, `\"status\":201`) {
		i := strings.Index(req, `"role":"tool"`)
		t.Fatalf("create via api: %s", req[max(0, i-50):min(len(req), i+700)])
	}
	cps := a.expect(a.do("GET", "/store/finance/counterparties?q=Абдуллаев", ownerTok, nil), 200, "counterparties").items()
	if len(cps) != 1 {
		t.Fatalf("counterparty not created: %v", cps)
	}
	today = a.expect(a.do("GET", "/store/assistant/today?store_id="+storeID, ownerTok, nil), 200, "today").items()
	if len(today) != 2 || today[0]["text"] != "Завёл поставщика «Абдуллаев ЧП»" {
		t.Fatalf("journal = %v", today)
	}
	// Удаление — только через кнопку.
	fai.play(
		fakeTurn{tool: "call_api", args: map[string]any{"method": "DELETE", "path": "/store/finance/counterparties/" + cps[0]["id"].(string), "note": "Удалить поставщика"}},
		fakeTurn{text: `{"reply":"Подтвердите кнопкой.","lang":"ru"}`},
	)
	send(map[string]any{"text": "удали его"})
	if m = last(); len(blocks(m, "confirm")) != 1 {
		t.Fatalf("delete confirm = %v", m)
	}
	a.expect(a.do("GET", "/store/finance/counterparties?q=Абдуллаев", ownerTok, nil), 200, "still there")

	// Блок товара: помощник запоминает «кола — блок по 6» (PUT …/pack), my-products отдаёт pack.
	a.expect(a.do("PUT", "/store/inventory/my-products/"+cola+"/pack", ownerTok, map[string]any{"pack": 6}), 200, "pack")
	if mp := a.expect(a.do("GET", "/store/inventory/my-products?store_id="+storeID+"&q=Coca", ownerTok, nil), 200, "my-products").items(); len(mp) != 1 || mp[0]["pack"] != "6" {
		t.Fatalf("pack in my-products = %v", mp)
	}
	a.expect(a.do("PUT", "/store/inventory/my-products/"+cola+"/pack", ownerTok, map[string]any{"pack": 5000}), 400, "bad pack")

	// Приход со слов владельца: черновик через API, он — «в работе» у чата
	// (попадает в контекст), провести — кнопкой; документ поправили в
	// панели — кнопка просит подтвердить заново.
	wh := a.expect(a.do("GET", "/store/inventory/my-products?store_id="+storeID+"&q=Coca", ownerTok, nil), 200, "warehouse").str("warehouse_id")
	supplierID := cps[0]["id"].(string)
	fai.play(
		fakeTurn{tool: "call_api", args: map[string]any{"method": "POST", "path": "/store/inventory/documents", "note": "Черновик прихода: Coca-Cola 42 шт по 7 333",
			"body": map[string]any{"type": "income", "warehouse_id": wh, "counterparty_id": supplierID, "items": []map[string]any{{"product_id": cola, "qty": "42", "price": "7333"}}}}},
		fakeTurn{text: `{"reply":"Записал 7 блоков по 6 = 42 штуки по 7 333. Провести?","lang":"ru"}`},
	)
	send(map[string]any{"text": "7 blok kola keldi"})
	if m = last(); m["text"] != "Записал 7 блоков по 6 = 42 штуки по 7 333. Провести?" {
		t.Fatalf("draft = %v", m)
	}
	docs := a.expect(a.do("GET", "/store/inventory/documents?store_id="+storeID+"&type=income&status=draft", ownerTok, nil), 200, "drafts").items()
	if len(docs) != 1 {
		t.Fatalf("drafts = %v", docs)
	}
	docID := docs[0]["id"].(string)
	fai.play(
		fakeTurn{tool: "call_api", args: map[string]any{"method": "POST", "path": "/store/inventory/documents/" + docID + "/post", "note": "Провести приход колы"}},
		fakeTurn{text: `{"reply":"Нажмите кнопку.","lang":"ru"}`},
	)
	send(map[string]any{"text": "проведи"})
	m = last()
	if req := fai.lastRequest(); !strings.Contains(req, "current_document") || !strings.Contains(req, docID) {
		t.Fatalf("draft not in context: %s", req[:min(len(req), 300)])
	}
	confirms = blocks(m, "confirm")
	if len(confirms) != 1 || confirms[0]["action"].(map[string]any)["expect"] == "" {
		t.Fatalf("post confirm = %v", confirms)
	}
	postAct := confirms[0]["action"]
	// Поправили количество в панели → кнопка не проводит, просит подтвердить заново.
	a.expect(a.do("PATCH", "/store/inventory/documents/"+docID, ownerTok, map[string]any{"items": []map[string]any{{"product_id": cola, "qty": "48", "price": "7333"}}}), 200, "edit draft")
	send(map[string]any{"action": postAct})
	m = last()
	if !strings.Contains(m["text"].(string), "изменился") || len(blocks(m, "confirm")) != 1 {
		t.Fatalf("changed doc = %v", m)
	}
	if d := a.expect(a.do("GET", "/store/inventory/documents/"+docID, ownerTok, nil), 200, "doc"); d.str("status") != "draft" {
		t.Fatalf("doc posted despite change: %v", d.Body)
	}
	fai.play(fakeTurn{text: `{"reply":"Провёл: 48 штук колы.","lang":"ru"}`})
	send(map[string]any{"action": blocks(m, "confirm")[0]["action"]})
	if m = last(); m["text"] != "Провёл: 48 штук колы." {
		t.Fatalf("posted = %v", m)
	}
	if d := a.expect(a.do("GET", "/store/inventory/documents/"+docID, ownerTok, nil), 200, "doc"); d.str("status") != "posted" {
		t.Fatalf("doc = %v", d.Body)
	}

	// «kola» (латиницей) находит Coca-Cola: поиск пробует другую письменность («кола»).
	if mp := a.expect(a.do("GET", "/store/inventory/my-products?store_id="+storeID+"&q=kola", ownerTok, nil), 200, "kola").items(); len(mp) != 1 || mp[0]["name"] != "Coca-Cola 1,5 л" {
		t.Fatalf("kola = %v", mp)
	}
	// find_products по вариантам + remember_alias → в следующий раз alias первым и в контексте.
	fai.play(
		fakeTurn{tool: "find_products", args: map[string]any{"queries": []string{"kola", "кола", "coca-cola"}}},
		fakeTurn{tool: "remember_alias", args: map[string]any{"word": "Kola", "product_id": cola}},
		fakeTurn{text: `{"reply":"Это Coca-Cola 1,5 л.","lang":"uz"}`},
	)
	send(map[string]any{"text": "kola qancha qoldi"})
	if req := fai.lastRequest(); !strings.Contains(req, "Coca-Cola 1,5 л") || !strings.Contains(req, `\"where\":\"mine\"`) || !strings.Contains(req, `{\"ok\": true}`) {
		t.Fatalf("find_products/remember_alias: %s", req[max(0, len(req)-3000):])
	}
	fai.play(
		fakeTurn{tool: "find_products", args: map[string]any{"queries": []string{"KOLA"}}},
		fakeTurn{text: `{"reply":"ок","lang":"uz"}`},
	)
	send(map[string]any{"text": "kola"})
	aliasReq := fai.lastRequest()
	if !strings.Contains(aliasReq, `kola → Coca-Cola 1,5 л`) || !strings.Contains(aliasReq, `\"where\":\"alias\"`) {
		t.Fatalf("alias not used: %s", aliasReq[max(0, len(aliasReq)-3000):])
	}

	// Кнопка выбора: модель положила id в send — в чат уйдёт название, id — в ref;
	// нажатие кнопки доходит до модели с «[выбрано: id]», голосовое — расшифровкой.
	fai.play(fakeTurn{text: `{"reply":"Какой?","lang":"ru","buttons":[{"label":"Coca-Cola 1,5 л","send":"` + cola + `"}]}`})
	send(map[string]any{"text": "kola"})
	btn := blocks(last(), "buttons")[0]["items"].([]any)[0].(map[string]any)
	if btn["send"] != "Coca-Cola 1,5 л" || btn["ref"] != cola {
		t.Fatalf("button = %v", btn)
	}
	if _, err := pool.Exec(ctx, `UPDATE assistant_messages SET text = '', transcript = '7 blok kola keldi', kind = 'audio'
		WHERE id = (SELECT id FROM assistant_messages WHERE role = 'owner' ORDER BY created_at DESC LIMIT 1)`); err != nil {
		t.Fatal(err)
	}
	fai.play(fakeTurn{text: `{"reply":"ок","lang":"ru"}`})
	send(map[string]any{"text": btn["send"], "ref": btn["ref"]})
	choiceReq := fai.lastRequest()
	if !strings.Contains(choiceReq, "[выбрано: "+cola+"]") || !strings.Contains(choiceReq, "7 blok kola keldi") || !strings.Contains(choiceReq, "кнопки: Coca-Cola 1,5 л") {
		t.Fatalf("choice/voice memory: %s", choiceReq[:min(len(choiceReq), 4000)])
	}
	if own := messages().items(); own[len(own)-2]["text"] != "Coca-Cola 1,5 л" {
		t.Fatalf("owner text = %v", own[len(own)-2])
	}

	// Фото товара, которого нет в базе: Super Market заполняет карточку, товар
	// добавляется в «Мои товары», помощник продолжает разговор.
	food := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Еда"}), 201, "section").str("id")
	sweets := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Сладости", "parent_id": food}), 201, "subcategory").str("id")
	fai.set(`{"product":true,"name":"Печенье Rahat, 200 г","name_uz":"Rahat pechenyesi, 200 g","brand":"Rahat","unit":"шт","description":"","confidence":"high","match":"` + sweets + `","alternatives":[]}`)
	fai.play(fakeTurn{text: `{"reply":"Товар «Печенье Rahat, 200 г» добавил. Сколько пришло и по какой цене?","lang":"ru"}`})
	r = send(map[string]any{"images": []string{up["url"].(string)}, "kind": "product"})
	if r.str("owner", "kind") != "image" {
		t.Fatalf("product photo send = %v", r.Body)
	}
	m = last()
	if m["status"] != "done" || m["text"] != "Товар «Печенье Rahat, 200 г» добавил. Сколько пришло и по какой цене?" {
		t.Fatalf("product photo reply = %v", m)
	}
	if req := fai.lastRequest(); !strings.Contains(req, "Super Market заполнил карточку: «Печенье Rahat, 200 г»") {
		t.Fatalf("product note not passed to model: %s", req)
	}
	// Магазин ещё в «Начале работы» — товар встал в его черновик (в работающем магазине — сразу в товары).
	if sr := a.expect(a.do("GET", "/store/start/search?store_id="+storeID+"&q=Rahat", ownerTok, nil), 200, "search").items(); len(sr) != 1 || sr[0]["added"] != true {
		t.Fatalf("product not added: %v", sr)
	}
	today = a.expect(a.do("GET", "/store/assistant/today?store_id="+storeID, ownerTok, nil), 200, "today").items()
	if len(today) != 5 || !strings.HasPrefix(today[0]["text"].(string), "Новый товар «Печенье Rahat, 200 г»") {
		t.Fatalf("journal = %v", today)
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
