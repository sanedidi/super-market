package push

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/phone"
)

// Рассылки: супер-админ пишет push всем покупателям, по фильтру или одному.
// Рассылка ждёт своего времени (ночью — до 08:00), затем воркер кладёт по
// записи в очередь на каждого получателя и отправляет как обычные уведомления.

// Target — куда ведёт нажатие на уведомление.
type Target struct {
	// home, catalog, map, cart, orders, profile, family — разделы приложения;
	// store, category, product, deals — магазин и его товары; block — блок
	// главной; url — внешняя ссылка.
	Type       string `json:"type"`
	StoreID    string `json:"store_id,omitempty"` // UUID или "nearest" — ближайший к покупателю
	CategoryID string `json:"category_id,omitempty"`
	ProductID  string `json:"product_id,omitempty"`
	BlockID    string `json:"block_id,omitempty"`
	URL        string `json:"url,omitempty"`
}

// Audience — кому отправить.
type Audience struct {
	Type      string `json:"type"` // all | filter | one
	City      string `json:"city,omitempty"`
	Language  string `json:"language,omitempty"` // ru | uz
	NetworkID string `json:"network_id,omitempty"`
	StoreID   string `json:"store_id,omitempty"`
	// Orders: within — заказывали за Days дней, not_within — заказывали, но не
	// за последние Days дней, never — ни разу не заказывали.
	Orders string `json:"orders,omitempty"`
	Days   int    `json:"days,omitempty"`
	UserID string `json:"user_id,omitempty"`
}

type CampaignInput struct {
	Title    string   `json:"title"`
	Body     string   `json:"body"`
	Target   Target   `json:"target"`
	Audience Audience `json:"audience"`
	// SendAt — когда отправить; null — сейчас.
	SendAt *time.Time `json:"send_at"`
}

type Stats struct {
	Pending int `json:"pending"`
	Sent    int `json:"sent"`
	NoPush  int `json:"no_push"`
	Failed  int `json:"failed"`
}

type Campaign struct {
	ID            string     `json:"id"`
	Title         string     `json:"title"`
	Body          string     `json:"body"`
	Target        Target     `json:"target"`
	TargetTitle   string     `json:"target_title"`
	Audience      Audience   `json:"audience"`
	AudienceTitle string     `json:"audience_title"`
	SendAt        time.Time  `json:"send_at"`
	Status        string     `json:"status"`
	Recipients    int        `json:"recipients"`
	CreatedBy     string     `json:"created_by"`
	CreatedAt     time.Time  `json:"created_at"`
	StartedAt     *time.Time `json:"started_at"`
	FinishedAt    *time.Time `json:"finished_at"`
	CancelledAt   *time.Time `json:"cancelled_at"`
	Stats         Stats      `json:"stats"`
}

// Service — рассылки и тестовый push для супер-админа.
type Service struct {
	pool *pgxpool.Pool
	fcm  Sender // nil — push не настроен
	now  func() time.Time
}

func NewService(pool *pgxpool.Pool, fcm Sender) *Service {
	return &Service{pool: pool, fcm: fcm, now: time.Now}
}

// Tashkent — время рассылок и ночной паузы.
var Tashkent = time.FixedZone("Asia/Tashkent", 5*3600)

// QuietStart, QuietEnd — с 22:00 до 08:00 рассылки не отправляются.
const QuietStart, QuietEnd = 22, 8

// SkipNight переносит время из ночи (22:00–08:00 по Ташкенту) на 08:00.
func SkipNight(t time.Time) time.Time {
	l := t.In(Tashkent)
	morning := time.Date(l.Year(), l.Month(), l.Day(), QuietEnd, 0, 0, 0, Tashkent)
	switch {
	case l.Hour() < QuietEnd:
		return morning
	case l.Hour() >= QuietStart:
		return morning.AddDate(0, 0, 1)
	}
	return t
}

var sections = map[string]string{
	"home": "Главная", "catalog": "Каталог", "map": "Карта магазинов", "cart": "Корзина",
	"orders": "Мои заказы", "profile": "Профиль", "family": "Моя семья",
}

func uuidOrEmpty(field, v string) error {
	if v != "" && !httpx.IsUUID(v) {
		return apperr.Validation(field + ": неверный id")
	}
	return nil
}

