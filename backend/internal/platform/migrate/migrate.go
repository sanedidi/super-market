// Package migrate применяет SQL-миграции из встроенной файловой системы.
//
// Формат файла: <версия>_<название>.sql, например 0001_init.sql.
// Каждая миграция выполняется в своей транзакции вместе с записью
// в таблицу schema_migrations, поэтому применяется целиком или никак.
// Advisory lock не даёт двум процессам мигрировать одновременно.
package migrate

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"path"
	"sort"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// lockID — произвольная константа для pg_advisory_lock.
const lockID int64 = 7_345_001

// Migration — один SQL-файл.
type Migration struct {
	Version int64
	Name    string
	SQL     string
}

// Load читает и сортирует миграции. Ошибка, если имя файла не по формату
// или две миграции имеют одну версию.
func Load(fsys fs.FS) ([]Migration, error) {
	entries, err := fs.ReadDir(fsys, ".")
	if err != nil {
		return nil, fmt.Errorf("чтение папки миграций: %w", err)
	}

	var out []Migration
	seen := map[int64]string{}
	for _, e := range entries {
		if e.IsDir() || path.Ext(e.Name()) != ".sql" {
			continue
		}
		base := strings.TrimSuffix(e.Name(), ".sql")
		verStr, name, ok := strings.Cut(base, "_")
		if !ok || name == "" {
			return nil, fmt.Errorf("миграция %q: ожидается имя вида 0001_name.sql", e.Name())
		}
		ver, err := strconv.ParseInt(verStr, 10, 64)
		if err != nil || ver <= 0 {
			return nil, fmt.Errorf("миграция %q: версия должна быть положительным числом", e.Name())
		}
		if prev, dup := seen[ver]; dup {
			return nil, fmt.Errorf("миграции %q и %q имеют одну версию %d", prev, e.Name(), ver)
		}
		seen[ver] = e.Name()

		body, err := fs.ReadFile(fsys, e.Name())
		if err != nil {
			return nil, fmt.Errorf("чтение %q: %w", e.Name(), err)
		}
		out = append(out, Migration{Version: ver, Name: name, SQL: string(body)})
	}

	sort.Slice(out, func(i, j int) bool { return out[i].Version < out[j].Version })
	return out, nil
}

// Up применяет все ещё не применённые миграции и возвращает их количество.
func Up(ctx context.Context, pool *pgxpool.Pool, fsys fs.FS, log *slog.Logger) (int, error) {
	migrations, err := Load(fsys)
	if err != nil {
		return 0, err
	}

	conn, err := pool.Acquire(ctx)
	if err != nil {
		return 0, fmt.Errorf("соединение для миграций: %w", err)
	}
	defer conn.Release()

	if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock($1)", lockID); err != nil {
		return 0, fmt.Errorf("advisory lock: %w", err)
	}
	defer func() {
		// Используем отдельный контекст: даже при отмене ctx блокировку нужно снять.
		_, _ = conn.Exec(context.WithoutCancel(ctx), "SELECT pg_advisory_unlock($1)", lockID)
	}()

	if _, err := conn.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS schema_migrations (
			version    bigint      PRIMARY KEY,
			name       text        NOT NULL,
			applied_at timestamptz NOT NULL DEFAULT now()
		)`); err != nil {
		return 0, fmt.Errorf("создание schema_migrations: %w", err)
	}

	applied, err := appliedVersions(ctx, conn.Conn())
	if err != nil {
		return 0, err
	}

	count := 0
	for _, m := range migrations {
		if applied[m.Version] {
			continue
		}
		if err := apply(ctx, conn.Conn(), m); err != nil {
			return count, err
		}
		log.Info("миграция применена", "version", m.Version, "name", m.Name)
		count++
	}
	return count, nil
}

func appliedVersions(ctx context.Context, conn *pgx.Conn) (map[int64]bool, error) {
	rows, err := conn.Query(ctx, "SELECT version FROM schema_migrations")
	if err != nil {
		return nil, fmt.Errorf("чтение schema_migrations: %w", err)
	}
	versions, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return nil, fmt.Errorf("чтение schema_migrations: %w", err)
	}
	out := make(map[int64]bool, len(versions))
	for _, v := range versions {
		out[v] = true
	}
	return out, nil
}

func apply(ctx context.Context, conn *pgx.Conn, m Migration) (err error) {
	tx, err := conn.Begin(ctx)
	if err != nil {
		return fmt.Errorf("миграция %d: begin: %w", m.Version, err)
	}
	defer func() {
		if err != nil {
			err = errors.Join(err, rollback(ctx, tx))
		}
	}()

	// Exec без аргументов идёт через simple protocol, поэтому в одном
	// файле можно писать несколько SQL-команд.
	if _, err = tx.Exec(ctx, m.SQL); err != nil {
		return fmt.Errorf("миграция %d_%s: %w", m.Version, m.Name, err)
	}
	if _, err = tx.Exec(ctx,
		"INSERT INTO schema_migrations (version, name) VALUES ($1, $2)", m.Version, m.Name); err != nil {
		return fmt.Errorf("миграция %d: запись версии: %w", m.Version, err)
	}
	if err = tx.Commit(ctx); err != nil {
		return fmt.Errorf("миграция %d: commit: %w", m.Version, err)
	}
	return nil
}

func rollback(ctx context.Context, tx pgx.Tx) error {
	if err := tx.Rollback(context.WithoutCancel(ctx)); err != nil && !errors.Is(err, pgx.ErrTxClosed) {
		return fmt.Errorf("rollback: %w", err)
	}
	return nil
}
