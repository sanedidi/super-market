package assistant

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/invoices"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// reply — что попадёт в сообщение помощника.
type reply struct {
	text   string
	blocks []Block
	lang   string
	scanID *string
	intent string
	args   any
}

func t(lang, ru, uz string) string { return i18n.Pick(lang, ru, uz) }

// handle — ответ на сообщение владельца.
func (s *Service) handle(ctx context.Context, p *identity.Principal, in SendInput, owner Message) (reply, error) {
	lang := i18n.FromContext(ctx)
	switch {
	case in.Action != nil:
		return s.doAction(ctx, p, in.StoreID, lang, *in.Action)
	case len(in.Images) > 0 && in.Kind == "product":
		return s.startProduct(ctx, p, in, lang)
	case len(in.Images) > 0:
		// Фото накладной — это всегда приход: модель не нужна.
		return s.startScan(ctx, p, in.StoreID, lang, in.Images)
	}
	return s.agent(ctx, p, in, owner, s.currentScan(ctx, p, in.StoreID), "")
}

func firstNonEmpty(a, b string) string {
	if strings.TrimSpace(a) != "" {
		return a
	}
	return b
}

func argStr(args map[string]any, key string) string {
	if args == nil {
		return ""
	}
	switch v := args[key].(type) {
	case string:
		return strings.TrimSpace(v)
	case float64:
		return strconv.FormatFloat(v, 'f', -1, 64)
	}
	return ""
}

func argInt(args map[string]any, key string) int {
	if args == nil {
		return 0
	}
	switch v := args[key].(type) {
	case float64:
		return int(v)
	case string:
		n, _ := strconv.Atoi(strings.TrimSpace(v))
		return n
	}
	return 0
}

func argBool(args map[string]any, key string) bool {
	if args == nil {
		return false
	}
	b, _ := args[key].(bool)
	return b
}

// appendButton — кнопка в первый блок buttons (создаёт его, если нет).
func appendButton(blocks []Block, b Block) []Block {
	for _, bl := range blocks {
		if bl["type"] == "buttons" {
			items, _ := bl["items"].([]Block)
			bl["items"] = append(items, b)
			return blocks
		}
	}
	return append(blocks, Block{"type": "buttons", "items": []Block{b}})
}

// ---------- накладная ----------

// currentScan — накладная, над которой идёт работа в этом чате (ready или
// processing); проведённая или с ошибкой — уже не текущая.
func (s *Service) currentScan(ctx context.Context, p *identity.Principal, storeID string) *invoices.Scan {
	var id *string
	err := s.pool.QueryRow(ctx, `SELECT scan_id FROM assistant_chats WHERE store_id = $1 AND employee_id = $2`, storeID, p.EmployeeID).Scan(&id)
	if err != nil || id == nil {
		return nil
	}
	sc, err := s.scans.Get(ctx, p, *id)
	if err != nil || (sc.Status != invoices.StatusReady && sc.Status != invoices.StatusProcessing) {
		return nil
	}
	return &sc
}

// currentDocument — черновик документа чата (id); проведённого или
// удалённого — нет.
func (s *Service) currentDocument(ctx context.Context, p *identity.Principal, storeID string) string {
	var id *string
	err := s.pool.QueryRow(ctx, `
		SELECT c.document_id FROM assistant_chats c JOIN stock_documents d ON d.id = c.document_id
		WHERE c.store_id = $1 AND c.employee_id = $2 AND d.status = 'draft'`, storeID, p.EmployeeID).Scan(&id)
	if err != nil || id == nil {
		return ""
	}
	return *id
}

func (s *Service) setCurrentDocument(ctx context.Context, p *identity.Principal, storeID string, id *string) {
	_, _ = s.pool.Exec(ctx, `
		INSERT INTO assistant_chats (store_id, employee_id, document_id) VALUES ($1, $2, $3)
		ON CONFLICT (store_id, employee_id) DO UPDATE SET document_id = EXCLUDED.document_id, updated_at = now()`, storeID, p.EmployeeID, id)
}

