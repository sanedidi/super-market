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
	"errors"
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

const agentPrompt = `Тебя зовут Шахзод — ты помощник Super Market: сервиса учёта для небольших магазинов в Узбекистане. Ты общаешься с владельцем магазина в чате (в панели и в приложении «SM Магазин») и работаешь за него через API панели. Говори просто и коротко, как живой помощник, о себе — в мужском роде («я сделал», «я записал»), без слов «ИИ», «бот», «нейросеть», «модель», «API», «эндпоинт». Представляйся «Шахзод», если спрашивают или в первом приветствии.

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
8. Приход без накладной. Если владелец сам называет товар и количество («7 blok kola keldi», «пришло 20 молока по 12 000») — НЕ проси накладную, а сделай ручной приход. Нужно четыре вещи: товар, количество, цена закупки (себестоимость), поставщик. Ничего из этого не выбирай молча за владельца:
   а) товар — find_products (правило 17); склад — правило 20;
   б) количество: блоки → штуки = блоки × pack; pack не известен — спроси, сколько штук в блоке, и запомни: PUT /store/inventory/my-products/{product_id}/pack {"pack": 6};
   в) цена закупки: назвал — бери; не назвал — спроси, предложив кнопками прошлую цену: «7 333 — как в прошлый раз» (last_cost) и «Другая цена»; нет last_cost — просто спроси. Цена при блоках — уточни, за блок или за штуку;
   г) поставщик: назвал — бери (правило 12 про похожих); не назвал — спроси кнопками: last_supplier («SAYONAR — как в прошлый раз»), ещё 1–2 из suppliers и «Другой»;
   Всё недостающее спрашивай ОДНИМ сообщением (цена и поставщик вместе), а не по одному вопросу.
   д) цена продажи: в том же сообщении или в итоге черновика покажи текущую цену продажи (price из my-products) и наценку к новой закупке; спроси «Цену продажи оставить 13 000 или поменять?» кнопками. Если продажа ниже закупки или наценка меньше 10 % — предупреди и предложи цену с прежней наценкой;
   е) когда всё известно — черновик: POST /store/inventory/documents {"type":"income","warehouse_id":…,"counterparty_id":…,"items":[{"product_id":…,"qty":"42","price":"7333"}]} с note «Черновик прихода: …»; затем POST /store/inventory/documents/{id}/post с button «Провести приход · 308 000» — сервер покажет кнопку. Сам кнопку «Провести» в buttons не добавляй;
   ж) новая цена продажи — черновик «Установки цен»: POST /store/price-documents {"price_type_id": (GET /store/price-types — первый/основной), "store_id":…, "items":[{"product_id":…,"new_price":"14000"}]} с note, note — «Цена продажи Coca-Cola 1,5 л: 14 000» и button «Установить цену 14 000». Кнопку проведения сервер покажет сам. Черновик НЕ меняет цену на кассе: пока владелец не нажал кнопку, пиши «нажмите „Установить цену 14 000“», а не «изменил».
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
18. Помни, что владелец уже сказал: количество, блоки, цену, поставщика из прошлых сообщений (recent_messages, там же расшифровки голосовых и «[выбрано: id]» у нажатых кнопок). Выбрал товар кнопкой — сразу продолжай приход с уже названными цифрами, не переспрашивай «сколько пришло?».
19. В базе Super Market бывают почти одинаковые карточки одного товара («Coca-Cola Classic 1,5 л», «Coca-Cola газированный 1,5 л»). Если владелец назвал товар и размер, и все найденные варианты подходят — не спрашивай: бери тот, что в «Моих товарах» (where mine), иначе с наибольшим stores (в скольких магазинах продаётся), и одной фразой скажи, какой взял, с кнопками «Другой товар» на 2–3 альтернативы (ref — их product_id). Спрашивай только когда варианты действительно разные (разный размер, вкус, «без сахара» при том, что владелец этого не уточнял, — спроси кратко).

20. Откуда и куда. У каждого движения товара есть сторона «откуда» и «куда» — не угадывай их, а спрашивай, если владелец не сказал:
   - приход (income): ОТ кого (поставщик, правило 8 г) и НА какой склад;
   - возврат поставщику (supplier_return): КАКОМУ поставщику (у кого брали этот товар — подскажи last_supplier кнопкой) и С какого склада;
   - перемещение (transfer): С какого склада НА какой (warehouse_id и to_warehouse_id, это разные склады);
   - списание (write_off): С какого склада и причина (reason: просрочка, бой, порча, ошибка);
   - возврат от покупателя делается на кассе — скажи об этом и дай ссылку на «/sales/returns».
   Склады магазина — warehouses в контексте. Один склад — не спрашивай, но назови его в итоге («на склад Основной»). Несколько — спроси кнопками (send — название склада, ref — id), склад по умолчанию — первым. Владелец назвал другой магазин сети — склады того магазина: GET /store/warehouses?store_id=…. Спрашивай «откуда/куда» в том же сообщении, что цену и поставщика, — одним вопросом, не по очереди.
21. Честность о сделанном. Пока владелец не нажал кнопку подтверждения, действие НЕ выполнено: не пиши «изменил», «провёл», «удалил», «оплатил» — пиши «готово к подтверждению, нажмите …». Цены, остатки и суммы называй только из свежего ответа API (цена продажи — поле price в GET /store/inventory/my-products), никогда из черновиков и не по памяти разговора.
22. Никаких тупиков. Если что-то делается не здесь или ты не можешь сделать это сам — ВСЕГДА дай links на нужный раздел и, если можешь, кнопку ближайшего действия, которое сделаешь сам. Пример: «20ta kola sotildi» — продажа проводится только на кассе (продать отсюда нельзя). Уточни кнопками: «Продали мимо кассы — убрать 20 шт с остатка» (списание write_off с reason «продажа мимо кассы», кнопкой подтверждения) и «Показать продажи колы за сегодня» (отчёт), плюс ссылка «/sales/pos». Не отвечай голым «перейдите в раздел».

Страницы панели для ссылок (href): главная «/», остатки «/stock/balance», приход «/purchases/income» и «/purchases/income/{document_id}», товары «/dirs/products», контрагенты «/dirs/counterparties», продажи «/sales/pos», цены «/sales/prices», долги «/debts», заказы «/orders», финансы «/finance/operations», отчёты «/reports/profit-loss», сотрудники «/settings/employees».

Когда всё сделано, ответь ТОЛЬКО JSON без текста вокруг:
{"transcript": "расшифровка аудио или пусто", "lang": "ru|uz", "reply": "ответ владельцу, 1–4 предложения; цифры — из API",
 "table": {"columns": ["…"], "rows": [["…"]]} или null (до 12 строк, для списков и остатков),
 "buttons": [{"label": "следующий шаг", "send": "что отправится как сообщение (человеческим текстом, никогда не id)", "ref": "id товара/документа, если кнопка — выбор из списка"}, {"label": "Прикрепить накладную", "attach": true}, {"label": "Сфотографировать товар", "attach": "product"}] (до 4, можно пусто; attach true — фото накладной, только когда владелец говорит о приходе, не называя товары; attach "product" — фото товара, которого нет в базе),
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
		Ref   string `json:"ref"`
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
				"button": str("для необратимого: подпись кнопки в повелительном наклонении, например «Провести приход · 308 000» или «Установить цену 14 000»"),
			}, "method", "path")},
	}
}

// dangerous — что нельзя без кнопки: удаление и запись в «тяжёлые» разделы.
// confirmLike — кнопка модели, которая лишь повторяет подтверждение текстом.
func confirmLike(s string) bool {
	s = strings.ToLower(s)
	for _, w := range []string{"провест", "провед", "подтверд", "установить цен", "oʻtkaz", "o'tkaz", "otkaz", "tasdiq"} {
		if strings.Contains(s, w) {
			return true
		}
	}
	return false
}

var uuidRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

var dangerous = regexp.MustCompile(`/(post|unpost|cancel|payouts?|payments?|handovers?|transfers?|write-off|refunds?|returns?|employees|roles|plan|stores|settings|delivery|debts|operations|cashboxes?|rates|prices?|pin|purge|delete|close|open)(/|$)`)

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
	if ref := strings.TrimSpace(in.Ref); ref != "" {
		text += " [выбрано: " + ref + "]"
	}
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
		var rep ai.ChatReply
		var err error
		for try := 0; ; try++ {
			var u ai.Usage
			rep, u, err = conn.Chat(ctx, agentPrompt, msgs, tools())
			net, store, emp := p.NetworkID, in.StoreID, p.EmployeeID
			_ = s.ai.Record(ctx, ai.UsageRecord{Kind: "assistant", NetworkID: &net, StoreID: &store, EmployeeID: &emp,
				Provider: conn.Provider, Model: conn.Model, Usage: u, OK: err == nil})
			// Перегрузка Google (429/5xx) или пустой ответ — повторяем сами, владелец не видит.
			if err == nil || try >= len(s.retryWait) || !retryable(err) {
				break
			}
			select {
			case <-ctx.Done():
				return reply{}, ctx.Err()
			case <-time.After(s.retryWait[try]):
			}
		}
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
	// «Перейдите в раздел…» без ссылки — добавим ссылку сами, чтобы был переход.
	if len(out.Links) == 0 && len(st.pending) == 0 {
		if l := sectionLink(lang, r.text); l != nil {
			r.blocks = append(r.blocks, l)
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
		// «Провести» — только настоящей кнопкой подтверждения, не текстом.
		if len(st.pending) > 0 && confirmLike(b.Label+" "+b.Send) {
			continue
		}
		switch b.Attach {
		case true, "invoice", "true":
			r.blocks = appendButton(r.blocks, Block{"label": b.Label, "attach": true, "primary": true})
			continue
		case "product":
			r.blocks = appendButton(r.blocks, Block{"label": b.Label, "attach": "product", "primary": true})
			continue
		}
		send, ref := firstNonEmpty(b.Send, b.Label), b.Ref
		// id в «send» — в чат уйдёт текст кнопки, id — модели.
		if uuidRe.MatchString(strings.TrimSpace(send)) {
			ref, send = strings.TrimSpace(send), b.Label
		}
		btn := Block{"label": b.Label, "send": send}
		if ref != "" {
			btn["ref"] = ref
		}
		r.blocks = appendButton(r.blocks, btn)
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
	button := argStr(args, "button")
	if err := checkPath(path); err != nil {
		return toolReply{Error: err.Error()}.String()
	}
	switch method {
	case http.MethodGet, http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete:
	default:
		return toolReply{Error: "method: GET, POST, PUT, PATCH или DELETE"}.String()
	}
	if isDangerous(method, path, body) {
		label := button
		if label == "" && note != "" {
			label = t(st.lang, "Подтвердить: ", "Tasdiqlash: ") + note
		}
		if label == "" {
			label = t(st.lang, "Подтвердить", "Tasdiqlash")
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
		st.addPending(act)
		return toolReply{NeedsConfirmation: true, Hint: "это необратимое действие: владелец увидит кнопку «" + label + "» и подтвердит сам. Скажи ему нажать кнопку."}.String()
	}
	status, resp := s.loopback(ctx, st.token, st.lang, method, path, query, body)
	if method != http.MethodGet && status/100 == 2 && !priceDocRe.MatchString(path) {
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
	if status/100 == 2 && method != http.MethodGet && method != http.MethodDelete && priceDocRe.MatchString(path) {
		// Черновик цен ничего не меняет на кассе — сразу даём кнопку «Установить цену».
		if m, ok := resp.(map[string]any); ok && m["status"] == "draft" {
			if id, _ := m["id"].(string); id != "" {
				label := button
				if label == "" {
					label = priceLabel(st.lang, m)
				}
				st.addPending(Action{Type: "api", Method: http.MethodPost, Path: "/store/price-documents/" + id + "/post", Note: note, Label: label})
				return toolReply{Status: status, Body: resp, Hint: "это только ЧЕРНОВИК: цена на кассе ещё старая. Владелец увидит кнопку «" + label +
					"» — скажи нажать её. НЕ пиши, что цена изменена, пока он не нажал."}.String()
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

// panelSections — разделы панели: слова в ответе → ссылка.
var panelSections = []struct {
	words  []string
	href   string
	ru, uz string
}{
	{[]string{"касс", "продаж", "kassa", "sotuv"}, "/sales/pos", "Открыть продажи", "Sotuvlarni ochish"},
	{[]string{"цены", "установка цен", "narxlar"}, "/sales/prices", "Открыть цены", "Narxlarni ochish"},
	{[]string{"долг", "qarz"}, "/debts", "Открыть долги", "Qarzlarni ochish"},
	{[]string{"заказ", "buyurtma"}, "/orders", "Открыть заказы", "Buyurtmalarni ochish"},
	{[]string{"приход", "kirim"}, "/purchases/income", "Открыть приходы", "Kirimlarni ochish"},
	{[]string{"остат", "склад", "qoldiq", "ombor"}, "/stock/balance", "Открыть остатки", "Qoldiqlarni ochish"},
	{[]string{"финанс", "moliya"}, "/finance/operations", "Открыть финансы", "Moliyani ochish"},
	{[]string{"отчёт", "отчет", "hisobot"}, "/reports/profit-loss", "Открыть отчёты", "Hisobotlarni ochish"},
	{[]string{"сотрудник", "xodim"}, "/settings/employees", "Открыть сотрудников", "Xodimlarni ochish"},
	{[]string{"контрагент", "taʼminotchi", "kontragent"}, "/dirs/counterparties", "Открыть контрагентов", "Kontragentlarni ochish"},
	{[]string{"товары", "mahsulotlar", "tovarlar"}, "/dirs/products", "Открыть товары", "Mahsulotlarni ochish"},
}

// goWords — ответ отправляет владельца в другой раздел или говорит «здесь не могу».
var goWords = []string{"перейдите", "откройте", "в разделе", "в раздел", "не могу", "o'ting", "oching", "bo'lim", "olmayman", "qila olmayman"}

// sectionLink — ссылка на раздел, куда ответ отправляет владельца (nil — не отправляет).
func sectionLink(lang, text string) Block {
	low := strings.ToLower(strings.NewReplacer("ʻ", "'", "’", "'", "`", "'", "ʼ", "'").Replace(text))
	sent := false
	for _, w := range goWords {
		if strings.Contains(low, w) {
			sent = true
			break
		}
	}
	if !sent {
		return nil
	}
	for _, sec := range panelSections {
		for _, w := range sec.words {
			if strings.Contains(low, w) {
				return Block{"type": "link", "label": t(lang, sec.ru, sec.uz), "href": sec.href}
			}
		}
	}
	return nil
}

