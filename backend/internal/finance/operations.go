package finance

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// ------------------------------------------------------- кассовые операции

type CashOperation struct {
	ID               string    `json:"id"`
	Number           int64     `json:"number"`
	Kind             string    `json:"kind"`
	CashboxID        string    `json:"cashbox_id"`
	CashboxName      string    `json:"cashbox_name"`
	Currency         string    `json:"currency"`
	Amount           string    `json:"amount"`
	AmountUZS        string    `json:"amount_uzs"`
	Rate             *string   `json:"rate"`
	CounterpartyID   *string   `json:"counterparty_id"`
	CounterpartyName *string   `json:"counterparty_name"`
	ReasonID         *string   `json:"reason_id"`
	ReasonName       *string   `json:"reason_name"`
	Note             string    `json:"note"`
	CreatedBy        string    `json:"created_by"`
	CreatedAt        time.Time `json:"created_at"`
}

const cashOpSelect = `
	SELECT o.id, o.number, o.kind, o.cashbox_id, c.name, c.currency, o.amount::text, o.amount_uzs::text,
	       o.rate::text, o.counterparty_id, cp.name, o.reason_id, r.name, o.note, e.full_name, o.created_at
	FROM cash_operations o
	JOIN cashboxes c ON c.id = o.cashbox_id
	JOIN employees e ON e.id = o.created_by
	LEFT JOIN counterparties cp ON cp.id = o.counterparty_id
	LEFT JOIN financial_reasons r ON r.id = o.reason_id`

type CashOpFilter struct {
	CashboxID string
	From, To  *time.Time
	Page      httpx.Page
}

func (s *Service) ListCashOperations(ctx context.Context, p *identity.Principal, f CashOpFilter) ([]CashOperation, error) {
	rows, err := s.pool.Query(ctx, cashOpSelect+`
		WHERE o.network_id = $1 AND ($2 OR c.store_id = ANY($3::uuid[]))
		  AND ($4 = '' OR o.cashbox_id::text = $4)
		  AND ($5::timestamptz IS NULL OR o.created_at >= $5) AND ($6::timestamptz IS NULL OR o.created_at < $6)
		ORDER BY o.created_at DESC LIMIT $7 OFFSET $8`,
		p.NetworkID, p.SeesAllStores(), p.StoreIDs, f.CashboxID, f.From, f.To, f.Page.Limit, f.Page.Offset)
	return many[CashOperation](rows, err)
}

type CashOperationInput struct {
	Kind           string       `json:"kind"`
	CashboxID      string       `json:"cashbox_id"`
	Amount         money.Amount `json:"amount"`
	CounterpartyID *string      `json:"counterparty_id"`
	ReasonID       *string      `json:"reason_id"`
	Note           string       `json:"note"`
}

