// Package db открывает пул соединений с PostgreSQL.
package db

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// Connect создаёт пул и проверяет, что база отвечает.
// Если база ещё поднимается (docker compose), ждёт до 30 секунд.
func Connect(ctx context.Context, url string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		return nil, fmt.Errorf("разбор DATABASE_URL: %w", err)
	}
	cfg.MaxConnLifetime = time.Hour
	cfg.MaxConnIdleTime = 5 * time.Minute
	SetupLang(cfg)

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("создание пула: %w", err)
	}

	deadline := time.Now().Add(30 * time.Second)
	for {
		pingCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
		err = pool.Ping(pingCtx)
		cancel()
		if err == nil {
			return pool, nil
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			pool.Close()
			return nil, fmt.Errorf("база недоступна: %w", err)
		}
		select {
		case <-ctx.Done():
		case <-time.After(time.Second):
		}
	}
}

// SetupLang — язык данных на соединении: перед выдачей соединения из пула
// ставит app.lang = язык контекста запроса (i18n). SQL-функция
// loc(ru, uz) читает его и отдаёт название на нужном языке. Запрос
// set_config идёт только когда язык соединения меняется.
func SetupLang(cfg *pgxpool.Config) {
	prev := cfg.BeforeAcquire
	cfg.BeforeAcquire = func(ctx context.Context, conn *pgx.Conn) bool {
		if prev != nil && !prev(ctx, conn) {
			return false
		}
		lang := i18n.FromContext(ctx)
		data := conn.PgConn().CustomData()
		if cur, _ := data["lang"].(string); cur == lang {
			return true
		}
		if _, err := conn.Exec(ctx, "SELECT set_config('app.lang', $1, false)", lang); err != nil {
			// Соединение в непонятном состоянии — пул закроет его и даст другое.
			return false
		}
		data["lang"] = lang
		return true
	}
}
