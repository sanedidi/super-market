package assistant

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/invoices"
)

// systemPrompt — кто такой помощник и в каком виде отвечать. Намерения
// (intent) исполняет сервер (process.go); модель только понимает владельца,
// пишет короткий ответ и кнопки.
const systemPrompt = `Ты — помощник Super Market: сервис учёта для небольших магазинов в Узбекистане. Ты общаешься с владельцем магазина в чате панели. Говори просто и коротко, как живой помощник, без слов «ИИ», «бот», «нейросеть», «модель». Себя называй «Super Market» или «я».

Языки: владелец пишет или говорит по-русски, по-узбекски (латиница или кириллица) или вперемешку («kola 12 blok keldi, цена 9 ming»). Отвечай на языке последнего сообщения владельца: узбекский — латиницей. Названия товаров и поставщиков не переводи. Числа словами («yigirma», «двадцать», «12 ta», «9 ming») переводи в цифры (20, 20, 12, 9000).

Если сообщение — аудио, сначала расшифруй его как есть (поле transcript), затем пойми.

Ты умеешь (intent):
- "income"   — владелец хочет внести приход («пришли товары», «tovar keldi»). Попроси прикрепить фото накладной (кнопка прикрепления добавится сама) или перечислить товары.
- "scan_supplier" — назвал поставщика накладной, над которой идёт работа. args: {"name": "..."}.
- "scan_line" — отвечает по строке накладной: args: {"line": N, "pack": 6, "product_query": "...", "skip": true}. pack — сколько штук в одной единице накладной (ответил «штуки» → 1, «блоки по 6» → 6). Строку определяй по номеру или по названию из контекста current_scan. Если неясно, какая строка, — intent "chat" и уточни.
- "scan_post" — просит провести приход. Сам приход НЕ проводи: ответь, что провести можно кнопкой ниже (сервер покажет кнопку).
- "stock"    — сколько товара осталось. args: {"query": "кола"} (слово для поиска по названию; пусто — всё, что заканчивается).
- "reorder"  — что заказать / что заканчивается.
- "sales"    — продажи, выручка, чеки за день. args: {"date": "YYYY-MM-DD"} (пусто — сегодня; «вчера» — вчерашняя дата по полю today).
- "chat"     — всё остальное: приветствие, вопрос, уточнение, благодарность. Про долги покупателей, цены и прочее, чего нет в списке, честно скажи, что пока это делается в панели, и предложи, что умеешь.

Отвечай ТОЛЬКО JSON без пояснений:
{"transcript": "расшифровка аудио или пусто", "lang": "ru|uz", "intent": "...", "args": {...}, "reply": "короткий ответ владельцу (1–3 предложения)", "buttons": [{"label": "текст кнопки", "send": "что отправится как сообщение владельца"}]}
Кнопки — только когда уместно предложить следующий шаг (до 4 штук). Для stock, reorder, sales в reply напиши одну вводную фразу: цифры и таблицу добавит сервер. Никогда не выдумывай остатки, суммы и товары — их даёт сервер.`

// promptContext — что модель должна знать о магазине и разговоре.
type promptContext struct {
	Today     string            `json:"today"`
	Store     string            `json:"store"`
	Lang      string            `json:"ui_lang"`
	Suppliers []string          `json:"suppliers"`
	Scan      *scanContext      `json:"current_scan,omitempty"`
	Recent    []recentMessage   `json:"recent_messages"`
	Message   string            `json:"owner_message,omitempty"`
	Hints     map[string]string `json:"hints,omitempty"`
}

type scanContext struct {
	ID       string            `json:"id"`
	Supplier string            `json:"supplier"`
	Number   string            `json:"number"`
	Total    string            `json:"total"`
	Lines    int               `json:"lines"`
	Open     []scanLineContext `json:"lines_need_answer"`
}

type scanLineContext struct {
	Line  int    `json:"line"`
	Name  string `json:"name"`
	Qty   string `json:"qty"`
	Unit  string `json:"unit"`
	State string `json:"state"` // missing — товар не найден; pack — блоки или штуки?; check — проверить цену
	Pack  string `json:"pack_guess,omitempty"`
}

type recentMessage struct {
	Role string `json:"role"`
	Text string `json:"text"`
}

// buildPrompt — контекст для модели: магазин, поставщики, текущая накладная,
// последние реплики и само сообщение.
func (s *Service) buildPrompt(ctx context.Context, p *identity.Principal, storeID, lang, text string, sc *invoices.Scan) (string, error) {
	pc := promptContext{Today: s.now().In(tashkent).Format("2006-01-02"), Lang: lang, Suppliers: []string{}, Recent: []recentMessage{}, Message: text}
	_ = s.pool.QueryRow(ctx, `SELECT name FROM stores WHERE id = $1`, storeID).Scan(&pc.Store)
	rows, err := s.pool.Query(ctx, `SELECT name FROM counterparties WHERE network_id = $1 AND is_active ORDER BY name LIMIT 30`, p.NetworkID)
	if err != nil {
		return "", err
	}
	for rows.Next() {
		var n string
		if rows.Scan(&n) == nil {
			pc.Suppliers = append(pc.Suppliers, n)
		}
	}
	rows.Close()
	rows, err = s.pool.Query(ctx, `
		SELECT role, CASE WHEN role = 'owner' AND transcript IS NOT NULL THEN transcript ELSE text END
		FROM assistant_messages WHERE store_id = $1 AND employee_id = $2 AND status = 'done' AND role <> 'system' AND text <> ''
		ORDER BY created_at DESC LIMIT 10`, storeID, p.EmployeeID)
	if err != nil {
		return "", err
	}
	for rows.Next() {
		var m recentMessage
		if rows.Scan(&m.Role, &m.Text) == nil {
			if r := []rune(m.Text); len(r) > 300 {
				m.Text = string(r[:300]) + "…"
			}
			pc.Recent = append([]recentMessage{m}, pc.Recent...)
		}
	}
	rows.Close()
	if sc != nil && sc.Status == invoices.StatusReady {
		c := &scanContext{ID: sc.ID, Supplier: sc.SupplierName, Number: sc.InvoiceNumber, Total: sc.LinesTotal, Lines: len(sc.Lines), Open: []scanLineContext{}}
		if sc.CounterpartyName != nil {
			c.Supplier = *sc.CounterpartyName
		}
		for _, l := range sc.Lines {
			if l.State == "missing" || l.State == "pack" || l.State == "check" {
				lc := scanLineContext{Line: l.Line, Name: l.Name, Qty: l.Qty, Unit: l.Unit, State: l.State}
				if l.State == "pack" {
					lc.Pack = l.Pack
				}
				c.Open = append(c.Open, lc)
			}
		}
		pc.Scan = c
	}
	b, err := json.Marshal(pc)
	if err != nil {
		return "", err
	}
	var sb strings.Builder
	sb.WriteString("Контекст (JSON):\n")
	sb.Write(b)
	if text == "" {
		sb.WriteString("\n\nСообщение владельца — во вложенном аудио.")
	} else {
		sb.WriteString(fmt.Sprintf("\n\nСообщение владельца: %q", text))
	}
	return sb.String(), nil
}

var tashkent = time.FixedZone("Asia/Tashkent", 5*60*60)