// storeName — «Лимонария · ул. Навои, 15»; nearest — ближайший магазин.
func (s *Service) storeName(ctx context.Context, id string) (string, error) {
	if id == "nearest" {
		return "ближайший магазин", nil
	}
	if !httpx.IsUUID(id) {
		return "", apperr.Validation("target.store_id: выберите магазин")
	}
	var name, addr string
	err := s.pool.QueryRow(ctx, `SELECT name, address FROM stores WHERE id = $1 AND status = 'active'`, id).Scan(&name, &addr)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", apperr.Validation("target.store_id: магазин не найден или закрыт")
	}
	if addr != "" {
		name += " · " + addr
	}
	return name, err
}

func (s *Service) one(ctx context.Context, field, query, id string) (string, error) {
	if !httpx.IsUUID(id) {
		return "", apperr.Validation(field + ": не выбрано")
	}
	var name string
	err := s.pool.QueryRow(ctx, query, id).Scan(&name)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", apperr.Validation(field + ": не найдено")
	}
	return name, err
}

// BlockTitle — название блока главной для админки.
func BlockTitle(b map[string]any) string {
	t, _ := b["title"].(string)
	switch b["type"] {
	case "shelf":
		return "Полка «" + t + "»"
	case "banners":
		return "Баннеры"
	case "category_icons":
		return "Иконки разделов"
	case "promo":
		if t != "" {
			return "Промо-полоска «" + t + "»"
		}
		return "Промо-полоска"
	case "catalog_sections":
		return "Каталог по разделам"
	case "brand_shelf":
		return "Полка бренда"
	}
	if t != "" {
		return t
	}
	s, _ := b["type"].(string)
	return s
}

// Block — блок главной платформы, к которому может вести уведомление.
type Block struct {
	ID    string `json:"id"`
	Title string `json:"title"`
}

// Blocks — опубликованные блоки главной платформы.
func (s *Service) Blocks(ctx context.Context) ([]Block, error) {
	var raw []map[string]any
	err := s.pool.QueryRow(ctx, `SELECT blocks FROM home_layouts WHERE scope = 'platform'`).Scan(&raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return []Block{}, nil
	}
	if err != nil {
		return nil, err
	}
	out := []Block{}
	for _, b := range raw {
		id, _ := b["id"].(string)
		if id == "" || b["type"] == "order_status" || b["type"] == "header" {
			continue
		}
		out = append(out, Block{ID: id, Title: BlockTitle(b)})
	}
	return out, nil
}

// checkTarget проверяет переход и возвращает его описание: «Лимонария → Фрукты».
func (s *Service) checkTarget(ctx context.Context, t *Target) (string, error) {
	t.URL = strings.TrimSpace(t.URL)
	if t.Type == "" {
		t.Type = "home"
	}
	if name, ok := sections[t.Type]; ok {
		*t = Target{Type: t.Type}
		return name, nil
	}
	switch t.Type {
	case "store", "category", "product", "deals":
	case "block":
		blocks, err := s.Blocks(ctx)
		if err != nil {
			return "", err
		}
		for _, b := range blocks {
			if b.ID == t.BlockID {
				*t = Target{Type: "block", BlockID: b.ID}
				return "Главная → " + b.Title, nil
			}
		}
		return "", apperr.Validation("target.block_id: выберите блок главной")
	case "url":
		u, err := url.Parse(t.URL)
		if err != nil || u.Scheme != "https" || u.Host == "" || len(t.URL) > 500 {
			return "", apperr.Validation("target.url: нужна ссылка https://…")
		}
		*t = Target{Type: "url", URL: t.URL}
		return "Ссылка " + u.Host, nil
	default:
		return "", apperr.Validation("target.type: неизвестный переход")
	}
	// Магазин и его товары.
	if t.Type == "store" && t.StoreID == "nearest" {
		return "", apperr.Validation("target.store_id: выберите конкретный магазин")
	}
	store, err := s.storeName(ctx, t.StoreID)
	if err != nil {
		return "", err
	}
	short := strings.SplitN(store, " · ", 2)[0]
	switch t.Type {
	case "store":
		*t = Target{Type: "store", StoreID: t.StoreID}
		return store, nil
	case "deals":
		*t = Target{Type: "deals", StoreID: t.StoreID}
		return "Скидки: " + short, nil
	case "category":
		name, err := s.one(ctx, "target.category_id", `SELECT name FROM categories WHERE id = $1 AND is_active`, t.CategoryID)
		if err != nil {
			return "", err
		}
		*t = Target{Type: "category", StoreID: t.StoreID, CategoryID: t.CategoryID}
		return short + " → " + name, nil
	default: // product
		name, err := s.one(ctx, "target.product_id", `SELECT name FROM products WHERE id = $1 AND network_id IS NULL`, t.ProductID)
		if err != nil {
			return "", err
		}
		*t = Target{Type: "product", StoreID: t.StoreID, ProductID: t.ProductID}
		return short + " → " + name, nil
	}
}

