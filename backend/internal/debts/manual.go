package debts

// Долг вручную — «SM Магазин» → «Долги покупателей» → «Добавить должника»
// (Figma «Приложения» → «SM Магазин · Долг вручную», Р1–Р6). Старый долг
// (например, из тетради) по номеру, имени и сумме: касса, остатки и прибыль
// не меняются. Номер уже есть — сумма прибавляется к его долгу в магазине.
// Лимит и стоп-лист запись не останавливают — только помечают over_limit.

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// DocManual — запись журнала «Внесён вручную».
const DocManual = "manual"

type ManualInput struct {
	StoreID  string       `json:"store_id"`
	Phone    string       `json:"phone"`
	FullName string       `json:"full_name"`
	Amount   money.Amount `json:"amount"`
	Note     string       `json:"note"`
}

type Manual struct {
	ID        string  `json:"id"`
	Number    int64   `json:"number"`
	DebtorID  string  `json:"debtor_id"`
	Phone     string  `json:"phone"`
	FullName  string  `json:"full_name"`
	StoreID   string  `json:"store_id"`
	Amount    string  `json:"amount"`
	Balance   string  `json:"balance"` // долг в магазине после записи
	Limit     string  `json:"limit"`
	OverLimit bool    `json:"over_limit"` // сверх лимита или покупатель в стоп-листе
	Blocked   bool    `json:"blocked"`
	Created   bool    `json:"created"` // покупатель заведён этой записью
	DueDate   *string `json:"due_date"`
}

// maxManual — защита от лишних нулей при вводе.
var maxManual = money.D("1000000000")

// AddManual записывает старый долг покупателя в магазине.
func (s *Service) AddManual(ctx context.Context, p *identity.Principal, in ManualInput) (Manual, error) {
	var out Manual
	if err := p.Require(identity.PermDebtsManage); err != nil {
		return out, err
	}
	if err := s.ownStore(ctx, p, in.StoreID); err != nil {
		return out, err
	}
	ph, err := normPhone(in.Phone)
	if err != nil {
		return out, err
	}
	if !in.Amount.Valid() || money.D(string(in.Amount)).Sign() <= 0 {
		return out, apperr.Validation("amount: сумма долга должна быть больше нуля").Uz("amount: qarz summasi noldan katta boʻlishi kerak")
	}
	amount := money.D(string(in.Amount)).Round2()
	if amount.Cmp(maxManual) > 0 {
		return out, apperr.Validation("amount: слишком большая сумма").Uz("amount: summa juda katta")
	}
	in.FullName = strings.TrimSpace(in.FullName)
	in.Note = strings.TrimSpace(in.Note)
	if len([]rune(in.Note)) > 300 {
		return out, apperr.Validation("note: не длиннее 300 символов").Uz("note: 300 belgidan oshmasin")
	}
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var name string
		err := tx.QueryRow(ctx, `SELECT id, full_name FROM debtors WHERE network_id = $1 AND phone = $2`, p.NetworkID, ph).Scan(&out.DebtorID, &name)
		if errors.Is(err, pgx.ErrNoRows) {
			out.Created = true
		} else if err != nil {
			return err
		}
		if strings.TrimSpace(name) == "" && in.FullName == "" {
			return apperr.Validation("full_name: укажите имя покупателя").Uz("full_name: xaridor ismini kiriting")
		}
		if out.DebtorID, err = upsertDebtor(ctx, tx, p.NetworkID, ph, in.FullName); err != nil {
			return err
		}
		if err := lockDebtor(ctx, tx, out.DebtorID); err != nil {
			return err
		}
		limit, blocked, _, err := effectiveLimit(ctx, tx, p.NetworkID, out.DebtorID)
		if err != nil {
			return err
		}
		bal, err := storeBalance(ctx, tx, out.DebtorID, in.StoreID)
		if err != nil {
			return err
		}
		total := bal.Add(amount)
		out.OverLimit = blocked || total.Cmp(limit) > 0
		if out.Number, err = db.NextNumber(ctx, tx, "debt_manual", p.NetworkID, ""); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `
			INSERT INTO debt_manual (network_id, number, debtor_id, store_id, amount, note, over_limit, created_by)
			VALUES ($1, $2, $3, $4, $5::numeric, $6, $7, $8) RETURNING id`,
			p.NetworkID, out.Number, out.DebtorID, in.StoreID, amount.Money(), in.Note, out.OverLimit, p.EmployeeID).Scan(&out.ID); err != nil {
			return err
		}
		if _, err := addEntry(ctx, tx, p.NetworkID, out.DebtorID, in.StoreID, amount, DocManual, out.ID); err != nil {
			return err
		}
		all := money.Group(total.Money())
		return notifyBuyer(ctx, tx, ph, in.StoreID, "debt_added",
			i18n.Text{RU: "Записали в долг · %s", UZ: "Qarzga yozildi · %s"},
			i18n.Text{RU: "%s сум. Всего в этом магазине: " + all + " сум", UZ: "%s soʻm. Bu doʻkonda jami: " + all + " soʻm"}, amount)
	})
	if err != nil {
		return Manual{}, err
	}
	list, err := s.balances(ctx, s.pool, p.NetworkID, []string{in.StoreID}, &out.DebtorID, "")
	if err != nil {
		return Manual{}, err
	}
	out.StoreID, out.Amount = in.StoreID, amount.Money()
	if len(list) > 0 {
		b := list[0]
		out.Phone, out.FullName, out.Balance, out.Limit, out.Blocked, out.DueDate = b.Phone, b.FullName, b.Amount, b.Limit, b.Blocked, b.DueDate
	}
	return out, nil
}

// StoreLookup — покупатель по номеру для формы «Добавить должника»: есть ли
// он в сети, сколько должен в этом магазине и какой у него лимит.
func (s *Service) StoreLookup(ctx context.Context, p *identity.Principal, storeID, rawPhone string) (Lookup, error) {
	if err := p.Require(identity.PermDebtsManage); err != nil {
		return Lookup{}, err
	}
	if err := s.ownStore(ctx, p, storeID); err != nil {
		return Lookup{}, err
	}
	ph, err := normPhone(rawPhone)
	if err != nil {
		return Lookup{}, err
	}
	return s.lookup(ctx, p.NetworkID, storeID, ph)
}

// ownStore — магазин этой сети, доступный сотруднику.
func (s *Service) ownStore(ctx context.Context, p *identity.Principal, storeID string) error {
	errStore := apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	if !httpx.IsUUID(storeID) || !p.CanAccessStore(storeID) {
		return errStore
	}
	var ok bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM stores WHERE id = $1 AND network_id = $2)`, storeID, p.NetworkID).Scan(&ok); err != nil {
		return err
	}
	if !ok {
		return errStore
	}
	return nil
}
