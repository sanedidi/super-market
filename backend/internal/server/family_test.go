package server_test

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/family"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/telegram"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// TestFamily — «Моя семья»: создание, приглашение (приложение и бот),
// просьба купить, отметки, «Заказать домой», напоминания, выход и удаление.
func TestFamily(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	cfg.TelegramBotUsername = "market_test_bot"
	cfg.PaymeMerchantID, cfg.PaymeKey = "merchant-1", paymeKey
	tg := &fakeTelegram{}
	app, err := server.Build(ctx, cfg, pool, tg, quietLog())
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app.Handler)
	t.Cleanup(srv.Close)
	a := api{t: t, srv: srv, pool: pool}

	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, _ := catalogBasics(t, a, adminTok)
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	const lat, lng = 41.2995, 69.2401
	a.expect(a.do("PATCH", "/store/stores/"+store, tok, map[string]any{"lat": lat, "lng": lng}), 200, "store")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
	doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{"type": "posting", "warehouse_id": wh,
		"items": []map[string]any{{"product_id": cola, "qty": 20, "price": 10000}}}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post")
	a.expect(a.do("PUT", "/store/stores/"+store+"/delivery", tok, map[string]any{
		"accepts_online": true, "delivery_radius_m": 5000,
		"rules": []map[string]any{{"type": "fixed", "params": map[string]any{"price": 5000}}},
	}), 200, "delivery")

	mom, _ := a.login("+998900000050", identity.AppClient)
	a.expect(a.do("PATCH", "/client/me", mom, map[string]any{"full_name": "Мама"}), 200, "name")
	dad, _ := a.login("+998900000051", identity.AppClient)
	a.expect(a.do("PATCH", "/client/me", dad, map[string]any{"full_name": "Папа"}), 200, "name")
	stranger, _ := a.login("+998900000059", identity.AppClient)

	if f := a.expect(a.do("GET", "/client/family", mom, nil), 200, "no family"); f.Body["family"] != nil {
		t.Fatalf("family = %v", f.Body)
	}
	a.expect(a.do("POST", "/client/family/requests", mom, map[string]any{"title": "x"}), 404, "request without family")
	f := a.expect(a.do("POST", "/client/family", mom, map[string]any{"name": "Каримовы"}), 201, "create")
	if f.str("my_role") != "owner" || len(f.Body["members"].([]any)) != 1 {
		t.Fatalf("family = %v", f.Body)
	}
	a.expect(a.do("POST", "/client/family", mom, map[string]any{"name": "Ещё"}), 409, "second family")

	inv := a.expect(a.do("POST", "/client/family/invites", mom, nil), 201, "invite")
	code := inv.str("code")
	if len(code) != 8 || inv.str("url") != "https://t.me/market_test_bot?start=fam_"+code {
		t.Fatalf("invite = %v", inv.Body)
	}
	a.expect(a.do("POST", "/client/family/join", dad, map[string]any{"code": "ZZZZZZZZ"}), 400, "bad code")
	j := a.expect(a.do("POST", "/client/family/join", dad, map[string]any{"code": strings.ToLower(code), "label": "Муж"}), 200, "join")
	if j.str("my_role") != "member" || len(j.Body["members"].([]any)) != 2 {
		t.Fatalf("joined = %v", j.Body)
	}
	a.expect(a.do("POST", "/client/family/join", stranger, map[string]any{"code": code}), 400, "code used")
	var dadID string
	for _, m := range j.Body["members"].([]any) {
		if m := m.(map[string]any); m["is_me"] == true {
			dadID = m["user_id"].(string)
		}
	}
	a.expect(a.do("DELETE", "/client/family/members/"+dadID, dad, nil), 403, "member can't remove")

	// Бот: /start fam_<код> до привязки номера — сначала номер, потом вступление.
	svc := identity.NewService(pool, tg, server.IdentityConfig(cfg), quietLog())
	bot := identity.NewBot(svc, tg, quietLog())
	dlv, _, ord := server.OrderServices(cfg, pool, tg, quietLog())
	fam := family.NewService(pool, ord, dlv, cfg.TelegramBotUsername)
	bot.Deeplinks = map[string]identity.DeeplinkFunc{"fam": func(ctx context.Context, ph, c string) (string, error) {
		name, err := fam.JoinByPhone(ctx, ph, c)
		return "Вы в семье " + name, err
	}}
	msg := func(contact *telegram.Contact, text string) telegram.Update {
		return telegram.Update{Message: &telegram.Message{
			From: &telegram.User{ID: 901}, Chat: telegram.Chat{ID: 901, Type: "private"}, Text: text, Contact: contact,
		}}
	}
	code2 := a.expect(a.do("POST", "/client/family/invites", mom, nil), 201, "invite 2").str("code")
	if err := bot.Handle(ctx, msg(nil, "/start fam_"+code2)); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(tg.last().text, "Поделиться номером") {
		t.Fatalf("bot = %q", tg.last().text)
	}
	if err := bot.Handle(ctx, msg(&telegram.Contact{PhoneNumber: "998900000052", UserID: 901}, "")); err != nil {
		t.Fatal(err)
	}
	if got := tg.last().text; got != "Вы в семье Каримовы" {
		t.Fatalf("bot = %q", got)
	}
	son, _ := a.login("+998900000052", identity.AppClient)
	if len(a.expect(a.do("GET", "/client/family", son, nil), 200, "son").Body["family"].(map[string]any)["members"].([]any)) != 3 {
		t.Fatal("son not in family")
	}
	// Уже привязанный номер: чужой код — ответ с ошибкой, без паники.
	if err := bot.Handle(ctx, msg(nil, "/start fam_AAAAAAAA")); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(tg.last().text, "Не получилось") {
		t.Fatalf("bot = %q", tg.last().text)
	}

	// Просьба купить: мама → папе, товар из каталога и текст.
	a.expect(a.do("POST", "/client/family/requests", mom, map[string]any{"title": "Ужин", "items": []any{}}), 400, "empty items")
	a.expect(a.do("POST", "/client/family/requests", mom, map[string]any{"title": "Ужин", "assignee_id": "00000000-0000-0000-0000-000000000000",
		"items": []map[string]any{{"text": "хлеб", "qty": 1}}}), 400, "assignee not in family")
	rq := a.expect(a.do("POST", "/client/family/requests", mom, map[string]any{
		"title": "Ужин", "assignee_id": dadID, "comment": "по дороге",
		"items": []map[string]any{{"product_id": cola, "qty": 2}, {"text": "Хлеб", "qty": 1}},
	}), 201, "request")
	rid := rq.str("id")
	items := rq.Body["items"].([]any)
	if rq.str("status") != "pending" || len(items) != 2 || rq.Body["for_me"] != false {
		t.Fatalf("request = %v", rq.Body)
	}
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM notifications_outbox WHERE kind = 'family_request'`); n != "1" {
		t.Fatalf("outbox = %s", n)
	}
	dl := a.expect(a.do("GET", "/client/family/requests", dad, nil), 200, "dad list").items()
	if len(dl) != 1 || dl[0]["for_me"] != true || !strings.Contains(dl[0]["summary"].(string), "Хлеб") {
		t.Fatalf("dad list = %v", dl)
	}
	a.expect(a.do("GET", "/client/family/requests/"+rid, stranger, nil), 404, "stranger")
	if g := a.expect(a.do("GET", "/client/family", dad, nil), 200, "badge"); g.Body["family"].(map[string]any)["requests_for_me"] != float64(1) {
		t.Fatalf("badge = %v", g.Body)
	}

	// Папа отметил хлеб — частично.
	bread := items[1].(map[string]any)["id"].(string)
	colaItem := items[0].(map[string]any)["id"].(string)
	p := a.expect(a.do("POST", "/client/family/requests/"+rid+"/items/"+bread+"/bought", dad, map[string]any{"bought": true}), 200, "bought")
	if p.str("status") != "partial" {
		t.Fatalf("partial = %v", p.Body)
	}

	// «Заказать домой»: оставшееся — в ближайшем магазине.
	q := a.expect(a.do("GET", "/client/family/requests/"+rid+"/to-cart?lat=41.30&lng=69.24", dad, nil), 200, "to-cart")
	lines := q.Body["lines"].([]any)
	if q.str("store", "id") != store || len(lines) != 1 || lines[0].(map[string]any)["item_id"] != colaItem || q.Body["found"] != float64(1) {
		t.Fatalf("quote = %v", q.Body)
	}
	a.expect(a.do("GET", "/client/family/requests/"+rid+"/to-cart?lat=40&lng=60", dad, nil), 200, "far away")

	// Напоминание в прошлом — worker шлёт push исполнителю.
	if _, err := pool.Exec(ctx, `UPDATE shopping_requests SET remind_at = now() - interval '1 minute', reminded_at = NULL, deliver_offer_at = now() - interval '1 minute' WHERE id = $1`, rid); err != nil {
		t.Fatal(err)
	}
	if err := fam.Remind(ctx); err != nil {
		t.Fatal(err)
	}
	if err := fam.Remind(ctx); err != nil { // повторно не шлёт
		t.Fatal(err)
	}
	if n := sqlStr(t, pool, `SELECT string_agg(kind, ',' ORDER BY kind) FROM notifications_outbox WHERE kind LIKE 'family_%' AND kind <> 'family_joined'`); n != "family_offer,family_remind,family_request" {
		t.Fatalf("outbox = %s", n)
	}

	// Заказ оформлен — просьба закрыта, автору push.
	addr := a.expect(a.do("POST", "/client/addresses", dad, map[string]any{"address": "Дом", "lat": 41.30, "lng": lng}), 201, "address").str("id")
	o := a.expect(a.do("POST", "/client/orders", dad, map[string]any{"store_id": store, "address_id": addr, "payment_provider": "payme",
		"items": []map[string]any{{"product_id": cola, "qty": 2}}}), 201, "order").str("order", "id")
	a.expect(a.do("POST", "/client/family/requests/"+rid+"/ordered", mom, map[string]any{"order_id": o}), 400, "not my order")
	d := a.expect(a.do("POST", "/client/family/requests/"+rid+"/ordered", dad, map[string]any{"order_id": o}), 200, "ordered")
	if d.str("status") != "ordered" || d.str("order_id") != o {
		t.Fatalf("ordered = %v", d.Body)
	}
	if len(a.expect(a.do("GET", "/client/family/requests", mom, nil), 200, "active").items()) != 0 ||
		len(a.expect(a.do("GET", "/client/family/requests?status=history", mom, nil), 200, "history").items()) != 1 {
		t.Fatal("history")
	}

	// Вторая просьба: отменить может только автор или владелец.
	r2 := a.expect(a.do("POST", "/client/family/requests", dad, map[string]any{"title": "Молоко",
		"items": []map[string]any{{"text": "Молоко", "qty": 1}}}), 201, "request 2").str("id")
	a.expect(a.do("POST", "/client/family/requests/"+r2+"/cancel", son, nil), 403, "son cancel")
	a.expect(a.do("POST", "/client/family/requests/"+r2+"/snooze", son, map[string]any{"minutes": 30}), 200, "snooze")
	a.expect(a.do("POST", "/client/family/requests/"+r2+"/cancel", mom, nil), 200, "owner cancel")

	// Выход и удаление аккаунта владельца: семья переходит к папе.
	a.expect(a.do("POST", "/client/family/leave", son, nil), 204, "son leave")
	a.expect(a.do("DELETE", "/client/me", mom, nil), 204, "delete mom")
	g := a.expect(a.do("GET", "/client/family", dad, nil), 200, "dad family").Body["family"].(map[string]any)
	if g["my_role"] != "owner" || len(g["members"].([]any)) != 1 {
		t.Fatalf("after delete = %v", g)
	}
	a.expect(a.do("POST", "/client/family/leave", dad, nil), 204, "dad leave")
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM families`); n != "0" {
		t.Fatalf("families = %s", n)
	}
}
