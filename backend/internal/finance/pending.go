package finance

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
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
	"github.com/sanedidi/super-market/backend/internal/push"
)

// «К сдаче» → «Принято» (Figma «SM Магазин · Касса: норма размена…», М1–М5).
//
// «Закрыть день» оставляет в ящике норму размена магазина, остальное кассир
// откладывает в конверт для владельца — это «К сдаче» (pending_handovers).
// По учёту конверт ещё в кассе магазина, но не в ящике: размен следующего
// дня = остаток кассы − «К сдаче». Владелец нажимает «Принял» — сдача кассы
// в главную кассу; получил меньше — недостача смены того кассира.

// PendingHandover — конверт одного закрытого дня.
type PendingHandover struct {
	ID          string     `json:"id"`
	StoreID     string     `json:"store_id"`
	StoreName   string     `json:"store_name"`
	ShiftID     string     `json:"shift_id"`
	ShiftNumber int64      `json:"shift_number"`
	DeviceName  string     `json:"device_name"`
	ClosedBy    *string    `json:"closed_by_name"`
	ClosedAt    *time.Time `json:"closed_at"`
	ClosedVia   *string    `json:"closed_via"`
	SalesCount  int        `json:"sales_count"`
	// Отложено владельцу и сколько осталось в ящике на размен.
	Amount     string    `json:"amount"`
	LeftAmount string    `json:"left_amount"`
	CreatedAt  time.Time `json:"created_at"`
	// Принято: кто и когда, сколько получил, недостача (плюс — не хватило,
	// минус — лишнее). null — ещё «К сдаче».
	AcceptedAt     *time.Time `json:"accepted_at"`
	AcceptedByName *string    `json:"accepted_by_name"`
	Received       *string    `json:"received"`
	Shortage       *string    `json:"shortage"`
	TransferID     *string    `json:"transfer_id"`
}

const pendingSelect = `
	SELECT ph.id, ph.store_id, st.name, ph.shift_id, sh.number, d.name, ce.full_name, sh.closed_at, sh.closed_via,
	       (SELECT count(*) FROM sales WHERE shift_id = sh.id)::int,
	       ph.amount::text, ph.left_amount::text, ph.created_at, ph.accepted_at, ae.full_name,
	       ph.received::text, ph.shortage::text, ph.transfer_id
	FROM pending_handovers ph
	JOIN stores st ON st.id = ph.store_id
	JOIN pos_shifts sh ON sh.id = ph.shift_id
	JOIN pos_devices d ON d.id = sh.device_id
	LEFT JOIN employees ce ON ce.id = sh.closed_by
	LEFT JOIN employees ae ON ae.id = ph.accepted_by`

func scanPending(r pgx.CollectableRow) (PendingHandover, error) {
	var x PendingHandover
	err := r.Scan(&x.ID, &x.StoreID, &x.StoreName, &x.ShiftID, &x.ShiftNumber, &x.DeviceName, &x.ClosedBy, &x.ClosedAt,
		&x.ClosedVia, &x.SalesCount, &x.Amount, &x.LeftAmount, &x.CreatedAt, &x.AcceptedAt, &x.AcceptedByName,
		&x.Received, &x.Shortage, &x.TransferID)
	return x, err
}

// ShiftClosedHandover — день закрыт (в транзакции закрытия смены): в ящике
// остаётся размен по норме магазина (или leave — кассир поменял на этот раз,
// F3), остальное — «К сдаче». Нормы нет и leave не прислали — как раньше:
// в ящике остаётся всё. counted — сколько в ящике этой кассы на закрытии.
// Возвращает отложенную сумму (nil — ничего не откладывали).
func ShiftClosedHandover(ctx context.Context, tx pgx.Tx, networkID, storeID, shiftID string, counted money.Dec, leave *money.Dec) (*money.Dec, error) {
	var float *string
	if err := tx.QueryRow(ctx, `SELECT cash_float::text FROM stores WHERE id = $1`, storeID).Scan(&float); err != nil {
		return nil, err
	}
	if leave == nil {
		if float == nil {
			return nil, nil
		}
		f := money.D(*float)
		leave = &f
	}
	if counted.Sign() < 0 {
		counted = money.D("0")
	}
	left := *leave
	if left.Sign() < 0 {
		left = money.D("0")
	}
	if left.Cmp(counted) > 0 {
		left = counted
	}
	cb, err := StoreCashbox(ctx, tx, networkID, storeID)
	if err != nil || cb == "" {
		return nil, err
	}
	// Других открытых смен в магазине нет — учёт кассы выравниваем по ящику:
	// в ящике ровно то, что посчитали (или по расчёту), плюс прежние конверты.
	var others bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pos_shifts WHERE store_id = $1 AND closed_at IS NULL AND id <> $2)`,
		storeID, shiftID).Scan(&others); err != nil {
		return nil, err
	}
	if !others {
		if err := SyncDrawer(ctx, tx, networkID, cb, counted, shiftID); err != nil {
			return nil, err
		}
	}
	amount := counted.Sub(left)
	if amount.Sign() <= 0 {
		return nil, nil
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO pending_handovers (network_id, store_id, cashbox_id, shift_id, amount, left_amount)
		VALUES ($1, $2, $3, $4, $5::numeric, $6::numeric) ON CONFLICT (shift_id) DO NOTHING`,
		networkID, storeID, cb, shiftID, amount.Money(), left.Money()); err != nil {
		return nil, err
	}
	return &amount, nil
}

