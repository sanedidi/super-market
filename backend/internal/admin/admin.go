// Package admin — сводка, покупатели и очередь уведомлений для
// панели супер-админа (данные нескольких модулей только для чтения
// и небольшие действия над ними).
package admin

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/orders"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

type Service struct {
	pool *pgxpool.Pool
	// acceptTimeout — за сколько магазин должен принять оплаченный заказ.
	acceptTimeout time.Duration
}

func NewService(pool *pgxpool.Pool, acceptTimeout time.Duration) *Service {
	return &Service{pool: pool, acceptTimeout: acceptTimeout}
}

// Tashkent-дата «сегодня» в SQL.
const todaySQL = `(now() AT TIME ZONE 'Asia/Tashkent')::date`

// ------------------------------------------------------------- сводка

// Stats — что требует внимания супер-админа и итоги дня.
type Stats struct {
	StaleOrders      int `json:"stale_orders"`
	PaidWaiting      int `json:"paid_waiting"`
	RefundsPending   int `json:"refunds_pending"`
	PayoutsRequested int `json:"payouts_requested"`
	ProductsPending  int `json:"products_pending"`
	OverdueNetworks  int `json:"overdue_networks"`
	FailedPush       int `json:"failed_notifications"`
	// Заказы, оплаченные сегодня (по Ташкенту), кроме отменённых.
	TodayOrders int    `json:"today_orders"`
	TodayGMV    string `json:"today_gmv"`
	// Сколько минут даётся магазину на принятие заказа.
	AcceptTimeoutMin int `json:"accept_timeout_min"`
}

func (s *Service) Stats(ctx context.Context) (Stats, error) {
	st := Stats{AcceptTimeoutMin: int(s.acceptTimeout.Minutes())}
	err := s.pool.QueryRow(ctx, `
		SELECT
			(SELECT count(*) FROM orders o WHERE `+orders.StaleSQL("$1")+`)::int,
			(SELECT count(*) FROM orders WHERE status = 'paid')::int,
			(SELECT count(*) FROM payments WHERE status = 'refund_pending')::int,
			(SELECT count(*) FROM payouts WHERE status = 'requested')::int,
			(SELECT count(*) FROM products WHERE moderation_status = 'pending')::int,
			(SELECT count(DISTINCT network_id) FROM subscription_invoices
			  WHERE status = 'unpaid' AND due_date < `+todaySQL+`)::int,
			(SELECT count(*) FROM notifications_outbox WHERE status = 'failed')::int,
			count(o.id)::int, COALESCE(sum(o.total), 0)::numeric(18,2)::text
		FROM orders o
		WHERE o.paid_at >= `+todaySQL+`::timestamp AT TIME ZONE 'Asia/Tashkent' AND o.status <> 'cancelled'`,
		s.acceptTimeout.Seconds()).Scan(&st.StaleOrders, &st.PaidWaiting, &st.RefundsPending, &st.PayoutsRequested,
		&st.ProductsPending, &st.OverdueNetworks, &st.FailedPush, &st.TodayOrders, &st.TodayGMV)
	return st, err
}

// ---------------------------------------------------------- покупатели

type Customer struct {
	ID             string     `json:"id"`
	Phone          string     `json:"phone"`
	FullName       string     `json:"full_name"`
	CreatedAt      time.Time  `json:"created_at"`
	DeletedAt      *time.Time `json:"deleted_at"`
	BlockedAt      *time.Time `json:"blocked_at"`
	BlockedReason  string     `json:"blocked_reason"`
	OrdersCount    int        `json:"orders_count"`
	LastOrderAt    *time.Time `json:"last_order_at"`
	FamilyName     *string    `json:"family_name"`
	TelegramLinked bool       `json:"telegram_linked"`
}

type CustomerAddress struct {
	ID        string    `json:"id"`
	Label     string    `json:"label"`
	Address   string    `json:"address"`
	Apartment string    `json:"apartment"`
	CreatedAt time.Time `json:"created_at"`
}

type CustomerOrder struct {
	ID        string    `json:"id"`
	Number    int64     `json:"number"`
	StoreName string    `json:"store_name"`
	Status    string    `json:"status"`
	Total     string    `json:"total"`
	CreatedAt time.Time `json:"created_at"`
}

type CustomerDetail struct {
	Customer
	Language     string            `json:"language"`
	City         string            `json:"city"`
	DevicesCount int               `json:"devices_count"`
	Addresses    []CustomerAddress `json:"addresses"`
	RecentOrders []CustomerOrder   `json:"recent_orders"`
}

