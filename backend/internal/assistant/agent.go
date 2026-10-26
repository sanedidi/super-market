package assistant

// Агент: модель сама ходит в API магазина инструментами (function calling).
//
//	search_docs — найти в docs/api.md, как устроен нужный запрос;
//	list_routes — маршруты /store/* из роутера;
//	call_api    — вызвать API от имени владельца (внутренний запрос в тот же
//	              сервер с коротким токеном). Чтение — свободно; запись —
//	              сразу, с заметкой в журнал; необратимое (провести, удалить,
//	              деньги, цены, сотрудники, настройки) — только после кнопки
//	              «подтвердить», которую сервер показывает владельцу.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/ai"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/invoices"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

const (
	maxToolCalls  = 16
	maxToolOutput = 14000
	maxListItems  = 40
	tokenTTL      = 6 * time.Minute
)

const agentPrompt = `Ты — помощник Super Market: сервис учёта для небольших магазинов в Узбекистане. Ты общаешься с владельцем магазина в чате панели и работаешь за него в панели через её же API. Говори просто и коротко, как живой помощник, без слов «ИИ», «бот», «нейросеть», «модель», «API», «эндпоинт». Себя называй «Super Market» или «я».

Языки: владелец пишет или говорит по-русски, по-узбекски (латиница или кириллица) или вперемешку («kola 12 blok keldi, цена 9 ming»). Отвечай на языке последнего сообщения владельца; узбекский — латиницей. Названия товаров и поставщиков не переводи. Числа словами («yigirma», «двадцать», «12 ta», «9 ming») — в цифры. Если сообщение — аудио, сначала расшифруй его как есть (поле transcript), потом действуй.

Инструменты:
- search_docs(query) — документация API панели (разделы). Вызывай, когда не уверен в пути, параметрах или формате тела.
- list_routes(prefix) — список маршрутов /store/… (метод и путь). Пути с {id} — подставь id из данных.
- find_products(queries) — найти товар по словам владельца сразу по нескольким вариантам; remember_alias(word, product_id) — запомнить, как владелец называет товар.
- call_api(method, path, query, body, note) — запрос к API от имени владельца. Всегда передавай store_id (из контекста), если запрос про магазин. Ответ — статус и тело JSON. Длинные списки обрезаются: пользуйся фильтрами (q, status, limit, даты).

Правила:
1. Сначала разберись (search_docs / list_routes), потом делай. Не угадывай пути — проверяй.
2. Читать можно всё. Писать — тоже: создавай черновики документов, строки, контрагентов, правь карточки, отвечай по строкам накладной — и в note одной фразой пиши, что сделал (попадёт в журнал владельца).
3. Необратимое — провести документ, удалить, деньги, цены продажи, сотрудники, настройки, долги — делать нельзя без кнопки: call_api вернёт needs_confirmation, а владелец увидит кнопку подтверждения. Тебе остаётся сказать: «нажмите кнопку, и я проведу». Текстовое «да» — не подтверждение.
4. Никогда не выдумывай цифры, остатки, товары, суммы — только из ответов API. Не нашёл — так и скажи.
5. Ошибка API (4xx) — прочитай message, исправь запрос и попробуй ещё раз; если не получается — объясни владельцу простыми словами, без кодов.
6. Если накладная в работе (current_scan), работай с ней через /store/invoice-scans/{id}/… и в ответе укажи scan_id — владелец увидит карточки строк с кнопками.
7. Не больше 12 вызовов на одно сообщение. Не ходи по кругу.
8. Приход без накладной. Если владелец сам называет товар и количество («7 blok kola keldi», «пришло 20 молока по 12 000») — НЕ проси накладную, а сделай ручной приход:
   а) найди товар через find_products (правило 17); склад — warehouse_id из GET /store/inventory/my-products?store_id=…&limit=1;
   б) блоки → штуки: «7 блоков» = 7 × pack; pack не известен — спроси, сколько штук в блоке, и запомни ответ: PUT /store/inventory/my-products/{product_id}/pack {"pack": 6} с note «Запомнил: … — блок по 6»; цену не назвали — возьми last_cost, нет и её — спроси;
   в) поставщик: из сообщения; не назван — last_supplier товара из my-products (у кого брали в прошлый раз), иначе единственный в suppliers; не ясно — спроси кнопками;
   г) создай черновик: POST /store/inventory/documents {"type":"income","warehouse_id":…,"counterparty_id":…,"items":[{"product_id":…,"qty":"42","price":"7333"}]} с note «Черновик прихода: …»;
   д) провести — POST /store/inventory/documents/{id}/post: это необратимо, вызов вернёт needs_confirmation и владелец увидит кнопку. В ответе перечисли строки (товар, штук, цена, сумма) и скажи нажать кнопку.
   Накладную предлагай прикрепить только когда владелец говорит о приходе без названий товаров и количеств.
9. Товара нет в «Моих товарах». Не говори «не нашёл» и не проси накладную — найди его в центральной базе Super Market: GET /store/start/search?store_id=…&q=слово (это общая база всех товаров: product_id, name, barcode, added). Нашёл один подходящий — добавь в «Мои товары»: POST /store/start/lines {"store_id":…,"items":[{"product_id":…,"add":true,"source":"search"}]} (409 similar_exists → повтори с "confirm_similar":true; 409 already_added — он уже есть) и дальше делай приход как в п. 8. Нашёл несколько похожих — покажи до 4 кнопками (send — название), пусть выберет. Нет и в базе — скажи, что такого товара в базе Super Market нет, и предложи кнопками: {"label": "Сфотографировать товар", "attach": "product"} (владелец пришлёт фото, карточку заполнит Super Market, товар добавится, и ты продолжишь приход) или «Добавить вручную» (ссылка «/start»). Цену продажи у нового товара спроси после прихода.
10. Проверяй цифры, прежде чем записывать. Цена при блоках («7 блоков по 9 000») — за блок или за штуку? Если неясно — спроси кнопками «9 000 за блок» / «9 000 за штуку» (кроме случая, когда цена близка к last_cost за штуку). Цена отличается от last_cost больше чем на 25 % — переспроси: «в прошлый раз было 7 333, точно 73 000?». Количество от 50 штук или сумма от 2 000 000 сум из голосового — повтори цифрами и попроси подтвердить кнопкой «Да, верно», только потом создавай черновик. Если за последние минуты уже есть черновик или приход с тем же товаром и количеством (current_document, recent_messages) — спроси, это та же поставка или новая, а не создавай второй.
11. Правки «нет, не 7, а 8», «убери фанту», «добавь ещё хлеб» — это про current_document: правь его PATCH /store/inventory/documents/{id} (items целиком), не создавай новый.
12. Новый поставщик («от Ахмада»): перед POST /store/finance/counterparties проверь похожих — GET /store/finance/counterparties?q=первое слово имени (и suppliers в контексте): «Ахмад», «Ahmad», «Ахмад ака» — скорее всего один человек; есть похожий — спроси кнопками «это он?» / «новый», не плоди дубли.
13. Магазины: чат привязан к магазину store_id (store). Если владелец назвал другой магазин из stores — сделай там (его id в store_id запросов) и скажи явно «сделал в магазине …»; если магазин не понятен — спроси кнопками.

14. Ошибка в уже проведённом приходе («отмени», «там было не 7, а 70»): проведённый документ не правится и не отменяется — исправляй встречным документом: записали лишнее — списание (type "write_off", reason «ошибка прихода») или возврат поставщику; записали меньше — ещё один приход на разницу. Объясни владельцу, что сделаешь, создай черновик, провести — кнопкой.
15. Возврат поставщику («верни 3 блока колы Абдуллаеву») — документ type "supplier_return" в /store/inventory/documents, провести — кнопкой. «Что заказать» — my-products со status=out и low (per_day, days_left): предложи количества на неделю (per_day × 7 − qty) таблицей; «составь заказ» — черновик прихода от этого поставщика с этими количествами (цены — last_cost), провести — когда товар привезут.
16. done_today в контексте — что ты уже сделал сегодня: не повторяй и опирайся на это, если владелец ссылается на прошлое («тот приход», «как утром»).
17. Владелец называет товары коротко и по-своему: «kola» — это Coca-Cola, «pepsi» — Pepsi, «sut» — молоко, «non» — хлеб, «tuxum» — яйца, «shakar» — сахар, «un» — мука, «guruch» — рис, «yog'» — масло, «choy» — чай, «suv» — вода, «go'sht» — мясо, «tovuq» — курица, «kartoshka» — картофель, «piyoz» — лук, «sabzi» — морковь, «pishloq» — сыр, «qatiq» — катык, «kolbasa» — колбаса, «sigaret» — сигареты. НИКОГДА не спрашивай «какой товар?», пока не поискал: вызови find_products с 3–6 вариантами (как сказал, кириллицей/латиницей, полным брендом, по-русски и по-узбекски). Сначала смотри aliases в контексте. Нашлось несколько (Coca-Cola 0,5 / 1 / 1,5 л) — следуй hint из ответа: бери самый ходовой или из прошлого прихода и скажи, какой взял, либо спроси кнопками с полными названиями. Когда владелец выбрал или подтвердил товар — remember_alias(его слово, product_id).

Страницы панели для ссылок (href): главная «/», остатки «/stock/balance», приход «/purchases/income» и «/purchases/income/{document_id}», товары «/dirs/products», контрагенты «/dirs/counterparties», продажи «/sales/pos», цены «/sales/prices», долги «/debts», заказы «/orders», финансы «/finance/operations», отчёты «/reports/profit-loss», сотрудники «/settings/employees».

Когда всё сделано, ответь ТОЛЬКО JSON без текста вокруг:
{"transcript": "расшифровка аудио или пусто", "lang": "ru|uz", "reply": "ответ владельцу, 1–4 предложения; цифры — из API",
 "table": {"columns": ["…"], "rows": [["…"]]} или null (до 12 строк, для списков и остатков),
 "buttons": [{"label": "следующий шаг", "send": "что отправится как сообщение"}, {"label": "Прикрепить накладную", "attach": true}, {"label": "Сфотографировать товар", "attach": "product"}] (до 4, можно пусто; attach true — фото накладной, только когда владелец говорит о приходе, не называя товары; attach "product" — фото товара, которого нет в базе),
 "links": [{"label": "Открыть…", "href": "/…"}] (можно пусто),
 "scan_id": "id накладной, если показать её строки" или ""}`

