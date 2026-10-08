package orders

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

// Супер-админ: crowd-доставка — обзор, курьеры, инциденты, выплаты, правила, магазины.

type CrowdOverview struct {
	// Сегодня (по Ташкенту): собранные заказы в подключённых магазинах и сколько взяли курьеры «по пути».
	TodayOffered int `json:"today_offered"`
	TodayTaken   int `json:"today_taken"`
	// Среднее «выдан → вручён» за 7 дней: курьеры «по пути» и штатные.
	CrowdMinutes  *int   `json:"crowd_minutes"`
	StaffMinutes  *int   `json:"staff_minutes"`
	Verified      int    `json:"verified"`
	Unverified    int    `json:"unverified"`
	Blocked       int    `json:"blocked"`
	OnlineNow     int    `json:"online_now"`
	NewWeek       int    `json:"new_week"`
	OpenIncidents int    `json:"open_incidents"`
	LostWeek      int    `json:"lost_week"` // заказы с нарушениями за неделю
	PayoutTotal   string `json:"payout_total"`
	PayoutCount   int    `json:"payout_count"`
	PayoutOn      string `json:"payout_on"`
	BonusPending  string `json:"bonus_pending"`
	Stores        int    `json:"stores"` // подключённых магазинов
}

func dayStart(now time.Time) time.Time {
	d := now.In(tashkent)
	return time.Date(d.Year(), d.Month(), d.Day(), 0, 0, 0, 0, tashkent)
}

func (s *Service) AdminCrowdOverview(ctx context.Context) (CrowdOverview, error) {
	var o CrowdOverview
	var crowdMin, staffMin *float64
	err := s.pool.QueryRow(ctx, `
		SELECT
		  (SELECT count(*) FROM orders o JOIN stores s ON s.id = o.store_id
		   WHERE s.crowd_enabled AND o.payment_provider <> 'cash' AND o.picked_at >= $1)::int,
		  (SELECT count(*) FROM orders o WHERE o.crowd_accepted_at >= $1)::int,
		  (SELECT avg(EXTRACT(EPOCH FROM delivered_at - picked_up_at) / 60) FROM orders
		   WHERE crowd_courier_id IS NOT NULL AND status = 'delivered' AND delivered_at > now() - interval '7 days' AND picked_up_at IS NOT NULL),
		  (SELECT avg(EXTRACT(EPOCH FROM delivered_at - picked_up_at) / 60) FROM orders
		   WHERE courier_id IS NOT NULL AND status = 'delivered' AND delivered_at > now() - interval '7 days' AND picked_up_at IS NOT NULL),
		  (SELECT count(*) FROM crowd_couriers WHERE deleted_at IS NULL AND status = 'active')::int,
		  (SELECT count(*) FROM crowd_couriers WHERE deleted_at IS NULL AND status = 'unverified')::int,
		  (SELECT count(*) FROM crowd_couriers WHERE deleted_at IS NULL AND status = 'blocked')::int,
		  (SELECT count(*) FROM crowd_couriers WHERE status = 'active' AND online AND located_at > now() - interval '15 minutes')::int,
		  (SELECT count(*) FROM crowd_couriers WHERE verified_at > now() - interval '7 days')::int,
		  (SELECT count(*) FROM courier_incidents WHERE status = 'open')::int,
		  (SELECT count(DISTINCT order_id) FROM courier_incidents WHERE violation AND created_at > now() - interval '7 days')::int,
		  COALESCE((SELECT sum(b) FROM (SELECT sum(amount) b FROM crowd_ledger GROUP BY courier_id HAVING sum(amount) > 0) x), 0)::numeric(18,2)::text,
		  (SELECT count(*) FROM (SELECT 1 FROM crowd_ledger GROUP BY courier_id HAVING sum(amount) > 0) x)::int,
		  COALESCE((SELECT sum(amount) FROM store_crowd_bonuses WHERE status = 'pending'), 0)::numeric(18,2)::text,
		  (SELECT count(*) FROM stores WHERE crowd_enabled AND status = 'active')::int`,
		dayStart(s.now())).Scan(&o.TodayOffered, &o.TodayTaken, &crowdMin, &staffMin, &o.Verified, &o.Unverified, &o.Blocked,
		&o.OnlineNow, &o.NewWeek, &o.OpenIncidents, &o.LostWeek, &o.PayoutTotal, &o.PayoutCount, &o.BonusPending, &o.Stores)
	round := func(f *float64) *int {
		if f == nil {
			return nil
		}
		v := int(*f + 0.5)
		return &v
	}
	o.CrowdMinutes, o.StaffMinutes = round(crowdMin), round(staffMin)
	o.PayoutOn = nextMonday(s.now())
	return o, err
}

