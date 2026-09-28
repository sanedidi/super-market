package server_test

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/db/migrations"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/config"
	"github.com/sanedidi/super-market/backend/internal/platform/migrate"
	"github.com/sanedidi/super-market/backend/internal/platform/telegram"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// ------------------------------------------------------------ окружение

// quietLog глушит логи; TEST_LOG=1 выводит их (для разбора 500 в тестах).
func quietLog() *slog.Logger {
	if os.Getenv("TEST_LOG") != "" {
		return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	}
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// freshDB создаёт отдельную базу на тест, применяет миграции и удаляет её в конце.
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
	name := "it_" + hex.EncodeToString(b)
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
	if _, err := migrate.Up(ctx, pool, migrations.FS, quietLog()); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return pool
}

func testConfig() config.Config {
	return config.Config{
		Env:              config.EnvDev,
		JWTSecret:        "test-secret-test-secret-test-secret",
		AccessTTL:        15 * time.Minute,
		RefreshTTL:       24 * time.Hour,
		OTPTTL:           5 * time.Minute,
		SuperAdminPhones: []string{"+998900000001"},
	}
}

// api — тонкий HTTP-клиент для тестов.
type api struct {
	t   *testing.T
	srv *httptest.Server
}

type resp struct {
	Status int
	Body   map[string]any
}

func (r resp) str(path ...string) string {
	var v any = r.Body
	for _, p := range path {
		m, _ := v.(map[string]any)
		v = m[p]
	}
	s, _ := v.(string)
	return s
}

func (r resp) items() []map[string]any {
	raw, _ := r.Body["items"].([]any)
	out := make([]map[string]any, len(raw))
	for i, x := range raw {
		out[i], _ = x.(map[string]any)
	}
	return out
}

func (a api) do(method, path, bearer string, body any) resp {
	a.t.Helper()
	var rdr io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rdr = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, a.srv.URL+"/api/v1"+path, rdr)
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	res, err := a.srv.Client().Do(req)
	if err != nil {
		a.t.Fatal(err)
	}
	defer res.Body.Close()
	out := resp{Status: res.StatusCode, Body: map[string]any{}}
	_ = json.NewDecoder(res.Body).Decode(&out.Body)
	return out
}

func (a api) expect(r resp, status int, what string) resp {
	a.t.Helper()
	if r.Status != status {
		a.t.Fatalf("%s: status %d, want %d, body %v", what, r.Status, status, r.Body)
	}
	return r
}

// login проходит вход с фиксированным dev-кодом.
func (a api) login(phone, app string) (access, refresh string) {
	a.t.Helper()
	a.expect(a.do("POST", "/auth/otp/request", "", map[string]string{"phone": phone}), 200, "request code "+phone)
	r := a.expect(a.do("POST", "/auth/otp/verify", "", map[string]string{
		"phone": phone, "code": "111111", "app": app,
	}), 200, "verify "+phone)
	return r.str("access_token"), r.str("refresh_token")
}

func newAPI(t *testing.T, cfg config.Config, pool *pgxpool.Pool, tg identity.Sender) api {
	t.Helper()
	h, err := server.New(context.Background(), cfg, pool, tg, quietLog())
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	return api{t: t, srv: srv}
}

// ----------------------------------------------------------------- тесты

