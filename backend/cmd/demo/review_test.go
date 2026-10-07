package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/db/migrations"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/config"
	"github.com/sanedidi/super-market/backend/internal/platform/migrate"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// freshDB — отдельная база на тест с миграциями (как в internal/server).
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
	name := "demo_" + hex.EncodeToString(b)
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+name); err != nil {
		t.Fatalf("create db: %v", err)
	}
	t.Cleanup(func() {
		_, _ = admin.Exec(context.Background(), "DROP DATABASE IF EXISTS "+name+" WITH (FORCE)")
		admin.Close()
	})
	u, err := url.Parse(base)
	if err != nil {
		t.Fatal(err)
	}
	u.Path = "/" + name
	pool, err := pgxpool.New(ctx, u.String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	quiet := slog.New(slog.NewTextHandler(io.Discard, nil))
	if _, err := migrate.Up(ctx, pool, migrations.FS, quiet); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if err := ensureSeedTable(ctx, pool); err != nil {
		t.Fatal(err)
	}
	return pool
}

const (
	testReviewPhone = "+998900000077"
	testReviewCode  = "343549"
)

func testConfig() config.Config {
	return config.Config{
		Env:         config.EnvDev,
		JWTSecret:   "test-secret-test-secret-test-secret",
		AccessTTL:   15 * time.Minute,
		RefreshTTL:  24 * time.Hour,
		OTPTTL:      5 * time.Minute,
		ReviewLogin: testReviewPhone + ":" + testReviewCode,
	}
}

func count(t *testing.T, pool *pgxpool.Pool, sql string, args ...any) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(context.Background(), sql, args...).Scan(&n); err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
	return n
}