// AdminCrowdCourier — строка таблицы курьеров.
type AdminCrowdCourier struct {
	UserID        string     `json:"user_id"`
	Code          string     `json:"code"`
	FullName      string     `json:"full_name"`
	Phone         string     `json:"phone"`
	Status        string     `json:"status"`
	Online        bool       `json:"online"`
	Busy          bool       `json:"busy"` // везёт заказ
	Level         string     `json:"level"`
	Delivered     int        `json:"delivered"`
	OntimePct     int        `json:"ontime_pct"`
	OpenIncidents int        `json:"open_incidents"`
	Balance       string     `json:"balance"`
	VerifiedStore *string    `json:"verified_store"`
	VerifiedAt    *time.Time `json:"verified_at"`
	BlockedReason string     `json:"blocked_reason"`
	CreatedAt     time.Time  `json:"created_at"`
}

type AdminCrowdFilter struct {
	Status string
	Query  string
	Page   httpx.Page
}

func (s *Service) AdminCrowdCouriers(ctx context.Context, f AdminCrowdFilter) ([]AdminCrowdCourier, error) {
	if f.Status != "" && f.Status != "active" && f.Status != "unverified" && f.Status != "blocked" {
		return nil, apperr.Validation("status: active, unverified или blocked").Uz("status: active, unverified yoki blocked")
	}
	q := strings.TrimSpace(f.Query)
	digits := strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, q)
	rows, err := s.pool.Query(ctx, `
		SELECT cc.user_id, cc.code, cc.full_name, u.phone, cc.status,
		       cc.online AND cc.located_at > now() - interval '15 minutes',
		       EXISTS (SELECT 1 FROM orders o WHERE o.crowd_courier_id = cc.user_id AND o.status IN ('picked', 'delivering')),
		       (SELECT count(*) FROM courier_incidents i WHERE i.courier_id = cc.user_id AND i.status = 'open')::int,
		       COALESCE((SELECT sum(amount) FROM crowd_ledger l WHERE l.courier_id = cc.user_id), 0)::numeric(18,2)::text,
		       vs.name, cc.verified_at, cc.blocked_reason, cc.created_at
		FROM crowd_couriers cc JOIN users u ON u.id = cc.user_id
		LEFT JOIN stores vs ON vs.id = cc.verified_store_id
		WHERE cc.deleted_at IS NULL AND ($1 = '' OR cc.status = $1)
		  AND ($2 = '' OR cc.full_name ILIKE '%' || $2 || '%' OR cc.code ILIKE '%' || $2 || '%'
		       OR ($3 <> '' AND regexp_replace(u.phone, '\D', '', 'g') LIKE '%' || $3 || '%'))
		ORDER BY cc.status = 'unverified', cc.verified_at DESC NULLS LAST, cc.created_at DESC
		LIMIT $4 OFFSET $5`, f.Status, q, digits, f.Page.Limit, f.Page.Offset)
	if err != nil {
		return nil, err
	}
	list, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (AdminCrowdCourier, error) {
		var c AdminCrowdCourier
		err := row.Scan(&c.UserID, &c.Code, &c.FullName, &c.Phone, &c.Status, &c.Online, &c.Busy, &c.OpenIncidents,
			&c.Balance, &c.VerifiedStore, &c.VerifiedAt, &c.BlockedReason, &c.CreatedAt)
		return c, err
	})
	if err != nil {
		return nil, err
	}
	cs, err := s.crowdSettings(ctx, s.pool)
	if err != nil {
		return nil, err
	}
	for i := range list {
		st, err := crowdStats(ctx, s.pool, list[i].UserID)
		if err != nil {
			return nil, err
		}
		list[i].Delivered, list[i].OntimePct = st.Delivered, st.OntimePct
		list[i].Level = crowdLevel(cs, list[i].Status, st, i18n.FromContext(ctx)).Title
	}
	return list, nil
}

