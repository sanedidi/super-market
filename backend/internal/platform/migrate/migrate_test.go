package migrate

import (
	"context"
	"io"
	"log/slog"
	"os"
	"testing"
	"testing/fstest"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestLoadSortsByVersion(t *testing.T) {
	fsys := fstest.MapFS{
		"0010_orders.sql": {Data: []byte("SELECT 10;")},
		"0002_tenant.sql": {Data: []byte("SELECT 2;")},
		"0001_init.sql":   {Data: []byte("SELECT 1;")},
		"README.md":       {Data: []byte("не миграция")},
	}
	got, err := Load(fsys)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	want := []int64{1, 2, 10}
	if len(got) != len(want) {
		t.Fatalf("got %d migrations, want %d", len(got), len(want))
	}
	for i, v := range want {
		if got[i].Version != v {
			t.Errorf("migration %d: version %d, want %d", i, got[i].Version, v)
		}
	}
	if got[1].Name != "tenant" || got[1].SQL != "SELECT 2;" {
		t.Errorf("unexpected migration: %+v", got[1])
	}
}

func TestLoadRejectsBadFiles(t *testing.T) {
	cases := map[string]fstest.MapFS{
		"no name":       {"0001.sql": {Data: []byte("x")}},
		"bad version":   {"abc_init.sql": {Data: []byte("x")}},
		"zero version":  {"0000_init.sql": {Data: []byte("x")}},
		"duplicate ver": {"0001_a.sql": {Data: []byte("x")}, "1_b.sql": {Data: []byte("y")}},
	}
	for name, fsys := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := Load(fsys); err == nil {
				t.Fatal("expected error")
			}
		})
	}
}

// TestUpAgainstPostgres запускается, только если задан TEST_DATABASE_URL
// (в CI — да, локально — по желанию).
func TestUpAgainstPostgres(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL не задан")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatalf("pool: %v", err)
	}
	defer pool.Close()

	// Отдельная схема, чтобы тест не трогал реальные таблицы.
	if _, err := pool.Exec(ctx, "DROP SCHEMA IF EXISTS migrate_test CASCADE; CREATE SCHEMA migrate_test"); err != nil {
		t.Fatalf("schema: %v", err)
	}
	defer pool.Exec(ctx, "DROP SCHEMA IF EXISTS migrate_test CASCADE")

	cfg := pool.Config().Copy()
	cfg.ConnConfig.RuntimeParams["search_path"] = "migrate_test"
	testPool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatalf("test pool: %v", err)
	}
	defer testPool.Close()

	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	fsys := fstest.MapFS{
		"0001_items.sql": {Data: []byte("CREATE TABLE items (id int PRIMARY KEY); INSERT INTO items VALUES (1);")},
		"0002_more.sql":  {Data: []byte("INSERT INTO items VALUES (2);")},
	}

	n, err := Up(ctx, testPool, fsys, log)
	if err != nil || n != 2 {
		t.Fatalf("first Up: n=%d err=%v", n, err)
	}
	n, err = Up(ctx, testPool, fsys, log)
	if err != nil || n != 0 {
		t.Fatalf("second Up must be a no-op: n=%d err=%v", n, err)
	}

	// Сломанная миграция не должна оставить ни данных, ни записи о версии.
	fsys["0003_broken.sql"] = &fstest.MapFile{Data: []byte("INSERT INTO items VALUES (3); SELECT * FROM missing_table;")}
	if _, err := Up(ctx, testPool, fsys, log); err == nil {
		t.Fatal("broken migration must fail")
	}
	var count int
	if err := testPool.QueryRow(ctx, "SELECT count(*) FROM items").Scan(&count); err != nil || count != 2 {
		t.Fatalf("items after failed migration: count=%d err=%v", count, err)
	}
	if err := testPool.QueryRow(ctx, "SELECT count(*) FROM schema_migrations").Scan(&count); err != nil || count != 2 {
		t.Fatalf("schema_migrations after failed migration: count=%d err=%v", count, err)
	}
}