func (s *Service) setCurrentScan(ctx context.Context, p *identity.Principal, storeID string, scanID *string) {
	_, _ = s.pool.Exec(ctx, `
		INSERT INTO assistant_chats (store_id, employee_id, scan_id) VALUES ($1, $2, $3)
		ON CONFLICT (store_id, employee_id) DO UPDATE SET scan_id = EXCLUDED.scan_id, updated_at = now()`, storeID, p.EmployeeID, scanID)
}

// startScan — фото накладной → распознавание; ждём результат (до scanWait)
// и показываем строки, которым нужен ответ.
func (s *Service) startScan(ctx context.Context, p *identity.Principal, storeID, lang string, images []string) (reply, error) {
	sc, err := s.scans.Create(ctx, p, invoices.CreateInput{StoreID: storeID, Images: images})
	if err != nil {
		return reply{}, err
	}
	s.setCurrentScan(ctx, p, storeID, &sc.ID)
	deadline := s.now().Add(s.scanWait)
	for sc.Status == invoices.StatusProcessing && s.now().Before(deadline) {
		select {
		case <-ctx.Done():
			return reply{}, ctx.Err()
		case <-time.After(2 * time.Second):
		}
		if sc, err = s.scans.Get(ctx, p, sc.ID); err != nil {
			return reply{}, err
		}
	}
	return s.renderScan(ctx, p, lang, sc, "")
}

// findCounterparty — поставщик по названию (как в накладных: похожесть ≥ 0,5).
func (s *Service) findCounterparty(ctx context.Context, networkID, name string) *string {
	n := strings.ToLower(strings.TrimSpace(name))
	if n == "" {
		return nil
	}
	var id string
	err := s.pool.QueryRow(ctx, `SELECT id FROM counterparties WHERE network_id = $1 AND is_active AND similarity(lower(name), $2) >= 0.5
		ORDER BY similarity(lower(name), $2) DESC LIMIT 1`, networkID, n).Scan(&id)
	if err != nil {
		return nil
	}
	return &id
}