const customerSelect = `
	SELECT u.id, u.phone, u.full_name, c.created_at, c.deleted_at, c.blocked_at, c.blocked_reason,
	       (SELECT count(*) FROM orders o WHERE o.customer_id = u.id AND o.status NOT IN ('awaiting_payment', 'expired'))::int,
	       (SELECT max(o.created_at) FROM orders o WHERE o.customer_id = u.id),
	       (SELECT f.name FROM family_members fm JOIN families f ON f.id = fm.family_id WHERE fm.user_id = u.id),
	       EXISTS (SELECT 1 FROM telegram_links t WHERE t.phone = u.phone)
	FROM customers c JOIN users u ON u.id = c.user_id`

func scanCustomer(row pgx.CollectableRow) (Customer, error) {
	var c Customer
	err := row.Scan(&c.ID, &c.Phone, &c.FullName, &c.CreatedAt, &c.DeletedAt, &c.BlockedAt, &c.BlockedReason,
		&c.OrdersCount, &c.LastOrderAt, &c.FamilyName, &c.TelegramLinked)
	return c, err
}

func onlyDigits(s string) string {
	return strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, s)
}

// CustomerFilter — поиск покупателей: q — телефон (цифры) или имя.
type CustomerFilter struct {
	Query   string
	Blocked bool
	Page    httpx.Page
}

func (s *Service) ListCustomers(ctx context.Context, f CustomerFilter) ([]Customer, error) {
	q := strings.TrimSpace(f.Query)
	digits := onlyDigits(q)
	if len(digits) < 3 {
		digits = ""
	}
	rows, err := s.pool.Query(ctx, customerSelect+`
		WHERE ($1 = '' OR ($2 <> '' AND u.phone LIKE '%' || $2 || '%') OR u.full_name ILIKE '%' || $1 || '%')
		  AND (NOT $3 OR c.blocked_at IS NOT NULL)
		ORDER BY c.created_at DESC, u.id LIMIT $4 OFFSET $5`, q, digits, f.Blocked, f.Page.Limit, f.Page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanCustomer)
}

func (s *Service) GetCustomer(ctx context.Context, id string) (CustomerDetail, error) {
	rows, err := s.pool.Query(ctx, customerSelect+` WHERE u.id = $1`, id)
	if err != nil {
		return CustomerDetail{}, err
	}
	c, err := pgx.CollectExactlyOneRow(rows, scanCustomer)
	if errors.Is(err, pgx.ErrNoRows) {
		return CustomerDetail{}, apperr.NotFound("покупатель не найден")
	}
	if err != nil {
		return CustomerDetail{}, err
	}
	d := CustomerDetail{Customer: c}
	if err := s.pool.QueryRow(ctx, `
		SELECT c.language, c.city, (SELECT count(*) FROM devices dv WHERE dv.user_id = c.user_id)::int
		FROM customers c WHERE c.user_id = $1`, id).Scan(&d.Language, &d.City, &d.DevicesCount); err != nil {
		return CustomerDetail{}, err
	}
	rows, err = s.pool.Query(ctx, `
		SELECT id, label, address, apartment, created_at FROM customer_addresses
		WHERE user_id = $1 ORDER BY created_at DESC`, id)
	if err != nil {
		return CustomerDetail{}, err
	}
	if d.Addresses, err = pgx.CollectRows(rows, pgx.RowToStructByPos[CustomerAddress]); err != nil {
		return CustomerDetail{}, err
	}
	rows, err = s.pool.Query(ctx, `
		SELECT o.id, o.number, s.name, o.status, o.total::text, o.created_at
		FROM orders o JOIN stores s ON s.id = o.store_id
		WHERE o.customer_id = $1 ORDER BY o.created_at DESC LIMIT 20`, id)
	if err != nil {
		return CustomerDetail{}, err
	}
	d.RecentOrders, err = pgx.CollectRows(rows, pgx.RowToStructByPos[CustomerOrder])
	return d, err
}

// BlockCustomer — покупатель больше не входит в приложение заново и не
// оформляет заказы. Открытые сессии остаются: он видит свои заказы.
func (s *Service) BlockCustomer(ctx context.Context, id, reason string) (CustomerDetail, error) {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return CustomerDetail{}, apperr.Validation("reason: укажите причину блокировки")
	}
	if len([]rune(reason)) > 500 {
		return CustomerDetail{}, apperr.Validation("reason: не длиннее 500 символов")
	}
	return s.setBlocked(ctx, id, true, reason)
}