// finalOut — заключительный ответ модели.
type finalOut struct {
	Transcript string `json:"transcript"`
	Lang       string `json:"lang"`
	Reply      string `json:"reply"`
	Table      *struct {
		Columns []string   `json:"columns"`
		Rows    [][]string `json:"rows"`
	} `json:"table"`
	Buttons []struct {
		Label string `json:"label"`
		Send  string `json:"send"`
		// Attach — true: фото накладной; "product": фото товара.
		Attach any `json:"attach"`
	} `json:"buttons"`
	Links []struct {
		Label string `json:"label"`
		Href  string `json:"href"`
	} `json:"links"`
	ScanID string `json:"scan_id"`
}

func tools() []ai.Tool {
	obj := func(props map[string]any, required ...string) map[string]any {
		m := map[string]any{"type": "object", "properties": props}
		if len(required) > 0 {
			m["required"] = required
		}
		return m
	}
	str := func(d string) map[string]any { return map[string]any{"type": "string", "description": d} }
	return []ai.Tool{
		{Name: "search_docs", Description: "Найти в документации API панели магазина разделы по ключевым словам: как устроен запрос, параметры, формат тела и ответа.",
			Params: obj(map[string]any{"query": str("2–5 ключевых слов, например «приход документ строки» или «остатки склад»")}, "query")},
		{Name: "list_routes", Description: "Маршруты API панели магазина (метод и путь) — все /store/… или по префиксу.",
			Params: obj(map[string]any{"prefix": str("начало пути, например /store/inventory (пусто — все)")})},
		{Name: "find_products", Description: "Найти товар по словам владельца сразу по нескольким вариантам названия: как он называл раньше, «Мои товары», потом база Super Market. Возвращает product_id, name, unit, qty, per_day, pack, last_cost, last_supplier, where (alias | mine | base).",
			Params: obj(map[string]any{"queries": map[string]any{"type": "array", "items": map[string]any{"type": "string"},
				"description": "2–6 вариантов: слово владельца как есть, другой письменностью, полным брендом, по-русски и по-узбекски — например [\"kola\", \"кола\", \"coca-cola\", \"cola\"] или [\"sut\", \"молоко\"]"}}, "queries")},
		{Name: "remember_alias", Description: "Запомнить, как владелец называет товар («kola» → Coca-Cola 1,5 л): в следующий раз find_products вернёт его первым.",
			Params: obj(map[string]any{"word": str("слово владельца, как он сказал"), "product_id": str("id выбранного товара")}, "word", "product_id")},
		{Name: "call_api", Description: "Вызвать API панели от имени владельца. Чтение свободно; запись — с note; необратимое вернёт needs_confirmation и покажет владельцу кнопку.",
			Params: obj(map[string]any{
				"method": map[string]any{"type": "string", "enum": []string{"GET", "POST", "PUT", "PATCH", "DELETE"}},
				"path":   str("путь вида /store/inventory/my-products (без /api/v1 и без query)"),
				"query":  map[string]any{"type": "object", "description": "параметры запроса, например {\"store_id\": \"…\", \"q\": \"кола\", \"limit\": 20}", "properties": map[string]any{}},
				"body":   map[string]any{"type": "object", "description": "тело JSON для POST/PUT/PATCH", "properties": map[string]any{}},
				"note":   str("для записи: одной фразой, что сделал — попадёт в журнал владельца"),
			}, "method", "path")},
	}
}