// doAction — нажатая кнопка: без модели, сразу делом.
func (s *Service) doAction(ctx context.Context, p *identity.Principal, storeID, lang string, a Action) (reply, error) {
	switch a.Type {
	case "scan_line":
		in := invoices.LineInput{ProductID: a.ProductID, Remember: a.ProductID != nil || a.Pack != nil}
		if a.Pack != nil {
			q := money.Qty(*a.Pack)
			in.Pack = &q
		}
		if a.Skip {
			skip := true
			in.Skip = &skip
			in.Remember = false
		}
		sc, err := s.scans.Get(ctx, p, a.ScanID)
		if err != nil {
			return reply{}, err
		}
		if sc.CounterpartyID == nil {
			in.Remember = false
		}
		next, err := s.scans.SetLine(ctx, p, a.ScanID, a.Line, in)
		if err != nil {
			return reply{}, err
		}
		s.setCurrentScan(ctx, p, storeID, &next.ID)
		return s.renderScan(ctx, p, lang, next, t(lang, "Записал.", "Yozdim."))
	case "scan_supplier":
		next, err := s.scans.SetSupplier(ctx, p, a.ScanID, invoices.SupplierInput{CounterpartyID: a.CounterpartyID, Create: a.Create})
		if err != nil {
			return reply{}, err
		}
		s.setCurrentScan(ctx, p, storeID, &next.ID)
		return s.renderScan(ctx, p, lang, next, "")
	case "scan_post":
		sc, err := s.scans.CreateDocument(ctx, p, a.ScanID, invoices.DocumentInput{Post: true})
		if err != nil {
			return reply{}, err
		}
		s.setCurrentScan(ctx, p, storeID, nil)
		num := ""
		if sc.DocumentNumber != nil {
			num = fmt.Sprintf("№ %d", *sc.DocumentNumber)
		}
		done := fmt.Sprintf(t(lang, "Приход %s проведён · %s сум · %d строк", "Kirim %s oʻtkazildi · %s soʻm · %d qator"), num, money.Group(sc.LinesTotal), len(sc.Lines)-sc.Counts.Skipped)
		_, _ = s.insert(ctx, p, storeID, newMsg{Role: RoleSystem, Kind: "done", Text: done, Lang: lang, ScanID: &sc.ID})
		r := reply{text: t(lang, "Готово, остатки обновил.", "Tayyor, qoldiqlarni yangiladim."), lang: lang, scanID: &sc.ID, intent: "scan_post"}
		if sc.DocumentID != nil {
			r.blocks = append(r.blocks, Block{"type": "link", "label": t(lang, "Открыть приход "+num, "Kirimni ochish "+num), "href": "/purchases/income/" + *sc.DocumentID})
		}
		r.blocks = append(r.blocks, Block{"type": "buttons", "items": []Block{
			{"label": t(lang, "Что заказать?", "Nima buyurtma qilish?"), "send": t(lang, "Что заказать?", "Nima buyurtma qilish kerak?")},
			{"label": t(lang, "Ещё приход", "Yana kirim"), "send": t(lang, "Пришли товары", "Tovarlar keldi")},
		}})
		return r, nil
	case "api":
		// Владелец подтвердил необратимый запрос агента: выполняем и даём
		// помощнику рассказать результат.
		tok, err := s.ident.ServiceToken(p, tokenTTL)
		if err != nil {
			return reply{}, err
		}
		var body map[string]any
		if len(a.Body) > 0 {
			_ = json.Unmarshal(a.Body, &body)
		}
		st := &agentState{p: p, storeID: storeID, token: tok, lang: lang}
		// Проведение документа: перечитать — его могли поправить в панели.
		if a.Expect != "" {
			if docPath, ok := strings.CutSuffix(a.Path, "/post"); ok {
				_, cur := s.loopback(ctx, tok, lang, http.MethodGet, docPath, nil, nil)
				doc, _ := cur.(map[string]any)
				if got := docExpect(doc); got != a.Expect {
					if st, _ := doc["status"].(string); st != "" && st != "draft" {
						return reply{text: t(lang, "Этот документ уже не черновик — проводить нечего.", "Bu hujjat endi qoralama emas — oʻtkazadigan narsa yoʻq."), lang: lang}, nil
					}
					a.Expect = got
					return reply{text: t(lang, "Документ изменился с момента кнопки (поменялись строки или сумма). Посмотрите ещё раз и подтвердите заново.",
						"Tugma bosilganidan beri hujjat oʻzgargan (qatorlar yoki summa). Yana koʻrib, qayta tasdiqlang."), lang: lang,
						blocks: []Block{{"type": "confirm", "label": a.Label, "action": a, "enabled": true}}}, nil
				}
			}
		}
		status, resp := s.loopback(ctx, tok, lang, strings.ToUpper(a.Method), a.Path, a.Query, body)
		if status/100 == 2 {
			s.journal(ctx, st, a.Method, a.Path, a.Note)
			s.setCurrentScan(ctx, p, storeID, nil)
			if strings.HasSuffix(a.Path, "/post") || a.Method == http.MethodDelete {
				s.setCurrentDocument(ctx, p, storeID, nil)
			}
		}
		raw, _ := json.Marshal(resp)
		note := fmt.Sprintf("[Владелец нажал кнопку «%s». Запрос %s %s выполнен, HTTP %d, ответ: %s] Коротко расскажи владельцу результат; если ошибка — объясни простыми словами.",
			a.Label, a.Method, a.Path, status, cut(string(raw), 4000))
		return s.agent(ctx, p, SendInput{StoreID: storeID}, Message{}, nil, note)
	}
	return reply{}, apperr.Validation("action.type: scan_line, scan_supplier, scan_post или api").Uz("action.type: scan_line, scan_supplier, scan_post yoki api")
}

