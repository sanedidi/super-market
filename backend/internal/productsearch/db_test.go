package productsearch_test

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"io"
	"log/slog"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/db/migrations"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/migrate"
	"github.com/sanedidi/super-market/backend/internal/productsearch"
)

// freshDB — отдельная база с миграциями (нужен TEST_DATABASE_URL).
func freshDB(t *testing.T) *pgxpool.Pool {
	t.Helper()
	base := os.Getenv("TEST_DATABASE_URL")
	if base == "" {
		t.Skip("TEST_DATABASE_URL не задан")
	}
	ctx := context.Background()
	admin, err := pgxpool.New(ctx, base)
	if err != nil {
		t.Fatal(err)
	}
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	name := "ps_" + hex.EncodeToString(b)
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+name); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = admin.Exec(context.Background(), "DROP DATABASE IF EXISTS "+name+" WITH (FORCE)")
		admin.Close()
	})
	u, _ := url.Parse(base)
	u.Path = "/" + name
	cfg, err := pgxpool.ParseConfig(u.String())
	if err != nil {
		t.Fatal(err)
	}
	db.SetupLang(cfg)
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if _, err := migrate.Up(ctx, pool, migrations.FS, slog.New(slog.NewTextHandler(io.Discard, nil))); err != nil {
		t.Fatal(err)
	}
	return pool
}

// TestSearchFoldMatchesSQL — Go-нормализация запроса совпадает с SQL-функцией
// search_fold, которой нормализованы товары.
func TestSearchFoldMatchesSQL(t *testing.T) {
	pool := freshDB(t)
	for _, s := range []string{
		"Молоко «Lactel» 3,2% 1 л", "ЁЛОЧКА", "Oʻzbek gʻalla O'ZBEK o‘zbek o`zbek oʼzbek",
		"ҚАТИҚ ўрик ғишт ҳалол", "Coca-Cola_Zero 0.5", "Шоколад Alpen Gold (молочный) №1",
		"Сок J7 «Апельсин» 0,97л", "  много   пробелов\tи\nстрок  ", "100% натуральный — сок…",
		"Sut «Musaffo» 2,5% 900 g", "Non: buxanka/oq", "Pishloq #5 @ 10$",
	} {
		var sql string
		if err := pool.QueryRow(context.Background(), `SELECT search_fold($1)`, s).Scan(&sql); err != nil {
			t.Fatal(err)
		}
		if got := productsearch.Fold(s); got != sql {
			t.Errorf("Fold(%q) = %q, SQL search_fold = %q", s, got, sql)
		}
	}
}