// dangerous — что нельзя без кнопки: удаление и запись в «тяжёлые» разделы.
var dangerous = regexp.MustCompile(`/(post|unpost|cancel|payouts?|payments?|handovers?|transfers?|write-off|refunds?|returns?|employees|roles|plan|stores|settings|delivery|debts|operations|cashboxes?|rates|prices?|price-documents|pin|purge|delete|close|open)(/|$)`)

func isDangerous(method, path string, body map[string]any) bool {
	if method == http.MethodDelete {
		return true
	}
	if method == http.MethodGet {
		return false
	}
	if dangerous.MatchString(path) {
		return true
	}
	if v, ok := body["post"].(bool); ok && v {
		return true
	}
	return false
}

// agent — разговор с инструментами до заключительного JSON.
func (s *Service) agent(ctx context.Context, p *identity.Principal, in SendInput, owner Message, sc *invoices.Scan, note string) (reply, error) {
	lang := i18n.FromContext(ctx)
	conn, err := s.ai.Conn(ctx)
	if err != nil {
		return reply{}, err
	}
	if in.Audio != nil && !conn.IsGoogle() {
		return reply{}, apperr.Conflict("audio_unsupported",
			"голосовые понимает только Gemini — супер-админ выбирает Vertex AI в «ИИ-сервисе». Пока напишите текстом.").
			Uz("ovozli xabarlarni faqat Gemini tushunadi — super-admin «SI xizmati»da Vertex AI ni tanlaydi. Hozircha matn bilan yozing.")
	}
	tok, err := s.ident.ServiceToken(p, tokenTTL)
	if err != nil {
		return reply{}, err
	}
	text := in.Text
	if note != "" {
		text = note
	}
	prompt, err := s.buildPrompt(ctx, p, in.StoreID, lang, text, sc)
	if err != nil {
		return reply{}, err
	}
	// Черновик документа в работе — модели вместе с контекстом.
	if docID := s.currentDocument(ctx, p, in.StoreID); docID != "" {
		if st, doc := s.loopback(ctx, tok, lang, http.MethodGet, "/store/inventory/documents/"+docID, nil, nil); st == 200 {
			b, _ := json.Marshal(doc)
			prompt += "\n\nЧерновик документа в работе (current_document, GET /store/inventory/documents/" + docID + "):\n" + cut(string(b), 6000)
		}
	}
	first := ai.ChatMsg{Role: "user", Text: prompt}
	if in.Audio != nil {
		first.Parts = []ai.Part{*in.Audio}
	}
	msgs := []ai.ChatMsg{first}
	st := &agentState{p: p, storeID: in.StoreID, token: tok, lang: lang}
	var out finalOut
	calls := 0
	for step := 0; ; step++ {
		rep, u, err := conn.Chat(ctx, agentPrompt, msgs, tools())
		net, store, emp := p.NetworkID, in.StoreID, p.EmployeeID
		_ = s.ai.Record(ctx, ai.UsageRecord{Kind: "assistant", NetworkID: &net, StoreID: &store, EmployeeID: &emp,
			Provider: conn.Provider, Model: conn.Model, Usage: u, OK: err == nil})
		if err != nil {
			return reply{}, err
		}
		if len(rep.Calls) == 0 {
			js, err := ai.ExtractJSON(rep.Text)
			if err != nil || json.Unmarshal(js, &out) != nil {
				// Модель ответила текстом, не JSON — покажем как есть.
				out = finalOut{Reply: strings.TrimSpace(rep.Text)}
			}
			break
		}
		if calls += len(rep.Calls); calls > maxToolCalls {
			return reply{}, apperr.Conflict("assistant_loop", "помощник не справился: слишком много шагов. Попробуйте сформулировать проще или по частям.").
				Uz("yordamchi uddalay olmadi: qadamlar juda koʻp. Soddaroq yoki boʻlib soʻrang.")
		}
		msgs = append(msgs, ai.ChatMsg{Role: "model", Text: rep.Text, Calls: rep.Calls})
		results := ai.ChatMsg{Role: "tool"}
		for _, call := range rep.Calls {
			results.Results = append(results.Results, ai.ToolResult{ID: call.ID, Name: call.Name, Content: s.runTool(ctx, st, call)})
		}
		msgs = append(msgs, results)
	}
	if in.Audio != nil {
		tr := strings.TrimSpace(out.Transcript)
		if tr == "" {
			tr = t(lang, "(не расслышал)", "(eshitmadim)")
		}
		_, _ = s.pool.Exec(ctx, `UPDATE assistant_messages SET transcript = $2, lang = $3 WHERE id = $1`, owner.ID, tr, out.Lang)
	}
	if out.Lang == "ru" || out.Lang == "uz" {
		lang = out.Lang
	}
	r := reply{text: strings.TrimSpace(out.Reply), lang: lang, intent: "agent", args: map[string]any{"calls": calls}}
	if r.text == "" {
		r.text = t(lang, "Готово.", "Tayyor.")
	}
	if out.Table != nil && len(out.Table.Columns) > 0 && len(out.Table.Rows) > 0 {
		rows := out.Table.Rows
		if len(rows) > 12 {
			rows = rows[:12]
		}
		r.blocks = append(r.blocks, Block{"type": "table", "columns": out.Table.Columns, "rows": rows})
	}
	for _, l := range out.Links {
		if strings.HasPrefix(l.Href, "/") && l.Label != "" {
			r.blocks = append(r.blocks, Block{"type": "link", "label": l.Label, "href": l.Href})
		}
	}
	// Накладная: карточки строк с кнопками, как в панели.
	scanID := out.ScanID
	if scanID == "" && st.scanTouched != "" {
		scanID = st.scanTouched
	}
	if scanID != "" {
		if cur, err := s.scans.Get(ctx, p, scanID); err == nil && (cur.Status == invoices.StatusReady || cur.Status == invoices.StatusProcessing) {
			s.setCurrentScan(ctx, p, in.StoreID, &cur.ID)
			sr, err := s.renderScan(ctx, p, lang, cur, "")
			if err == nil {
				r.scanID = &cur.ID
				r.blocks = append(r.blocks, sr.blocks...)
			}
		}
	}
	// Необратимое — кнопкой.
	for _, c := range st.pending {
		r.blocks = append(r.blocks, Block{"type": "confirm", "label": c.Label, "action": c, "enabled": true,
			"hint": t(lang, "Это действие нельзя отменить — помощник выполнит его только после нажатия.", "Bu amalni bekor qilib boʻlmaydi — yordamchi uni faqat tugma bosilgach bajaradi.")})
	}
	for i, b := range out.Buttons {
		if i >= 4 || strings.TrimSpace(b.Label) == "" {
			break
		}
		switch b.Attach {
		case true, "invoice", "true":
			r.blocks = appendButton(r.blocks, Block{"label": b.Label, "attach": true, "primary": true})
			continue
		case "product":
			r.blocks = appendButton(r.blocks, Block{"label": b.Label, "attach": "product", "primary": true})
			continue
		}
		r.blocks = appendButton(r.blocks, Block{"label": b.Label, "send": firstNonEmpty(b.Send, b.Label)})
	}
	return r, nil
}

