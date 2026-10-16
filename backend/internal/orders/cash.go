package orders

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/finance"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
	"github.com/sanedidi/super-market/backend/internal/push"
)

// Наличные у курьеров (Figma «Правки 16 окт» → К10, К11, М33, М34).
// Доставленный заказ «наличными курьеру» кладёт сумму на курьера (журнал
// courier_cash_entries). Курьер сдаёт деньги в кассу: «Сдал N» → у магазина
// «Курьер сдаёт N» → «Получил» (сумма в кассу магазина) или «Другая сумма»
// (получено меньше — разница остаётся на курьере).

// DocCourierCash — приход в кассу магазина от курьера (cash_entries.doc_type).
const DocCourierCash = "courier_cash"

const (
	HandoverPending  = "pending"
	HandoverReceived = "received"
)

// addCourierCash — заказ вручён: его наличные теперь на курьере.
func addCourierCash(ctx context.Context, tx pgx.Tx, orderID string) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO courier_cash_entries (network_id, store_id, courier_id, amount, order_id)
		SELECT network_id, store_id, courier_id, total, id FROM orders
		WHERE id = $1 AND payment_provider = $2 AND courier_id IS NOT NULL AND total > 0
		ON CONFLICT (order_id) WHERE order_id IS NOT NULL DO NOTHING`, orderID, CashOnDelivery)
	return err
}

// Handover — сдача наличных курьером.
type Handover struct {
	ID          string     `json:"id"`
	StoreID     string     `json:"store_id"`
	StoreName   string     `json:"store_name"`
	CourierID   string     `json:"courier_id"`
	CourierName string     `json:"courier_name"`
	Amount      string     `json:"amount"`
	Received    *string    `json:"received"`
	Status      string     `json:"status"`
	Comment     string     `json:"comment"`
	AnsweredBy  string     `json:"answered_by_name"`
	CreatedAt   time.Time  `json:"created_at"`
	AnsweredAt  *time.Time `json:"answered_at"`
	// Заказов, наличные которых сейчас у курьера в этом магазине (только в «ждёт»).
	Orders int `json:"orders"`
}

const handoverSelect = `
	SELECT h.id, h.store_id, s.name, h.courier_id, ce.full_name, h.amount::text, h.received::text, h.status, h.comment,
	       COALESCE(ae.full_name, ''), h.created_at, h.answered_at,
	       (SELECT count(*)::int FROM courier_cash_entries x WHERE x.courier_id = h.courier_id AND x.store_id = h.store_id AND x.order_id IS NOT NULL
	          AND x.created_at > COALESCE((SELECT max(y.created_at) FROM courier_cash_entries y
	                                       WHERE y.courier_id = h.courier_id AND y.store_id = h.store_id AND y.handover_id IS NOT NULL), '-infinity'))
	FROM courier_cash_handovers h
	JOIN stores s     ON s.id = h.store_id
	JOIN employees ce ON ce.id = h.courier_id
	LEFT JOIN employees ae ON ae.id = h.answered_by`

func getHandover(ctx context.Context, q db.Querier, id string) (Handover, error) {
	rows, err := q.Query(ctx, handoverSelect+` WHERE h.id = $1`, id)
	if err != nil {
		return Handover{}, err
	}
	h, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Handover])
	if errors.Is(err, pgx.ErrNoRows) {
		return Handover{}, apperr.NotFound("сдача не найдена").Uz("topshirish topilmadi")
	}
	return h, err
}

// CashStore — наличные курьера по одному магазину.
type CashStore struct {
	StoreID   string `json:"store_id"`
	StoreName string `json:"store_name"`
	OnHand    string `json:"on_hand"`
	// Уже отмечено «Сдал», ждёт кассира — входит в on_hand.
	Pending string `json:"pending"`
}

// CourierCash — экран курьера: сколько на руках и последние сдачи.
type CourierCash struct {
	OnHand    string      `json:"on_hand"`
	Pending   string      `json:"pending"`
	Stores    []CashStore `json:"stores"`
	Handovers []Handover  `json:"handovers"`
}

func (s *Service) CourierCash(ctx context.Context, p *identity.Principal) (CourierCash, error) {
	out := CourierCash{OnHand: "0.00", Pending: "0.00", Stores: []CashStore{}, Handovers: []Handover{}}
	if err := p.Require(identity.PermOrdersDeliver); err != nil {
		return out, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT x.store_id, s.name, x.on_hand::numeric(18,2)::text,
		       COALESCE((SELECT sum(h.amount) FROM courier_cash_handovers h
		                 WHERE h.courier_id = $1 AND h.store_id = x.store_id AND h.status = 'pending'), 0)::numeric(18,2)::text
		FROM (SELECT store_id, sum(amount) AS on_hand FROM courier_cash_entries WHERE courier_id = $1 GROUP BY store_id) x
		JOIN stores s ON s.id = x.store_id
		WHERE x.on_hand > 0
		ORDER BY x.on_hand DESC, s.name`, p.EmployeeID)
	if err != nil {
		return out, err
	}
	if out.Stores, err = pgx.CollectRows(rows, pgx.RowToStructByPos[CashStore]); err != nil {
		return out, err
	}
	total, pending := money.D("0"), money.D("0")
	for _, c := range out.Stores {
		total, pending = total.Add(money.D(c.OnHand)), pending.Add(money.D(c.Pending))
	}
	out.OnHand, out.Pending = total.Money(), pending.Money()
	rows, err = s.pool.Query(ctx, handoverSelect+` WHERE h.courier_id = $1 ORDER BY h.created_at DESC LIMIT 20`, p.EmployeeID)
	if err != nil {
		return out, err
	}
	out.Handovers, err = pgx.CollectRows(rows, pgx.RowToStructByPos[Handover])
	return out, err
}