// renderScan — накладная в чате: итог, поставщик, строки с вопросами, кнопка
// «Провести». intro — первая фраза (пусто — по состоянию).
func (s *Service) renderScan(ctx context.Context, p *identity.Principal, lang string, sc invoices.Scan, intro string) (reply, error) {
	r := reply{lang: lang, scanID: &sc.ID, intent: "scan"}
	switch sc.Status {
	case invoices.StatusProcessing:
		r.text = t(lang, "Читаю накладную — это займёт около минуты. Напишите «готово?», и я покажу, что получилось.",
			"Nakladnoyni oʻqiyapman — bir daqiqacha vaqt oladi. «tayyormi?» deb yozing, natijani koʻrsataman.")
		r.blocks = []Block{{"type": "buttons", "items": []Block{{"label": t(lang, "Готово?", "Tayyormi?"), "send": t(lang, "Готово?", "Tayyormi?")}}}}
		return r, nil
	case invoices.StatusFailed:
		r.text = t(lang, "Не смог прочитать накладную: ", "Nakladnoyni oʻqiy olmadim: ") + sc.Error + t(lang, " Попробуйте сфотографировать ровнее и при хорошем свете.", " Tekisroq va yaxshi yorugʻlikda suratga oling.")
		r.blocks = []Block{{"type": "buttons", "items": []Block{{"label": t(lang, "Прикрепить заново", "Qayta biriktirish"), "attach": true, "primary": true}}}}
		return r, nil
	case invoices.StatusDone:
		r.text = t(lang, "По этой накладной приход уже проведён.", "Bu nakladnoy boʻyicha kirim allaqachon oʻtkazilgan.")
		return r, nil
	}
	need := sc.Counts.Missing + sc.Counts.Pack + sc.Counts.Check
	head := fmt.Sprintf(t(lang, "Накладная %s от %s — %d строк на %s сум.", "Nakladnoy %s, %s — %d qator, %s soʻm."),
		numOr(sc.InvoiceNumber, lang), supplierName(sc, lang), len(sc.Lines), money.Group(sc.LinesTotal))
	switch {
	case sc.CounterpartyID == nil:
		head += " " + t(lang, "От кого накладная?", "Nakladnoy kimdan?")
	case need == 0:
		head += " " + t(lang, "Все строки готовы — можно проводить.", "Hamma qator tayyor — oʻtkazsa boʻladi.")
	default:
		head += " " + fmt.Sprintf(t(lang, "%d товаров нашёл сразу, по %d нужна ваша помощь:", "%d tovarni darrov topdim, %d tasiga yordamingiz kerak:"), sc.Counts.OK, need)
	}
	r.text = strings.TrimSpace(intro + " " + head)
	if sc.CounterpartyID == nil {
		r.blocks = append(r.blocks, s.supplierCard(ctx, p, lang, sc))
	}
	shown := 0
	for _, l := range sc.Lines {
		if shown >= 6 || (l.State != "missing" && l.State != "pack" && l.State != "check") {
			continue
		}
		r.blocks = append(r.blocks, s.lineCard(ctx, p, lang, sc, l))
		shown++
	}
	if need > shown {
		r.text += " " + fmt.Sprintf(t(lang, "(показал первые %d)", "(birinchi %d tasini koʻrsatdim)"), shown)
	}
	enabled := sc.CounterpartyID != nil && sc.Counts.Missing == 0 && sc.Counts.Pack == 0
	hint := ""
	if !enabled {
		hint = t(lang, "Кнопка станет активной, когда будут выбраны поставщик и товары всех строк.",
			"Yetkazib beruvchi va barcha qator tovarlari tanlangach tugma faollashadi.")
	}
	r.blocks = append(r.blocks, Block{"type": "confirm", "label": fmt.Sprintf(t(lang, "Провести приход · %s сум", "Kirimni oʻtkazish · %s soʻm"), money.Group(sc.LinesTotal)),
		"action": Action{Type: "scan_post", ScanID: sc.ID, Label: t(lang, "Провести приход", "Kirimni oʻtkazish")}, "enabled": enabled, "hint": hint})
	return r, nil
}

func numOr(n, lang string) string {
	if n == "" {
		return t(lang, "без номера", "raqamsiz")
	}
	return "№ " + n
}

func supplierName(sc invoices.Scan, lang string) string {
	if sc.CounterpartyName != nil {
		return *sc.CounterpartyName
	}
	if sc.SupplierName != "" {
		return sc.SupplierName
	}
	return t(lang, "поставщика без названия", "nomsiz yetkazib beruvchi")
}