// agentState — что накопилось за один ответ.
type agentState struct {
	p           *identity.Principal
	storeID     string
	token       string
	lang        string
	pending     []Action
	scanTouched string
}

func (s *Service) runTool(ctx context.Context, st *agentState, call ai.ToolCall) string {
	switch call.Name {
	case "search_docs":
		return searchDocs(argStr(call.Args, "query"), maxToolOutput)
	case "list_routes":
		return s.listRoutes(argStr(call.Args, "prefix"))
	case "find_products":
		qs := []string{}
		if raw, ok := call.Args["queries"].([]any); ok {
			for _, q := range raw {
				if v, ok := q.(string); ok {
					qs = append(qs, v)
				}
			}
		}
		if q := argStr(call.Args, "query"); q != "" {
			qs = append(qs, q)
		}
		return s.findProducts(ctx, st, qs)
	case "remember_alias":
		return s.rememberAlias(ctx, st, argStr(call.Args, "word"), argStr(call.Args, "product_id"))
	case "call_api":
		return s.toolCallAPI(ctx, st, call.Args)
	}
	return `{"error": "неизвестный инструмент"}`
}

func (s *Service) listRoutes(prefix string) string {
	var b strings.Builder
	for _, r := range s.routes {
		if prefix == "" || strings.HasPrefix(r, prefix) || strings.Contains(r, " "+prefix) {
			b.WriteString(r)
			b.WriteByte('\n')
		}
	}
	if b.Len() == 0 {
		return "маршрутов с таким префиксом нет"
	}
	return b.String()
}

