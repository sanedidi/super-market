package assistant

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/sanedidi/super-market/backend/internal/ai"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/invoices"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
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

// modelOut — ответ модели (см. systemPrompt).
type modelOut struct {
	Transcript string         `json:"transcript"`
	Lang       string         `json:"lang"`
	Intent     string         `json:"intent"`
	Args       map[string]any `json:"args"`
	Reply      string         `json:"reply"`
	Buttons    []struct {
		Label string `json:"label"`
		Send  string `json:"send"`
	} `json:"buttons"`
}

func t(lang, ru, uz string) string { return i18n.Pick(lang, ru, uz) }

// handle — ответ на сообщение владельца.
func (s *Service) handle(ctx context.Context, p *identity.Principal, in SendInput, owner Message) (reply, error) {
	lang := i18n.FromContext(ctx)
	switch {
	case in.Action != nil:
		return s.doAction(ctx, p, in.StoreID, lang, *in.Action)
	case len(in.Images) > 0:
		// Фото накладной — это всегда приход: модель не нужна.
		return s.startScan(ctx, p, in.StoreID, lang, in.Images)
	}
	sc := s.currentScan(ctx, p, in.StoreID)
	prompt, err := s.buildPrompt(ctx, p, in.StoreID, lang, in.Text, sc)
	if err != nil {
		return reply{}, err
	}
	out, err := s.ask(ctx, p, in, prompt)
	if err != nil {
		return reply{}, err
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
	r := reply{text: strings.TrimSpace(out.Reply), lang: lang, intent: out.Intent, args: out.Args}
	if sc != nil {
		r.scanID = &sc.ID
	}
	for i, b := range out.Buttons {
		if i >= 4 || strings.TrimSpace(b.Label) == "" {
			break
		}
		r.blocks = appendButton(r.blocks, Block{"label": b.Label, "send": firstNonEmpty(b.Send, b.Label)})
	}
	switch out.Intent {
	case "income":
		r.blocks = []Block{{"type": "buttons", "items": []Block{
			{"label": t(lang, "Прикрепить накладную", "Nakladnoyni biriktirish"), "attach": true, "primary": true},
			{"label": t(lang, "Напишу списком", "Roʻyxat bilan yozaman"), "send": t(lang, "Напишу товары списком", "Tovarlarni roʻyxat bilan yozaman")},
		}}}
		if r.text == "" {
			r.text = t(lang, "Отлично. Прикрепите фото накладной — или перечислите товары, что пришло и по сколько.",
				"Yaxshi. Nakladnoy rasmini biriktiring — yoki qaysi tovar qancha kelganini yozing.")
		}
	case "stock":
		return s.stock(ctx, p, in.StoreID, r, argStr(out.Args, "query"))
	case "reorder":
		return s.reorder(ctx, p, in.StoreID, r)
	case "sales":
		return s.sales(ctx, p, in.StoreID, r, argStr(out.Args, "date"))
	case "scan_supplier", "scan_line", "scan_post":
		if sc == nil {
			r.text = t(lang, "Сейчас нет накладной в работе. Прикрепите фото накладной — и продолжим.",
				"Hozir ishlanayotgan nakladnoy yoʻq. Nakladnoy rasmini biriktiring — davom etamiz.")
			r.blocks = []Block{{"type": "buttons", "items": []Block{{"label": t(lang, "Прикрепить накладную", "Nakladnoyni biriktirish"), "attach": true, "primary": true}}}}
			return r, nil
		}
		return s.scanIntent(ctx, p, in.StoreID, r, sc, out)
	}
	if r.text == "" {
		r.text = t(lang, "Не понял. Скажите, что нужно: приход, остатки, что заказать или продажи за день.",
			"Tushunmadim. Nima kerakligini ayting: kirim, qoldiqlar, nima buyurtma qilish yoki kunlik sotuvlar.")
	}
	return r, nil
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

// ask — вопрос модели: контекст + текст или аудио; расход — в ai_usage.
func (s *Service) ask(ctx context.Context, p *identity.Principal, in SendInput, prompt string) (modelOut, error) {
	conn, err := s.ai.Conn(ctx)
	if err != nil {
		return modelOut{}, err
	}
	var parts []ai.Part
	if in.Audio != nil {
		if !conn.IsGoogle() {
			return modelOut{}, apperr.Conflict("audio_unsupported",
				"голосовые понимает только Gemini — супер-админ выбирает Vertex AI в «ИИ-сервисе». Пока напишите текстом.").
				Uz("ovozli xabarlarni faqat Gemini tushunadi — super-admin «SI xizmati»da Vertex AI ni tanlaydi. Hozircha matn bilan yozing.")
		}
		parts = append(parts, *in.Audio)
	}
	started := s.now()
	raw, usage, err := conn.Generate(ctx, systemPrompt, prompt, parts)
	net, store, emp := p.NetworkID, in.StoreID, p.EmployeeID
	_ = s.ai.Record(ctx, ai.UsageRecord{Kind: "assistant", NetworkID: &net, StoreID: &store, EmployeeID: &emp,
		Provider: conn.Provider, Model: conn.Model, Usage: usage, OK: err == nil})
	if err != nil {
		return modelOut{}, err
	}
	s.log.Info("assistant: model", "ms", s.now().Sub(started).Milliseconds(), "in", usage.Input, "out", usage.Output)
	js, err := ai.ExtractJSON(raw)
	if err != nil {
		return modelOut{}, &ai.ErrService{Msg: "модель ответила не по форме", MsgUz: "model shaklga mos javob bermadi"}
	}
	var out modelOut
	if err := json.Unmarshal(js, &out); err != nil {
		return modelOut{}, &ai.ErrService{Msg: "модель ответила не по форме", MsgUz: "model shaklga mos javob bermadi"}
	}
	return out, nil
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

// scanIntent — владелец ответил по накладной текстом: поставщик, строка, «провести».
func (s *Service) scanIntent(ctx context.Context, p *identity.Principal, storeID string, r reply, sc *invoices.Scan, out modelOut) (reply, error) {
	lang := r.lang
	switch out.Intent {
	case "scan_supplier":
		name := argStr(out.Args, "name")
		id := s.findCounterparty(ctx, p.NetworkID, name)
		var err error
		var next invoices.Scan
		if id != nil {
			next, err = s.scans.SetSupplier(ctx, p, sc.ID, invoices.SupplierInput{CounterpartyID: id})
		} else if sc.SupplierName != "" && name != "" && strings.Contains(strings.ToLower(sc.SupplierName), strings.ToLower(name)) {
			next, err = s.scans.SetSupplier(ctx, p, sc.ID, invoices.SupplierInput{Create: true})
		} else {
			return s.renderScan(ctx, p, lang, *sc, t(lang, "Такого поставщика не нашёл — выберите из списка или заведите нового.",
				"Bunday yetkazib beruvchini topmadim — roʻyxatdan tanlang yoki yangisini kiriting."))
		}
		if err != nil {
			return reply{}, err
		}
		return s.renderScan(ctx, p, lang, next, r.text)
	case "scan_line":
		line := argInt(out.Args, "line")
		var l *invoices.Line
		for i := range sc.Lines {
			if sc.Lines[i].Line == line {
				l = &sc.Lines[i]
			}
		}
		if l == nil {
			return s.renderScan(ctx, p, lang, *sc, t(lang, "Не понял, про какую строку речь — нажмите кнопку у нужной строки.",
				"Qaysi qator haqida ekanini tushunmadim — kerakli qator tugmasini bosing."))
		}
		in := invoices.LineInput{Remember: sc.CounterpartyID != nil}
		if argBool(out.Args, "skip") {
			skip := true
			in.Skip = &skip
			in.Remember = false
		}
		if pack := argStr(out.Args, "pack"); pack != "" {
			q := money.Qty(pack)
			in.Pack = &q
		}
		if q := argStr(out.Args, "product_query"); q != "" && l.State == "missing" {
			sug, err := s.scans.Suggest(ctx, p, sc.ID, line, q)
			if err != nil {
				return reply{}, err
			}
			if len(sug) == 0 || (len(sug) > 1 && sug[0].Score < 90) {
				return s.renderScan(ctx, p, lang, *sc, t(lang, "Нашёл несколько похожих — выберите кнопкой у строки.",
					"Bir nechta oʻxshashini topdim — qator tugmasidan tanlang."))
			}
			in.ProductID = &sug[0].ProductID
		}
		if in.Pack == nil && in.Skip == nil && in.ProductID == nil {
			return s.renderScan(ctx, p, lang, *sc, r.text)
		}
		next, err := s.scans.SetLine(ctx, p, sc.ID, line, in)
		if err != nil {
			return reply{}, err
		}
		return s.renderScan(ctx, p, lang, next, r.text)
	default: // scan_post — только кнопкой.
		return s.renderScan(ctx, p, lang, *sc, t(lang, "Провести приход можно только кнопкой ниже — чтобы ничего не записалось случайно.",
			"Kirimni faqat pastdagi tugma bilan oʻtkazish mumkin — tasodifan yozilib qolmasligi uchun."))
	}
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
	}
	return reply{}, apperr.Validation("action.type: scan_line, scan_supplier или scan_post").Uz("action.type: scan_line, scan_supplier yoki scan_post")
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

// ---------- остатки, что заказать, продажи ----------

func (s *Service) stock(ctx context.Context, p *identity.Principal, storeID string, r reply, query string) (reply, error) {
	lang := r.lang
	f := inventory.MyProductsFilter{StoreID: storeID, Query: query, Page: httpx.Page{Limit: 8}}
	res, err := s.inv.MyProducts(ctx, p, f)
	if err != nil {
		return reply{}, err
	}
	if len(res.Items) == 0 {
		if query == "" {
			r.text = t(lang, "В магазине пока нет товаров с остатками.", "Doʻkonda hali qoldiqli tovarlar yoʻq.")
		} else {
			r.text = fmt.Sprintf(t(lang, "По «%s» ничего не нашёл. Попробуйте другое слово или откройте остатки.", "«%s» boʻyicha hech narsa topmadim. Boshqa soʻz bilan urinib koʻring yoki qoldiqlarni oching."), query)
			r.blocks = []Block{{"type": "link", "label": t(lang, "Остатки", "Qoldiqlar"), "href": "/stock/balance"}}
		}
		return r, nil
	}
	if r.text == "" {
		if query == "" {
			r.text = t(lang, "Вот что требует внимания:", "Eʼtibor talab qiladiganlar:")
		} else {
			r.text = fmt.Sprintf(t(lang, "По «%s» нашёл %d:", "«%s» boʻyicha %d ta topdim:"), query, res.Total)
		}
	}
	rows := [][]string{}
	for _, it := range res.Items {
		rows = append(rows, []string{it.Name, qtyText(it, lang), perDay(it), daysText(it, lang)})
	}
	r.blocks = append(r.blocks, Block{"type": "table", "columns": []string{t(lang, "Товар", "Tovar"), t(lang, "Остаток", "Qoldiq"), t(lang, "В день", "Kuniga"), t(lang, "Хватит", "Yetadi")}, "rows": rows})
	if res.Total > len(res.Items) {
		r.blocks = append(r.blocks, Block{"type": "link", "label": fmt.Sprintf(t(lang, "Все %d в «Остатках»", "Barchasi (%d) «Qoldiqlar»da"), res.Total), "href": "/stock/balance"})
	}
	r.blocks = append(r.blocks, Block{"type": "buttons", "items": []Block{{"label": t(lang, "Что заказать?", "Nima buyurtma qilish?"), "send": t(lang, "Что заказать?", "Nima buyurtma qilish kerak?")}}})
	return r, nil
}

func qtyText(it inventory.MyProduct, lang string) string {
	if it.Uncounted {
		return t(lang, "не посчитан", "sanalmagan")
	}
	return trimQty(it.Qty) + " " + it.UnitShort
}

func perDay(it inventory.MyProduct) string {
	v, _ := strconv.ParseFloat(it.PerDay, 64)
	if v <= 0 {
		return "—"
	}
	return "~" + trimQty(it.PerDay)
}

func daysText(it inventory.MyProduct, lang string) string {
	q, _ := strconv.ParseFloat(it.Qty, 64)
	switch {
	case it.Uncounted:
		return "—"
	case q <= 0:
		return t(lang, "нет", "yoʻq")
	case it.DaysLeft == nil:
		return "—"
	case *it.DaysLeft == 0:
		return t(lang, "< 1 дня", "< 1 kun")
	}
	return fmt.Sprintf(t(lang, "%d дн.", "%d kun"), *it.DaysLeft)
}

// reorder — что заканчивается (out, low) и сколько заказать: на неделю по
// скорости продаж, минус остаток.
func (s *Service) reorder(ctx context.Context, p *identity.Principal, storeID string, r reply) (reply, error) {
	lang := r.lang
	items := []inventory.MyProduct{}
	for _, st := range []string{inventory.MyStatusOut, inventory.MyStatusLow} {
		res, err := s.inv.MyProducts(ctx, p, inventory.MyProductsFilter{StoreID: storeID, Status: st, Page: httpx.Page{Limit: 10}})
		if err != nil {
			return reply{}, err
		}
		items = append(items, res.Items...)
	}
	if len(items) == 0 {
		r.text = t(lang, "Пока ничего не заканчивается — остатков хватает.", "Hozircha hech narsa tugamayapti — qoldiqlar yetarli.")
		return r, nil
	}
	if r.text == "" {
		r.text = fmt.Sprintf(t(lang, "Заканчиваются %d товаров. Заказать на неделю:", "%d ta tovar tugayapti. Bir haftaga buyurtma:"), len(items))
	}
	rows := [][]string{}
	for _, it := range items {
		per, _ := strconv.ParseFloat(it.PerDay, 64)
		q, _ := strconv.ParseFloat(it.Qty, 64)
		order := math.Ceil(per*7 - math.Max(q, 0))
		orderText := "—"
		if order > 0 {
			orderText = strconv.Itoa(int(order)) + " " + it.UnitShort
		}
		rows = append(rows, []string{it.Name, qtyText(it, lang), daysText(it, lang), orderText})
	}
	r.blocks = append(r.blocks, Block{"type": "table", "columns": []string{t(lang, "Товар", "Tovar"), t(lang, "Остаток", "Qoldiq"), t(lang, "Хватит", "Yetadi"), t(lang, "Заказать", "Buyurtma")}, "rows": rows})
	r.blocks = append(r.blocks, Block{"type": "link", "label": t(lang, "Все остатки", "Barcha qoldiqlar"), "href": "/stock/balance?status=low"})
	return r, nil
}

// sales — продажи за день (сегодня или дата).
func (s *Service) sales(ctx context.Context, p *identity.Principal, storeID string, r reply, date string) (reply, error) {
	lang := r.lang
	if date != "" {
		if _, err := time.Parse("2006-01-02", date); err != nil {
			date = ""
		}
	}
	sum, err := s.summary.Day(ctx, p, date, storeID)
	if err != nil {
		return reply{}, err
	}
	day := t(lang, "сегодня", "bugun")
	if date != "" && date != s.now().In(tashkent).Format("2006-01-02") {
		day = t(lang, "за ", "") + date
	}
	txt := fmt.Sprintf(t(lang, "Продажи %s: %s сум, %d чеков, средний чек %s сум.", "Sotuvlar (%s): %s soʻm, %d chek, oʻrtacha chek %s soʻm."),
		day, money.Group(sum.Revenue), sum.SalesCount, money.Group(sum.AvgCheck))
	if sum.ChangePct != nil {
		txt += " " + fmt.Sprintf(t(lang, "Это %+d %% к прошлому дню.", "Bu oldingi kunga nisbatan %+d %%."), *sum.ChangePct)
	}
	if sum.OrdersCount > 0 {
		txt += " " + fmt.Sprintf(t(lang, "Онлайн-заказов: %d на %s сум.", "Onlayn buyurtmalar: %d, %s soʻm."), sum.OrdersCount, money.Group(sum.OrdersTotal))
	}
	if r.text != "" {
		txt = r.text + "\n" + txt
	}
	r.text = txt
	r.blocks = []Block{{"type": "link", "label": t(lang, "Подробнее на главной", "Batafsil bosh sahifada"), "href": "/"}}
	return r, nil
}
