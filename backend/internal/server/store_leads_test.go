package server_test

import (
	"context"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// TestStoreLeads — агент «SM Агент» добавляет магазин (Figma «SM Агент ·
// Добавить магазин»): дубли по телефону и по точке, закрепление на 30 дней,
// подключение супер-админом (сеть с магазином в точке заявки), отклонение
// с причиной и 50% первой оплаты подписки на баланс агента.
func TestStoreLeads(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	app, err := server.Build(ctx, cfg, pool, &fakeTelegram{}, quietLog())
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app.Handler)
	t.Cleanup(srv.Close)
	a := api{t: t, srv: srv, pool: pool}
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)

	// Существующий магазин Super Market: «Baraka» на 41.300, 69.240.
	a.expect(a.do("POST", "/admin/networks", adminTok, map[string]string{
		"name": "Baraka", "kind": "single", "owner_phone": "+998900000002", "owner_name": "Владелец",
	}), 201, "store network")
	storeTok, _ := a.login("+998900000002", identity.AppStore)
	a.expect(a.do("POST", "/store/stores", storeTok, map[string]any{"name": "Baraka Market", "lat": 41.300, "lng": 69.240}), 201, "store")

	agentTok, _, _ := setupDistributor(t, a, adminTok, "+998900000003", 41.31, 69.25)
	agent2Tok, _, _ := setupDistributor(t, a, adminTok, "+998900000004", 41.32, 69.26)
	// У владельца агента приложение — пуши о решении и начислении.
	if _, err := pool.Exec(ctx, `INSERT INTO devices (user_id, token, platform, app)
		SELECT u.id, 'device-token-' || u.id, 'android', 'store' FROM users u WHERE u.phone IN ('+998900000003', '+998900000004')`); err != nil {
		t.Fatal(err)
	}

	lead := func(tok, name, phone string, lat, lng float64) resp {
		return a.do("POST", "/store/supply/leads", tok, map[string]any{
			"name": name, "owner_name": "Азиз Каримов", "owner_phone": phone, "address": "Чиланзар-9, 14", "lat": lat, "lng": lng,
		})
	}

	// Проверки полей.
	a.expect(lead(agentTok, " ", "+998901234567", 41.35, 69.30), 400, "no name")
	a.expect(lead(agentTok, "Zamon", "12", 41.35, 69.30), 400, "bad phone")
	a.expect(a.do("POST", "/store/supply/leads", agentTok, map[string]any{"name": "Zamon", "owner_name": "Азиз", "owner_phone": "901234567"}), 400, "no point")
	a.expect(lead(storeTok, "Zamon", "+998901234567", 41.35, 69.30), 403, "store cannot add leads")

	// Дубль: номер владельца уже есть в Super Market.
	if r := a.expect(lead(agentTok, "Zamon", "+998900000002", 41.35, 69.30), 409, "phone of store owner"); r.str("error", "code") != "store_exists" ||
		r.str("error", "details", "reason") != "phone" || r.str("error", "details", "name") != "Baraka" {
		t.Fatalf("dup phone = %v", r.Body)
	}
	// Дубль: в 30 м уже есть магазин.
	if r := a.expect(lead(agentTok, "Zamon", "+998901234567", 41.30025, 69.240), 409, "nearby store"); r.str("error", "details", "reason") != "nearby" ||
		r.str("error", "details", "name") != "Baraka Market" || r.Body["error"].(map[string]any)["details"].(map[string]any)["distance_m"].(float64) > 50 {
		t.Fatalf("dup nearby = %v", r.Body)
	}

	// Заявка: закреплён за агентом 30 дней, номер нормализован.
	l1 := a.expect(lead(agentTok, "Zamon Market", "90 123 45 67", 41.35, 69.30), 201, "lead")
	if l1.str("status") != "pending" || l1.str("owner_phone") != "+998901234567" || l1.Body["invoice_amount"] != nil {
		t.Fatalf("lead = %v", l1.Body)
	}
	until, _ := time.Parse(time.RFC3339, l1.str("expires_at"))
	if d := time.Until(until); d < 29*24*time.Hour || d > 31*24*time.Hour {
		t.Fatalf("expires_at = %v", until)
	}
	l1ID := l1.str("id")
	// Второй агент: тот же номер или та же точка — закреплён за другим.
	if r := a.expect(lead(agent2Tok, "Zamon", "+998901234567", 41.40, 69.40), 409, "phone of lead"); r.str("error", "details", "kind") != "lead" ||
		r.Body["error"].(map[string]any)["details"].(map[string]any)["mine"] != false || r.str("error", "details", "until") == "" {
		t.Fatalf("dup lead = %v", r.Body)
	}
	a.expect(lead(agent2Tok, "Zamon", "+998907654321", 41.35015, 69.30), 409, "point of lead")
	a.expect(lead(agentTok, "Zamon", "+998901234567", 41.40, 69.40), 409, "own lead twice")
	// Вторая и третья заявки первого агента.
	l2ID := a.expect(lead(agentTok, "Navro'z Savdo", "+998974102218", 41.36, 69.31), 201, "lead 2").str("id")
	l3ID := a.expect(lead(agentTok, "Mini Market 24", "+998998700531", 41.37, 69.32), 201, "lead 3").str("id")

	// Агент видит только свои заявки.
	mine := a.expect(a.do("GET", "/store/supply/leads", agentTok, nil), 200, "my leads")
	if len(mine.items()) != 3 || mine.Body["counts"].(map[string]any)["pending"].(float64) != 3 || mine.str("earned") != "0.00" {
		t.Fatalf("my leads = %v", mine.Body)
	}
	a.expect(a.do("GET", "/store/supply/leads/"+l1ID, agent2Tok, nil), 404, "foreign lead")
	a.expect(a.do("GET", "/store/supply/leads?status=bad", agentTok, nil), 400, "bad filter")

	// Супер-админ: список новых, карточка с тем, что рядом.
	a.expect(a.do("GET", "/admin/store-leads", agentTok, nil), 403, "agent is not admin")
	list := a.expect(a.do("GET", "/admin/store-leads", adminTok, nil), 200, "admin list")
	if len(list.items()) != 3 || list.Body["counts"].(map[string]any)["pending"].(float64) != 3 || list.items()[0]["agent_phone"] != "+998900000003" {
		t.Fatalf("admin list = %v", list.Body)
	}
	if r := a.expect(a.do("GET", "/admin/store-leads?q=navro", adminTok, nil), 200, "search"); len(r.items()) != 1 {
		t.Fatalf("search = %v", r.Body)
	}
	// Магазин в 100 м от третьей заявки — предупреждение супер-админу.
	if _, err := pool.Exec(ctx, `UPDATE stores SET location = ST_SetSRID(ST_MakePoint(69.32, 41.3709), 4326)::geography WHERE name = 'Baraka Market'`); err != nil {
		t.Fatal(err)
	}
	card := a.expect(a.do("GET", "/admin/store-leads/"+l3ID, adminTok, nil), 200, "card")
	if nb := card.Body["nearby"].([]any); len(nb) != 1 || nb[0].(map[string]any)["name"] != "Baraka Market" || card.Body["agent_connected"].(float64) != 0 {
		t.Fatalf("card = %v", card.Body)
	}

	// Отклонение — только с причиной; магазин сразу свободен.
	a.expect(a.do("POST", "/admin/store-leads/"+l2ID+"/reject", adminTok, map[string]any{"reason": ""}), 400, "reject without reason")
	if r := a.expect(a.do("POST", "/admin/store-leads/"+l2ID+"/reject", adminTok, map[string]any{"reason": "Владелец отказался"}), 200, "reject"); r.str("status") != "rejected" {
		t.Fatalf("rejected = %v", r.Body)
	}
	a.expect(a.do("POST", "/admin/store-leads/"+l2ID+"/connect", adminTok, map[string]any{}), 409, "connect rejected")
	a.expect(lead(agent2Tok, "Navro'z Savdo", "+998974102218", 41.36, 69.31), 201, "free after reject")
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM notifications_outbox WHERE kind = 'lead_rejected' AND body LIKE '%Владелец отказался%'`); n != "1" {
		t.Fatalf("reject push = %s", n)
	}

	// Срок истёк: магазин снова свободен, подключить нельзя.
	if _, err := pool.Exec(ctx, `UPDATE store_leads SET expires_at = now() - interval '1 minute' WHERE id = $1`, l3ID); err != nil {
		t.Fatal(err)
	}
	if r := a.expect(a.do("GET", "/store/supply/leads/"+l3ID, agentTok, nil), 200, "expired"); r.str("status") != "expired" {
		t.Fatalf("expired = %v", r.Body)
	}
	if r := a.expect(a.do("POST", "/admin/store-leads/"+l3ID+"/connect", adminTok, map[string]any{}), 409, "connect expired"); r.str("error", "code") != "lead_expired" {
		t.Fatalf("connect expired = %v", r.Body)
	}
	a.expect(lead(agent2Tok, "Mini Market 24", "+998998700531", 41.37, 69.32), 201, "free after expiry")

	// Подключение: сеть с логином и тарифом, магазин — в точке заявки.
	a.expect(a.do("POST", "/admin/store-leads/"+l1ID+"/connect", adminTok, map[string]any{"kind": "distributor"}), 400, "agent kind")
	con := a.expect(a.do("POST", "/admin/store-leads/"+l1ID+"/connect", adminTok, map[string]any{
		"kind": "single", "owner_login": "zamon_market", "owner_password": "k7M-42tq", "plan_key": "start",
	}), 200, "connect")
	if con.str("status") != "connected" || con.str("network_name") != "Zamon Market" || con.str("plan_name") == "" {
		t.Fatalf("connected = %v", con.Body)
	}
	network := con.str("network_id")
	if s := sqlStr(t, pool, `SELECT s.name || '|' || s.phone || '|' || round(ST_Y(s.location::geometry)::numeric, 2) || '|' || n.kind
		FROM stores s JOIN networks n ON n.id = s.network_id WHERE n.id = $1`, network); s != "Zamon Market|+998901234567|41.35|single" {
		t.Fatalf("store = %s", s)
	}
	a.expect(a.do("POST", "/admin/store-leads/"+l1ID+"/connect", adminTok, map[string]any{}), 409, "connect twice")
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM notifications_outbox WHERE kind = 'lead_connected'`); n != "1" {
		t.Fatalf("connect push = %s", n)
	}
	// Владелец входит по логину и временному паролю; точка магазина уже стоит —
	// в мастере настройки остаются часы работы и доставка.
	a.expect(a.do("POST", "/auth/store/login", "", map[string]any{"login": "zamon_market", "password": "k7M-42tq"}), 200, "owner login")

	// Счёт за подписку: пока не оплачен — агент видит «Ждём оплату» без суммы.
	if _, err := pool.Exec(ctx, `UPDATE networks SET billing_from = '2026-01-01', plan_trial_until = NULL WHERE id = $1`, network); err != nil {
		t.Fatal(err)
	}
	if n, err := app.Billing.GenerateInvoices(ctx, time.Now()); err != nil || n < 1 {
		t.Fatalf("generate: %d, %v", n, err)
	}
	waiting := a.expect(a.do("GET", "/store/supply/leads/"+l1ID, agentTok, nil), 200, "waiting")
	if waiting.str("status") != "connected" || waiting.str("invoice_due") == "" || waiting.Body["invoice_amount"] != nil || waiting.Body["reward_amount"] != nil {
		t.Fatalf("waiting = %v", waiting.Body)
	}
	if r := a.expect(a.do("GET", "/admin/store-leads/"+l1ID, adminTok, nil), 200, "admin waiting"); r.str("invoice_amount") == "" {
		t.Fatalf("admin waiting = %v", r.Body)
	}
	var invoice, amount string
	if err := pool.QueryRow(ctx, `SELECT id, amount_uzs::text FROM subscription_invoices WHERE network_id = $1`, network).Scan(&invoice, &amount); err != nil {
		t.Fatal(err)
	}

	// Магазин оплатил — агенту 50% от оплаченного, один раз.
	a.expect(a.do("POST", "/admin/billing/invoices/"+invoice+"/paid", adminTok, map[string]any{"note": "наличные"}), 200, "paid")
	paid := a.expect(a.do("GET", "/store/supply/leads/"+l1ID, agentTok, nil), 200, "paid lead")
	half := sqlStr(t, pool, `SELECT round($1::numeric / 2, 2)::text`, amount)
	if paid.str("status") != "paid" || paid.str("reward_amount") != half || paid.str("rewarded_at") == "" {
		t.Fatalf("paid lead = %v (amount %s)", paid.Body, amount)
	}
	if bal := a.expect(a.do("GET", "/store/balance", agentTok, nil), 200, "agent balance"); bal.str("available") != half {
		t.Fatalf("agent balance = %v", bal.Body)
	}
	if e := a.expect(a.do("GET", "/store/balance/entries", agentTok, nil), 200, "entries").items(); len(e) != 1 || e[0]["kind"] != "agent_reward" {
		t.Fatalf("entries = %v", e)
	}
	if err := app.Billing.SettleAgentRewards(ctx); err != nil {
		t.Fatal(err)
	}
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM balance_entries WHERE kind = 'agent_reward'`); n != "1" {
		t.Fatalf("reward twice: %s", n)
	}
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM notifications_outbox WHERE kind = 'staff_notice' AND body LIKE '%Вам начислено%'`); n != "1" {
		t.Fatalf("reward push = %s", n)
	}
	mine = a.expect(a.do("GET", "/store/supply/leads?status=paid", agentTok, nil), 200, "my paid")
	if len(mine.items()) != 1 || mine.str("earned") != half || mine.Body["counts"].(map[string]any)["closed"].(float64) != 2 {
		t.Fatalf("my paid = %v", mine.Body)
	}
	rw := a.expect(a.do("GET", "/admin/store-leads/rewards", adminTok, nil), 200, "rewards")
	if len(rw.items()) != 1 || rw.str("earned_month") != half || rw.items()[0]["paid_amount"] != amount {
		t.Fatalf("rewards = %v", rw.Body)
	}

	// Удаление сети магазина не ломает заявку и начисление.
	a.expect(a.do("DELETE", "/admin/networks/"+network, adminTok, map[string]any{"confirm_name": "Zamon Market", "money_ack": true}), 200, "delete store network")
	if r := a.expect(a.do("GET", "/store/supply/leads/"+l1ID, agentTok, nil), 200, "after delete"); r.str("reward_amount") != half {
		t.Fatalf("after delete = %v", r.Body)
	}
}