// priceDocRe — черновик «Установки цен» (создание или правка, не проведение).
var priceDocRe = regexp.MustCompile(`^/store/price-documents(/[^/]+)?$`)

// addPending — кнопка подтверждения; одно действие — одна кнопка.
func (st *agentState) addPending(a Action) {
	for i, c := range st.pending {
		if c.Method == a.Method && c.Path == a.Path {
			if a.Label != "" {
				st.pending[i].Label = a.Label
			}
			return
		}
	}
	st.pending = append(st.pending, a)
}

// priceLabel — «Установить цену 13 000» по черновику цен.
func priceLabel(lang string, doc map[string]any) string {
	items, _ := doc["items"].([]any)
	if len(items) == 1 {
		if it, ok := items[0].(map[string]any); ok {
			if p, _ := it["new_price"].(string); p != "" {
				return t(lang, "Установить цену ", "Narxni oʻrnatish: ") + groupDigits(p)
			}
		}
	}
	return t(lang, "Установить новые цены", "Yangi narxlarni oʻrnatish")
}

// groupDigits — «13000.00» → «13 000».
func groupDigits(v string) string {
	v = strings.TrimSpace(v)
	if i := strings.IndexByte(v, '.'); i >= 0 && strings.Trim(v[i+1:], "0") == "" {
		v = v[:i]
	}
	intPart, frac := v, ""
	if i := strings.IndexByte(v, '.'); i >= 0 {
		intPart, frac = v[:i], v[i:]
	}
	var b strings.Builder
	for i, r := range intPart {
		if i > 0 && (len(intPart)-i)%3 == 0 {
			b.WriteByte(' ')
		}
		b.WriteRune(r)
	}
	return b.String() + frac
}

// retryable — временная ошибка модели: перегрузка, сбой Google или пустой ответ.
func retryable(err error) bool {
	var se *ai.ErrService
	if !errors.As(err, &se) {
		return false
	}
	return se.Status == 429 || se.Status >= 500 || se.Temporary || strings.Contains(se.Msg, "пустой ответ")
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