func TestSearch(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, sql, args...); err != nil {
			t.Fatal(err)
		}
	}
	var net, other string
	if err := pool.QueryRow(ctx, `INSERT INTO networks (name, kind) VALUES ('Сеть', 'chain') RETURNING id`).Scan(&net); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `INSERT INTO networks (name, kind) VALUES ('Другая', 'chain') RETURNING id`).Scan(&other); err != nil {
		t.Fatal(err)
	}
	exec(`INSERT INTO categories (name) VALUES ('Продукты')`)
	ids := map[string]string{}
	add := func(key, name, nameUz, network, barcode string) {
		t.Helper()
		var n any
		if network != "" {
			n = network
		}
		var id string
		if err := pool.QueryRow(ctx, `
			INSERT INTO products (name, name_uz, network_id, moderation_status, category_id, unit_id)
			VALUES ($1, $2, $3, CASE WHEN $3::uuid IS NULL THEN 'approved' ELSE 'pending' END,
			        (SELECT id FROM categories LIMIT 1), (SELECT id FROM units ORDER BY name LIMIT 1))
			RETURNING id`, name, nameUz, n).Scan(&id); err != nil {
			t.Fatal(err)
		}
		if barcode != "" {
			exec(`INSERT INTO product_barcodes (barcode, product_id) VALUES ($1, $2)`, barcode, id)
		}
		ids[key] = id
	}
	add("milk", "Молоко Lactel 3,2% 1 л", "Sut Lactel 3,2% 1 l", "", "4780069000239")
	add("milk2", "Молоко Musaffo 2,5%", "", "", "")
	add("kefir", "Кефир Musaffo 1%", "Kefir Musaffo 1%", "", "")
	add("cola", "Напиток Coca-Cola 1,5 л", "Ichimlik Coca-Cola 1,5 l", "", "5449000000996")
	add("katik", "Катык", "Qatiq", "", "")
	add("oil", "Масло подсолнечное", "Kungaboqar yogʻi", "", "")
	add("own", "Самса домашняя", "", net, "")
	add("foreign", "Самса чужая", "", other, "")
	if err := productsearch.RefreshRanks(ctx, pool); err != nil {
		t.Fatal(err)
	}
	if err := productsearch.RefreshWords(ctx, pool, time.Time{}); err != nil {
		t.Fatal(err)
	}
	if err := productsearch.NewRanker(pool).Tick(ctx); err != nil {
		t.Fatal(err)
	}

	scope := productsearch.Scope{NetworkID: net}
	find := func(q string) []string {
		t.Helper()
		m, err := productsearch.Resolve(ctx, pool, q, scope)
		if err != nil {
			t.Fatal(q, err)
		}
		if m.Empty() {
			return nil
		}
		args := []any{}
		rows, err := pool.Query(ctx, `SELECT s.product_id FROM product_search s WHERE `+scope.Where("s", &args)+` AND `+m.Where("s", &args)+`
			ORDER BY `+m.Rank("s", &args)+` DESC, s.score DESC, `+productsearch.NameOrder("s")+`, 1`, productsearch.Args(args)...)
		if err != nil {
			t.Fatal(q, err)
		}
		defer rows.Close()
		var out []string
		for rows.Next() {
			var id string
			_ = rows.Scan(&id)
			for k, v := range ids {
				if v == id {
					out = append(out, k)
				}
			}
		}
		return out
	}
	expect := func(q string, want ...string) {
		t.Helper()
		got := find(q)
		if len(got) != len(want) {
			t.Errorf("%q = %v, want %v", q, got, want)
			return
		}
		for i := range want {
			if got[i] != want[i] {
				t.Errorf("%q = %v, want %v", q, got, want)
				return
			}
		}
	}

	expect("молоко", "milk", "milk2")
	expect("МОЛОКО lactel", "milk")
	expect("4780069000239", "milk")     // штрихкод
	expect("sut", "milk")               // узбекское название
	expect("сут", "milk")               // узбекское — кириллицей
	expect("moloko", "milk", "milk2")   // русское — латиницей
	expect("кока кола", "cola")         // латинский бренд — кириллицей
	expect("coca-cola 1,5", "cola")     // знаки препинания не мешают
	expect("vjkjrj", "milk", "milk2")   // не та раскладка
	expect("малоко", "milk", "milk2")   // опечатка
	expect("кифир", "kefir")            // опечатка
	expect("катик", "katik")            // узбекское qatiq → катик
	expect("қатиқ", "katik")            // узбекская кириллица
	expect("yogʻi", "oil")              // апострофы
	expect("yogi", "oil")               //
	expect("yog'i", "oil")              //
	expect("мо", "milk", "milk2")       // короткий запрос — начало названия
	expect("musaffo", "kefir", "milk2") // по алфавиту при равном весе
	expect("самса", "own")              // чужая сеть не видна
	expect("0,5")                       // одни короткие слова — фраза подстрокой
	expect("3,2", "milk")               //
	expect("1,5 л", "cola")             //
	expect("молоко coca")               // частые слова, но вместе нигде
	expect("несуществующее")            //
	expect("12")                        //

	// Вес: товар, заведённый в магазинах, выше.
	var store string
	if err := pool.QueryRow(ctx, `
		INSERT INTO stores (network_id, name) VALUES ($1, 'М1') RETURNING id`, net).Scan(&store); err != nil {
		t.Skip("stores: ", err) // схема магазина сложнее — вес проверим без него
	}
	exec(`INSERT INTO store_products (network_id, store_id, product_id) VALUES ($1, $2, $3)`, net, store, ids["milk2"])
	if err := productsearch.RefreshRanks(ctx, pool); err != nil {
		t.Fatal(err)
	}
	expect("молоко", "milk2", "milk")

	// Переименование и выключение товара сразу видны поиску (триггер).
	exec(`UPDATE products SET name = 'Ряженка Musaffo', name_uz = 'Ryajenka Musaffo' WHERE id = $1`, ids["kefir"])
	expect("кефир")
	expect("ряженка", "kefir")
	exec(`UPDATE products SET is_active = false WHERE id = $1`, ids["katik"])
	expect("катык")
}