// TestStage1Flow проходит этап 1 целиком: супер-админ создаёт сеть,
// владелец создаёт магазины и сотрудника, права и доступ к магазинам работают.
func TestStage1Flow(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)

	// Супер-админ.
	adminTok, _ := a.login("+998 90 000-00-01", identity.AppAdmin)
	a.expect(a.do("POST", "/auth/otp/request", "", map[string]string{"phone": "+998900000009"}), 200, "request stranger")
	a.expect(a.do("POST", "/auth/otp/verify", "", map[string]string{
		"phone": "+998900000009", "code": "111111", "app": "admin",
	}), 403, "stranger into admin")

	net := a.expect(a.do("POST", "/admin/networks", adminTok, map[string]string{
		"name": "Olma", "kind": "chain", "owner_phone": "998900000002", "owner_name": "Владелец Olma",
	}), 201, "create network")
	if net.str("owner_phone") != "+998900000002" {
		t.Fatalf("owner_phone = %q", net.str("owner_phone"))
	}
	a.expect(a.do("GET", "/admin/networks?q=olma", adminTok, nil), 200, "list networks")

	// Владелец: токен store не подходит к admin и наоборот.
	ownerTok, ownerRefresh := a.login("+998900000002", identity.AppStore)
	a.expect(a.do("GET", "/admin/networks", ownerTok, nil), 403, "store token on admin route")
	a.expect(a.do("GET", "/store/me", adminTok, nil), 403, "admin token on store route")

	me := a.expect(a.do("GET", "/store/me", ownerTok, nil), 200, "me")
	if me.Body["is_owner"] != true {
		t.Fatalf("owner is_owner = %v", me.Body["is_owner"])
	}

	// Магазины и склады.
	s1 := a.expect(a.do("POST", "/store/stores", ownerTok, map[string]any{
		"name": "Olma Чиланзар", "address": "Чиланзар 1", "lat": 41.2757, "lng": 69.2034,
	}), 201, "create store 1")
	s2 := a.expect(a.do("POST", "/store/stores", ownerTok, map[string]any{"name": "Olma Юнусабад"}), 201, "create store 2")
	store1, store2 := s1.str("id"), s2.str("id")
	if s1.str("default_warehouse_id") == "" || s1.Body["lat"].(float64) != 41.2757 {
		t.Fatalf("store 1 = %v", s1.Body)
	}
	a.expect(a.do("POST", "/store/stores", ownerTok, map[string]any{"name": "X", "lat": 41.0}), 400, "lat without lng")

	whs := a.expect(a.do("GET", "/store/warehouses?store_id="+store1, ownerTok, nil), 200, "warehouses").items()
	if len(whs) != 1 || whs[0]["is_default"] != true || whs[0]["name"] != "Основной склад" {
		t.Fatalf("warehouses = %v", whs)
	}
	a.expect(a.do("PATCH", "/store/warehouses/"+whs[0]["id"].(string), ownerTok, map[string]any{"is_active": false}),
		409, "deactivate default warehouse")
	wh2 := a.expect(a.do("POST", "/store/warehouses", ownerTok, map[string]any{"store_id": store1, "name": "Подсобка"}),
		201, "second warehouse")
	a.expect(a.do("PATCH", "/store/stores/"+store1, ownerTok, map[string]any{"default_warehouse_id": wh2.str("id")}),
		200, "switch default warehouse")
	a.expect(a.do("PATCH", "/store/stores/"+store2, ownerTok, map[string]any{"default_warehouse_id": wh2.str("id")}),
		400, "default warehouse of another store")

	// Роли и сотрудники.
	a.expect(a.do("POST", "/store/roles", ownerTok, map[string]any{"name": "Кассир", "permissions": []string{"nope"}}),
		400, "unknown permission")
	role := a.expect(a.do("POST", "/store/roles", ownerTok, map[string]any{"name": "Кассир", "permissions": []string{}}),
		201, "create role")
	roles := a.expect(a.do("GET", "/store/roles", ownerTok, nil), 200, "roles").items()
	if len(roles) != 2 || roles[0]["is_owner"] != true {
		t.Fatalf("roles = %v", roles)
	}
	a.expect(a.do("PATCH", "/store/roles/"+roles[0]["id"].(string), ownerTok, map[string]any{"name": "Босс"}),
		404, "owner role is immutable")

	emp := a.expect(a.do("POST", "/store/employees", ownerTok, map[string]any{
		"phone": "+998900000003", "full_name": "Кассир Чиланзар", "role_id": role.str("id"), "store_ids": []string{store1},
	}), 201, "create employee")
	a.expect(a.do("POST", "/store/employees", ownerTok, map[string]any{
		"phone": "+998900000003", "full_name": "Дубль", "role_id": role.str("id"),
	}), 409, "duplicate employee")

	// Кассир видит только свой магазин и не может управлять магазинами.
	cashierTok, _ := a.login("+998900000003", identity.AppStore)
	stores := a.expect(a.do("GET", "/store/stores", cashierTok, nil), 200, "cashier stores").items()
	if len(stores) != 1 || stores[0]["id"] != store1 {
		t.Fatalf("cashier sees %v", stores)
	}
	a.expect(a.do("GET", "/store/stores/"+store2, cashierTok, nil), 404, "cashier on foreign store")
	denied := a.expect(a.do("POST", "/store/stores", cashierTok, map[string]any{"name": "Y"}), 403, "cashier creates store")
	if denied.str("error", "code") != "forbidden" {
		t.Fatalf("error body = %v", denied.Body)
	}

	// Право выдали — действует сразу, без нового входа.
	a.expect(a.do("PATCH", "/store/roles/"+role.str("id"), ownerTok, map[string]any{
		"permissions": []string{identity.PermStoresManage},
	}), 200, "grant permission")
	a.expect(a.do("PATCH", "/store/stores/"+store1, cashierTok, map[string]any{"phone": "+998712000000"}),
		200, "cashier with new permission")

	// Блокировка сотрудника закрывает его сессии.
	a.expect(a.do("PATCH", "/store/employees/"+emp.str("id"), ownerTok, map[string]any{"status": "inactive"}),
		200, "deactivate employee")
	a.expect(a.do("GET", "/store/stores", cashierTok, nil), 401, "blocked employee token")

	// Refresh-токен ротируется.
	r := a.expect(a.do("POST", "/auth/refresh", "", map[string]string{"refresh_token": ownerRefresh}), 200, "refresh")
	a.expect(a.do("POST", "/auth/refresh", "", map[string]string{"refresh_token": ownerRefresh}), 401, "reused refresh")
	newTok := r.str("access_token")
	a.expect(a.do("GET", "/store/me", newTok, nil), 200, "new access token")
	a.expect(a.do("POST", "/auth/store/logout", newTok, nil), 204, "logout")
	a.expect(a.do("GET", "/store/me", newTok, nil), 401, "after logout")

	// Одиночный магазин — только один магазин.
	a.expect(a.do("POST", "/admin/networks", adminTok, map[string]string{
		"name": "Дукон у дома", "kind": "single", "owner_phone": "+998900000004", "owner_name": "Азиз",
	}), 201, "create single")
	singleTok, _ := a.login("+998900000004", identity.AppStore)
	a.expect(a.do("POST", "/store/stores", singleTok, map[string]any{"name": "Дукон"}), 201, "single store 1")
	a.expect(a.do("POST", "/store/stores", singleTok, map[string]any{"name": "Дукон 2"}), 409, "single store 2")

	// Изоляция сетей: чужой магазин не виден.
	a.expect(a.do("GET", "/store/stores/"+store1, singleTok, nil), 404, "foreign network store")

	// Заблокированная сеть не может войти.
	a.expect(a.do("PATCH", "/admin/networks/"+net.str("id"), adminTok, map[string]string{"status": "blocked"}),
		200, "block network")
	a.expect(a.do("POST", "/auth/otp/request", "", map[string]string{"phone": "+998900000005"}), 200, "request")
	a.expect(a.do("GET", "/store/stores", ownerTok, nil), 401, "blocked network token")

	// Покупатель регистрируется при первом входе.
	clientTok, _ := a.login("+998900000006", identity.AppClient)
	a.expect(a.do("GET", "/store/me", clientTok, nil), 403, "client token on store route")
}

