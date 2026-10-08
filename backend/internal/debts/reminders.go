package debts

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Напоминания покупателям.
// В день оплаты — всегда, в 10:00 по Ташкенту (один раз на срок).
// За 3 дня до срока и на следующий день после — если включены доп. напоминания.
// Вручную — из панели или «SM Магазин», не чаще раза в сутки.

const (
	ReminderHour  = 10
	manualEvery   = 24 * time.Hour
	beforeDueDays = 3
)

var reminderTexts = map[string]struct{ title, body i18n.Text }{
	"before": {
		i18n.Text{RU: "Срок оплаты долга через 3 дня · %s", UZ: "Qarzni toʻlash muddatiga 3 kun qoldi · %s"},
		i18n.Text{RU: "Ваш долг %s сум. Погасите его в магазине до срока", UZ: "Qarzingiz %s soʻm. Uni muddatigacha doʻkonda toʻlang"},
	},
	"due": {
		i18n.Text{RU: "Сегодня день оплаты долга · %s", UZ: "Bugun qarzni toʻlash kuni · %s"},
		i18n.Text{RU: "Ваш долг %s сум — погасите его сегодня в магазине", UZ: "Qarzingiz %s soʻm — uni bugun doʻkonda toʻlang"},
	},
	"overdue": {
		i18n.Text{RU: "Долг просрочен · %s", UZ: "Qarz muddati oʻtdi · %s"},
		i18n.Text{RU: "Ваш долг %s сум. Срок оплаты прошёл — погасите долг в магазине", UZ: "Qarzingiz %s soʻm. Toʻlov muddati oʻtdi — qarzni doʻkonda toʻlang"},
	},
	"manual": {
		i18n.Text{RU: "Напоминание · %s", UZ: "Eslatma · %s"},
		i18n.Text{RU: "Ваш долг %s сум. Пожалуйста, погасите долг в магазине", UZ: "Qarzingiz %s soʻm. Iltimos, qarzni doʻkonda toʻlang"},
	},
}

// Tick — работа воркера: автоматические напоминания.
func (s *Service) Tick(ctx context.Context) error {
	now := s.now().In(tashkent)
	if now.Hour() < ReminderHour || now.Hour() >= 22 {
		return nil
	}
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	rows, err := s.pool.Query(ctx, `SELECT DISTINCT network_id FROM debt_entries`)
	if err != nil {
		return err
	}
	networks, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	for _, n := range networks {
		if err := s.remindNetwork(ctx, n, today); err != nil {
			s.log.Error("напоминания о долгах: ошибка", "network_id", n, "err", err)
		}
	}
	return nil
}

func (s *Service) remindNetwork(ctx context.Context, networkID string, today time.Time) error {
	st, err := loadSettings(ctx, s.pool, networkID)
	if err != nil {
		return err
	}
	list, err := s.balances(ctx, s.pool, networkID, nil, nil, "b.amount > 0 AND b.since IS NOT NULL")
	if err != nil {
		return err
	}
	for _, b := range list {
		if b.DueDate == nil {
			continue
		}
		due, err := time.Parse("2006-01-02", *b.DueDate)
		if err != nil {
			continue
		}
		var kind string
		switch {
		case due.Equal(today):
			kind = "due"
		case st.ExtraReminders && due.AddDate(0, 0, -beforeDueDays).Equal(today):
			kind = "before"
		case st.ExtraReminders && due.AddDate(0, 0, 1).Equal(today):
			kind = "overdue"
		default:
			continue
		}
		err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
			tag, err := tx.Exec(ctx, `
				INSERT INTO debt_reminders (network_id, debtor_id, store_id, kind, due_date) VALUES ($1, $2, $3, $4, $5)
				ON CONFLICT DO NOTHING`, networkID, b.DebtorID, b.StoreID, kind, *b.DueDate)
			if err != nil || tag.RowsAffected() == 0 {
				return err
			}
			t := reminderTexts[kind]
			return notifyBuyer(ctx, tx, b.Phone, b.StoreID, "debt_reminder", t.title, t.body, money.D(b.Amount))
		})
		if err != nil {
			return err
		}
	}
	return nil
}

type RemindInput struct {
	StoreID string `json:"store_id"`
}

type Reminded struct {
	SentAt time.Time `json:"sent_at"`
	// Когда можно отправить следующее.
	NextAt time.Time `json:"next_at"`
}

// Remind — ручное напоминание об оплате. Не чаще раза в сутки по паре
// «покупатель — магазин»; без приложения у покупателя — 409 no_app.
func (s *Service) Remind(ctx context.Context, p *identity.Principal, debtorID string, in RemindInput) (Reminded, error) {
	var out Reminded
	if err := p.Require(identity.PermDebtsManage); err != nil {
		return out, err
	}
	if !httpx.IsUUID(debtorID) {
		return out, apperr.NotFound("покупатель не найден").Uz("xaridor topilmadi")
	}
	if !httpx.IsUUID(in.StoreID) || !p.CanAccessStore(in.StoreID) {
		return out, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var ph string
		err := tx.QueryRow(ctx, `SELECT phone FROM debtors WHERE id = $1 AND network_id = $2 FOR UPDATE`, debtorID, p.NetworkID).Scan(&ph)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.NotFound("покупатель не найден").Uz("xaridor topilmadi")
		}
		if err != nil {
			return err
		}
		bal, err := storeBalance(ctx, tx, debtorID, in.StoreID)
		if err != nil {
			return err
		}
		if bal.Sign() <= 0 {
			return apperr.Conflict("no_debt", "у покупателя нет долга в этом магазине").Uz("xaridorning bu doʻkonda qarzi yoʻq")
		}
		app, err := hasApp(ctx, tx, ph)
		if err != nil {
			return err
		}
		if !app {
			return apperr.Conflict("no_app", "у покупателя нет приложения Super Market — позвоните ему").Uz("xaridorda Super Market ilovasi yoʻq — unga qoʻngʻiroq qiling")
		}
		var last *time.Time
		if err := tx.QueryRow(ctx, `SELECT max(created_at) FROM debt_reminders WHERE debtor_id = $1 AND store_id = $2 AND kind = 'manual'`,
			debtorID, in.StoreID).Scan(&last); err != nil {
			return err
		}
		now := s.now()
		if last != nil && now.Sub(*last) < manualEvery {
			next := last.Add(manualEvery)
			return apperr.Conflict("too_soon", "напоминание уже отправлялось — следующее можно после "+next.In(tashkent).Format("02.01 15:04")).Uz("eslatma allaqachon yuborilgan — keyingisini " + next.In(tashkent).Format("02.01 15:04") + " dan keyin yuborish mumkin").
				WithDetails(map[string]any{"next_at": next})
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO debt_reminders (network_id, debtor_id, store_id, kind, due_date, created_by)
			VALUES ($1, $2, $3, 'manual', ($4::timestamptz AT TIME ZONE 'Asia/Tashkent')::date, $5)`,
			p.NetworkID, debtorID, in.StoreID, now, p.EmployeeID); err != nil {
			return err
		}
		t := reminderTexts["manual"]
		out = Reminded{SentAt: now, NextAt: now.Add(manualEvery)}
		return notifyBuyer(ctx, tx, ph, in.StoreID, "debt_reminder", t.title, t.body, bal)
	})
	return out, err
}