// ListPendingHandovers — «Ожидает сдачи» (status = pending) и «Принято»
// (accepted) по магазину; пусто — по всем магазинам сотрудника.
func (s *Service) ListPendingHandovers(ctx context.Context, p *identity.Principal, storeID, status string, page httpx.Page) ([]PendingHandover, error) {
	if err := p.Require(identity.PermFinanceManage); err != nil {
		return nil, err
	}
	if storeID != "" && (!httpx.IsUUID(storeID) || !p.CanAccessStore(storeID)) {
		return nil, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	if status != "" && status != "pending" && status != "accepted" {
		return nil, apperr.Validation("status: pending или accepted").Uz("status: pending yoki accepted")
	}
	order := `ph.created_at DESC`
	if status == "pending" {
		order = `ph.created_at`
	}
	if status == "accepted" {
		order = `ph.accepted_at DESC`
	}
	rows, err := s.pool.Query(ctx, pendingSelect+`
		WHERE ph.network_id = $1 AND ($2 OR ph.store_id = ANY($3::uuid[])) AND ($4 = '' OR ph.store_id::text = $4)
		  AND ($5 = '' OR ($5 = 'pending') = (ph.accepted_at IS NULL))
		ORDER BY `+order+` LIMIT $6 OFFSET $7`,
		p.NetworkID, p.SeesAllStores(), p.StoreIDs, storeID, status, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanPending)
}

func (s *Service) getPending(ctx context.Context, q db.Querier, p *identity.Principal, id string) (PendingHandover, error) {
	if !httpx.IsUUID(id) {
		return PendingHandover{}, apperr.NotFound("сдача не найдена").Uz("topshirish topilmadi")
	}
	rows, err := q.Query(ctx, pendingSelect+` WHERE ph.id = $1 AND ph.network_id = $2`, id, p.NetworkID)
	if err != nil {
		return PendingHandover{}, err
	}
	x, err := pgx.CollectExactlyOneRow(rows, scanPending)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !p.CanAccessStore(x.StoreID)) {
		return PendingHandover{}, apperr.NotFound("сдача не найдена").Uz("topshirish topilmadi")
	}
	return x, err
}

type AcceptInput struct {
	// Сколько получил. Не прислали — всё, что отложено.
	Received *money.Amount `json:"received"`
}

// AcceptPendingHandover — владелец «Принял» конверт (М2/М3): сдача кассы
// магазина в главную кассу; получил меньше (больше) — недостача (излишек)
// смены. Повтор — та же сдача.
func (s *Service) AcceptPendingHandover(ctx context.Context, p *identity.Principal, id string, in AcceptInput) (PendingHandover, error) {
	if err := p.Require(identity.PermFinanceManage); err != nil {
		return PendingHandover{}, err
	}
	if p.EmployeeID == "" {
		return PendingHandover{}, apperr.Forbidden("принять деньги может только сотрудник сети").Uz("pulni faqat tarmoq xodimi qabul qila oladi")
	}
	if in.Received != nil && (!in.Received.Valid() || money.D(string(*in.Received)).Sign() < 0) {
		return PendingHandover{}, apperr.Validation("received: сколько получили").Uz("received: qancha olindi")
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		return s.accept(ctx, tx, p, id, in.Received)
	})
	if err != nil {
		return PendingHandover{}, err
	}
	return s.getPending(ctx, s.pool, p, id)
}