// CreateCashOperation — приход или расход по кассе. С контрагентом —
// оплата поставщику (расход) или деньги от контрагента (приход); без
// него — по финансовой причине (аренда, зарплата, ...).
func (s *Service) CreateCashOperation(ctx context.Context, p *identity.Principal, in CashOperationInput) (CashOperation, error) {
	if err := p.Require(identity.PermFinanceManage); err != nil {
		return CashOperation{}, err
	}
	if in.Kind != "income" && in.Kind != "expense" {
		return CashOperation{}, apperr.Validation("kind: ожидается income или expense").Uz("kind: income yoki expense boʻlishi kerak")
	}
	if !httpx.IsUUID(in.CashboxID) {
		return CashOperation{}, apperr.Validation("cashbox_id: касса не найдена").Uz("cashbox_id: kassa topilmadi")
	}
	if !in.Amount.Valid() || strings.Trim(string(in.Amount), "0.") == "" {
		return CashOperation{}, apperr.Validation("amount: сумма должна быть больше нуля").Uz("amount: summa noldan katta boʻlishi kerak")
	}
	if in.CounterpartyID == nil && in.ReasonID == nil {
		return CashOperation{}, apperr.Validation("укажите контрагента или финансовую причину").Uz("kontragent yoki moliyaviy sababni tanlang")
	}
	for name, id := range map[string]*string{"counterparty_id": in.CounterpartyID, "reason_id": in.ReasonID} {
		if id != nil && !httpx.IsUUID(*id) {
			return CashOperation{}, apperr.Validation(name + ": запись не найдена").Uz(name + ": yozuv topilmadi")
		}
	}

	var id string
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		cb, err := lockCashbox(ctx, tx, p.NetworkID, in.CashboxID)
		if err != nil {
			return err
		}
		if !cb.IsActive || !canUseCashbox(p, cb) {
			return apperr.Validation("cashbox_id: касса не найдена или отключена").Uz("cashbox_id: kassa topilmadi yoki oʻchirilgan")
		}
		if in.CounterpartyID != nil {
			if err := CheckCounterparty(ctx, tx, p.NetworkID, *in.CounterpartyID); err != nil {
				return err
			}
		}
		if in.ReasonID != nil {
			var kind string
			var active bool
			err := tx.QueryRow(ctx, `SELECT kind, is_active FROM financial_reasons WHERE id = $1 AND network_id = $2`,
				*in.ReasonID, p.NetworkID).Scan(&kind, &active)
			if errors.Is(err, pgx.ErrNoRows) || (err == nil && (!active || kind != in.Kind)) {
				return apperr.Validation("reason_id: причина не найдена или другого вида").Uz("reason_id: sabab topilmadi yoki boshqa turdagi")
			}
			if err != nil {
				return err
			}
		}

		// Сумма в UZS: для долларовой кассы — по текущему курсу.
		var rate *string
		amountUZS := string(in.Amount)
		if cb.Currency == "USD" {
			r, err := CurrentRate(ctx, tx, p.NetworkID)
			if err != nil {
				return err
			}
			rate = &r
			if err := tx.QueryRow(ctx, `SELECT round($1::numeric * $2::numeric, 2)::text`, string(in.Amount), r).Scan(&amountUZS); err != nil {
				return err
			}
		}

		n, err := db.NextNumber(ctx, tx, "cash_operations", p.NetworkID, "")
		if err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `
			INSERT INTO cash_operations (network_id, number, kind, cashbox_id, amount, amount_uzs, rate,
			                             counterparty_id, reason_id, note, created_by)
			VALUES ($1, $2, $3, $4, $5::numeric, $6::numeric, $7::numeric, $8, $9, $10, $11) RETURNING id`,
			p.NetworkID, n, in.Kind, cb.ID, string(in.Amount), amountUZS, rate,
			in.CounterpartyID, in.ReasonID, strings.TrimSpace(in.Note), p.EmployeeID).Scan(&id); err != nil {
			return err
		}

		if in.Kind == "income" {
			err = AddCash(ctx, tx, p.NetworkID, cb.ID, string(in.Amount), DocCashOperation, id)
		} else {
			err = SubtractCash(ctx, tx, p.NetworkID, cb.ID, string(in.Amount), DocCashOperation, id)
		}
		if err != nil {
			return err
		}
		if in.CounterpartyID != nil {
			// Платим поставщику — наш долг уменьшается; получаем — растёт.
			sign := "-"
			if in.Kind == "income" {
				sign = ""
			}
			return AddCounterparty(ctx, tx, p.NetworkID, *in.CounterpartyID, sign+amountUZS, DocCashOperation, id)
		}
		return nil
	})
	if err != nil {
		return CashOperation{}, err
	}
	rows, err := s.pool.Query(ctx, cashOpSelect+` WHERE o.id = $1`, id)
	return one[CashOperation](rows, err, i18n.Text{RU: "операция не найдена", UZ: "operatsiya topilmadi"})
}

func canUseCashbox(p *identity.Principal, cb cashboxRef) bool {
	if cb.StoreID == nil {
		return p.SeesAllStores()
	}
	return p.CanAccessStore(*cb.StoreID)
}

// ------------------------------------------ из кассы в кассу, сдача кассы

