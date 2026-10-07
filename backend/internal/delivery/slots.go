package delivery

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

// SlotSettings — доставка ко времени: окна длиной SlotMinutes на сегодня и
// DaysAhead дней вперёд, не ближе LeadMinutes от текущего момента, не больше
// Capacity заказов в окно.
type SlotSettings struct {
	Enabled     bool `json:"enabled"`
	SlotMinutes int  `json:"slot_minutes"`
	DaysAhead   int  `json:"days_ahead"`
	LeadMinutes int  `json:"lead_minutes"`
	Capacity    int  `json:"capacity"`
}

type SlotSettingsInput struct {
	Enabled     *bool `json:"enabled"`
	SlotMinutes *int  `json:"slot_minutes"`
	DaysAhead   *int  `json:"days_ahead"`
	LeadMinutes *int  `json:"lead_minutes"`
	Capacity    *int  `json:"capacity"`
}

var defaultSlots = SlotSettings{SlotMinutes: 60, DaysAhead: 1, LeadMinutes: 60, Capacity: 5}

func (in SlotSettingsInput) validate() error {
	check := func(v *int, lo, hi int, msg, msgUz string) error {
		if v != nil && (*v < lo || *v > hi) {
			return apperr.Validation(msg).Uz(msgUz)
		}
		return nil
	}
	return errors.Join(
		check(in.SlotMinutes, 30, 240, "slots.slot_minutes: от 30 до 240 минут", "slots.slot_minutes: 30 dan 240 daqiqagacha"),
		check(in.DaysAhead, 0, 6, "slots.days_ahead: от 0 до 6 дней", "slots.days_ahead: 0 dan 6 kungacha"),
		check(in.LeadMinutes, 0, 720, "slots.lead_minutes: от 0 до 720 минут", "slots.lead_minutes: 0 dan 720 daqiqagacha"),
		check(in.Capacity, 1, 500, "slots.capacity: от 1 до 500 заказов", "slots.capacity: 1 dan 500 tagacha buyurtma"),
	)
}

func getSlotSettings(ctx context.Context, q db.Querier, storeID string, lock bool) (SlotSettings, error) {
	st := defaultSlots
	sql := `SELECT enabled, slot_minutes, days_ahead, lead_minutes, capacity FROM delivery_slot_rules WHERE store_id = $1`
	if lock {
		sql += ` FOR UPDATE`
	}
	err := q.QueryRow(ctx, sql, storeID).Scan(&st.Enabled, &st.SlotMinutes, &st.DaysAhead, &st.LeadMinutes, &st.Capacity)
	if errors.Is(err, pgx.ErrNoRows) {
		return st, nil
	}
	return st, err
}

func saveSlotSettings(ctx context.Context, q db.Querier, storeID string, in SlotSettingsInput) error {
	_, err := q.Exec(ctx, `
		INSERT INTO delivery_slot_rules (store_id, enabled, slot_minutes, days_ahead, lead_minutes, capacity)
		VALUES ($1, COALESCE($2, false), COALESCE($3, 60), COALESCE($4, 1), COALESCE($5, 60), COALESCE($6, 5))
		ON CONFLICT (store_id) DO UPDATE SET
			enabled = COALESCE($2, delivery_slot_rules.enabled),
			slot_minutes = COALESCE($3, delivery_slot_rules.slot_minutes),
			days_ahead = COALESCE($4, delivery_slot_rules.days_ahead),
			lead_minutes = COALESCE($5, delivery_slot_rules.lead_minutes),
			capacity = COALESCE($6, delivery_slot_rules.capacity),
			updated_at = now()`,
		storeID, in.Enabled, in.SlotMinutes, in.DaysAhead, in.LeadMinutes, in.Capacity)
	return err
}

// Slot — окно доставки. Status: free, past (слишком скоро или прошло), full.
type Slot struct {
	From   time.Time `json:"from"`
	To     time.Time `json:"to"`
	Status string    `json:"status"`
	Left   int       `json:"left"`
}

type SlotDay struct {
	Date  string `json:"date"` // ГГГГ-ММ-ДД по Ташкенту
	Slots []Slot `json:"slots"`
}

type SlotsView struct {
	Enabled bool      `json:"enabled"`
	Days    []SlotDay `json:"days"`
}

// Слоты по умолчанию, если у магазина не заданы часы работы (работает круглосуточно).
const defaultOpens, defaultCloses = 8 * time.Hour, 22 * time.Hour