// supplierCard — «От кого накладная?»: завести распознанного или выбрать своего.
func (s *Service) supplierCard(ctx context.Context, p *identity.Principal, lang string, sc invoices.Scan) Block {
	items := []Block{}
	if sc.SupplierName != "" {
		items = append(items, Block{"label": t(lang, "Завести «"+sc.SupplierName+"»", "«"+sc.SupplierName+"» ni kiritish"), "primary": true,
			"action": Action{Type: "scan_supplier", ScanID: sc.ID, Create: true, Label: sc.SupplierName}})
	}
	rows, err := s.pool.Query(ctx, `SELECT id, name FROM counterparties WHERE network_id = $1 AND is_active ORDER BY name LIMIT 4`, p.NetworkID)
	if err == nil {
		for rows.Next() {
			var id, name string
			if rows.Scan(&id, &name) == nil {
				cp := id
				items = append(items, Block{"label": name, "action": Action{Type: "scan_supplier", ScanID: sc.ID, CounterpartyID: &cp, Label: name}})
			}
		}
		rows.Close()
	}
	return Block{"type": "card", "title": t(lang, "Поставщик", "Yetkazib beruvchi"), "note": sc.SupplierName,
		"status": t(lang, "От кого накладная?", "Nakladnoy kimdan?"), "status_kind": "warn", "buttons": items}
}

// lineCard — строка, которой нужен ответ, с кнопками по её состоянию.
func (s *Service) lineCard(ctx context.Context, p *identity.Principal, lang string, sc invoices.Scan, l invoices.Line) Block {
	unit := l.Unit
	if unit == "" {
		unit = t(lang, "шт", "dona")
	}
	note := fmt.Sprintf("%s × %s", trimQty(l.Qty), money.Group(l.Price))
	if l.PackSource == invoices.PackSum && l.Pack != "1" {
		note += " · " + fmt.Sprintf(t(lang, "по сумме: 1 %s = %s", "summa boʻyicha: 1 %s = %s"), unit, trimQty(l.Pack))
	}
	card := Block{"type": "card", "title": l.Name, "sum": money.Group(l.Sum), "note": note}
	items := []Block{}
	switch l.State {
	case "missing":
		card["status"] = t(lang, "Не нашёл в ваших товарах", "Tovarlaringiz orasida topmadim")
		card["status_kind"] = "error"
		if sug, err := s.scans.Suggest(ctx, p, sc.ID, l.Line, ""); err == nil {
			for i, sg := range sug {
				if i >= 3 {
					break
				}
				pid := sg.ProductID
				items = append(items, Block{"label": sg.Name, "primary": i == 0 && sg.Score >= 90,
					"action": Action{Type: "scan_line", ScanID: sc.ID, Line: l.Line, ProductID: &pid, Label: sg.Name}})
			}
		}
		items = append(items, Block{"label": t(lang, "Пропустить строку", "Qatorni oʻtkazib yuborish"),
			"action": Action{Type: "scan_line", ScanID: sc.ID, Line: l.Line, Skip: true, Label: t(lang, "Пропустить «"+l.Name+"»", "«"+l.Name+"» ni oʻtkazib yuborish")}})
	case "pack":
		qty := trimQty(l.Qty)
		card["status"] = fmt.Sprintf(t(lang, "Это %s штук или %s блоков по %s?", "Bu %s donami yoki %s ta blok (har biri %s)?"), qty, qty, trimQty(l.Pack))
		card["status_kind"] = "warn"
		one, pack := "1", l.Pack
		items = append(items,
			Block{"label": qty + " " + t(lang, "штук", "dona"), "action": Action{Type: "scan_line", ScanID: sc.ID, Line: l.Line, Pack: &one, Label: qty + " " + t(lang, "штук", "dona")}},
			Block{"label": fmt.Sprintf(t(lang, "%s блоков по %s", "%s blok, har biri %s"), qty, trimQty(l.Pack)), "primary": true,
				"action": Action{Type: "scan_line", ScanID: sc.ID, Line: l.Line, Pack: &pack, Label: fmt.Sprintf(t(lang, "%s блоков по %s", "%s blok, har biri %s"), qty, trimQty(l.Pack))}})
	case "check":
		if l.PriceChange != nil && l.LastPrice != nil {
			card["status"] = fmt.Sprintf(t(lang, "Цена %+d %% к прошлой (было %s)", "Narx oldingiga nisbatan %+d %% (edi %s)"), *l.PriceChange, money.Group(*l.LastPrice))
		} else {
			card["status"] = t(lang, "Проверьте товар", "Tovarni tekshiring")
		}
		card["status_kind"] = "warn"
		if l.ProductID != nil {
			pid := *l.ProductID
			items = append(items, Block{"label": t(lang, "Всё верно", "Hammasi toʻgʻri"), "primary": true,
				"action": Action{Type: "scan_line", ScanID: sc.ID, Line: l.Line, ProductID: &pid, Label: t(lang, "«"+l.Name+"» — всё верно", "«"+l.Name+"» — hammasi toʻgʻri")}})
		}
		items = append(items, Block{"label": t(lang, "Пропустить строку", "Qatorni oʻtkazib yuborish"),
			"action": Action{Type: "scan_line", ScanID: sc.ID, Line: l.Line, Skip: true, Label: t(lang, "Пропустить «"+l.Name+"»", "«"+l.Name+"» ni oʻtkazib yuborish")}})
	}
	card["buttons"] = items
	card["line"] = l.Line
	return card
}

