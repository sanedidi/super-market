package pos

import (
	"context"

	"github.com/sanedidi/super-market/backend/internal/finance"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Drawer — наличные в ящике магазина (Figma «Финансы понятно», Ф1): по
// открытым сменам — размен + наличные продажи ± внесения и изъятия, как
// «Должно быть» в X-отчёте; без смены — что оставили на размен при сдаче.
// Терминал — отдельно: эти деньги на счёте, не в ящике.
type Drawer struct {
	CashboxID   string `json:"cashbox_id"`
	CashboxName string `json:"cashbox_name"`
	// Наличными в ящике сейчас.
	Amount string `json:"amount"`
	// Остаток кассы магазина по учёту (без смены — то же, что amount).
	Ledger string `json:"ledger"`
	// Терминал и QR за открытые смены — на счёт в банке.
	Card string `json:"card"`
	// Открытые смены с X-отчётом (расшифровка суммы).
	Shifts []Shift `json:"shifts"`
}

func (s *Service) Drawer(ctx context.Context, p *identity.Principal, storeID string) (Drawer, error) {
	out := Drawer{Shifts: []Shift{}}
	if err := p.Require(identity.PermFinanceManage); err != nil {
		return out, err
	}
	if !httpx.IsUUID(storeID) || !p.CanAccessStore(storeID) {
		return out, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	cb, err := finance.StoreCashbox(ctx, s.pool, p.NetworkID, storeID)
	if err != nil {
		return out, err
	}
	if cb == "" {
		return out, apperr.NotFound("у магазина нет кассы наличных").Uz("doʻkonda naqd pul kassasi yoʻq")
	}
	out.CashboxID = cb
	if err := s.pool.QueryRow(ctx, `SELECT name FROM cashboxes WHERE id = $1`, cb).Scan(&out.CashboxName); err != nil {
		return out, err
	}
	amount, shifts, err := finance.DrawerCash(ctx, s.pool, p.NetworkID, storeID, cb)
	if err != nil {
		return out, err
	}
	ledger, err := finance.CashBalance(ctx, s.pool, cb)
	if err != nil {
		return out, err
	}
	out.Amount, out.Ledger = amount.Money(), ledger.Money()
	card := money.D("0")
	for _, o := range shifts {
		sh, err := s.ShiftWithReport(ctx, p, o.ID)
		if err != nil {
			return out, err
		}
		if sh.Report != nil {
			for _, m := range sh.Report.ByMethod {
				if m.Kind != "cash" {
					card = card.Add(money.D(m.Sales)).Sub(money.D(m.Returns))
				}
			}
		}
		out.Shifts = append(out.Shifts, sh)
	}
	out.Card = card.Money()
	return out, nil
}