func (s *Service) accept(ctx context.Context, tx pgx.Tx, p *identity.Principal, id string, received *money.Amount) error {
	x, err := s.getPending(ctx, tx, p, id)
	if err != nil {
		return err
	}
	var cb, store string
	var accepted *time.Time
	if err := tx.QueryRow(ctx, `SELECT cashbox_id, store_id, accepted_at FROM pending_handovers WHERE id = $1 FOR UPDATE`, id).
		Scan(&cb, &store, &accepted); err != nil {
		return err
	}
	if accepted != nil {
		return nil
	}
	from, err := lockCashbox(ctx, tx, p.NetworkID, cb)
	if err != nil {
		return err
	}
	var main string
	err = tx.QueryRow(ctx, `SELECT id FROM cashboxes WHERE network_id = $1 AND is_main AND currency = $2`, p.NetworkID, from.Currency).Scan(&main)
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.Validation("нет главной кассы в валюте " + from.Currency).Uz(from.Currency + " valyutasida asosiy kassa yoʻq")
	}
	if err != nil {
		return err
	}
	if _, err := lockCashbox(ctx, tx, p.NetworkID, main); err != nil {
		return err
	}
	amount := money.D(x.Amount)
	got := amount
	if received != nil {
		got = money.D(string(*received))
	}
	shortage := amount.Sub(got)
	var transfer *string
	if got.Sign() > 0 {
		n, err := db.NextNumber(ctx, tx, "cash_transfers", p.NetworkID, "")
		if err != nil {
			return err
		}
		note := i18n.T(ctx, fmt.Sprintf("Закрытие дня · смена №%d", x.ShiftNumber), fmt.Sprintf("Kunni yopish · smena №%d", x.ShiftNumber))
		var t string
		if err := tx.QueryRow(ctx, `
			INSERT INTO cash_transfers (network_id, number, kind, from_id, to_id, amount_from, amount_to, note, created_by, left_amount, shortage)
			VALUES ($1, $2, 'handover', $3, $4, $5::numeric, $5::numeric, $6, $7, $8::numeric, $9::numeric) RETURNING id`,
			p.NetworkID, n, cb, main, got.Money(), note, p.EmployeeID, x.LeftAmount, shortage.Money()).Scan(&t); err != nil {
			return err
		}
		transfer = &t
		// Конверт по учёту ещё в кассе магазина: списываем без проверки
		// остатка — деньги уже у владельца.
		if err := AddCash(ctx, tx, p.NetworkID, cb, got.Neg().Money(), DocCashTransfer, t); err != nil {
			return err
		}
		if err := AddCash(ctx, tx, p.NetworkID, main, got.Money(), DocCashTransfer, t); err != nil {
			return err
		}
	}
	if !shortage.IsZero() {
		if err := AddCash(ctx, tx, p.NetworkID, cb, shortage.Neg().Money(), DocHandoverShortage, id); err != nil {
			return err
		}
	}
	_, err = tx.Exec(ctx, `UPDATE pending_handovers SET accepted_at = now(), accepted_by = $2, received = $3::numeric,
		shortage = $4::numeric, transfer_id = $5 WHERE id = $1`, id, p.EmployeeID, got.Money(), shortage.Money(), transfer)
	return err
}

type AcceptAllInput struct {
	StoreID string `json:"store_id"`
}