type CashTransfer struct {
	ID           string    `json:"id"`
	Number       int64     `json:"number"`
	Kind         string    `json:"kind"`
	FromID       string    `json:"from_id"`
	FromName     string    `json:"from_name"`
	FromCurrency string    `json:"from_currency"`
	ToID         string    `json:"to_id"`
	ToName       string    `json:"to_name"`
	ToCurrency   string    `json:"to_currency"`
	AmountFrom   string    `json:"amount_from"`
	AmountTo     string    `json:"amount_to"`
	Rate         *string   `json:"rate"`
	Note         string    `json:"note"`
	CreatedBy    string    `json:"created_by"`
	CreatedAt    time.Time `json:"created_at"`
}

const transferSelect = `
	SELECT t.id, t.number, t.kind, t.from_id, f.name, f.currency, t.to_id, d.name, d.currency,
	       t.amount_from::text, t.amount_to::text, t.rate::text, t.note, e.full_name, t.created_at
	FROM cash_transfers t
	JOIN cashboxes f ON f.id = t.from_id
	JOIN cashboxes d ON d.id = t.to_id
	JOIN employees e ON e.id = t.created_by`

func (s *Service) ListTransfers(ctx context.Context, p *identity.Principal, kind string, page httpx.Page) ([]CashTransfer, error) {
	rows, err := s.pool.Query(ctx, transferSelect+`
		WHERE t.network_id = $1 AND ($2 OR f.store_id = ANY($3::uuid[]) OR d.store_id = ANY($3::uuid[]))
		  AND ($4 = '' OR t.kind = $4)
		ORDER BY t.created_at DESC LIMIT $5 OFFSET $6`,
		p.NetworkID, p.SeesAllStores(), p.StoreIDs, kind, page.Limit, page.Offset)
	return many[CashTransfer](rows, err)
}

type TransferInput struct {
	FromID string       `json:"from_id"`
	ToID   string       `json:"to_id"` // для сдачи кассы можно не указывать — главная касса в той же валюте
	Amount money.Amount `json:"amount"`
	Note   string       `json:"note"`
}