type toolReply struct {
	Status            int    `json:"status,omitempty"`
	Body              any    `json:"body,omitempty"`
	Error             string `json:"error,omitempty"`
	NeedsConfirmation bool   `json:"needs_confirmation,omitempty"`
	Hint              string `json:"hint,omitempty"`
}

func (r toolReply) String() string {
	b, _ := json.Marshal(r)
	return string(b)
}

func (s *Service) toolCallAPI(ctx context.Context, st *agentState, args map[string]any) string {
	method := strings.ToUpper(argStr(args, "method"))
	path := argStr(args, "path")
	query, _ := args["query"].(map[string]any)
	body, _ := args["body"].(map[string]any)
	note := argStr(args, "note")
	if err := checkPath(path); err != nil {
		return toolReply{Error: err.Error()}.String()
	}
	switch method {
	case http.MethodGet, http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete:
	default:
		return toolReply{Error: "method: GET, POST, PUT, PATCH или DELETE"}.String()
	}
	if isDangerous(method, path, body) {
		label := note
		if label == "" {
			label = method + " " + path
		}
		var raw json.RawMessage
		if body != nil {
			raw, _ = json.Marshal(body)
		}
		act := Action{Type: "api", Method: method, Path: path, Query: query, Body: raw, Note: note, Label: label}
		if docPath, ok := strings.CutSuffix(path, "/post"); ok && strings.HasPrefix(docPath, "/store/inventory/documents/") {
			_, cur := s.loopback(ctx, st.token, st.lang, http.MethodGet, docPath, nil, nil)
			doc, _ := cur.(map[string]any)
			act.Expect = docExpect(doc)
		}
		st.pending = append(st.pending, act)
		return toolReply{NeedsConfirmation: true, Hint: "это необратимое действие: владелец увидит кнопку «" + label + "» и подтвердит сам. Скажи ему нажать кнопку."}.String()
	}
	status, resp := s.loopback(ctx, st.token, st.lang, method, path, query, body)
	if method != http.MethodGet && status/100 == 2 {
		s.journal(ctx, st, method, path, note)
	}
	if status/100 == 2 && strings.HasPrefix(path, "/store/inventory/documents") {
		// Создан или поправлен черновик — он теперь «в работе» у чата.
		if m, ok := resp.(map[string]any); ok {
			if id, _ := m["id"].(string); id != "" && m["status"] == "draft" {
				s.setCurrentDocument(ctx, st.p, st.storeID, &id)
			}
		}
	}
	if strings.HasPrefix(path, "/store/invoice-scans/") {
		if id := strings.SplitN(strings.TrimPrefix(path, "/store/invoice-scans/"), "/", 2)[0]; id != "" {
			st.scanTouched = id
		}
	}
	return toolReply{Status: status, Body: resp}.String()
}