// Data — data push-уведомления: приложение по ней открывает нужный экран.
func (t Target) Data() map[string]any {
	d := map[string]any{"type": "open", "target": t.Type}
	for k, v := range map[string]string{"store_id": t.StoreID, "category_id": t.CategoryID, "product_id": t.ProductID, "block_id": t.BlockID, "url": t.URL} {
		if v != "" {
			d[k] = v
		}
	}
	return d
}

var languages = map[string]string{"ru": "русский", "uz": "узбекский"}

// checkAudience проверяет аудиторию и возвращает её описание.
func (s *Service) checkAudience(ctx context.Context, a *Audience) (string, error) {
	a.City = strings.TrimSpace(a.City)
	switch a.Type {
	case "", "all":
		*a = Audience{Type: "all"}
		return "Все покупатели", nil
	case "one":
		name, err := s.one(ctx, "audience.user_id", `
			SELECT u.phone || CASE WHEN u.full_name <> '' THEN ' · ' || u.full_name ELSE '' END
			FROM users u JOIN customers c ON c.user_id = u.id WHERE u.id = $1 AND c.deleted_at IS NULL`, a.UserID)
		if err != nil {
			return "", err
		}
		*a = Audience{Type: "one", UserID: a.UserID}
		return "Один клиент · " + name, nil
	case "filter":
	default:
		return "", apperr.Validation("audience.type: all, filter или one")
	}
	parts := []string{}
	if a.City != "" {
		parts = append(parts, a.City)
	}
	if a.Language != "" {
		l, ok := languages[a.Language]
		if !ok {
			return "", apperr.Validation("audience.language: ru или uz")
		}
		parts = append(parts, l)
	}
	if err := uuidOrEmpty("audience.network_id", a.NetworkID); err != nil {
		return "", err
	}
	if err := uuidOrEmpty("audience.store_id", a.StoreID); err != nil {
		return "", err
	}
	switch {
	case a.StoreID != "":
		name, err := s.storeName(ctx, a.StoreID)
		if err != nil {
			return "", apperr.Validation("audience.store_id: магазин не найден")
		}
		a.NetworkID = ""
		parts = append(parts, "покупатели "+strings.SplitN(name, " · ", 2)[0])
	case a.NetworkID != "":
		name, err := s.one(ctx, "audience.network_id", `SELECT name FROM networks WHERE id = $1`, a.NetworkID)
		if err != nil {
			return "", err
		}
		parts = append(parts, "покупатели сети "+name)
	}
	switch a.Orders {
	case "":
		a.Days = 0
	case "within", "not_within":
		if a.Days < 1 || a.Days > 365 {
			return "", apperr.Validation("audience.days: от 1 до 365")
		}
		if a.Orders == "within" {
			parts = append(parts, fmt.Sprintf("заказывали за %d дн.", a.Days))
		} else {
			parts = append(parts, fmt.Sprintf("не заказывали %d дн.", a.Days))
		}
	case "never":
		a.Days = 0
		parts = append(parts, "ни разу не заказывали")
	default:
		return "", apperr.Validation("audience.orders: within, not_within или never")
	}
	a.UserID = ""
	if len(parts) == 0 {
		a.Type = "all"
		return "Все покупатели", nil
	}
	return "По фильтру · " + strings.Join(parts, " · "), nil
}

