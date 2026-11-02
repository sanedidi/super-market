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
	// «Ожидает сдачи» (Figma М1): сколько отложено владельцу и в скольких
	// конвертах (закрытых днях).
	PendingTotal string `json:"pending_total"`
	PendingCount int    `json:"pending_count"`
	// Настройки кассы магазина (М6): норма размена (null — не задана) и
	// пересчёт ящика (null — не требовать).
	CashFloat        *string `json:"cash_float"`
	RecountEveryDays *int    `json:"recount_every_days"`
	// Деньги копятся в ящике (М4): размен больше нормы ×3, а без нормы —
	// больше выручки последнего закрытого дня. Пора «Пересчитать ящик».
	FloatWarning bool `json:"float_warning"`
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
	if err := s.pool.QueryRow(ctx, `SELECT COALESCE(sum(amount), 0)::numeric(18,2)::text, count(*)::int FROM pending_handovers
		WHERE cashbox_id = $1 AND accepted_at IS NULL`, cb).Scan(&out.PendingTotal, &out.PendingCount); err != nil {
		return out, err
	}
	var lastSales *string
	if err := s.pool.QueryRow(ctx, `
		SELECT st.cash_float::text, st.recount_every_days,
		       (SELECT COALESCE(sum(sl.total), 0)::text FROM sales sl WHERE sl.shift_id = (
		          SELECT sh.id FROM pos_shifts sh WHERE sh.store_id = st.id AND sh.closed_at IS NOT NULL ORDER BY sh.closed_at DESC LIMIT 1))
		FROM stores st WHERE st.id = $1`, storeID).Scan(&out.CashFloat, &out.RecountEveryDays, &lastSales); err != nil {
		return out, err
	}
	// Размен: у открытых смен — что ввели на начало (но не больше, чем в
	// ящике сейчас: после пересчёта предупреждение уходит), без смены — что в ящике.
	base := amount
	if len(out.Shifts) > 0 {
		opening := money.D("0")
		for _, sh := range out.Shifts {
			opening = opening.Add(money.D(sh.OpeningCash))
		}
		base = opening.Min(amount)
	}
	switch {
	case out.CashFloat != nil:
		f := money.D(*out.CashFloat)
		out.FloatWarning = f.Sign() > 0 && base.Cmp(f.Mul(money.D("3"))) > 0
	case lastSales != nil:
		ls := money.D(*lastSales)
		out.FloatWarning = ls.Sign() > 0 && base.Cmp(ls) > 0
	}
	return out, nil
}