func (s *Service) UnblockCustomer(ctx context.Context, id string) (CustomerDetail, error) {
	return s.setBlocked(ctx, id, false, "")
}

func (s *Service) setBlocked(ctx context.Context, id string, block bool, reason string) (CustomerDetail, error) {
	if _, err := s.GetCustomer(ctx, id); err != nil {
		return CustomerDetail{}, err
	}
	tag, err := s.pool.Exec(ctx, `
		UPDATE customers SET blocked_at = CASE WHEN $2 THEN now() END, blocked_reason = $3
		WHERE user_id = $1 AND (blocked_at IS NOT NULL) <> $2`, id, block, reason)
	if err != nil {
		return CustomerDetail{}, err
	}
	if tag.RowsAffected() == 0 {
		if block {
			return CustomerDetail{}, apperr.Conflict("already_blocked", "покупатель уже заблокирован")
		}
		return CustomerDetail{}, apperr.Conflict("not_blocked", "покупатель не заблокирован")
	}
	return s.GetCustomer(ctx, id)
}

// -------------------------------------------------------- уведомления

type Notification struct {
	ID        int64      `json:"id"`
	UserID    string     `json:"user_id"`
	Phone     string     `json:"phone"`
	Kind      string     `json:"kind"`
	Title     string     `json:"title"`
	Body      string     `json:"body"`
	Status    string     `json:"status"`
	Channel   string     `json:"channel"`
	Attempts  int        `json:"attempts"`
	LastError string     `json:"last_error"`
	SendAfter time.Time  `json:"send_after"`
	CreatedAt time.Time  `json:"created_at"`
	SentAt    *time.Time `json:"sent_at"`
}

const notificationSelect = `
	SELECT n.id, n.user_id, u.phone, n.kind, n.title, n.body, n.status, n.channel, n.attempts, n.last_error,
	       n.send_after, n.created_at, n.sent_at
	FROM notifications_outbox n JOIN users u ON u.id = n.user_id`

// NotificationFilter — status: pending, sent, skipped, failed; q — телефон
// покупателя (цифры) или текст заголовка.
type NotificationFilter struct {
	Status string
	Query  string
	Page   httpx.Page
}

func (s *Service) ListNotifications(ctx context.Context, f NotificationFilter) ([]Notification, error) {
	switch f.Status {
	case "", "pending", "sent", "skipped", "failed":
	default:
		return nil, apperr.Validation("status: pending, sent, skipped или failed")
	}
	q := strings.TrimSpace(f.Query)
	digits := onlyDigits(q)
	if len(digits) < 3 {
		digits = ""
	}
	rows, err := s.pool.Query(ctx, notificationSelect+`
		WHERE ($1 = '' OR n.status = $1)
		  AND ($2 = '' OR ($3 <> '' AND u.phone LIKE '%' || $3 || '%') OR n.title ILIKE '%' || $2 || '%')
		ORDER BY n.created_at DESC, n.id DESC LIMIT $4 OFFSET $5`, f.Status, q, digits, f.Page.Limit, f.Page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Notification])
}

// RetryNotification возвращает неотправленное уведомление в очередь:
// воркер попробует снова с нуля попыток.
func (s *Service) RetryNotification(ctx context.Context, rawID string) (Notification, error) {
	id, err := strconv.ParseInt(rawID, 10, 64)
	if err != nil || id <= 0 {
		return Notification{}, apperr.NotFound("уведомление не найдено")
	}
	var status string
	err = s.pool.QueryRow(ctx, `SELECT status FROM notifications_outbox WHERE id = $1`, id).Scan(&status)
	if errors.Is(err, pgx.ErrNoRows) {
		return Notification{}, apperr.NotFound("уведомление не найдено")
	}
	if err != nil {
		return Notification{}, err
	}
	tag, err := s.pool.Exec(ctx, `
		UPDATE notifications_outbox SET status = 'pending', attempts = 0, last_error = '', send_after = now()
		WHERE id = $1 AND status IN ('failed', 'skipped')`, id)
	if err != nil {
		return Notification{}, err
	}
	if tag.RowsAffected() == 0 {
		return Notification{}, apperr.Conflict("not_failed", "повторить можно только неотправленное уведомление")
	}
	rows, err := s.pool.Query(ctx, notificationSelect+` WHERE n.id = $1`, id)
	if err != nil {
		return Notification{}, err
	}
	return pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Notification])
}