func checkPath(path string) error {
	switch {
	case !strings.HasPrefix(path, "/store/"):
		return fmt.Errorf("path: только /store/…")
	case strings.HasPrefix(path, "/store/assistant"):
		return fmt.Errorf("path: помощник не вызывает сам себя")
	case strings.Contains(path, "..") || strings.ContainsAny(path, "?# "):
		return fmt.Errorf("path: без query и пробелов")
	}
	return nil
}

// journal — строка «сделано» в чате: что помощник записал.
func (s *Service) journal(ctx context.Context, st *agentState, method, path, note string) {
	if note == "" {
		note = method + " " + path
	}
	_, _ = s.insert(ctx, st.p, st.storeID, newMsg{Role: RoleSystem, Kind: "done", Text: note, Lang: st.lang})
}

// loopback — внутренний запрос в тот же сервер от имени владельца.
func (s *Service) loopback(ctx context.Context, tok, lang, method, path string, query map[string]any, body map[string]any) (int, any) {
	if s.handler == nil {
		return 503, map[string]any{"error": "сервер ещё не готов"}
	}
	u := "/api/v1" + path
	if len(query) > 0 {
		q := url.Values{}
		keys := make([]string, 0, len(query))
		for k := range query {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			q.Set(k, anyStr(query[k]))
		}
		u += "?" + q.Encode()
	}
	var rd *bytes.Reader
	if body != nil && method != http.MethodGet {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	} else {
		rd = bytes.NewReader(nil)
	}
	// Контекст фонового ответа может нести RouteContext исходного запроса
	// (/store/assistant/messages) — chi тогда не маршрутизирует заново.
	req := httptest.NewRequest(method, u, rd).WithContext(context.WithValue(ctx, chi.RouteCtxKey, nil))
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Accept-Language", lang)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Assistant", "1")
	rec := httptest.NewRecorder()
	s.handler.ServeHTTP(rec, req)
	return rec.Code, limitJSON(rec.Body.Bytes())
}

func anyStr(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64)
	case bool:
		return strconv.FormatBool(x)
	case nil:
		return ""
	}
	b, _ := json.Marshal(v)
	return string(b)
}

// limitJSON — ответ API для модели: длинные списки и тексты обрезаются.
func limitJSON(raw []byte) any {
	var v any
	if json.Unmarshal(raw, &v) != nil {
		s := string(raw)
		if len(s) > maxToolOutput {
			s = cut(s, maxToolOutput) + "…"
		}
		return s
	}
	if m, ok := v.(map[string]any); ok {
		if items, ok := m["items"].([]any); ok && len(items) > maxListItems {
			m["items"] = items[:maxListItems]
			m["items_shown"] = maxListItems
			m["items_truncated"] = true
		}
	}
	b, _ := json.Marshal(v)
	if len(b) > maxToolOutput {
		return map[string]any{"truncated": true, "text": cut(string(b), maxToolOutput) + "…"}
	}
	return v
}
