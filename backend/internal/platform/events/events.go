// Package events — «что-то изменилось в магазине» для экранов кухни, экрана
// выдачи и кассы кафе. У магазина есть версия событий (store_event_versions);
// любое изменение бегунков, стоп-листа или настроек кухни увеличивает её в
// той же транзакции и шлёт NOTIFY (Postgres доставит его при COMMIT).
//
// Устройство ждёт изменений длинным запросом (long polling): «версия больше
// N?» — ответ сразу, как только версия выросла, или через ~25 секунд. Через
// nginx и мобильный интернет это надёжнее потока событий, а задержка та же.
package events

import (
	"context"
	"errors"
	"log/slog"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

const channel = "store_events"

// Bump увеличивает версию событий магазина. Вызывать в транзакции изменения:
// экраны узнают о нём только после COMMIT.
func Bump(ctx context.Context, q db.Querier, storeID string) (int64, error) {
	var v int64
	if err := q.QueryRow(ctx, `
		INSERT INTO store_event_versions (store_id, version) VALUES ($1, 1)
		ON CONFLICT (store_id) DO UPDATE SET version = store_event_versions.version + 1
		RETURNING version`, storeID).Scan(&v); err != nil {
		return 0, err
	}
	_, err := q.Exec(ctx, `SELECT pg_notify($1, $2)`, channel, storeID+":"+strconv.FormatInt(v, 10))
	return v, err
}

// Version — текущая версия событий магазина (0 — изменений ещё не было).
func Version(ctx context.Context, q db.Querier, storeID string) (int64, error) {
	var v int64
	err := q.QueryRow(ctx, `SELECT version FROM store_event_versions WHERE store_id = $1`, storeID).Scan(&v)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, nil
	}
	return v, err
}

// Hub будит ожидающих по NOTIFY. Слушает отдельным соединением (не из пула),
// запускается при первом ожидании.
type Hub struct {
	pool    *pgxpool.Pool
	log     *slog.Logger
	once    sync.Once
	mu      sync.Mutex
	waiters map[string]map[chan struct{}]struct{}
}

func NewHub(pool *pgxpool.Pool, log *slog.Logger) *Hub {
	return &Hub{pool: pool, log: log, waiters: map[string]map[chan struct{}]struct{}{}}
}

// Wait возвращает версию событий магазина, как только она станет больше after,
// или текущую — по истечении max (или если клиент ушёл).
func (h *Hub) Wait(ctx context.Context, storeID string, after int64, max time.Duration) (int64, error) {
	h.once.Do(func() { go h.listen(context.Background()) })
	ch := make(chan struct{}, 1)
	h.mu.Lock()
	if h.waiters[storeID] == nil {
		h.waiters[storeID] = map[chan struct{}]struct{}{}
	}
	h.waiters[storeID][ch] = struct{}{}
	h.mu.Unlock()
	defer func() {
		h.mu.Lock()
		delete(h.waiters[storeID], ch)
		if len(h.waiters[storeID]) == 0 {
			delete(h.waiters, storeID)
		}
		h.mu.Unlock()
	}()

	// Ожидающий записан до чтения версии — изменение между ними не потеряется.
	v, err := Version(ctx, h.pool, storeID)
	if err != nil || v > after {
		return v, err
	}
	timer := time.NewTimer(max)
	defer timer.Stop()
	select {
	case <-ch:
	case <-timer.C:
	case <-ctx.Done():
		return v, nil
	}
	return Version(ctx, h.pool, storeID)
}

func (h *Hub) wake(storeID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.waiters[storeID] {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

// wakeAll — после переподключения: уведомления за время обрыва потеряны,
// пусть все перечитают версию.
func (h *Hub) wakeAll() {
	h.mu.Lock()
	ids := make([]string, 0, len(h.waiters))
	for id := range h.waiters {
		ids = append(ids, id)
	}
	h.mu.Unlock()
	for _, id := range ids {
		h.wake(id)
	}
}

func (h *Hub) listen(ctx context.Context) {
	for {
		err := h.listenOnce(ctx)
		if ctx.Err() != nil {
			return
		}
		if h.log != nil {
			h.log.Warn("events: соединение LISTEN оборвалось, переподключаюсь", "err", err)
		}
		time.Sleep(2 * time.Second)
	}
}

func (h *Hub) listenOnce(ctx context.Context) error {
	conn, err := pgx.ConnectConfig(ctx, h.pool.Config().ConnConfig.Copy())
	if err != nil {
		return err
	}
	defer conn.Close(context.Background())
	if _, err := conn.Exec(ctx, "LISTEN "+channel); err != nil {
		return err
	}
	h.wakeAll()
	for {
		n, err := conn.WaitForNotification(ctx)
		if err != nil {
			return err
		}
		storeID, _, _ := strings.Cut(n.Payload, ":")
		h.wake(storeID)
	}
}