type HandoverInput struct {
	StoreID string       `json:"store_id"`
	Amount  money.Amount `json:"amount"`
	Comment string       `json:"comment"`
}

// CreateHandover — курьер: «Сдал N» в кассу магазина. Можно часть; больше,
// чем на руках (за вычетом ещё не подтверждённых сдач), — нельзя.
func (s *Service) CreateHandover(ctx context.Context, p *identity.Principal, in HandoverInput) (Handover, error) {
	if err := p.Require(identity.PermOrdersDeliver); err != nil {
		return Handover{}, err
	}
	if !httpx.IsUUID(in.StoreID) {
		return Handover{}, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	if !in.Amount.Valid() || money.D(string(in.Amount)).Sign() <= 0 {
		return Handover{}, apperr.Validation("amount: сумма должна быть больше нуля").Uz("amount: summa noldan katta boʻlishi kerak")
	}
	var id string
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		// Сдачи одного курьера — по очереди (проверка остатка).
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('courier_cash:' || $1::text))`, p.EmployeeID); err != nil {
			return err
		}
		var network, free string
		err := tx.QueryRow(ctx, `
			SELECT s.network_id::text,
			       (COALESCE((SELECT sum(amount) FROM courier_cash_entries WHERE courier_id = $1 AND store_id = s.id), 0)
			        - COALESCE((SELECT sum(amount) FROM courier_cash_handovers WHERE courier_id = $1 AND store_id = s.id AND status = 'pending'), 0))::numeric(18,2)::text
			FROM stores s WHERE s.id = $2 AND s.network_id = $3`, p.EmployeeID, in.StoreID, p.NetworkID).Scan(&network, &free)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
		}
		if err != nil {
			return err
		}
		if money.D(string(in.Amount)).Cmp(money.D(free)) > 0 {
			return apperr.Conflict("too_much", "столько наличных у вас нет — можно сдать до "+money.Group(free)+" сум").
				Uz("sizda buncha naqd pul yoʻq — " + money.Group(free) + " soʻmgacha topshirish mumkin")
		}
		if err := tx.QueryRow(ctx, `
			INSERT INTO courier_cash_handovers (network_id, store_id, courier_id, amount, comment)
			VALUES ($1, $2, $3, $4::numeric, $5) RETURNING id`,
			network, in.StoreID, p.EmployeeID, string(in.Amount), strings.TrimSpace(in.Comment)).Scan(&id); err != nil {
			return err
		}
		var name string
		if err := tx.QueryRow(ctx, `SELECT full_name FROM employees WHERE id = $1`, p.EmployeeID).Scan(&name); err != nil {
			return err
		}
		sum := money.Group(money.D(string(in.Amount)).Money())
		return push.EnqueueStaff(ctx, tx, in.StoreID, identity.PermFinanceManage, "courier_cash",
			i18n.Text{RU: "Курьер сдаёт наличные", UZ: "Kuryer naqd pul topshirmoqda"},
			i18n.Text{RU: name + " сдаёт " + sum + " сум — пересчитайте и подтвердите", UZ: name + " " + sum + " soʻm topshirmoqda — sanab, tasdiqlang"},
			map[string]string{"type": "courier_cash", "id": id})
	})
	if err != nil {
		return Handover{}, err
	}
	return getHandover(ctx, s.pool, id)
}

// StoreCourierCash — «Наличные у курьеров» и сдачи, которые ждут кассира (М33).
type StoreCourierCash struct {
	Total    string       `json:"total"`
	Couriers []CashHolder `json:"couriers"`
	Pending  []Handover   `json:"pending"`
}

type CashHolder struct {
	CourierID string     `json:"courier_id"`
	Name      string     `json:"name"`
	OnHand    string     `json:"on_hand"`
	Pending   string     `json:"pending"`
	Orders    int        `json:"orders"`
	Since     *time.Time `json:"since"` // первый ещё не сданный заказ
}

func requireCashier(p *identity.Principal, storeID string) error {
	if err := p.RequireAny(identity.PermFinanceManage, identity.PermSalesPOS, identity.PermOrdersManage); err != nil {
		return err
	}
	if !httpx.IsUUID(storeID) || !p.CanAccessStore(storeID) {
		return apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	return nil
}

func (s *Service) StoreCourierCash(ctx context.Context, p *identity.Principal, storeID string) (StoreCourierCash, error) {
	out := StoreCourierCash{Total: "0.00", Couriers: []CashHolder{}, Pending: []Handover{}}
	if err := requireCashier(p, storeID); err != nil {
		return out, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT x.courier_id, e.full_name, x.on_hand::numeric(18,2)::text,
		       COALESCE((SELECT sum(h.amount) FROM courier_cash_handovers h
		                 WHERE h.courier_id = x.courier_id AND h.store_id = $1 AND h.status = 'pending'), 0)::numeric(18,2)::text,
		       (SELECT count(*)::int FROM courier_cash_entries y WHERE y.courier_id = x.courier_id AND y.store_id = $1 AND y.order_id IS NOT NULL
		          AND y.created_at > COALESCE((SELECT max(z.created_at) FROM courier_cash_entries z
		                                       WHERE z.courier_id = x.courier_id AND z.store_id = $1 AND z.handover_id IS NOT NULL), '-infinity')),
		       (SELECT min(y.created_at) FROM courier_cash_entries y WHERE y.courier_id = x.courier_id AND y.store_id = $1 AND y.order_id IS NOT NULL
		          AND y.created_at > COALESCE((SELECT max(z.created_at) FROM courier_cash_entries z
		                                       WHERE z.courier_id = x.courier_id AND z.store_id = $1 AND z.handover_id IS NOT NULL), '-infinity'))
		FROM (SELECT courier_id, sum(amount) AS on_hand FROM courier_cash_entries WHERE store_id = $1 GROUP BY courier_id) x
		JOIN employees e ON e.id = x.courier_id
		WHERE x.on_hand > 0
		ORDER BY x.on_hand DESC, e.full_name`, storeID)
	if err != nil {
		return out, err
	}
	if out.Couriers, err = pgx.CollectRows(rows, pgx.RowToStructByPos[CashHolder]); err != nil {
		return out, err
	}
	total := money.D("0")
	for _, c := range out.Couriers {
		total = total.Add(money.D(c.OnHand))
	}
	out.Total = total.Money()
	rows, err = s.pool.Query(ctx, handoverSelect+` WHERE h.store_id = $1 AND h.status = 'pending' ORDER BY h.created_at`, storeID)
	if err != nil {
		return out, err
	}
	out.Pending, err = pgx.CollectRows(rows, pgx.RowToStructByPos[Handover])
	return out, err
}

