// Package payments — онлайн-оплата заказов через Payme и Click.
//
// Оба провайдера работают по схеме «провайдер вызывает наш сервер»:
// клиент уходит на страницу оплаты по ссылке CheckoutURL, провайдер
// спрашивает, можно ли оплатить заказ, и сообщает об оплате. Эти запросы
// обрабатывают PaymeHandler и Click*Handler. Изменения заказа (оплачен,
// возврат) делаются через интерфейс Orders, который реализует модуль orders.
package payments

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

const (
	ProviderPayme = "payme"
	ProviderClick = "click"
)

// Orders — то, что платежам нужно от заказов.
type Orders interface {
	// PayableAmount — сумма к оплате, если заказ ждёт оплаты. Иначе ошибка.
	PayableAmount(ctx context.Context, q db.Querier, orderID string) (string, error)
	// MarkPaid вызывается в транзакции, где платёж стал оплаченным.
	MarkPaid(ctx context.Context, tx pgx.Tx, orderID string) error
	// CanRefund — можно ли вернуть деньги по заказу (заказ ещё не собран).
	CanRefund(ctx context.Context, q db.Querier, orderID string) (bool, error)
	// Refunded вызывается, когда провайдер вернул деньги.
	Refunded(ctx context.Context, tx pgx.Tx, orderID string) error
}

type Config struct {
	PaymeMerchantID string
	PaymeKey        string
	PaymeTest       bool
	ClickServiceID  string
	ClickMerchantID string
	ClickSecretKey  string
	ReturnURL       string
	// Payme отменяет неоплаченную транзакцию через 12 часов.
	PaymeTimeout time.Duration
}

type Service struct {
	pool   *pgxpool.Pool
	cfg    Config
	orders Orders
	log    *slog.Logger
	now    func() time.Time
}

func NewService(pool *pgxpool.Pool, cfg Config, log *slog.Logger) *Service {
	if cfg.PaymeTimeout == 0 {
		cfg.PaymeTimeout = 12 * time.Hour
	}
	return &Service{pool: pool, cfg: cfg, log: log.With("component", "payments"), now: time.Now}
}

// SetOrders подключает модуль заказов (он создаётся после платежей).
func (s *Service) SetOrders(o Orders) { s.orders = o }

// Enabled — какие провайдеры настроены.
func (s *Service) Enabled(provider string) bool {
	switch provider {
	case ProviderPayme:
		return s.cfg.PaymeMerchantID != "" && s.cfg.PaymeKey != ""
	case ProviderClick:
		return s.cfg.ClickServiceID != "" && s.cfg.ClickMerchantID != "" && s.cfg.ClickSecretKey != ""
	}
	return false
}

// CheckoutURL — ссылка на страницу оплаты провайдера для заказа.
func (s *Service) CheckoutURL(provider, orderID, amount string) (string, error) {
	if !s.Enabled(provider) {
		return "", apperr.Validation("payment_provider: способ оплаты недоступен").Uz("payment_provider: toʻlov usuli mavjud emas")
	}
	returnURL := s.cfg.ReturnURL
	switch provider {
	case ProviderPayme:
		tiyin := money.D(amount).Mul(money.D("100")).Fixed(0)
		params := fmt.Sprintf("m=%s;ac.order_id=%s;a=%s", s.cfg.PaymeMerchantID, orderID, tiyin)
		if returnURL != "" {
			params += ";c=" + returnURL
		}
		host := "https://checkout.paycom.uz/"
		if s.cfg.PaymeTest {
			host = "https://checkout.test.paycom.uz/"
		}
		return host + base64.StdEncoding.EncodeToString([]byte(params)), nil
	case ProviderClick:
		v := url.Values{}
		v.Set("service_id", s.cfg.ClickServiceID)
		v.Set("merchant_id", s.cfg.ClickMerchantID)
		v.Set("amount", money.D(amount).Money())
		v.Set("transaction_param", orderID)
		if returnURL != "" {
			v.Set("return_url", returnURL)
		}
		return "https://my.click.uz/services/pay?" + v.Encode(), nil
	}
	return "", apperr.Validation("payment_provider: ожидается payme или click").Uz("payment_provider: payme yoki click boʻlishi kerak")
}

// logEvent сохраняет сырой запрос и ответ провайдера.
func (s *Service) logEvent(ctx context.Context, provider, method string, req, resp any) {
	reqJSON, _ := json.Marshal(req)
	respJSON, _ := json.Marshal(resp)
	if _, err := s.pool.Exec(ctx, `INSERT INTO payment_events (provider, method, request, response) VALUES ($1, $2, $3, $4)`,
		provider, method, reqJSON, respJSON); err != nil {
		s.log.Warn("не удалось сохранить событие оплаты", "err", err)
	}
}

// ------------------------------------------------------------- возвраты

// RequestRefund переводит оплаченный платёж заказа в refund_pending.
// Возврат выполняет супер-админ в кабинете провайдера: Payme сообщит об
// этом сам (CancelTransaction), для Click — отметка MarkRefunded.
func RequestRefund(ctx context.Context, tx pgx.Tx, orderID string) (bool, error) {
	tag, err := tx.Exec(ctx, `UPDATE payments SET status = 'refund_pending' WHERE order_id = $1 AND status = 'paid'`, orderID)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
}

// CancelOpen отменяет неоплаченные попытки оплаты заказа (заказ истёк или отменён).
func CancelOpen(ctx context.Context, tx pgx.Tx, orderID string) error {
	_, err := tx.Exec(ctx, `UPDATE payments SET status = 'cancelled', cancelled_at = now() WHERE order_id = $1 AND status = 'created'`, orderID)
	return err
}

type Payment struct {
	ID          string     `json:"id"`
	OrderID     string     `json:"order_id"`
	OrderNumber int64      `json:"order_number"`
	NetworkName string     `json:"network_name"`
	Provider    string     `json:"provider"`
	Amount      string     `json:"amount"`
	Status      string     `json:"status"`
	ExternalID  *string    `json:"external_id"`
	PaidAt      *time.Time `json:"paid_at"`
	RefundedAt  *time.Time `json:"refunded_at"`
	CreatedAt   time.Time  `json:"created_at"`
}

// List — платежи для супер-админа; status=refund_pending — очередь возвратов.
func (s *Service) List(ctx context.Context, status string, limit, offset int) ([]Payment, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT p.id, p.order_id, o.number, n.name, p.provider, p.amount::text, p.status, p.external_id,
		       p.paid_at, p.refunded_at, p.created_at
		FROM payments p JOIN orders o ON o.id = p.order_id JOIN networks n ON n.id = o.network_id
		WHERE $1 = '' OR p.status = $1
		ORDER BY p.created_at DESC, p.id LIMIT $2 OFFSET $3`, status, limit, offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Payment])
}

// MarkRefunded — супер-админ подтверждает, что вернул деньги в кабинете провайдера.
func (s *Service) MarkRefunded(ctx context.Context, id string) error {
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var orderID string
		err := tx.QueryRow(ctx, `UPDATE payments SET status = 'refunded', refunded_at = now()
			WHERE id = $1 AND status = 'refund_pending' RETURNING order_id`, id).Scan(&orderID)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Conflict("not_refund_pending", "платёж не ждёт возврата").Uz("toʻlov qaytarishni kutmayapti")
		}
		if err != nil {
			return err
		}
		return s.orders.Refunded(ctx, tx, orderID)
	})
}