type CrowdBlockInput struct {
	Reason string `json:"reason"`
}

// AdminCrowdBlock — заблокировать курьера: сессии закрываются, текущие
// заказы до выдачи снимаются.
func (s *Service) AdminCrowdBlock(ctx context.Context, admin *identity.Principal, id string, in CrowdBlockInput) error {
	reason := strings.TrimSpace(in.Reason)
	if reason == "" || len([]rune(reason)) > 500 {
		return apperr.Validation("reason: причина блокировки (до 500 символов)").Uz("reason: bloklash sababi (500 belgigacha)")
	}
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE crowd_couriers SET status = 'blocked', blocked_reason = $2, online = false WHERE user_id = $1`, id, reason)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.NotFound("курьер не найден").Uz("kuryer topilmadi")
		}
		if _, err := tx.Exec(ctx, `UPDATE sessions SET revoked_at = now() WHERE user_id = $1 AND app = 'crowd' AND revoked_at IS NULL`, id); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT id FROM orders WHERE crowd_courier_id = $1 AND status = 'picked' FOR UPDATE`, id)
		if err != nil {
			return err
		}
		ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			return err
		}
		for _, oid := range ids {
			if err := clearCrowd(ctx, tx, oid, "admin", "Курьер по пути заблокирован — заказ снова в ленте"); err != nil {
				return err
			}
		}
		return nil
	})
}

func (s *Service) AdminCrowdUnblock(ctx context.Context, id string) error {
	// Возвращаем статус, который был до блокировки: проверен — если проверка была.
	tag, err := s.pool.Exec(ctx, `
		UPDATE crowd_couriers SET status = CASE WHEN verified_at IS NOT NULL THEN 'active' ELSE 'unverified' END, blocked_reason = ''
		WHERE user_id = $1 AND status = 'blocked'`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.NotFound("заблокированный курьер не найден").Uz("bloklangan kuryer topilmadi")
	}
	return nil
}

// AdminCrowdIncident — инцидент для разбора.
type AdminCrowdIncident struct {
	ID          string     `json:"id"`
	CourierID   string     `json:"courier_id"`
	CourierName string     `json:"courier_name"`
	CourierCode string     `json:"courier_code"`
	OrderID     *string    `json:"order_id"`
	OrderNumber *int64     `json:"order_number"`
	StoreName   *string    `json:"store_name"`
	Kind        string     `json:"kind"`
	Note        string     `json:"note"`
	Violation   bool       `json:"violation"`
	Status      string     `json:"status"`
	Resolution  string     `json:"resolution"`
	CreatedAt   time.Time  `json:"created_at"`
	ResolvedAt  *time.Time `json:"resolved_at"`
}

func (s *Service) AdminCrowdIncidents(ctx context.Context, status string, page httpx.Page) ([]AdminCrowdIncident, error) {
	if status != "" && status != "open" && status != "resolved" {
		return nil, apperr.Validation("status: open или resolved").Uz("status: open yoki resolved")
	}
	rows, err := s.pool.Query(ctx, `
		SELECT i.id, i.courier_id, COALESCE(NULLIF(cc.full_name, ''), cc.code), cc.code, i.order_id, o.number, s.name,
		       i.kind, i.note, i.violation, i.status, i.resolution, i.created_at, i.resolved_at
		FROM courier_incidents i JOIN crowd_couriers cc ON cc.user_id = i.courier_id
		LEFT JOIN orders o ON o.id = i.order_id LEFT JOIN stores s ON s.id = o.store_id
		WHERE ($1 = '' OR i.status = $1) AND i.kind <> 'released'
		ORDER BY i.status = 'open' DESC, i.created_at DESC LIMIT $2 OFFSET $3`, status, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[AdminCrowdIncident])
}

