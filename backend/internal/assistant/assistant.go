// Package assistant — помощник в панели магазина (тест; Figma «Super Market ·
// Помощник», страница «Веб-панель · тест», П1–П3 и «Логика»).
//
// Владелец пишет, говорит голосом или прикрепляет фото накладной. Помощник
// отвечает коротко и даёт кнопки; всё, что он делает, идёт через те же
// сервисы, что и панель: накладная — invoices (распознавание, строки, приход),
// остатки и «что заказать» — inventory.MyProducts, продажи — summary.Day.
// Необратимое («Провести приход») — только кнопкой: текстовое «да» помощник
// не считает подтверждением.
//
// Модель (ИИ-сервис супер-админа) получает инструкцию, контекст магазина и
// сообщение (текст или аудио) и отвечает JSON: расшифровка, язык, намерение,
// аргументы, ответ и кнопки. Голосовые понимает только Gemini (Vertex AI).
package assistant

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/ai"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/invoices"
	"github.com/sanedidi/super-market/backend/internal/media"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/summary"
)

const (
	RoleOwner     = "owner"
	RoleAssistant = "assistant"
	RoleSystem    = "system"

	StatusPending = "pending"
	StatusDone    = "done"
	StatusFailed  = "failed"

	// Голосовое — не длиннее минуты и 8 МБ (webm/opus ≈ 100 КБ на 10 с).
	MaxAudio = 8 << 20
)

type Service struct {
	pool    *pgxpool.Pool
	ai      *ai.Service
	media   *media.Service
	scans   *invoices.Service
	inv     *inventory.Service
	summary *summary.Service
	log     *slog.Logger
	// run — как выполнять ответ: фоном (сервер) или сразу (тесты).
	run func(func())
	now func() time.Time
	// scanWait — сколько ждать распознавание накладной в одном ответе.
	scanWait time.Duration
}

func NewService(pool *pgxpool.Pool, aiSvc *ai.Service, mediaSvc *media.Service, scans *invoices.Service,
	inv *inventory.Service, sum *summary.Service, log *slog.Logger) *Service {
	return &Service{pool: pool, ai: aiSvc, media: mediaSvc, scans: scans, inv: inv, summary: sum, log: log,
		run: func(f func()) { go f() }, now: time.Now, scanWait: 90 * time.Second}
}

// Sync — отвечать прямо в запросе (тесты).
func (s *Service) Sync() { s.run = func(f func()) { f() }; s.scanWait = 2 * time.Second }

// Block — что показать в сообщении кроме текста (панель рисует по type):
//
//	buttons  — items: [{label, send | action | attach, primary}]
//	card     — title, sum, note, status, status_kind (warn | error | ok), buttons
//	table    — columns: [..], rows: [[..]]
//	link     — label, href (внутри панели)
//	confirm  — label, action, enabled, hint (необратимое действие — только кнопкой)
type Block map[string]any

// Action — нажатая кнопка: что сделать без модели.
type Action struct {
	// scan_line — строка накладной: товар, упаковка или пропустить;
	// scan_supplier — поставщик накладной; scan_post — провести приход.
	Type   string `json:"type"`
	ScanID string `json:"scan_id"`
	Line   int    `json:"line,omitempty"`
	// Pack — единиц товара в единице накладной («12 блоков по 6» → 6).
	Pack           *string `json:"pack,omitempty"`
	ProductID      *string `json:"product_id,omitempty"`
	Skip           bool    `json:"skip,omitempty"`
	CounterpartyID *string `json:"counterparty_id,omitempty"`
	Create         bool    `json:"create,omitempty"`
	// Label — текст кнопки: так сообщение владельца выглядит в чате.
	Label string `json:"label,omitempty"`
}

type Message struct {
	ID   string `json:"id"`
	Role string `json:"role"`
	// text, audio, image, action — от владельца; text, error — помощник;
	// done — строка «сделано» (журнал действий).
	Kind       string    `json:"kind"`
	Text       string    `json:"text"`
	Transcript *string   `json:"transcript"`
	Lang       string    `json:"lang"`
	Images     []string  `json:"images"`
	Blocks     []Block   `json:"blocks"`
	Status     string    `json:"status"`
	ScanID     *string   `json:"scan_id"`
	CreatedAt  time.Time `json:"created_at"`
}

type SendInput struct {
	StoreID string   `json:"store_id"`
	Text    string   `json:"text"`
	Images  []string `json:"images"`
	Action  *Action  `json:"action"`
	// Audio — голосовое (multipart, поле audio); не из JSON.
	Audio *ai.Part `json:"-"`
}

// SendResult — сообщение владельца и ответ помощника (сначала pending —
// панель опрашивает список, пока он не станет done).
type SendResult struct {
	Owner Message `json:"owner"`
	Reply Message `json:"reply"`
}

type Messages struct {
	Items []Message `json:"items"`
	// Pending — помощник ещё отвечает: панель опрашивает дальше.
	Pending bool `json:"pending"`
}