// liveOrder — заказ, который считается покупкой.
const liveOrder = `o.status IN ('paid', 'accepted', 'picking', 'picked', 'delivering', 'delivered')`

// audienceSQL — условие на покупателей c (customers) и пользователей u.
// Отписанные от акций не получают рассылку (кроме «одного клиента»).
func audienceSQL(a Audience) (string, []any) {
	var (
		conds = []string{"c.deleted_at IS NULL", "c.blocked_at IS NULL"}
		args  []any
	)
	arg := func(v any) string {
		args = append(args, v)
		return "$" + strconv.Itoa(len(args))
	}
	if a.Type == "one" {
		conds = append(conds, "c.user_id = "+arg(a.UserID)+"::uuid")
		return strings.Join(conds, " AND "), args
	}
	conds = append(conds, "c.notify_promos")
	if a.Type != "filter" {
		return strings.Join(conds, " AND "), args
	}
	if a.City != "" {
		p := arg(a.City)
		conds = append(conds, `(lower(c.city) = lower(`+p+`) OR EXISTS (SELECT 1 FROM orders o JOIN stores s ON s.id = o.store_id
			WHERE o.customer_id = c.user_id AND `+liveOrder+` AND lower(s.city) = lower(`+p+`)))`)
	}
	if a.Language != "" {
		conds = append(conds, "c.language = "+arg(a.Language))
	}
	if a.StoreID != "" {
		conds = append(conds, "EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.user_id AND "+liveOrder+" AND o.store_id = "+arg(a.StoreID)+"::uuid)")
	} else if a.NetworkID != "" {
		conds = append(conds, "EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.user_id AND "+liveOrder+" AND o.network_id = "+arg(a.NetworkID)+"::uuid)")
	}
	switch a.Orders {
	case "within":
		conds = append(conds, "EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.user_id AND "+liveOrder+
			" AND o.created_at > now() - "+arg(a.Days)+" * interval '1 day')")
	case "not_within":
		conds = append(conds, "EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.user_id AND "+liveOrder+")",
			"NOT EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.user_id AND "+liveOrder+
				" AND o.created_at > now() - "+arg(a.Days)+" * interval '1 day')")
	case "never":
		conds = append(conds, "NOT EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.user_id AND "+liveOrder+")")
	}
	return strings.Join(conds, " AND "), args
}

// Reach — сколько покупателей подходит и у скольких есть push.
type Reach struct {
	Recipients    int       `json:"recipients"`
	WithPush      int       `json:"with_push"`
	WithoutPush   int       `json:"without_push"`
	SendAt        time.Time `json:"send_at"`
	Shifted       bool      `json:"shifted"` // время перенесено из-за ночи
	TargetTitle   string    `json:"target_title"`
	AudienceTitle string    `json:"audience_title"`
}

func (s *Service) check(ctx context.Context, in *CampaignInput) (Reach, error) {
	in.Title = strings.TrimSpace(in.Title)
	in.Body = strings.TrimSpace(in.Body)
	if n := utf8.RuneCountInString(in.Title); n == 0 || n > 65 {
		return Reach{}, apperr.Validation("title: от 1 до 65 символов")
	}
	if n := utf8.RuneCountInString(in.Body); n == 0 || n > 240 {
		return Reach{}, apperr.Validation("body: от 1 до 240 символов")
	}
	tt, err := s.checkTarget(ctx, &in.Target)
	if err != nil {
		return Reach{}, err
	}
	at, err := s.checkAudience(ctx, &in.Audience)
	if err != nil {
		return Reach{}, err
	}
	now := s.now()
	want := now
	if in.SendAt != nil {
		if in.SendAt.Before(now.Add(-time.Minute)) {
			return Reach{}, apperr.Validation("send_at: время уже прошло")
		}
		if in.SendAt.After(now.AddDate(0, 3, 0)) {
			return Reach{}, apperr.Validation("send_at: не дальше трёх месяцев")
		}
		want = *in.SendAt
	}
	at2 := SkipNight(want)
	r := Reach{SendAt: at2, Shifted: !at2.Equal(want), TargetTitle: tt, AudienceTitle: at}
	if at2.Before(now) {
		r.SendAt = now
	}
	where, args := audienceSQL(in.Audience)
	err = s.pool.QueryRow(ctx, `
		SELECT count(*)::int, count(*) FILTER (WHERE EXISTS (SELECT 1 FROM devices d WHERE d.user_id = c.user_id))::int
		FROM customers c JOIN users u ON u.id = c.user_id WHERE `+where, args...).Scan(&r.Recipients, &r.WithPush)
	r.WithoutPush = r.Recipients - r.WithPush
	return r, err
}