type CrowdResolveInput struct {
	Resolution string `json:"resolution"`
	// Считать нарушением курьера (влияет на уровень).
	Violation bool `json:"violation"`
	// Штраф курьеру, сум (необязательно).
	Penalty *money.Amount `json:"penalty"`
}

func (s *Service) AdminCrowdResolve(ctx context.Context, admin *identity.Principal, id string, in CrowdResolveInput) error {
	res := strings.TrimSpace(in.Resolution)
	if res == "" || len([]rune(res)) > 500 {
		return apperr.Validation("resolution: решение (до 500 символов)").Uz("resolution: qaror (500 belgigacha)")
	}
	if in.Penalty != nil && (!in.Penalty.Valid() || money.D(string(*in.Penalty)).Sign() < 0) {
		return apperr.Validation("penalty: сумма штрафа").Uz("penalty: jarima summasi")
	}
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var courier string
		var orderID *string
		err := tx.QueryRow(ctx, `
			UPDATE courier_incidents SET status = 'resolved', resolution = $2, violation = violation OR $3,
			       resolved_by = $4, resolved_at = now()
			WHERE id = $1 AND status = 'open' RETURNING courier_id, order_id`, id, res, in.Violation, admin.UserID).Scan(&courier, &orderID)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.NotFound("открытый инцидент не найден").Uz("ochiq hodisa topilmadi")
		}
		if err != nil {
			return err
		}
		if in.Violation && orderID != nil {
			// Нарушение по заказу — бонус магазину за этот заказ не начисляется.
			if _, err := tx.Exec(ctx, `UPDATE store_crowd_bonuses SET status = 'cancelled' WHERE order_id = $1 AND status = 'pending'`, *orderID); err != nil {
				return err
			}
		}
		if in.Penalty != nil && money.D(string(*in.Penalty)).Sign() > 0 {
			_, err = tx.Exec(ctx, `INSERT INTO crowd_ledger (courier_id, kind, amount, note, created_by) VALUES ($1, 'penalty', -$2::numeric, $3, $4)`,
				courier, string(*in.Penalty), "Штраф: "+res, admin.UserID)
			return err
		}
		return nil
	})
}

// CrowdPayout — курьер с положительным балансом к выплате.
type CrowdPayout struct {
	UserID     string `json:"user_id"`
	Code       string `json:"code"`
	FullName   string `json:"full_name"`
	Phone      string `json:"phone"`
	Balance    string `json:"balance"`
	Deliveries int    `json:"deliveries"` // с прошлой выплаты
}

func (s *Service) AdminCrowdPayouts(ctx context.Context) ([]CrowdPayout, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT cc.user_id, cc.code, cc.full_name, u.phone, sum(l.amount)::numeric(18,2)::text,
		       count(*) FILTER (WHERE l.kind = 'delivery' AND l.created_at > COALESCE(
		           (SELECT max(p.created_at) FROM crowd_ledger p WHERE p.courier_id = cc.user_id AND p.kind = 'payout'), 'epoch'))::int
		FROM crowd_ledger l JOIN crowd_couriers cc ON cc.user_id = l.courier_id JOIN users u ON u.id = cc.user_id
		GROUP BY cc.user_id, cc.code, cc.full_name, u.phone
		HAVING sum(l.amount) > 0
		ORDER BY sum(l.amount) DESC`)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[CrowdPayout])
}

type CrowdPayInput struct {
	CourierIDs []string `json:"courier_ids"`
	Note       string   `json:"note"`
}

// AdminCrowdPay — отметить выплату: баланс выбранных курьеров обнуляется строкой «выплата».
func (s *Service) AdminCrowdPay(ctx context.Context, admin *identity.Principal, in CrowdPayInput) (int, error) {
	if len(in.CourierIDs) == 0 || len(in.CourierIDs) > 500 {
		return 0, apperr.Validation("courier_ids: от 1 до 500 курьеров").Uz("courier_ids: 1 dan 500 tagacha kuryer")
	}
	for _, id := range in.CourierIDs {
		if !httpx.IsUUID(id) {
			return 0, apperr.Validation("courier_ids: неверный id").Uz("courier_ids: id notoʻgʻri")
		}
	}
	note := strings.TrimSpace(in.Note)
	if note == "" {
		note = "Выплата на карту"
	}
	if len([]rune(note)) > 300 {
		return 0, apperr.Validation("note: не длиннее 300 символов").Uz("note: 300 belgidan oshmasin")
	}
	var n int
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
			INSERT INTO crowd_ledger (courier_id, kind, amount, note, created_by)
			SELECT courier_id, 'payout', -sum(amount), $2, $3 FROM crowd_ledger
			WHERE courier_id = ANY($1::uuid[]) GROUP BY courier_id HAVING sum(amount) > 0`, in.CourierIDs, note, admin.UserID)
		n = int(tag.RowsAffected())
		return err
	})
	return n, err
}