// Journal — что помощник сделал сегодня (строки «сделано»).
type Journal struct {
	Items []Message `json:"items"`
}

func (s *Service) access(p *identity.Principal, storeID string) error {
	if !p.IsOwner {
		return apperr.Forbidden("помощник пока доступен только владельцу сети").Uz("yordamchi hozircha faqat tarmoq egasiga ochiq")
	}
	if !httpx.IsUUID(storeID) || !p.CanAccessStore(storeID) {
		return apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	return nil
}

const msgCols = `id, role, kind, text, transcript, lang, images, blocks, status, scan_id, created_at`

func scanMsg(row pgx.Row) (Message, error) {
	var m Message
	var blocks []byte
	if err := row.Scan(&m.ID, &m.Role, &m.Kind, &m.Text, &m.Transcript, &m.Lang, &m.Images, &blocks, &m.Status, &m.ScanID, &m.CreatedAt); err != nil {
		return m, err
	}
	m.Blocks = []Block{}
	if len(blocks) > 0 {
		_ = json.Unmarshal(blocks, &m.Blocks)
	}
	if m.Images == nil {
		m.Images = []string{}
	}
	return m, nil
}

// List — сообщения чата владельца в магазине; after — только новее этого сообщения.
func (s *Service) List(ctx context.Context, p *identity.Principal, storeID, after string) (Messages, error) {
	out := Messages{Items: []Message{}}
	if err := s.access(p, storeID); err != nil {
		return out, err
	}
	if after != "" && !httpx.IsUUID(after) {
		after = ""
	}
	rows, err := s.pool.Query(ctx, `
		SELECT `+msgCols+` FROM assistant_messages
		WHERE store_id = $1 AND employee_id = $2
		  AND ($3 = '' OR created_at > (SELECT created_at FROM assistant_messages WHERE id = $3::uuid))
		ORDER BY created_at DESC LIMIT 200`, storeID, p.EmployeeID, after)
	if err != nil {
		return out, err
	}
	defer rows.Close()
	for rows.Next() {
		m, err := scanMsg(rows)
		if err != nil {
			return out, err
		}
		if m.Status == StatusPending {
			out.Pending = true
		}
		out.Items = append(out.Items, m)
	}
	// Старые сверху.
	for i, j := 0, len(out.Items)-1; i < j; i, j = i+1, j-1 {
		out.Items[i], out.Items[j] = out.Items[j], out.Items[i]
	}
	return out, rows.Err()
}

// Today — журнал: что помощник сделал сегодня.
func (s *Service) Today(ctx context.Context, p *identity.Principal, storeID string) (Journal, error) {
	out := Journal{Items: []Message{}}
	if err := s.access(p, storeID); err != nil {
		return out, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT `+msgCols+` FROM assistant_messages
		WHERE store_id = $1 AND role = 'system'
		  AND created_at >= date_trunc('day', now() AT TIME ZONE 'Asia/Tashkent') AT TIME ZONE 'Asia/Tashkent'
		ORDER BY created_at DESC LIMIT 50`, storeID)
	if err != nil {
		return out, err
	}
	defer rows.Close()
	for rows.Next() {
		m, err := scanMsg(rows)
		if err != nil {
			return out, err
		}
		out.Items = append(out.Items, m)
	}
	return out, rows.Err()
}

type newMsg struct {
	Role, Kind, Text, Lang string
	Images                 []string
	Blocks                 []Block
	Status                 string
	ScanID                 *string
	Intent                 string
	Args                   any
}

func (s *Service) insert(ctx context.Context, p *identity.Principal, storeID string, m newMsg) (Message, error) {
	if m.Images == nil {
		m.Images = []string{}
	}
	if m.Blocks == nil {
		m.Blocks = []Block{}
	}
	if m.Status == "" {
		m.Status = StatusDone
	}
	blocks, _ := json.Marshal(m.Blocks)
	args := []byte("{}")
	if m.Args != nil {
		args, _ = json.Marshal(m.Args)
	}
	row := s.pool.QueryRow(ctx, `
		INSERT INTO assistant_messages (network_id, store_id, employee_id, role, kind, text, lang, images, blocks, status, scan_id, intent, args)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
		RETURNING `+msgCols, p.NetworkID, storeID, p.EmployeeID, m.Role, m.Kind, m.Text, m.Lang, m.Images, blocks, m.Status, m.ScanID, m.Intent, args)
	return scanMsg(row)
}

// finish — ответ готов (или не получился).
func (s *Service) finish(ctx context.Context, id string, r reply, status string) error {
	blocks, _ := json.Marshal(r.blocks)
	args := []byte("{}")
	if r.args != nil {
		args, _ = json.Marshal(r.args)
	}
	if r.blocks == nil {
		blocks = []byte("[]")
	}
	// created_at — момент ответа: строки «сделано», добавленные по ходу,
	// встают в чате перед ответом.
	_, err := s.pool.Exec(ctx, `UPDATE assistant_messages SET text = $2, blocks = $3, status = $4, scan_id = $5, lang = $6, intent = $7, args = $8,
		created_at = now() WHERE id = $1`, id, r.text, blocks, status, r.scanID, r.lang, r.intent, args)
	return err
}

// Send — сообщение владельца: текст, голосовое, фото накладной или нажатая
// кнопка. Ответ помощника создаётся сразу (pending) и заполняется фоном.
func (s *Service) Send(ctx context.Context, p *identity.Principal, in SendInput) (SendResult, error) {
	if err := s.access(p, in.StoreID); err != nil {
		return SendResult{}, err
	}
	in.Text = strings.TrimSpace(in.Text)
	if len([]rune(in.Text)) > 2000 {
		return SendResult{}, apperr.Validation("text: не длиннее 2000 символов").Uz("text: 2000 belgidan oshmasin")
	}
	if len(in.Images) > 5 {
		return SendResult{}, apperr.Validation("images: не больше 5 фото").Uz("images: 5 tadan koʻp rasm boʻlmasin")
	}
	for _, u := range in.Images {
		if _, ok := media.KeyFromURL(u); !ok {
			return SendResult{}, apperr.Validation("images: фото должно быть загружено через /store/uploads").Uz("images: rasm /store/uploads orqali yuklangan boʻlishi kerak")
		}
	}
	if in.Audio != nil && len(in.Audio.Data) > MaxAudio {
		return SendResult{}, apperr.Validation("audio: голосовое не больше 8 МБ").Uz("audio: ovozli xabar 8 MB dan oshmasin")
	}
	if in.Text == "" && in.Audio == nil && len(in.Images) == 0 && in.Action == nil {
		return SendResult{}, apperr.Validation("text: напишите, скажите или прикрепите накладную").Uz("text: yozing, ayting yoki nakladnoyni biriktiring")
	}
	if in.Action != nil && !httpx.IsUUID(in.Action.ScanID) {
		return SendResult{}, apperr.Validation("action.scan_id: накладная не найдена").Uz("action.scan_id: nakladnoy topilmadi")
	}
	// Модель должна быть подключена до того, как сообщение попадёт в чат.
	if in.Action == nil {
		if _, err := s.ai.Conn(ctx); err != nil {
			return SendResult{}, err
		}
	}
	lang := i18n.FromContext(ctx)
	own := newMsg{Role: RoleOwner, Kind: "text", Text: in.Text, Lang: lang, Images: in.Images}
	switch {
	case in.Action != nil:
		own.Kind = "action"
		own.Text = in.Action.Label
		own.ScanID = &in.Action.ScanID
		own.Args = in.Action
	case in.Audio != nil:
		own.Kind = "audio"
	case len(in.Images) > 0:
		own.Kind = "image"
	}
	owner, err := s.insert(ctx, p, in.StoreID, own)
	if err != nil {
		return SendResult{}, err
	}
	rep, err := s.insert(ctx, p, in.StoreID, newMsg{Role: RoleAssistant, Kind: "text", Status: StatusPending, Lang: lang})
	if err != nil {
		return SendResult{}, err
	}
	pc := *p
	s.run(func() {
		bg := i18n.WithLang(context.WithoutCancel(ctx), lang)
		bg, cancel := context.WithTimeout(bg, 4*time.Minute)
		defer cancel()
		s.respond(bg, &pc, in, owner, rep.ID)
	})
	return SendResult{Owner: owner, Reply: rep}, nil
}

// respond — ответ помощника фоном: ошибки — в сообщение, не в лог.
func (s *Service) respond(ctx context.Context, p *identity.Principal, in SendInput, owner Message, replyID string) {
	r, err := s.handle(ctx, p, in, owner)
	status := StatusDone
	if err != nil {
		status = StatusFailed
		r.text = errText(err, i18n.FromContext(ctx))
		r.blocks = nil
		s.log.Warn("assistant", "err", err, "store", in.StoreID)
	}
	if r.lang == "" {
		r.lang = i18n.FromContext(ctx)
	}
	if err := s.finish(ctx, replyID, r, status); err != nil {
		s.log.Error("assistant: finish", "err", err)
	}
}

// errText — понятная причина для владельца.
func errText(err error, lang string) string {
	var ae *apperr.Error
	if errors.As(err, &ae) {
		return i18n.Pick(lang, "Не получилось: ", "Chiqmadi: ") + ae.Text(lang)
	}
	var se *ai.ErrService
	if errors.As(err, &se) {
		msg := se.Msg
		if lang == "uz" && se.MsgUz != "" {
			msg = se.MsgUz
		}
		return i18n.Pick(lang, "Сервис Super Market не ответил: ", "Super Market xizmati javob bermadi: ") + msg
	}
	return i18n.Pick(lang, "Что-то пошло не так, попробуйте ещё раз.", "Nimadir xato ketdi, yana urinib koʻring.")
}