// Preview — охват и итоговое время без создания рассылки.
func (s *Service) Preview(ctx context.Context, in CampaignInput) (Reach, error) {
	return s.check(ctx, &in)
}

// Create — новая рассылка. Отправит воркер в send_at (сразу — в ближайшие секунды).
func (s *Service) Create(ctx context.Context, adminID string, in CampaignInput) (Campaign, error) {
	r, err := s.check(ctx, &in)
	if err != nil {
		return Campaign{}, err
	}
	if r.Recipients == 0 {
		return Campaign{}, apperr.Validation("audience: под фильтр не попал ни один покупатель")
	}
	tj, _ := json.Marshal(in.Target)
	aj, _ := json.Marshal(in.Audience)
	var id string
	err = s.pool.QueryRow(ctx, `
		INSERT INTO push_campaigns (title, body, target, target_title, audience, audience_title, send_at, recipients, created_by)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING id`,
		in.Title, in.Body, tj, r.TargetTitle, aj, r.AudienceTitle, r.SendAt, r.Recipients, adminID).Scan(&id)
	if err != nil {
		return Campaign{}, err
	}
	return s.Get(ctx, id)
}

const campaignSelect = `
	SELECT p.id, p.title, p.body, p.target, p.target_title, p.audience, p.audience_title, p.send_at, p.status, p.recipients,
	       COALESCE(NULLIF(u.full_name, ''), u.phone, ''), p.created_at, p.started_at, p.finished_at, p.cancelled_at,
	       COALESCE(st.pending, 0), COALESCE(st.sent, 0), COALESCE(st.no_push, 0), COALESCE(st.failed, 0)
	FROM push_campaigns p
	LEFT JOIN users u ON u.id = p.created_by
	LEFT JOIN LATERAL (
		SELECT count(*) FILTER (WHERE n.status = 'pending')::int AS pending,
		       count(*) FILTER (WHERE n.status = 'sent')::int AS sent,
		       count(*) FILTER (WHERE n.status = 'skipped')::int AS no_push,
		       count(*) FILTER (WHERE n.status = 'failed')::int AS failed
		FROM notifications_outbox n WHERE n.campaign_id = p.id) st ON true`

func scanCampaign(r pgx.CollectableRow) (Campaign, error) {
	var c Campaign
	err := r.Scan(&c.ID, &c.Title, &c.Body, &c.Target, &c.TargetTitle, &c.Audience, &c.AudienceTitle, &c.SendAt, &c.Status, &c.Recipients,
		&c.CreatedBy, &c.CreatedAt, &c.StartedAt, &c.FinishedAt, &c.CancelledAt,
		&c.Stats.Pending, &c.Stats.Sent, &c.Stats.NoPush, &c.Stats.Failed)
	return c, err
}

func (s *Service) Get(ctx context.Context, id string) (Campaign, error) {
	rows, err := s.pool.Query(ctx, campaignSelect+` WHERE p.id = $1`, id)
	if err != nil {
		return Campaign{}, err
	}
	c, err := pgx.CollectExactlyOneRow(rows, scanCampaign)
	if errors.Is(err, pgx.ErrNoRows) {
		return c, apperr.NotFound("рассылка не найдена")
	}
	return c, err
}

func (s *Service) List(ctx context.Context, status string, page httpx.Page) ([]Campaign, error) {
	switch status {
	case "", "scheduled", "sending", "sent", "cancelled":
	default:
		return nil, apperr.Validation("status: scheduled, sending, sent или cancelled")
	}
	rows, err := s.pool.Query(ctx, campaignSelect+`
		WHERE ($1 = '' OR p.status = $1)
		ORDER BY (p.status IN ('scheduled', 'sending')) DESC, p.send_at DESC LIMIT $2 OFFSET $3`, status, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanCampaign)
}