func trimQty(q string) string {
	if i := strings.IndexByte(q, '.'); i >= 0 {
		q = strings.TrimRight(strings.TrimRight(q, "0"), ".")
	}
	return q
}

// ---------- фото товара ----------

// startProduct — владелец прислал фото товара, которого нет в базе: карточку
// заполняет Super Market (start/new-items), товар добавляется в «Мои
// товары», и агент продолжает то, что владелец просил (обычно — приход).
func (s *Service) startProduct(ctx context.Context, p *identity.Principal, in SendInput, lang string) (reply, error) {
	tok, err := s.ident.ServiceToken(p, tokenTTL)
	if err != nil {
		return reply{}, err
	}
	status, resp := s.loopback(ctx, tok, lang, http.MethodPost, "/store/start/new-items", nil,
		map[string]any{"store_id": in.StoreID, "images": in.Images})
	item, _ := resp.(map[string]any)
	if status/100 != 2 {
		return reply{}, apiErr(status, item, lang)
	}
	id, _ := item["id"].(string)
	deadline := s.now().Add(3 * time.Minute)
	for item["status"] == "processing" && s.now().Before(deadline) {
		select {
		case <-ctx.Done():
			return reply{}, ctx.Err()
		case <-time.After(3 * time.Second):
		}
		status, resp = s.loopback(ctx, tok, lang, http.MethodGet, "/store/start/new-items/"+id, nil, nil)
		item, _ = resp.(map[string]any)
	}
	again := Block{"type": "buttons", "items": []Block{
		{"label": t(lang, "Сфотографировать ещё раз", "Yana suratga olish"), "attach": "product", "primary": true},
		{"label": t(lang, "Заполнить вручную", "Qoʻlda toʻldirish"), "send": t(lang, "Заполню карточку вручную", "Kartochkani qoʻlda toʻldiraman")}}}
	link := Block{"type": "link", "label": t(lang, "Открыть «Начало работы»", "«Ishni boshlash»ni ochish"), "href": "/start"}
	switch item["status"] {
	case "processing":
		return reply{text: t(lang, "Super Market ещё заполняет карточку — это бывает долго. Напишите мне через минуту «готово?».",
			"Super Market hali kartochkani toʻldiryapti — bu uzoq boʻlishi mumkin. Bir daqiqadan keyin «tayyormi?» deb yozing."), lang: lang, blocks: []Block{link}}, nil
	case "failed":
		msg, _ := item["error"].(string)
		return reply{text: t(lang, "Не смог распознать товар по фото: ", "Rasmdan tovarni taniy olmadim: ") + msg, lang: lang, blocks: []Block{again, link}}, nil
	}
	res, _ := item["result"].(map[string]any)
	body := map[string]any{"store_id": in.StoreID}
	name, _ := res["name"].(string)
	if m, ok := res["match"].(map[string]any); ok && m != nil {
		body["product_id"] = m["product_id"]
		if n, _ := m["name"].(string); n != "" {
			name = n
		}
	} else {
		for _, k := range []string{"name", "name_uz", "description", "unit_id"} {
			if v, _ := res[k].(string); v != "" {
				body[k] = v
			}
		}
		if v, _ := res["brand_id"].(string); v != "" {
			body["brand_id"] = v
		} else if v, _ := res["brand"].(string); v != "" {
			body["brand_name"] = v
		}
		if sg, ok := res["suggestion"].(map[string]any); ok && sg != nil {
			if c, ok := sg["category"].(map[string]any); ok && c != nil {
				body["category_id"] = c["id"]
			} else if nc, ok := sg["new"].(map[string]any); ok && nc != nil {
				body["new_category"] = nc
			}
			if body["name_uz"] == nil {
				if v, _ := sg["name_uz"].(string); v != "" {
					body["name_uz"] = v
				}
			}
		}
		body["images"] = in.Images
	}
	status, resp = s.loopback(ctx, tok, lang, http.MethodPost, "/store/start/new-items/"+id+"/confirm", nil, body)
	out, _ := resp.(map[string]any)
	productID, _ := out["product_id"].(string)
	if status/100 != 2 {
		if e, ok := out["error"].(map[string]any); ok && e["code"] == "already_added" {
			if d, ok := e["details"].(map[string]any); ok {
				productID, _ = d["product_id"].(string)
			}
		}
		if productID == "" {
			// Не хватило категории или права — карточка ждёт в «Новых».
			return reply{text: t(lang, "Super Market заполнил карточку «"+name+"», но добавить сам не смог: ", "Super Market «"+name+"» kartochkasini toʻldirdi, lekin oʻzi qoʻsha olmadi: ") +
				apiErr(status, out, lang).Error() + t(lang, " Проверьте её во вкладке «Новые» в «Начале работы».", " Uni «Ishni boshlash»dagi «Yangilar» boʻlimida tekshiring."),
				lang: lang, blocks: []Block{link}}, nil
		}
	}
	s.journalText(ctx, p, in.StoreID, lang, t(lang, "Новый товар «"+name+"» — карточку заполнил Super Market, добавлен в «Мои товары»",
		"Yangi tovar «"+name+"» — kartochkani Super Market toʻldirdi, «Mening tovarlarim»ga qoʻshildi"))
	where := "товар добавлен в «Мои товары»"
	if d, _ := out["direct"].(bool); !d && status/100 == 2 {
		where = "магазин ещё в «Начале работы», товар встал в его черновик (в товары магазина попадёт после «Записать и закрыть», ссылка /start) — приход документом до этого может не пройти"
	}
	note := fmt.Sprintf("[Владелец прислал фото товара. Super Market заполнил карточку: «%s» (product_id %s), %s. Посмотри recent_messages: если владелец до этого просил приход этого товара — сделай его по правилу 8 (количество из его слов, цену закупки и поставщика спроси, если не назывались); если ничего не просил — скажи, что товар добавлен, и спроси цену продажи.]", name, productID, where)
	return s.agent(ctx, p, SendInput{StoreID: in.StoreID}, Message{}, nil, note)
}

// apiErr — ошибка ответа API понятными словами.
func apiErr(status int, body map[string]any, lang string) error {
	msg := ""
	if e, ok := body["error"].(map[string]any); ok {
		msg, _ = e["message"].(string)
	}
	if msg == "" {
		msg = fmt.Sprintf("HTTP %d", status)
	}
	return apperr.New(status, "assistant_api", msg).Uz(msg)
}

func (s *Service) journalText(ctx context.Context, p *identity.Principal, storeID, lang, text string) {
	_, _ = s.insert(ctx, p, storeID, newMsg{Role: RoleSystem, Kind: "done", Text: text, Lang: lang})
}

// docExpect — слепок документа для проверки перед проведением: итого и число строк.
func docExpect(doc map[string]any) string {
	if doc == nil {
		return ""
	}
	total, _ := doc["total"].(string)
	n, _ := doc["items_count"].(float64)
	if items, ok := doc["items"].([]any); ok {
		n = float64(len(items))
	}
	return fmt.Sprintf("%s|%d", total, int(n))
}