func TestReviewFlow(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	cfg := testConfig()

	// Без REVIEW_LOGIN и без seed — понятные ошибки.
	noLogin := cfg
	noLogin.ReviewLogin = ""
	if _, err := review(ctx, noLogin, pool); err == nil || !strings.Contains(err.Error(), "REVIEW_LOGIN") {
		t.Fatalf("без REVIEW_LOGIN: %v", err)
	}
	if _, err := review(ctx, cfg, pool); err == nil || !strings.Contains(err.Error(), "demo seed") {
		t.Fatalf("без seed: %v", err)
	}

	// Номер проверки уже есть (покупатель): после clean он должен остаться.
	if _, err := pool.Exec(ctx, `INSERT INTO users (phone) VALUES ($1)`, testReviewPhone); err != nil {
		t.Fatal(err)
	}
	if err := seed(ctx, cfg, pool, ""); err != nil {
		t.Fatalf("seed: %v", err)
	}
	first, err := review(ctx, cfg, pool)
	if err != nil {
		t.Fatalf("review: %v", err)
	}
	second, err := review(ctx, cfg, pool)
	if err != nil {
		t.Fatalf("review повторно: %v", err)
	}
	if first.courierPwd != second.courierPwd || first.courierPwd != reviewPassword(cfg.JWTSecret) || len(first.courierPwd) < 8 {
		t.Fatalf("пароль курьера: %q / %q", first.courierPwd, second.courierPwd)
	}
	if first.crowdCode == "" || first.crowdCode != second.crowdCode {
		t.Fatalf("код курьера: %q / %q", first.crowdCode, second.crowdCode)
	}
	// Повтор ничего не задвоил; сессии и коды, открытые review, удалены.
	if n := count(t, pool, `SELECT count(*) FROM employees e JOIN users u ON u.id = e.user_id WHERE u.phone = $1`, testReviewPhone); n != 1 {
		t.Fatalf("сотрудников с номером проверки: %d", n)
	}
	if n := count(t, pool, `SELECT count(*) FROM customer_addresses a JOIN users u ON u.id = a.user_id WHERE u.phone = $1`, testReviewPhone); n != 1 {
		t.Fatalf("адресов: %d", n)
	}
	if n := count(t, pool, `SELECT count(*) FROM sessions s JOIN users u ON u.id = s.user_id WHERE u.phone = ANY($1)`,
		[]string{testReviewPhone, reviewCourierPhone}); n != 0 {
		t.Fatalf("осталось сессий: %d", n)
	}
	if n := count(t, pool, `SELECT count(*) FROM auth_codes`); n != 0 {
		t.Fatalf("осталось кодов: %d", n)
	}

	// Как проверяющий: отдельный сервер, без кода разработчика.
	app, err := server.Build(ctx, cfg, pool, nil, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	c := client{h: app.Handler, reviewPhone: testReviewPhone, reviewCode: testReviewCode}

	store, err := c.login(testReviewPhone, identity.AppStore)
	if err != nil {
		t.Fatalf("вход в магазин: %v", err)
	}
	emps, err := c.call("GET", "/store/employees", store, nil, http.StatusOK)
	if err != nil || len(items(emps)) < 3 {
		t.Fatalf("сотрудники сети: %v %v", emps, err)
	}
	crowd, err := c.loginTerms(testReviewPhone, identity.AppCrowd, false)
	if err != nil {
		t.Fatalf("вход курьера «по пути»: %v", err)
	}
	me, err := c.call("GET", "/crowd/me", crowd, nil, http.StatusOK)
	if err != nil || str(me, "status") != "active" || str(me, "full_name") != "Демо Курьер" {
		t.Fatalf("курьер «по пути»: %v %v", me, err)
	}
	feed, err := c.call("GET", "/crowd/offers?lat=41.2856&lng=69.2044", crowd, nil, http.StatusOK)
	if err != nil || str(feed, "state") != "ok" {
		t.Fatalf("лента: %v %v", feed, err)
	}
	if _, err := c.login(testReviewPhone, identity.AppClient); err != nil {
		t.Fatalf("вход покупателя: %v", err)
	}
	if _, err := c.call("POST", "/auth/courier/login", "", obj{"login": reviewCourierLogin, "password": first.courierPwd}, http.StatusOK); err != nil {
		t.Fatalf("вход курьера магазина: %v", err)
	}
	// Код для админ-панели номер проверки не открывает.
	if _, err := c.login(testReviewPhone, identity.AppAdmin); err == nil {
		t.Fatal("номер проверки вошёл в панель супер-админа")
	}

	if err := clean(ctx, pool); err != nil {
		t.Fatalf("clean: %v", err)
	}
	if n := count(t, pool, `SELECT count(*) FROM users WHERE phone = $1`, testReviewPhone); n != 1 {
		t.Fatalf("пользователь, бывший до review, удалён: %d", n)
	}
	for _, q := range []string{
		`SELECT count(*) FROM employees e JOIN users u ON u.id = e.user_id WHERE u.phone = '` + testReviewPhone + `'`,
		`SELECT count(*) FROM crowd_couriers cc JOIN users u ON u.id = cc.user_id WHERE u.phone = '` + testReviewPhone + `'`,
		`SELECT count(*) FROM customer_addresses a JOIN users u ON u.id = a.user_id WHERE u.phone = '` + testReviewPhone + `'`,
		`SELECT count(*) FROM customers c JOIN users u ON u.id = c.user_id WHERE u.phone = '` + testReviewPhone + `'`,
		`SELECT count(*) FROM courier_logins WHERE login = 'review'`,
		`SELECT count(*) FROM users WHERE phone = '` + reviewCourierPhone + `'`,
		`SELECT count(*) FROM demo_seed`,
	} {
		if n := count(t, pool, q); n != 0 {
			t.Fatalf("после clean: %s = %d", q, n)
		}
	}

	// Номера не было до review — clean удаляет и пользователя.
	for _, q := range []string{
		`DELETE FROM sessions WHERE user_id = (SELECT id FROM users WHERE phone = $1)`, // входы этого теста
		`DELETE FROM users WHERE phone = $1`,
	} {
		if _, err := pool.Exec(ctx, q, testReviewPhone); err != nil {
			t.Fatal(err)
		}
	}
	if err := seed(ctx, cfg, pool, ""); err != nil {
		t.Fatalf("seed 2: %v", err)
	}
	if _, err := review(ctx, cfg, pool); err != nil {
		t.Fatalf("review 2: %v", err)
	}
	if err := clean(ctx, pool); err != nil {
		t.Fatalf("clean 2: %v", err)
	}
	if n := count(t, pool, `SELECT count(*) FROM users WHERE phone = ANY($1)`, []string{testReviewPhone, reviewCourierPhone}); n != 0 {
		t.Fatalf("пользователи review не удалены: %d", n)
	}
}