// Cancel — отменить рассылку, пока она не началась.
func (s *Service) Cancel(ctx context.Context, id string) (Campaign, error) {
	tag, err := s.pool.Exec(ctx, `UPDATE push_campaigns SET status = 'cancelled', cancelled_at = now() WHERE id = $1 AND status = 'scheduled'`, id)
	if err != nil {
		return Campaign{}, err
	}
	c, err := s.Get(ctx, id)
	if err == nil && tag.RowsAffected() == 0 {
		return c, apperr.Conflict("campaign_started", "рассылка уже отправляется или отменена — отменить нельзя")
	}
	return c, err
}

// Recipient — получатель рассылки и что с ним стало.
type Recipient struct {
	ID       int64      `json:"id"`
	UserID   string     `json:"user_id"`
	Phone    string     `json:"phone"`
	Name     string     `json:"name"`
	Status   string     `json:"status"`
	Devices  string     `json:"devices"`
	Reason   string     `json:"reason"`
	SentAt   *time.Time `json:"sent_at"`
	Attempts int        `json:"attempts"`
}

// Recipients — получатели: status = sent | not_sent | pending; q — телефон или имя.
func (s *Service) Recipients(ctx context.Context, id, status, q string, page httpx.Page) ([]Recipient, error) {
	cond := ""
	switch status {
	case "":
	case "sent":
		cond = "AND n.status = 'sent'"
	case "not_sent":
		cond = "AND n.status IN ('skipped', 'failed')"
	case "pending":
		cond = "AND n.status = 'pending'"
	default:
		return nil, apperr.Validation("status: sent, not_sent или pending")
	}
	q = strings.TrimSpace(q)
	digits := strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, q)
	if len(digits) < 3 {
		digits = ""
	}
	rows, err := s.pool.Query(ctx, `
		SELECT n.id, n.user_id, u.phone, u.full_name, n.status, n.devices, n.last_error, n.sent_at, n.attempts
		FROM notifications_outbox n JOIN users u ON u.id = n.user_id
		WHERE n.campaign_id = $1 `+cond+`
		  AND ($2 = '' OR ($3 <> '' AND u.phone LIKE '%' || $3 || '%') OR u.full_name ILIKE '%' || $2 || '%')
		ORDER BY (n.status = 'sent'), n.id LIMIT $4 OFFSET $5`, id, q, digits, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Recipient])
}

// Overview — цифры над списком рассылок.
type Overview struct {
	WithPush    int     `json:"with_push"`
	WithoutPush int     `json:"without_push"`
	PromosOff   int     `json:"promos_off"`
	Sent30      int     `json:"sent_30d"`
	Total30     int     `json:"total_30d"`
	Delivered30 float64 `json:"delivered_30d"` // доля доставленных, 0–100
	PushEnabled bool    `json:"push_enabled"`  // ключ Firebase задан на сервере
}

func (s *Service) Overview(ctx context.Context) (Overview, error) {
	o := Overview{PushEnabled: s.fcm != nil}
	err := s.pool.QueryRow(ctx, `
		SELECT count(*) FILTER (WHERE EXISTS (SELECT 1 FROM devices d WHERE d.user_id = c.user_id))::int,
		       count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM devices d WHERE d.user_id = c.user_id))::int,
		       count(*) FILTER (WHERE NOT c.notify_promos)::int
		FROM customers c WHERE c.deleted_at IS NULL AND c.blocked_at IS NULL`).Scan(&o.WithPush, &o.WithoutPush, &o.PromosOff)
	if err != nil {
		return o, err
	}
	err = s.pool.QueryRow(ctx, `
		SELECT count(*) FILTER (WHERE status = 'sent')::int, count(*) FILTER (WHERE status <> 'pending')::int
		FROM notifications_outbox WHERE created_at > now() - interval '30 days'`).Scan(&o.Sent30, &o.Total30)
	if o.Total30 > 0 {
		o.Delivered30 = float64(o.Sent30*1000/o.Total30) / 10
	}
	return o, err
}

// DeviceInfo — устройство покупателя в карточке поиска.
type DeviceInfo struct {
	Platform   string    `json:"platform"`
	Name       string    `json:"name"`
	LastSeenAt time.Time `json:"last_seen_at"`
}