func (s *Service) AdminCrowdSettings(ctx context.Context) (CrowdSettings, error) {
	return s.crowdSettings(ctx, s.pool)
}

// AdminCrowdSaveSettings — правила целиком (форма в админке).
func (s *Service) AdminCrowdSaveSettings(ctx context.Context, in CrowdSettings) (CrowdSettings, error) {
	for name, v := range map[string]string{"courier_fee": in.CourierFee, "platform_fee": in.PlatformFee, "long_wait_bonus": in.LongWaitBonus,
		"store_bonus": in.StoreBonus, "newbie_limit": in.NewbieLimit, "reliable_limit": in.ReliableLimit, "trusted_limit": in.TrustedLimit} {
		if !money.Amount(v).Valid() || money.D(v).Sign() < 0 {
			return in, apperr.Validation(name + ": неверная сумма").Uz(name + ": summa notoʻgʻri")
		}
	}
	if in.NewbieParallel < 1 || in.ReliableParallel < 1 || in.TrustedParallel < 1 ||
		in.NewbieParallel > 10 || in.ReliableParallel > 10 || in.TrustedParallel > 10 {
		return in, apperr.Validation("заказов сразу: от 1 до 10").Uz("bir vaqtdagi buyurtmalar: 1 dan 10 gacha")
	}
	if in.ReliableAfter < 1 || in.TrustedAfter <= in.ReliableAfter {
		return in, apperr.Validation("уровни: «Проверенный» — после большего числа доставок, чем «Надёжный»").Uz("darajalar: «Tekshirilgan» darajasi «Ishonchli»dan koʻproq yetkazishdan keyin beriladi")
	}
	_, err := s.pool.Exec(ctx, `
		UPDATE crowd_settings SET courier_fee = $1::numeric, platform_fee = $2::numeric, long_wait_bonus = $3::numeric,
		       long_wait_minutes = $4, wait_minutes = $5, pickup_minutes = $6, radius_m = $7, detour_m = $8,
		       store_bonus = $9::numeric, store_bonus_count = $10, store_bonus_hold_days = $11,
		       newbie_limit = $12::numeric, newbie_parallel = $13, reliable_after = $14, reliable_ontime = $15,
		       reliable_limit = $16::numeric, reliable_parallel = $17, trusted_after = $18, trusted_ontime = $19,
		       trusted_limit = $20::numeric, trusted_parallel = $21, updated_at = now()`,
		in.CourierFee, in.PlatformFee, in.LongWaitBonus, in.LongWaitMinutes, in.WaitMinutes, in.PickupMinutes, in.RadiusM, in.DetourM,
		in.StoreBonus, in.StoreBonusCount, in.StoreBonusHoldDays, in.NewbieLimit, in.NewbieParallel, in.ReliableAfter, in.ReliableOntime,
		in.ReliableLimit, in.ReliableParallel, in.TrustedAfter, in.TrustedOntime, in.TrustedLimit, in.TrustedParallel)
	if db.IsCheckViolation(err) {
		return in, apperr.Validation("значение вне допустимого диапазона").Uz("qiymat ruxsat etilgan oraliqdan tashqarida")
	}
	if err != nil {
		return in, err
	}
	return s.crowdSettings(ctx, s.pool)
}