// windows — окна на день day (полночь по Ташкенту) по часам работы.
func windows(hours []WorkingHours, day time.Time, slot time.Duration) [][2]time.Time {
	opens, closes := defaultOpens, defaultCloses
	if len(hours) > 0 {
		found := false
		for _, h := range hours {
			if h.Weekday == int(day.Weekday()) {
				o, err1 := parseClock(h.Opens)
				c, err2 := parseClock(h.Closes)
				if err1 != nil || err2 != nil {
					return nil
				}
				if c <= o { // работает после полуночи — окна до конца дня
					c = 24 * time.Hour
				}
				opens, closes, found = o, c, true
			}
		}
		if !found {
			return nil
		}
	}
	var out [][2]time.Time
	for t := opens; t+slot <= closes; t += slot {
		out = append(out, [2]time.Time{day.Add(t), day.Add(t + slot)})
	}
	return out
}

func hoursOf(ctx context.Context, q db.Querier, storeID string) ([]WorkingHours, error) {
	rows, err := q.Query(ctx, `SELECT weekday, to_char(opens, 'HH24:MI'), to_char(closes, 'HH24:MI')
		FROM store_working_hours WHERE store_id = $1 ORDER BY weekday`, storeID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[WorkingHours])
}

// booked — сколько активных заказов в каждом окне с from по to.
func booked(ctx context.Context, q db.Querier, storeID string, from, to time.Time) (map[int64]int, error) {
	rows, err := q.Query(ctx, `
		SELECT delivery_from, count(*) FROM orders
		WHERE store_id = $1 AND delivery_from >= $2 AND delivery_from < $3 AND status NOT IN ('cancelled', 'expired')
		GROUP BY delivery_from`, storeID, from, to)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int64]int{}
	for rows.Next() {
		var t time.Time
		var n int
		if err := rows.Scan(&t, &n); err != nil {
			return nil, err
		}
		out[t.Unix()] = n
	}
	return out, rows.Err()
}

func (s *Service) slotsView(ctx context.Context, q db.Querier, storeID string, st SlotSettings) (SlotsView, error) {
	view := SlotsView{Enabled: st.Enabled, Days: []SlotDay{}}
	if !st.Enabled {
		return view, nil
	}
	hours, err := hoursOf(ctx, q, storeID)
	if err != nil {
		return view, err
	}
	now := s.now().In(Tashkent)
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, Tashkent)
	end := today.AddDate(0, 0, st.DaysAhead+1)
	counts, err := booked(ctx, q, storeID, today, end)
	if err != nil {
		return view, err
	}
	earliest := now.Add(time.Duration(st.LeadMinutes) * time.Minute)
	for d := 0; d <= st.DaysAhead; d++ {
		day := today.AddDate(0, 0, d)
		sd := SlotDay{Date: day.Format("2006-01-02"), Slots: []Slot{}}
		for _, w := range windows(hours, day, time.Duration(st.SlotMinutes)*time.Minute) {
			sl := Slot{From: w[0], To: w[1], Left: st.Capacity - counts[w[0].Unix()], Status: "free"}
			if sl.Left < 0 {
				sl.Left = 0
			}
			switch {
			case w[0].Before(earliest):
				sl.Status, sl.Left = "past", 0
			case sl.Left == 0:
				sl.Status = "full"
			}
			sd.Slots = append(sd.Slots, sl)
		}
		view.Days = append(view.Days, sd)
	}
	return view, nil
}

// Slots — окна доставки магазина для приложения.
func (s *Service) Slots(ctx context.Context, storeID string) (SlotsView, error) {
	st, err := getSlotSettings(ctx, s.pool, storeID, false)
	if err != nil {
		return SlotsView{}, err
	}
	return s.slotsView(ctx, s.pool, storeID, st)
}

var (
	ErrSlotUnavailable = apperr.Conflict("slot_unavailable", "это время доставки недоступно, выберите другое").Uz("bu yetkazib berish vaqti mavjud emas, boshqasini tanlang")
	ErrSlotFull        = apperr.Conflict("slot_full", "на это время заказов больше не принимаем, выберите другое").Uz("bu vaqtga boshqa buyurtma qabul qilinmaydi, boshqa vaqtni tanlang")
)

// CheckSlot проверяет окно, которое начинается в from, и возвращает его конец.
// lock — заблокировать настройки окон магазина до конца транзакции, чтобы
// два заказа не заняли последнее место одновременно.
func (s *Service) CheckSlot(ctx context.Context, q db.Querier, storeID string, from time.Time, lock bool) (time.Time, error) {
	st, err := getSlotSettings(ctx, q, storeID, lock)
	if err != nil {
		return time.Time{}, err
	}
	view, err := s.slotsView(ctx, q, storeID, st)
	if err != nil {
		return time.Time{}, err
	}
	for _, d := range view.Days {
		for _, sl := range d.Slots {
			if !sl.From.Equal(from) {
				continue
			}
			switch sl.Status {
			case "free":
				return sl.To, nil
			case "full":
				return time.Time{}, ErrSlotFull
			}
			return time.Time{}, ErrSlotUnavailable
		}
	}
	return time.Time{}, ErrSlotUnavailable
}