// CustomerInfo — покупатель для «одного клиента» и тестового push.
type CustomerInfo struct {
	UserID      string       `json:"user_id"`
	Phone       string       `json:"phone"`
	Name        string       `json:"name"`
	Orders      int          `json:"orders"`
	LastOrderAt *time.Time   `json:"last_order_at"`
	PromosOn    bool         `json:"promos_on"`
	Devices     []DeviceInfo `json:"devices"`
}

// FindCustomer — покупатель по телефону (или самому админу при self).
func (s *Service) FindCustomer(ctx context.Context, rawPhone, selfID string) (CustomerInfo, error) {
	var c CustomerInfo
	where, arg := "u.phone = $1", any(nil)
	if rawPhone == "" {
		if selfID == "" {
			return c, apperr.Validation("phone: укажите телефон")
		}
		where, arg = "u.id = $1", selfID
	} else {
		p, err := phone.Normalize(rawPhone)
		if err != nil {
			return c, apperr.Validation("phone: неверный номер")
		}
		arg = p
	}
	err := s.pool.QueryRow(ctx, `
		SELECT u.id, u.phone, u.full_name, c.notify_promos,
		       (SELECT count(*) FROM orders o WHERE o.customer_id = u.id AND `+liveOrder+`)::int,
		       (SELECT max(o.created_at) FROM orders o WHERE o.customer_id = u.id AND `+liveOrder+`)
		FROM users u JOIN customers c ON c.user_id = u.id
		WHERE `+where+` AND c.deleted_at IS NULL`, arg).Scan(&c.UserID, &c.Phone, &c.Name, &c.PromosOn, &c.Orders, &c.LastOrderAt)
	if errors.Is(err, pgx.ErrNoRows) {
		if rawPhone == "" {
			return c, apperr.NotFound("ваш номер не входил в приложение покупателя — войдите в него и разрешите уведомления")
		}
		return c, apperr.NotFound("покупатель с таким номером не найден")
	}
	if err != nil {
		return c, err
	}
	rows, err := s.pool.Query(ctx, `SELECT platform, last_seen_at FROM devices WHERE user_id = $1 ORDER BY last_seen_at DESC LIMIT 10`, c.UserID)
	if err != nil {
		return c, err
	}
	c.Devices, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (DeviceInfo, error) {
		var d DeviceInfo
		err := r.Scan(&d.Platform, &d.LastSeenAt)
		d.Name = PlatformName(d.Platform)
		return d, err
	})
	return c, err
}

type TestInput struct {
	Phone  string `json:"phone"` // пусто — себе
	Title  string `json:"title"`
	Body   string `json:"body"`
	Target Target `json:"target"`
}

// DeviceResult — что ответил Firebase по устройству.
type DeviceResult struct {
	Name   string `json:"name"`
	OK     bool   `json:"ok"`
	Reason string `json:"reason"`
	MS     int64  `json:"ms"`
}

type TestResult struct {
	Customer CustomerInfo   `json:"customer"`
	Results  []DeviceResult `json:"results"`
	SentAt   time.Time      `json:"sent_at"`
}

