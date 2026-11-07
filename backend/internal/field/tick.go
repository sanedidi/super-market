package field

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

// Tick (worker, раз в минуту):
//   - продажник стоит на месте дольше 30 минут — обход на паузе (как только
//     снова пойдёт, пауза снимется сама — см. AddPoints);
//   - в 21:00 по Ташкенту и для обходов, начатых в прошлые дни, — обход
//     закрывается (забыл нажать «Закончить»);
//   - обход на паузе дольше 3 часов закрывается.
func (s *Service) Tick(ctx context.Context) error {
	now := s.now()
	local := now.In(tz)
	endOfDay := time.Date(local.Year(), local.Month(), local.Day(), autoEndHour, 0, 0, 0, tz)
	startOfDay := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, tz)
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT id, status, last_lat, last_lng FROM field_walks
			WHERE status <> 'ended' AND (
			      started_at < $1
			   OR ($2::timestamptz >= $3::timestamptz AND started_at < $3)
			   OR (status = 'paused' AND paused_at < $2::timestamptz - interval '3 hours'))
			FOR UPDATE SKIP LOCKED`, startOfDay, now, endOfDay)
		if err != nil {
			return err
		}
		type open struct {
			id, status string
			lat, lng   *float64
		}
		var toEnd []open
		for rows.Next() {
			var o open
			if err := rows.Scan(&o.id, &o.status, &o.lat, &o.lng); err != nil {
				rows.Close()
				return err
			}
			toEnd = append(toEnd, o)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		for _, o := range toEnd {
			if err := endWalk(ctx, tx, o.id, "auto", now, walkRow{status: o.status, lastLat: o.lat, lastLng: o.lng}); err != nil {
				return err
			}
		}
		rows, err = tx.Query(ctx, `
			UPDATE field_walks SET status = 'paused', paused_at = COALESCE(last_moved_at, started_at) + $2::interval, auto_paused = true
			WHERE status = 'active' AND COALESCE(last_moved_at, started_at) < $1::timestamptz - $2::interval
			RETURNING id, paused_at, last_lat, last_lng`, now, fmt.Sprintf("%d minutes", int(autoPauseAfter.Minutes())))
		if err != nil {
			return err
		}
		type paused struct {
			id       string
			at       time.Time
			lat, lng *float64
		}
		var ps []paused
		for rows.Next() {
			var p paused
			if err := rows.Scan(&p.id, &p.at, &p.lat, &p.lng); err != nil {
				rows.Close()
				return err
			}
			ps = append(ps, p)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		for _, p := range ps {
			if err := addEvent(ctx, tx, p.id, p.at, "auto_pause", p.lat, p.lng, nil); err != nil {
				return err
			}
		}
		return nil
	})
}