// AdminCrowdStore — магазин и его участие в crowd-доставке.
type AdminCrowdStore struct {
	ID            string `json:"id"`
	Name          string `json:"name"`
	Address       string `json:"address"`
	NetworkName   string `json:"network_name"`
	CrowdEnabled  bool   `json:"crowd_enabled"`
	Verifications int    `json:"verifications"`
	CrowdOrders   int    `json:"crowd_orders"` // доставлено курьерами «по пути» за 30 дней
	BonusPending  string `json:"bonus_pending"`
	BonusCredited string `json:"bonus_credited"`
}

func (s *Service) AdminCrowdStores(ctx context.Context, query string, page httpx.Page) ([]AdminCrowdStore, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT s.id, s.name, s.address, n.name, s.crowd_enabled,
		       (SELECT count(*) FROM courier_verifications v WHERE v.store_id = s.id AND v.result = 'approved')::int,
		       (SELECT count(*) FROM orders o WHERE o.store_id = s.id AND o.crowd_courier_id IS NOT NULL AND o.status = 'delivered'
		        AND o.delivered_at > now() - interval '30 days')::int,
		       COALESCE((SELECT sum(amount) FROM store_crowd_bonuses b WHERE b.store_id = s.id AND b.status = 'pending'), 0)::numeric(18,2)::text,
		       COALESCE((SELECT sum(amount) FROM store_crowd_bonuses b WHERE b.store_id = s.id AND b.status = 'credited'), 0)::numeric(18,2)::text
		FROM stores s JOIN networks n ON n.id = s.network_id
		WHERE s.status = 'active' AND ($1 = '' OR s.name ILIKE '%' || $1 || '%' OR n.name ILIKE '%' || $1 || '%')
		ORDER BY s.crowd_enabled DESC, n.name, s.name LIMIT $2 OFFSET $3`, strings.TrimSpace(query), page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[AdminCrowdStore])
}

type CrowdStoreInput struct {
	CrowdEnabled bool `json:"crowd_enabled"`
}

func (s *Service) AdminCrowdSetStore(ctx context.Context, id string, in CrowdStoreInput) error {
	tag, err := s.pool.Exec(ctx, `UPDATE stores SET crowd_enabled = $2 WHERE id = $1`, id, in.CrowdEnabled)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	return nil
}

// CrowdTick — фоновая задача worker'а:
//   - курьер не забрал заказ вовремя — заказ снова в ленте, нарушение;
//   - бонусы магазинам после выдержки: начисляются, если по заказу нет
//     нарушений и у курьера есть доставки хотя бы из двух других магазинов.
func (s *Service) CrowdTick(ctx context.Context) error {
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT id, crowd_courier_id FROM orders
			WHERE status = 'picked' AND crowd_courier_id IS NOT NULL AND crowd_pickup_until < now()
			FOR UPDATE SKIP LOCKED`)
		if err != nil {
			return err
		}
		type late struct{ id, courier string }
		list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (late, error) {
			var l late
			return l, r.Scan(&l.id, &l.courier)
		})
		if err != nil {
			return err
		}
		for _, l := range list {
			if err := clearCrowd(ctx, tx, l.id, "system", "Курьер по пути не забрал заказ вовремя — заказ снова в ленте"); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `
				INSERT INTO courier_incidents (courier_id, order_id, kind, note, violation, status, resolution, resolved_at)
				VALUES ($1, $2, 'pickup_timeout', 'Не пришёл в магазин вовремя', true, 'resolved', 'Заказ вернулся в ленту', now())`,
				l.courier, l.id); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	_, err = s.pool.Exec(ctx, `
		UPDATE store_crowd_bonuses b SET status = 'cancelled'
		WHERE b.status = 'pending' AND EXISTS (
		      SELECT 1 FROM courier_incidents i WHERE i.order_id = b.order_id AND i.violation)`)
	if err != nil {
		return err
	}
	_, err = s.pool.Exec(ctx, `
		UPDATE store_crowd_bonuses b SET status = 'credited', credited_at = now()
		WHERE b.status = 'pending' AND b.available_at <= now()
		  AND NOT EXISTS (SELECT 1 FROM courier_incidents i WHERE i.order_id = b.order_id AND i.status = 'open')
		  AND (SELECT count(*) FROM orders o WHERE o.crowd_courier_id = b.courier_id AND o.status = 'delivered'
		       AND o.store_id <> b.store_id) >= 2`)
	return err
}