// CreateTransfer: kind = transfer (из кассы в кассу) или handover (сдача
// кассы магазина в главную кассу). Между валютами — по текущему курсу.
func (s *Service) CreateTransfer(ctx context.Context, p *identity.Principal, kind string, in TransferInput) (CashTransfer, error) {
	if err := p.Require(identity.PermFinanceManage); err != nil {
		return CashTransfer{}, err
	}
	if !httpx.IsUUID(in.FromID) || (in.ToID != "" && !httpx.IsUUID(in.ToID)) {
		return CashTransfer{}, apperr.Validation("касса не найдена").Uz("kassa topilmadi")
	}
	if !in.Amount.Valid() || strings.Trim(string(in.Amount), "0.") == "" {
		return CashTransfer{}, apperr.Validation("amount: сумма должна быть больше нуля").Uz("amount: summa noldan katta boʻlishi kerak")
	}

	var id string
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		from, err := lockCashbox(ctx, tx, p.NetworkID, in.FromID)
		if err != nil {
			return err
		}
		if !from.IsActive || !canUseCashbox(p, from) {
			return apperr.Validation("from_id: касса не найдена или отключена").Uz("from_id: kassa topilmadi yoki oʻchirilgan")
		}
		toID := in.ToID
		if kind == "handover" {
			if from.IsMain {
				return apperr.Validation("from_id: сдают кассу магазина, а не главную").Uz("from_id: asosiy kassani emas, doʻkon kassasini topshirish kerak")
			}
			if toID == "" {
				err := tx.QueryRow(ctx, `SELECT id FROM cashboxes WHERE network_id = $1 AND is_main AND currency = $2`,
					p.NetworkID, from.Currency).Scan(&toID)
				if errors.Is(err, pgx.ErrNoRows) {
					return apperr.Validation("нет главной кассы в валюте " + from.Currency).Uz(from.Currency + " valyutasida asosiy kassa yoʻq")
				}
				if err != nil {
					return err
				}
			}
		} else if toID == "" {
			return apperr.Validation("to_id: обязательное поле").Uz("to_id: majburiy maydon")
		}
		if toID == from.ID {
			return apperr.Validation("кассы должны быть разными").Uz("kassalar har xil boʻlishi kerak")
		}
		to, err := lockCashbox(ctx, tx, p.NetworkID, toID)
		if err != nil {
			return err
		}
		if !to.IsActive {
			return apperr.Validation("to_id: касса отключена").Uz("to_id: kassa oʻchirilgan")
		}
		if kind == "handover" && !to.IsMain {
			return apperr.Validation("to_id: сдача кассы — только в главную кассу").Uz("to_id: kassa faqat asosiy kassaga topshiriladi")
		}
		// Сдавать в главную может кассир без доступа к ней; в прочие кассы — только с доступом.
		if kind == "transfer" && !canUseCashbox(p, to) {
			return apperr.Validation("to_id: касса не найдена").Uz("to_id: kassa topilmadi")
		}

		amountTo := string(in.Amount)
		var rate *string
		if from.Currency != to.Currency {
			r, err := CurrentRate(ctx, tx, p.NetworkID)
			if err != nil {
				return err
			}
			rate = &r
			q := `SELECT round($1::numeric * $2::numeric, 2)::text` // USD → UZS
			if from.Currency == "UZS" {
				q = `SELECT round($1::numeric / $2::numeric, 2)::text` // UZS → USD
			}
			if err := tx.QueryRow(ctx, q, string(in.Amount), r).Scan(&amountTo); err != nil {
				return err
			}
			if strings.Trim(amountTo, "0.") == "" {
				return apperr.Validation("amount: слишком маленькая сумма для перевода по курсу").Uz("amount: kurs boʻyicha oʻtkazish uchun summa juda kichik")
			}
		}

		n, err := db.NextNumber(ctx, tx, "cash_transfers", p.NetworkID, "")
		if err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `
			INSERT INTO cash_transfers (network_id, number, kind, from_id, to_id, amount_from, amount_to, rate, note, created_by)
			VALUES ($1, $2, $3, $4, $5, $6::numeric, $7::numeric, $8::numeric, $9, $10) RETURNING id`,
			p.NetworkID, n, kind, from.ID, to.ID, string(in.Amount), amountTo, rate,
			strings.TrimSpace(in.Note), p.EmployeeID).Scan(&id); err != nil {
			return err
		}
		if err := SubtractCash(ctx, tx, p.NetworkID, from.ID, string(in.Amount), DocCashTransfer, id); err != nil {
			return err
		}
		return AddCash(ctx, tx, p.NetworkID, to.ID, amountTo, DocCashTransfer, id)
	})
	if err != nil {
		return CashTransfer{}, err
	}
	rows, err := s.pool.Query(ctx, transferSelect+` WHERE t.id = $1`, id)
	return one[CashTransfer](rows, err, i18n.Text{RU: "перемещение не найдено", UZ: "oʻtkazma topilmadi"})
}

// ----------------------------------------------------- движение по кассе

type CashEntry struct {
	Amount    string    `json:"amount"`
	DocType   string    `json:"doc_type"`
	DocID     string    `json:"doc_id"`
	CreatedAt time.Time `json:"created_at"`
}

// CashboxEntries — выписка по кассе.
func (s *Service) CashboxEntries(ctx context.Context, p *identity.Principal, id string, page httpx.Page) ([]CashEntry, error) {
	if _, err := s.getCashbox(ctx, s.pool, p, id); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `SELECT amount::text, doc_type, doc_id, created_at FROM cash_entries
		WHERE cashbox_id = $1 ORDER BY created_at DESC, id DESC LIMIT $2 OFFSET $3`, id, page.Limit, page.Offset)
	return many[CashEntry](rows, err)
}

// CounterpartyEntries — акт сверки с контрагентом.
func (s *Service) CounterpartyEntries(ctx context.Context, p *identity.Principal, id string, page httpx.Page) ([]CashEntry, error) {
	if _, err := s.GetCounterparty(ctx, p, id); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `SELECT amount::text, doc_type, doc_id, created_at FROM counterparty_entries
		WHERE counterparty_id = $1 ORDER BY created_at DESC, id DESC LIMIT $2 OFFSET $3`, id, page.Limit, page.Offset)
	return many[CashEntry](rows, err)
}