// TestWrongCodeAttempts — после 5 неверных попыток код сгорает.
func TestWrongCodeAttempts(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)

	a.expect(a.do("POST", "/auth/otp/request", "", map[string]string{"phone": "+998900000010"}), 200, "request")
	a.expect(a.do("POST", "/auth/otp/request", "", map[string]string{"phone": "+998900000010"}), 429, "resend too soon")
	for i := 0; i < 5; i++ {
		a.expect(a.do("POST", "/auth/otp/verify", "", map[string]string{
			"phone": "+998900000010", "code": "000000", "app": "client",
		}), 400, fmt.Sprintf("wrong code %d", i+1))
	}
	a.expect(a.do("POST", "/auth/otp/verify", "", map[string]string{
		"phone": "+998900000010", "code": "111111", "app": "client",
	}), 400, "right code after too many attempts")
}

// fakeTelegram записывает отправленные сообщения вместо Telegram.
type fakeTelegram struct {
	mu   sync.Mutex
	sent []sentMsg
}

type sentMsg struct {
	chatID int64
	text   string
}

func (f *fakeTelegram) SendMessage(_ context.Context, chatID int64, text string, _ *telegram.ReplyMarkup) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = append(f.sent, sentMsg{chatID, text})
	return nil
}

func (f *fakeTelegram) GetUpdates(context.Context, int64, time.Duration) ([]telegram.Update, error) {
	return nil, nil
}

