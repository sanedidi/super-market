package billing

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// ---------------------------------------------------------------- баланс

type Balance struct {
	Available string `json:"available"`
	Pending   string `json:"pending"`
	// Когда можно запросить следующий вывод (null — уже можно).
	NextPayoutAt *time.Time `json:"next_payout_at"`
}

type BalanceEntry struct {
	ID          int64     `json:"id"`
	Kind        string    `json:"kind"`
	Status      string    `json:"status"`
	Amount      string    `json:"amount"`
	StoreID     *string   `json:"store_id"`
	OrderID     *string   `json:"order_id"`
	OrderNumber *int64    `json:"order_number"`
	InvoiceID   *string   `json:"invoice_id"`
	PayoutID    *string   `json:"payout_id"`
	Note        string    `json:"note"`
	CreatedAt   time.Time `json:"created_at"`
}

func (s *Service) nextPayoutAt(ctx context.Context, q db.Querier, networkID string) (*time.Time, error) {
	var last *time.Time
	if err := q.QueryRow(ctx, `SELECT max(created_at) FROM payouts WHERE network_id = $1 AND status <> 'rejected'`,
		networkID).Scan(&last); err != nil {
		return nil, err
	}
	if last == nil {
		return nil, nil
	}
	next := last.Add(PayoutInterval)
	if !next.After(s.now()) {
		return nil, nil
	}
	return &next, nil
}

func (s *Service) GetBalance(ctx context.Context, p *identity.Principal) (Balance, error) {
	if err := p.Require(identity.PermPayoutsManage); err != nil {
		return Balance{}, err
	}
	var b Balance
	if err := s.pool.QueryRow(ctx, `
		SELECT COALESCE(sum(amount) FILTER (WHERE status = 'available'), 0)::numeric(18,2)::text,
		       COALESCE(sum(amount) FILTER (WHERE status = 'pending'), 0)::numeric(18,2)::text
		FROM balance_entries WHERE network_id = $1`, p.NetworkID).Scan(&b.Available, &b.Pending); err != nil {
		return b, err
	}
	var err error
	b.NextPayoutAt, err = s.nextPayoutAt(ctx, s.pool, p.NetworkID)
	return b, err
}

func (s *Service) BalanceEntries(ctx context.Context, p *identity.Principal, from, to *time.Time, page httpx.Page) ([]BalanceEntry, error) {
	if err := p.Require(identity.PermPayoutsManage); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT b.id, b.kind, b.status, b.amount::text, b.store_id, b.order_id, o.number, b.invoice_id, b.payout_id, b.note, b.created_at
		FROM balance_entries b LEFT JOIN orders o ON o.id = b.order_id
		WHERE b.network_id = $1
		  AND ($2::timestamptz IS NULL OR b.created_at >= $2) AND ($3::timestamptz IS NULL OR b.created_at < $3)
		ORDER BY b.created_at DESC, b.id DESC LIMIT $4 OFFSET $5`, p.NetworkID, from, to, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[BalanceEntry])
}

// ---------------------------------------------------------------- вывод

type Payout struct {
	ID          string     `json:"id"`
	NetworkID   string     `json:"network_id"`
	NetworkName string     `json:"network_name"`
	Number      int64      `json:"number"`
	Amount      string     `json:"amount"`
	Status      string     `json:"status"`
	Requisites  string     `json:"requisites"`
	Note        string     `json:"note"`
	AdminNote   string     `json:"admin_note"`
	ProcessedAt *time.Time `json:"processed_at"`
	CreatedAt   time.Time  `json:"created_at"`
}

const payoutSelect = `
	SELECT p.id, p.network_id, n.name, p.number, p.amount::text, p.status, p.requisites, p.note, p.admin_note,
	       p.processed_at, p.created_at
	FROM payouts p JOIN networks n ON n.id = p.network_id`

type PayoutInput struct {
	Amount     money.Amount `json:"amount"`
	Requisites string       `json:"requisites"` // карта или расчётный счёт
	Note       string       `json:"note"`
}

func (s *Service) getPayout(ctx context.Context, q db.Querier, id string) (Payout, error) {
	if !httpx.IsUUID(id) {
		return Payout{}, apperr.NotFound("заявка не найдена")
	}
	rows, err := q.Query(ctx, payoutSelect+` WHERE p.id = $1`, id)
	if err != nil {
		return Payout{}, err
	}
	out, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Payout])
	if errors.Is(err, pgx.ErrNoRows) {
		return out, apperr.NotFound("заявка не найдена")
	}
	return out, err
}

// RequestPayout — заявка на вывод. Не чаще раза в неделю, минимальной суммы нет.
// Сумма сразу списывается с доступного баланса; при отказе возвращается.
func (s *Service) RequestPayout(ctx context.Context, p *identity.Principal, in PayoutInput) (Payout, error) {
	if err := p.Require(identity.PermPayoutsManage); err != nil {
		return Payout{}, err
	}
	if !in.Amount.Valid() || money.D(string(in.Amount)).Sign() <= 0 {
		return Payout{}, apperr.Validation("amount: сумма больше нуля")
	}
	if strings.TrimSpace(in.Requisites) == "" {
		return Payout{}, apperr.Validation("requisites: укажите карту или расчётный счёт")
	}
	var id string
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		n, err := db.NextNumber(ctx, tx, "payouts", p.NetworkID, "") // блокирует сеть
		if err != nil {
			return err
		}
		next, err := s.nextPayoutAt(ctx, tx, p.NetworkID)
		if err != nil {
			return err
		}
		if next != nil {
			return apperr.Conflict("payout_too_soon", "вывод доступен раз в неделю").
				WithDetails(map[string]any{"next_payout_at": next})
		}
		avail, err := available(ctx, tx, p.NetworkID)
		if err != nil {
			return err
		}
		if money.D(avail).Cmp(money.D(string(in.Amount))) < 0 {
			return apperr.Conflict("insufficient_balance", "на балансе недостаточно денег").
				WithDetails(map[string]any{"available": avail})
		}
		if err := tx.QueryRow(ctx, `INSERT INTO payouts (network_id, number, amount, requisites, note, requested_by)
			VALUES ($1, $2, $3::numeric, $4, $5, $6) RETURNING id`,
			p.NetworkID, n, string(in.Amount), strings.TrimSpace(in.Requisites), strings.TrimSpace(in.Note), p.EmployeeID).Scan(&id); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO balance_entries (network_id, kind, status, amount, payout_id, note)
			VALUES ($1, 'payout', 'available', -$2::numeric, $3, $4)`, p.NetworkID, string(in.Amount), id, fmt.Sprintf("Вывод №%d", n))
		return err
	})
	if err != nil {
		return Payout{}, err
	}
	out, err := s.getPayout(ctx, s.pool, id)
	if err == nil {
		s.notify.SuperAdmins(ctx, fmt.Sprintf("Заявка на вывод №%d: %s, %s сум.\nРеквизиты: %s",
			out.Number, out.NetworkName, out.Amount, out.Requisites))
	}
	return out, err
}

