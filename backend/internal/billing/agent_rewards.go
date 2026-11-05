package billing

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// AgentRewardPercent — доля агента «SM Агент» с первой оплаты подписки
// магазина, который подключили по его заявке (store_leads).
const AgentRewardPercent = 50

// SettleAgentRewards начисляет агентам их долю с первых оплаченных счетов
// магазинов, подключённых по заявкам. Сумма — от реально оплаченного счёта
// (зависит от тарифа магазина). Начисление разовое: rewarded_at.
// Деньги — на баланс агента (available): автосписание гасит ими подписку
// агента, остаток агент выводит.
func (s *Service) SettleAgentRewards(ctx context.Context) error {
	type reward struct{ agent, store, amount string }
	var done []reward
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT l.id, l.agent_network_id, COALESCE(n.name, l.name), i.id,
			       round(i.amount_uzs * $1 / 100, 2)::text
			FROM store_leads l
			JOIN networks n ON n.id = l.network_id
			JOIN LATERAL (
				SELECT id, amount_uzs FROM subscription_invoices
				WHERE network_id = l.network_id AND status = 'paid' AND amount_uzs > 0
				ORDER BY paid_at, period LIMIT 1) i ON true
			WHERE l.status = 'connected' AND l.rewarded_at IS NULL
			ORDER BY l.agent_network_id
			FOR UPDATE OF l SKIP LOCKED`, AgentRewardPercent)
		if err != nil {
			return err
		}
		type due struct{ lead, agent, store, invoice, amount string }
		list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (due, error) {
			var d due
			err := r.Scan(&d.lead, &d.agent, &d.store, &d.invoice, &d.amount)
			return d, err
		})
		if err != nil {
			return err
		}
		for _, d := range list {
			if err := lockNetwork(ctx, tx, d.agent); err != nil {
				return err
			}
			if money.D(d.amount).Sign() > 0 {
				if _, err := tx.Exec(ctx, `INSERT INTO balance_entries (network_id, kind, status, amount, note)
					VALUES ($1, 'agent_reward', 'available', $2::numeric, $3)`,
					d.agent, d.amount, fmt.Sprintf("%d%% первой оплаты магазина «%s»", AgentRewardPercent, d.store)); err != nil {
					return err
				}
			}
			if _, err := tx.Exec(ctx, `UPDATE store_leads SET reward_invoice_id = $2, reward_amount = $3::numeric, rewarded_at = now()
				WHERE id = $1`, d.lead, d.invoice, d.amount); err != nil {
				return err
			}
			done = append(done, reward{d.agent, d.store, d.amount})
		}
		return nil
	})
	if err != nil {
		return err
	}
	if s.notify == nil {
		return nil
	}
	for _, r := range done {
		s.notify.NetworkOwners(ctx, r.agent, identity.PermPayoutsManage, i18n.Text{
			RU: fmt.Sprintf("«%s» оплатил подписку\nВам начислено %s сум — %d%% первой оплаты. Деньги на балансе Super Market.",
				r.store, money.Group(r.amount), AgentRewardPercent),
			UZ: fmt.Sprintf("«%s» obunani toʻladi\nSizga %s soʻm hisoblandi — birinchi toʻlovning %d%%. Pul Super Market balansida.",
				r.store, money.Group(r.amount), AgentRewardPercent),
		})
	}
	return nil
}

// settleAgentRewards — после оплаты счёта: ошибка начисления не отменяет оплату
// (следующий тик worker-а начислит).
func (s *Service) settleAgentRewards(ctx context.Context) {
	if err := s.SettleAgentRewards(ctx); err != nil {
		s.log.Error("начисление агентам", "err", err)
	}
}
