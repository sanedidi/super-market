package productsearch

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Ranker обновляет данные поиска, задача воркера:
//   - раз в час — вес товаров в выдаче (product_search.score: продажи и
//     заказы за 30 дней во всех магазинах плюс в скольких магазинах товар
//     заведён) и слова новых и изменённых товаров в словаре опечаток
//     (search_words);
//   - раз в сутки — словарь целиком (убрать слова удалённых товаров,
//     пересчитать частоты); при старте воркера — только если словарь пуст.
//
// Работает в своей горутине (Run), чтобы долгий пересчёт на большом
// каталоге не задерживал остальные задачи воркера.
type Ranker struct {
	pool *pgxpool.Pool

	mu       sync.Mutex
	lastRank time.Time
	lastFull time.Time
}

const (
	rankEvery = time.Hour
	fullEvery = 24 * time.Hour
)

func NewRanker(pool *pgxpool.Pool) *Ranker { return &Ranker{pool: pool} }

// Run вызывает Tick раз в every, пока не отменён ctx.
func (r *Ranker) Run(ctx context.Context, every time.Duration, log *slog.Logger) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		start := time.Now()
		if err := r.Tick(ctx); err != nil && ctx.Err() == nil {
			log.Error("данные поиска не обновлены", "err", err)
		} else if d := time.Since(start); d > time.Second {
			log.Info("данные поиска обновлены", "duration_ms", d.Milliseconds())
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// Tick сам решает, пора ли что-то пересчитывать.
func (r *Ranker) Tick(ctx context.Context) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := time.Now()
	if r.lastFull.IsZero() {
		// Первый запуск: словарь, заполненный миграцией или прошлым запуском
		// воркера, годится — полную пересборку отложим на сутки.
		var filled bool
		if err := r.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM search_words)`).Scan(&filled); err != nil {
			return err
		}
		if filled {
			r.lastFull = now
		}
	}
	if now.Sub(r.lastFull) >= fullEvery {
		if err := RefreshWords(ctx, r.pool, time.Time{}); err != nil {
			return err
		}
		r.lastFull = now
	}
	if now.Sub(r.lastRank) < rankEvery {
		return nil
	}
	if err := RefreshRanks(ctx, r.pool); err != nil {
		return err
	}
	// Слова товаров, изменённых с прошлого раза (с запасом на долгие транзакции).
	if !r.lastRank.IsZero() {
		if err := RefreshWords(ctx, r.pool, r.lastRank.Add(-10*time.Minute)); err != nil {
			return err
		}
	}
	r.lastRank = now
	return nil
}

// RefreshRanks пересчитывает вес товаров в выдаче (product_search.score).
func RefreshRanks(ctx context.Context, pool *pgxpool.Pool) error {
	_, err := pool.Exec(ctx, `
		WITH x AS (
			SELECT product_id, (sum(purchases) + 5 * sum(stores))::int AS score FROM (
				SELECT product_id, purchases, 0 AS stores FROM product_popularity
				UNION ALL
				SELECT product_id, 0, 1 FROM store_products
			) u GROUP BY product_id
		)
		UPDATE product_search s SET score = COALESCE(x.score, 0)
		FROM product_search s2 LEFT JOIN x ON x.product_id = s2.product_id
		WHERE s.product_id = s2.product_id AND s.score <> COALESCE(x.score, 0)`)
	return err
}

// wordsSQL — слова из всех написаний названий (от 4 символов, не только цифры)
// и в скольких написаниях они встречаются.
const wordsSQL = `
	SELECT w, count(*)::int
	FROM product_search s, regexp_split_to_table(translate(s.text, '|', ' '), ' ') AS w
	WHERE s.is_active AND char_length(w) >= 4 AND w ~ '[^0-9]'`

// RefreshWords обновляет словарь опечаток: since нулевое — целиком,
// иначе добавляет слова товаров, изменённых после since.
func RefreshWords(ctx context.Context, pool *pgxpool.Pool, since time.Time) error {
	if !since.IsZero() {
		_, err := pool.Exec(ctx, `
			INSERT INTO search_words (word, freq)`+wordsSQL+`
			  AND s.product_id IN (SELECT id FROM products WHERE updated_at >= $1)
			GROUP BY w
			ON CONFLICT (word) DO NOTHING`, since)
		return err
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `DELETE FROM search_words`); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO search_words (word, freq)`+wordsSQL+` GROUP BY w`); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
