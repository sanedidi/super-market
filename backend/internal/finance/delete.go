package finance

import (
	"context"
	"net/http"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Удаление справочников финансов: только если запись нигде не используется,
// иначе 409 in_use — веб предложит «Отключить» (Figma «Веб-панели · удаление»).

func (s *Service) DeleteCounterpartyType(ctx context.Context, p *identity.Principal, id string) error {
	if err := p.Require(identity.PermCounterpartiesManage); err != nil {
		return err
	}
	return db.Remove(ctx, s.pool, "Тип контрагента", true,
		`DELETE FROM counterparty_types WHERE id = $1 AND network_id = $2`, id, p.NetworkID)
}

func (s *Service) DeleteCounterparty(ctx context.Context, p *identity.Principal, id string) error {
	if err := p.Require(identity.PermCounterpartiesManage); err != nil {
		return err
	}
	return db.Remove(ctx, s.pool, "Контрагент", true,
		`DELETE FROM counterparties WHERE id = $1 AND network_id = $2`, id, p.NetworkID)
}

func (s *Service) DeleteReason(ctx context.Context, p *identity.Principal, id string) error {
	if err := p.Require(identity.PermFinanceManage); err != nil {
		return err
	}
	return db.Remove(ctx, s.pool, "Причина", true,
		`DELETE FROM financial_reasons WHERE id = $1 AND network_id = $2`, id, p.NetworkID)
}

func (s *Service) DeleteCashbox(ctx context.Context, p *identity.Principal, id string) error {
	if err := p.Require(identity.PermFinanceManage); err != nil {
		return err
	}
	// Главную кассу сети не удаляем: в неё сдают выручку магазины.
	var main bool
	if err := s.pool.QueryRow(ctx, `SELECT is_main FROM cashboxes WHERE id = $1 AND network_id = $2`, id, p.NetworkID).Scan(&main); err == nil && main {
		return apperr.Conflict("main_cashbox", "Главную кассу сети удалить нельзя — в неё сдают выручку магазины")
	}
	return db.Remove(ctx, s.pool, "Касса", true,
		`DELETE FROM cashboxes WHERE id = $1 AND network_id = $2 AND NOT is_main`, id, p.NetworkID)
}

func (s *Service) DeletePaymentMethod(ctx context.Context, p *identity.Principal, id string) error {
	if err := p.Require(identity.PermFinanceManage); err != nil {
		return err
	}
	return db.Remove(ctx, s.pool, "Способ оплаты", true,
		`DELETE FROM payment_methods WHERE id = $1 AND network_id = $2`, id, p.NetworkID)
}

func (m *Module) del(fn func(context.Context, *identity.Principal, string) error) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		httpx.Delete(w, r, m.log, func(id string) error { return fn(r.Context(), pr(r), id) })
	}
}