func (s *Service) listPayouts(ctx context.Context, networkID, status string, page httpx.Page) ([]Payout, error) {
	if status != "" && status != "requested" && status != "paid" && status != "rejected" {
		return nil, apperr.Validation("status: requested, paid или rejected")
	}
	rows, err := s.pool.Query(ctx, payoutSelect+`
		WHERE ($1 = '' OR p.network_id::text = $1) AND ($2 = '' OR p.status = $2)
		ORDER BY p.created_at DESC, p.id LIMIT $3 OFFSET $4`, networkID, status, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Payout])
}

func (s *Service) StorePayouts(ctx context.Context, p *identity.Principal, status string, page httpx.Page) ([]Payout, error) {
	if err := p.Require(identity.PermPayoutsManage); err != nil {
		return nil, err
	}
	return s.listPayouts(ctx, p.NetworkID, status, page)
}

func (s *Service) AdminPayouts(ctx context.Context, networkID, status string, page httpx.Page) ([]Payout, error) {
	if networkID != "" && !httpx.IsUUID(networkID) {
		return nil, apperr.Validation("network_id: неверный id")
	}
	return s.listPayouts(ctx, networkID, status, page)
}

// ProcessPayout — супер-админ перевёл деньги (paid) или отказал (rejected).
// При отказе сумма возвращается на баланс сети.
func (s *Service) ProcessPayout(ctx context.Context, id, status, note string) (Payout, error) {
	if status != "paid" && status != "rejected" {
		return Payout{}, apperr.Validation("status: paid или rejected")
	}
	note = strings.TrimSpace(note)
	if status == "rejected" && note == "" {
		return Payout{}, apperr.Validation("note: укажите причину отказа")
	}
	var out Payout
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		cur, err := s.getPayout(ctx, tx, id)
		if err != nil {
			return err
		}
		if err := lockNetwork(ctx, tx, cur.NetworkID); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `UPDATE payouts SET status = $2, admin_note = $3, processed_at = now()
			WHERE id = $1 AND status = 'requested'`, id, status, note)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.Conflict("already_processed", "заявка уже обработана")
		}
		if status == "rejected" {
			if _, err := tx.Exec(ctx, `DELETE FROM balance_entries WHERE payout_id = $1`, id); err != nil {
				return err
			}
		}
		out, err = s.getPayout(ctx, tx, id)
		return err
	})
	if err != nil {
		return Payout{}, err
	}
	text := fmt.Sprintf("Вывод №%d на %s сум выплачен.", out.Number, out.Amount)
	if status == "rejected" {
		text = fmt.Sprintf("Вывод №%d на %s сум отклонён: %s. Сумма вернулась на баланс.", out.Number, out.Amount, note)
	}
	s.notify.NetworkOwners(ctx, out.NetworkID, identity.PermPayoutsManage, text)
	return out, nil
}