func (f *fakeTelegram) last() sentMsg {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.sent[len(f.sent)-1]
}

// TestTelegramLoginFlow — вход по настоящему коду через бота.
func TestTelegramLoginFlow(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.TelegramBotUsername = "market_test_bot"
	tg := &fakeTelegram{}
	a := newAPI(t, cfg, pool, tg)
	ctx := context.Background()

	// Номер ещё не привязан — клиент получает ссылку на бота.
	r := a.expect(a.do("POST", "/auth/otp/request", "", map[string]string{"phone": "+998901112233"}),
		409, "not linked")
	if r.str("error", "code") != "telegram_not_linked" ||
		r.Body["error"].(map[string]any)["details"].(map[string]any)["bot_url"] != "https://t.me/market_test_bot" {
		t.Fatalf("body = %v", r.Body)
	}

	svc := identity.NewService(pool, tg, server.IdentityConfig(cfg), quietLog())
	bot := identity.NewBot(svc, tg, quietLog())
	msg := func(fromID int64, contact *telegram.Contact, text string) telegram.Update {
		return telegram.Update{Message: &telegram.Message{
			From: &telegram.User{ID: fromID}, Chat: telegram.Chat{ID: fromID, Type: "private"},
			Text: text, Contact: contact,
		}}
	}

	// /start — бот просит поделиться номером.
	if err := bot.Handle(ctx, msg(555, nil, "/start")); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(tg.last().text, "Поделиться номером") {
		t.Fatalf("start reply = %q", tg.last().text)
	}

	// Чужой контакт не привязывается.
	if err := bot.Handle(ctx, msg(555, &telegram.Contact{PhoneNumber: "998901112233", UserID: 777}, "")); err != nil {
		t.Fatal(err)
	}
	a.expect(a.do("POST", "/auth/otp/request", "", map[string]string{"phone": "+998901112233"}),
		409, "foreign contact must not link")

	// Свой контакт — номер привязан, код приходит в этот чат.
	if err := bot.Handle(ctx, msg(555, &telegram.Contact{PhoneNumber: "998901112233", UserID: 555}, "")); err != nil {
		t.Fatal(err)
	}
	a.expect(a.do("POST", "/auth/otp/request", "", map[string]string{"phone": "+998901112233"}), 200, "request code")
	sent := tg.last()
	if sent.chatID != 555 {
		t.Fatalf("code sent to chat %d, want 555", sent.chatID)
	}
	code := regexp.MustCompile(`\d{6}`).FindString(sent.text)
	if code == "" {
		t.Fatalf("no code in %q", sent.text)
	}

	r = a.expect(a.do("POST", "/auth/otp/verify", "", map[string]string{
		"phone": "+998901112233", "code": code, "app": "client",
	}), 200, "verify telegram code")
	if r.str("access_token") == "" {
		t.Fatal("no access token")
	}
	// Код одноразовый.
	a.expect(a.do("POST", "/auth/otp/verify", "", map[string]string{
		"phone": "+998901112233", "code": code, "app": "client",
	}), 400, "code reuse")
}