type ReceiveInput struct {
	// Сколько получили; нет — вся сумма сдачи.
	Received *money.Amount `json:"received"`
	Comment  string        `json:"comment"`
}

// ReceiveHandover — кассир: «Получил» (вся сумма) или «Другая сумма»
// (меньше; разница остаётся на курьере). Полученное — в кассу магазина.
func (s *Service) ReceiveHandover(ctx context.Context, p *identity.Principal, id string, in ReceiveInput) (Handover, error) {
	if !httpx.IsUUID(id) {
		return Handover{}, apperr.NotFound("сдача не найдена").Uz("topshirish topilmadi")
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var storeID, network, courier, amount, status string
		err := tx.QueryRow(ctx, `SELECT store_id, network_id, courier_id, amount::text, status FROM courier_cash_handovers WHERE id = $1 FOR UPDATE`, id).
			Scan(&storeID, &network, &courier, &amount, &status)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && network != p.NetworkID) {
			return apperr.NotFound("сдача не найдена").Uz("topshirish topilmadi")
		}
		if err != nil {
			return err
		}
		if err := requireCashier(p, storeID); err != nil {
			return err
		}
		if status != HandoverPending {
			return apperr.Conflict("already_answered", "сдача уже подтверждена").Uz("topshirish allaqachon tasdiqlangan")
		}
		received := amount
		if in.Received != nil {
			if !in.Received.Valid() {
				return apperr.Validation("received: неверная сумма").Uz("received: summa notoʻgʻri")
			}
			r := money.D(string(*in.Received))
			if r.Sign() < 0 || r.Cmp(money.D(amount)) > 0 {
				return apperr.Validation("received: от 0 до суммы сдачи").Uz("received: 0 dan topshirish summasigacha")
			}
			received = r.Money()
		}
		var cashbox *string
		if money.D(received).Sign() > 0 {
			var cb string
			err := tx.QueryRow(ctx, `
				SELECT c.id FROM cashboxes c
				LEFT JOIN payment_methods pm ON pm.cashbox_id = c.id AND pm.kind = 'cash' AND pm.is_active
				WHERE c.store_id = $1 AND c.network_id = $2 AND c.is_active AND c.currency = 'UZS'
				ORDER BY pm.id IS NULL, c.created_at LIMIT 1`, storeID, network).Scan(&cb)
			if errors.Is(err, pgx.ErrNoRows) {
				return apperr.Conflict("no_cashbox", "у магазина нет кассы в сумах — создайте её в «Финансах»").Uz("doʻkonda soʻmdagi kassa yoʻq — uni «Moliya»da yarating")
			}
			if err != nil {
				return err
			}
			cashbox = &cb
			if err := finance.AddCash(ctx, tx, network, cb, received, DocCourierCash, id); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `
				INSERT INTO courier_cash_entries (network_id, store_id, courier_id, amount, handover_id)
				VALUES ($1, $2, $3, -($4::numeric), $5)`, network, storeID, courier, received, id); err != nil {
				return err
			}
		}
		_, err = tx.Exec(ctx, `
			UPDATE courier_cash_handovers SET status = 'received', received = $2::numeric, cashbox_id = $3, answered_by = $4,
			       answered_at = now(), comment = CASE WHEN $5 = '' THEN comment ELSE $5 END
			WHERE id = $1`, id, received, cashbox, p.EmployeeID, strings.TrimSpace(in.Comment))
		return err
	})
	if err != nil {
		return Handover{}, err
	}
	return getHandover(ctx, s.pool, id)
}