// AcceptAllPendingHandovers — «Принял всё» (М1): все конверты магазина —
// полностью.
func (s *Service) AcceptAllPendingHandovers(ctx context.Context, p *identity.Principal, in AcceptAllInput) ([]PendingHandover, error) {
	if err := p.Require(identity.PermFinanceManage); err != nil {
		return nil, err
	}
	if p.EmployeeID == "" {
		return nil, apperr.Forbidden("принять деньги может только сотрудник сети").Uz("pulni faqat tarmoq xodimi qabul qila oladi")
	}
	if !httpx.IsUUID(in.StoreID) || !p.CanAccessStore(in.StoreID) {
		return nil, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	var ids []string
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT id FROM pending_handovers WHERE network_id = $1 AND store_id = $2 AND accepted_at IS NULL
			ORDER BY created_at`, p.NetworkID, in.StoreID)
		if err != nil {
			return err
		}
		if ids, err = pgx.CollectRows(rows, pgx.RowTo[string]); err != nil {
			return err
		}
		for _, id := range ids {
			if err := s.accept(ctx, tx, p, id, nil); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	out := make([]PendingHandover, 0, len(ids))
	for _, id := range ids {
		x, err := s.getPending(ctx, s.pool, p, id)
		if err != nil {
			return nil, err
		}
		out = append(out, x)
	}
	return out, nil
}

type RecountInput struct {
	StoreID string       `json:"store_id"`
	Counted money.Amount `json:"counted"`
	// Куда делась разница: taken — «Забирал я, не отмечал» (сдача владельцу
	// задним числом, не недостача кассира), shortage — «Денег не хватает».
	Kind string `json:"kind"`
}

type RecountResult struct {
	Before  string `json:"before"`
	Counted string `json:"counted"`
	// Разница: плюс — в ящике меньше, чем по расчёту, минус — больше.
	Diff       string  `json:"diff"`
	Kind       string  `json:"kind"`
	TransferID *string `json:"transfer_id"`
}

// RecountDrawer — разовый пересчёт ящика (М5): в ящике становится столько,
// сколько посчитали. Разница — «Сдачи прошлых дней без отметки» (сдача в
// главную кассу) или недостача; больше, чем по расчёту, — излишек. Идёт
// смена — в ней изъятие (внесение), чтобы X-отчёт сошёлся с ящиком.
func (s *Service) RecountDrawer(ctx context.Context, p *identity.Principal, in RecountInput) (RecountResult, error) {
	out := RecountResult{Kind: in.Kind}
	if err := p.Require(identity.PermFinanceManage); err != nil {
		return out, err
	}
	if p.EmployeeID == "" {
		return out, apperr.Forbidden("пересчитать ящик может только сотрудник сети").Uz("gʻaladonni faqat tarmoq xodimi sanay oladi")
	}
	if !httpx.IsUUID(in.StoreID) || !p.CanAccessStore(in.StoreID) {
		return out, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	if !in.Counted.Valid() || money.D(string(in.Counted)).Sign() < 0 {
		return out, apperr.Validation("counted: сколько посчитали в ящике").Uz("counted: gʻaladonda qancha sanaldi")
	}
	if in.Kind != "taken" && in.Kind != "shortage" {
		return out, apperr.Validation("kind: taken — забирал я, shortage — недостача").Uz("kind: taken — oʻzim olganman, shortage — kamomad")
	}
	counted := money.D(string(in.Counted))
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		cb, err := StoreCashbox(ctx, tx, p.NetworkID, in.StoreID)
		if err != nil {
			return err
		}
		if cb == "" {
			return apperr.NotFound("у магазина нет кассы наличных").Uz("doʻkonda naqd pul kassasi yoʻq")
		}
		from, err := lockCashbox(ctx, tx, p.NetworkID, cb)
		if err != nil {
			return err
		}
		drawer, shifts, err := DrawerCash(ctx, tx, p.NetworkID, in.StoreID, cb)
		if err != nil {
			return err
		}
		if len(shifts) > 1 {
			return apperr.Conflict("several_shifts", "смены идут на нескольких кассах — пересчитайте ящик, когда останется одна").
				Uz("smenalar bir nechta kassada ochiq — bittasi qolganda gʻaladonni sanang")
		}
		diff := drawer.Sub(counted)
		out.Before, out.Counted, out.Diff = drawer.Money(), counted.Money(), diff.Money()
		if diff.IsZero() {
			return nil
		}
		var doc string
		if err := tx.QueryRow(ctx, `SELECT gen_random_uuid()::text`).Scan(&doc); err != nil {
			return err
		}
		if len(shifts) == 1 {
			// Учёт — по ящику смены, в смене — изъятие (внесение) на разницу.
			if err := SyncDrawer(ctx, tx, p.NetworkID, cb, drawer, doc); err != nil {
				return err
			}
			kind, amount := "out", diff
			reason := i18n.T(ctx, "Пересчёт ящика: недостача", "Gʻaladonni sanash: kamomad")
			if in.Kind == "taken" {
				reason = i18n.T(ctx, "Сдачи прошлых дней без отметки", "Oldingi kunlarda belgilanmagan topshirishlar")
			}
			if diff.Sign() < 0 {
				kind, amount = "in", diff.Neg()
				reason = i18n.T(ctx, "Пересчёт ящика: излишек", "Gʻaladonni sanash: ortiqcha")
			}
			if _, err := tx.Exec(ctx, `INSERT INTO pos_cash_moves (network_id, shift_id, client_uid, kind, amount, reason, created_by, created_at)
				VALUES ($1, $2, $3, $4, $5::numeric, $6, $7, now())`,
				p.NetworkID, shifts[0].ID, "recount-"+doc, kind, amount.Money(), reason, p.EmployeeID); err != nil {
				return err
			}
		}
		if in.Kind == "taken" && diff.Sign() > 0 {
			var main string
			err := tx.QueryRow(ctx, `SELECT id FROM cashboxes WHERE network_id = $1 AND is_main AND currency = $2`, p.NetworkID, from.Currency).Scan(&main)
			if errors.Is(err, pgx.ErrNoRows) {
				return apperr.Validation("нет главной кассы в валюте " + from.Currency).Uz(from.Currency + " valyutasida asosiy kassa yoʻq")
			}
			if err != nil {
				return err
			}
			n, err := db.NextNumber(ctx, tx, "cash_transfers", p.NetworkID, "")
			if err != nil {
				return err
			}
			note := i18n.T(ctx, "Сдачи прошлых дней без отметки", "Oldingi kunlarda belgilanmagan topshirishlar")
			var t string
			if err := tx.QueryRow(ctx, `
				INSERT INTO cash_transfers (network_id, number, kind, from_id, to_id, amount_from, amount_to, note, created_by, left_amount, shortage)
				VALUES ($1, $2, 'handover', $3, $4, $5::numeric, $5::numeric, $6, $7, $8::numeric, 0) RETURNING id`,
				p.NetworkID, n, cb, main, diff.Money(), note, p.EmployeeID, counted.Money()).Scan(&t); err != nil {
				return err
			}
			out.TransferID = &t
			if err := AddCash(ctx, tx, p.NetworkID, cb, diff.Neg().Money(), DocCashTransfer, t); err != nil {
				return err
			}
			return AddCash(ctx, tx, p.NetworkID, main, diff.Money(), DocCashTransfer, t)
		}
		return AddCash(ctx, tx, p.NetworkID, cb, diff.Neg().Money(), DocDrawerRecount, doc)
	})
	if err != nil {
		return RecountResult{}, err
	}
	if strings.TrimSpace(out.Diff) == "" {
		out.Diff = "0.00"
	}
	return out, nil
}

// RemindHour — после этого часа (Ташкент) владельцу приходит напоминание,
// если есть «К сдаче» (М6 «Напоминать о сдаче»).
const RemindHour = 21

// RemindHandovers — задача воркера: раз в день после 21:00 напомнить
// сотрудникам с правом «Финансы», что есть «К сдаче». Не принято больше
// суток — так и пишем.
func RemindHandovers(ctx context.Context, q db.Querier, now time.Time) (int, error) {
	local := now.In(tashkent)
	if local.Hour() < RemindHour {
		return 0, nil
	}
	today := local.Format("2006-01-02")
	rows, err := q.Query(ctx, `
		SELECT st.id, st.name, count(*)::int, sum(ph.amount)::numeric(18,0)::text, bool_or(ph.created_at < now() - interval '24 hours')
		FROM pending_handovers ph JOIN stores st ON st.id = ph.store_id
		WHERE ph.accepted_at IS NULL AND st.handover_remind
		  AND (st.handover_reminded_on IS NULL OR st.handover_reminded_on < $1::date)
		GROUP BY st.id, st.name LIMIT 200`, today)
	if err != nil {
		return 0, err
	}
	type due struct {
		id, name, total string
		count           int
		old             bool
	}
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (due, error) {
		var d due
		err := r.Scan(&d.id, &d.name, &d.count, &d.total, &d.old)
		return d, err
	})
	if err != nil {
		return 0, err
	}
	for _, d := range list {
		sum := money.Group(d.total)
		title := i18n.Text{RU: "К сдаче: " + sum + " сум", UZ: "Topshirish kerak: " + sum + " soʻm"}
		body := i18n.Text{
			RU: "«" + d.name + "»: кассир закрыл день и отложил деньги. Заберите и нажмите «Принял».",
			UZ: "«" + d.name + "»: kassir kunni yopdi va pulni ajratib qoʻydi. Olib, «Qabul qildim»ni bosing.",
		}
		if d.old {
			body = i18n.Text{
				RU: "«" + d.name + "»: деньги не приняты больше суток. Заберите и нажмите «Принял».",
				UZ: "«" + d.name + "»: pul bir kundan ortiq qabul qilinmagan. Olib, «Qabul qildim»ni bosing.",
			}
		}
		if err := push.EnqueueStaff(ctx, q, d.id, identity.PermFinanceManage, "cash_handover", title, body,
			map[string]string{"screen": "finance", "store_id": d.id}); err != nil {
			return 0, err
		}
		if _, err := q.Exec(ctx, `UPDATE stores SET handover_reminded_on = $2::date WHERE id = $1`, d.id, today); err != nil {
			return 0, err
		}
	}
	return len(list), nil
}