// Test — отправить push сразу и показать ответ по каждому устройству.
// Попадает и в журнал (вид test).
func (s *Service) Test(ctx context.Context, adminID string, in TestInput) (TestResult, error) {
	in.Title, in.Body = strings.TrimSpace(in.Title), strings.TrimSpace(in.Body)
	if in.Title == "" {
		in.Title = "Проверка уведомлений"
	}
	if in.Body == "" {
		in.Body = "Если вы это видите — push работает"
	}
	if utf8.RuneCountInString(in.Title) > 65 || utf8.RuneCountInString(in.Body) > 240 {
		return TestResult{}, apperr.Validation("title до 65, body до 240 символов")
	}
	if _, err := s.checkTarget(ctx, &in.Target); err != nil {
		return TestResult{}, err
	}
	cust, err := s.FindCustomer(ctx, in.Phone, adminID)
	if err != nil {
		return TestResult{}, err
	}
	res := TestResult{Customer: cust, Results: []DeviceResult{}, SentAt: s.now()}
	devs, err := UserDevices(ctx, s.pool, cust.UserID)
	if err != nil {
		return res, err
	}
	if len(devs) == 0 {
		return res, apperr.Conflict("no_devices", "у покупателя нет устройств с разрешёнными уведомлениями")
	}
	if s.fcm == nil {
		return res, apperr.Conflict("push_disabled", "push не настроен на сервере: нет FCM_CREDENTIALS")
	}
	data := in.Target.Data()
	msg := Message{Title: in.Title, Body: in.Body, Data: MessageData(data)}
	var okNames []string
	var lastErr string
	for _, d := range devs {
		start := time.Now()
		err := s.fcm.Send(ctx, d.Token, msg)
		r := DeviceResult{Name: PlatformName(d.Platform), OK: err == nil, Reason: Reason(err), MS: time.Since(start).Milliseconds()}
		if err == nil {
			okNames = append(okNames, r.Name)
		} else {
			lastErr = r.Reason
			if errors.Is(err, ErrUnregistered) {
				if _, err := s.pool.Exec(ctx, `DELETE FROM devices WHERE id = $1`, d.ID); err != nil {
					return res, err
				}
				r.Reason += ". Попросите клиента открыть приложение."
			}
		}
		res.Results = append(res.Results, r)
	}
	status := "sent"
	if len(okNames) == 0 {
		status = "failed"
	}
	dj, _ := json.Marshal(data)
	_, err = s.pool.Exec(ctx, `
		INSERT INTO notifications_outbox (user_id, kind, title, body, data, status, channel, devices, attempts, last_error, sent_at)
		VALUES ($1, 'test', $2, $3, $4, $5, 'push', $6, 1, $7, CASE WHEN $5 = 'sent' THEN now() END)`,
		cust.UserID, in.Title, in.Body, dj, status, strings.Join(dedupe(okNames), ", "), lastErr)
	return res, err
}

// StartDueCampaigns кладёт в очередь получателей рассылок, у которых
// подошло время.
func StartDueCampaigns(ctx context.Context, pool *pgxpool.Pool) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	type due struct {
		id, title, body string
		target          Target
		audience        Audience
	}
	rows, err := tx.Query(ctx, `
		SELECT id, title, body, target, audience FROM push_campaigns
		WHERE status = 'scheduled' AND send_at <= now()
		ORDER BY send_at LIMIT 5 FOR UPDATE SKIP LOCKED`)
	if err != nil {
		return err
	}
	var list []due
	for rows.Next() {
		var d due
		if err := rows.Scan(&d.id, &d.title, &d.body, &d.target, &d.audience); err != nil {
			rows.Close()
			return err
		}
		list = append(list, d)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, d := range list {
		data := d.target.Data()
		data["campaign_id"] = d.id
		dj, _ := json.Marshal(data)
		where, args := audienceSQL(d.audience)
		n := len(args)
		args = append(args, d.id, d.title, d.body, string(dj))
		tag, err := tx.Exec(ctx, fmt.Sprintf(`
			INSERT INTO notifications_outbox (user_id, kind, title, body, data, campaign_id)
			SELECT c.user_id, 'campaign', $%d, $%d, $%d::jsonb, $%d::uuid
			FROM customers c JOIN users u ON u.id = c.user_id WHERE %s`, n+2, n+3, n+4, n+1, where), args...)
		if err != nil {
			return err
		}
		status := "sending"
		if tag.RowsAffected() == 0 {
			status = "sent"
		}
		if _, err := tx.Exec(ctx, `
			UPDATE push_campaigns SET status = $2, recipients = $3, started_at = now(),
			       finished_at = CASE WHEN $2 = 'sent' THEN now() END
			WHERE id = $1`, d.id, status, tag.RowsAffected()); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

// FinishCampaigns отмечает отправленными рассылки без ожидающих уведомлений.
func FinishCampaigns(ctx context.Context, pool *pgxpool.Pool) error {
	_, err := pool.Exec(ctx, `
		UPDATE push_campaigns p SET status = 'sent', finished_at = now()
		WHERE p.status = 'sending'
		  AND NOT EXISTS (SELECT 1 FROM notifications_outbox n WHERE n.campaign_id = p.id AND n.status = 'pending')`)
	return err
}
