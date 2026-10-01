package server_test

import (
	"context"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/push"
	"github.com/sanedidi/super-market/backend/internal/server"
)

type fakeFCM struct {
	mu   sync.Mutex
	sent []string // token|title
	err  error
}

func (f *fakeFCM) Send(_ context.Context, token string, m push.Message) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return f.err
	}
	f.sent = append(f.sent, token+"|"+m.Title+"|"+m.Data["order_id"])
	return nil
}

// TestProfileAndPush — профиль покупателя, устройства, уведомления о статусе
// заказа (push и запасной Telegram), удаление аккаунта.
func TestProfileAndPush(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	cfg.PaymeMerchantID, cfg.PaymeKey = "merchant-1", paymeKey
	cfg.SupportURL = "https://t.me/sm_support"
	cfg.OfferURL = "https://super-market.uz/offer"
	cfg.TelegramBotUsername = "sm_test_bot"
	tg := &fakeTelegram{}
	app, err := server.Build(ctx, cfg, pool, tg, quietLog())
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app.Handler)
	t.Cleanup(srv.Close)
	a := api{t: t, srv: srv}
	prov := providers{t: t, srv: srv}

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

	if c := a.expect(a.do("GET", "/client/config", "", nil), 200, "config"); c.Body["push_enabled"] != false || c.str("support_url") != "https://t.me/sm_support" ||
		c.str("offer_url") != "https://super-market.uz/offer" || c.str("bot_url") != "https://t.me/sm_test_bot" {
		t.Fatalf("config = %v", c.Body)
	}
	// Запрос кода: через сколько можно запросить снова и ссылка на бота.
	if rc := a.expect(a.do("POST", "/auth/otp/request", "", map[string]any{"phone": "+998900000099"}), 200, "request code"); rc.Body["resend_in"].(float64) != 60 ||
		rc.str("bot_url") != "https://t.me/sm_test_bot" {
		t.Fatalf("request code = %v", rc.Body)
	}

	// Профиль.
	const phone = "+998900000050"
	client, _ := a.login(phone, identity.AppClient)
	me := a.expect(a.do("GET", "/client/me", client, nil), 200, "me")
	if me.str("phone") != phone || me.str("language") != "ru" || me.str("support_url") != "https://t.me/sm_support" ||
		me.Body["notifications"].(map[string]any)["orders"] != true {
		t.Fatalf("me = %v", me.Body)
	}
	a.expect(a.do("PATCH", "/client/me", client, map[string]any{"language": "en"}), 400, "bad language")
	me = a.expect(a.do("PATCH", "/client/me", client, map[string]any{
		"full_name": "  Азиз   Каримов ", "language": "uz", "city": "Ташкент",
	}), 200, "update me")
	if me.str("full_name") != "Азиз Каримов" || me.str("first_name") != "Азиз" || me.str("last_name") != "Каримов" ||
		me.str("language") != "uz" || me.str("city") != "Ташкент" || me.Body["terms_accepted_at"] != nil {
		t.Fatalf("updated me = %v", me.Body)
	}
	// Новые версии: имя и фамилия отдельно, согласие с офертой.
	me = a.expect(a.do("PATCH", "/client/me", client, map[string]any{"first_name": " Shaxzod ", "last_name": "Anvarov", "accept_terms": true}), 200, "names")
	accepted := me.str("terms_accepted_at")
	if me.str("full_name") != "Shaxzod Anvarov" || me.str("first_name") != "Shaxzod" || accepted == "" {
		t.Fatalf("names = %v", me.Body)
	}
	a.expect(a.do("PATCH", "/client/me", client, map[string]any{"first_name": ""}), 400, "empty first name")
	me = a.expect(a.do("PATCH", "/client/me", client, map[string]any{"last_name": "", "accept_terms": true}), 200, "no last name")
	if me.str("full_name") != "Shaxzod" || me.str("terms_accepted_at") != accepted {
		t.Fatalf("no last name = %v", me.Body)
	}
	me = a.expect(a.do("PATCH", "/client/me", client, map[string]any{"full_name": "Азиз Каримов"}), 200, "full name again")
	if me.str("first_name") != "Азиз" || me.str("last_name") != "Каримов" {
		t.Fatalf("full name again = %v", me.Body)
	}
	if me.Body["birth_date"] != nil || me.str("gender") != "" {
		t.Fatalf("empty birth/gender = %v", me.Body)
	}
	me = a.expect(a.do("PATCH", "/client/me", client, map[string]any{"birth_date": "2004-07-01", "gender": "male"}), 200, "birth")
	if me.str("birth_date") != "2004-07-01" || me.str("gender") != "male" || me.str("full_name") != "Азиз Каримов" {
		t.Fatalf("birth me = %v", me.Body)
	}
	a.expect(a.do("PATCH", "/client/me", client, map[string]any{"birth_date": "2999-01-01"}), 400, "future birth")
	a.expect(a.do("PATCH", "/client/me", client, map[string]any{"gender": "x"}), 400, "bad gender")
	me = a.expect(a.do("PATCH", "/client/me", client, map[string]any{"birth_date": ""}), 200, "clear birth")
	if me.Body["birth_date"] != nil || me.str("gender") != "male" {
		t.Fatalf("cleared birth = %v", me.Body)
	}

	// Устройство.
	const devToken = "fcm-token-0123456789-abcdefghij"
	a.expect(a.do("POST", "/client/devices", client, map[string]any{"token": "short", "platform": "ios"}), 400, "short token")
	a.expect(a.do("POST", "/client/devices", client, map[string]any{"token": devToken, "platform": "web"}), 400, "bad platform")
	a.expect(a.do("POST", "/client/devices", client, map[string]any{"token": devToken, "platform": "ios"}), 204, "device")
	a.expect(a.do("POST", "/client/devices", client, map[string]any{"token": devToken, "platform": "ios"}), 204, "device again")
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM devices WHERE language = 'uz'`); n != "1" {
		t.Fatalf("devices = %s", n)
	}

	// Заказ и оплата.
	addr := a.expect(a.do("POST", "/client/addresses", client, map[string]any{"address": "Чиланзар 5", "apartment": "12", "lat": lat + 0.005, "lng": lng}), 201, "address").str("id")
	o := a.expect(a.do("POST", "/client/orders", client, map[string]any{"store_id": store, "address_id": addr, "payment_provider": "payme",
		"items": []map[string]any{{"product_id": cola, "qty": 2}}}), 201, "order")
	orderID := o.str("order", "id")
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM notifications_outbox`); n != "0" {
		t.Fatalf("unpaid order must not notify: %s", n)
	}
	acc := map[string]any{"order_id": orderID}
	amount := 35000 * 100 // 2 × 15 000 + 5 000
	now := time.Now().UnixMilli()
	prov.payme(paymeKey, "CreateTransaction", map[string]any{"id": "pm-1", "time": now, "amount": amount, "account": acc})
	if pf := prov.payme(paymeKey, "PerformTransaction", map[string]any{"id": "pm-1"}); paymeErr(pf) != 0 {
		t.Fatalf("perform = %v", pf)
	}
	a.expect(a.do("POST", "/store/orders/"+orderID+"/accept", tok, nil), 200, "accept")

	var titles []string
	rows, _ := pool.Query(ctx, `SELECT title FROM notifications_outbox ORDER BY id`)
	for rows.Next() {
		var s string
		_ = rows.Scan(&s)
		titles = append(titles, s)
	}
	rows.Close()
	if strings.Join(titles, ";") != "Buyurtma №1 to‘landi;Buyurtma №1 qabul qilindi" {
		t.Fatalf("outbox = %v", titles)
	}

	// Отправка: push на устройство.
	fcm := &fakeFCM{}
	d := push.NewDispatcher(pool, fcm, tg, quietLog())
	if n, err := d.Tick(ctx); err != nil || n != 2 {
		t.Fatalf("tick = %d, %v", n, err)
	}
	if len(fcm.sent) != 2 || fcm.sent[0] != devToken+"|Buyurtma №1 to‘landi|"+orderID {
		t.Fatalf("fcm = %v", fcm.sent)
	}
	if s := sqlStr(t, pool, `SELECT string_agg(status || ':' || channel, ',' ORDER BY id) FROM notifications_outbox`); s != "sent:push,sent:push" {
		t.Fatalf("outbox after tick = %s", s)
	}

	// Токен протух — устройство удаляется, уведомление уходит в Telegram.
	if _, err := pool.Exec(ctx, `INSERT INTO telegram_links (phone, chat_id, tg_user_id) VALUES ($1, 5050, 5050)`, phone); err != nil {
		t.Fatal(err)
	}
	a.expect(a.do("POST", "/store/orders/"+orderID+"/start-picking", tok, nil), 200, "picking") // без уведомления
	a.expect(a.do("POST", "/store/orders/"+orderID+"/cancel", tok, map[string]any{"reason": "Нет курьера"}), 200, "cancel")
	fcm.err = push.ErrUnregistered
	if n, err := d.Tick(ctx); err != nil || n != 1 {
		t.Fatalf("tick 2 = %d, %v", n, err)
	}
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM devices`); n != "0" {
		t.Fatal("unregistered device kept")
	}
	if last := tg.last(); last.chatID != 5050 || !strings.Contains(last.text, "bekor qilindi") {
		t.Fatalf("telegram = %v", last)
	}

	// Сбой FCM без Telegram — повтор позже.
	if _, err := pool.Exec(ctx, `DELETE FROM telegram_links WHERE phone = $1`, phone); err != nil {
		t.Fatal(err)
	}
	a.expect(a.do("POST", "/client/devices", client, map[string]any{"token": devToken, "platform": "android"}), 204, "device 2")
	if _, err := pool.Exec(ctx, `INSERT INTO notifications_outbox (user_id, kind, title, body)
		SELECT customer_id, 'test', 't', 'b' FROM orders WHERE id = $1`, orderID); err != nil {
		t.Fatal(err)
	}
	fcm.err = context.DeadlineExceeded
	if _, err := d.Tick(ctx); err != nil {
		t.Fatal(err)
	}
	if s := sqlStr(t, pool, `SELECT status || ':' || attempts::text || ':' || (send_after > now())::text FROM notifications_outbox WHERE kind = 'test'`); s != "pending:1:true" {
		t.Fatalf("retry = %s", s)
	}

	// Колокольчик: история уведомлений, непрочитанные, отметка «прочитано».
	// Запланированное на будущее (напоминание) не показывается.
	if _, err := pool.Exec(ctx, `INSERT INTO notifications_outbox (user_id, kind, title, body, send_after)
		SELECT customer_id, 'later', 'l', 'b', now() + interval '1 hour' FROM orders WHERE id = $1`, orderID); err != nil {
		t.Fatal(err)
	}
	list := a.expect(a.do("GET", "/client/notifications", client, nil), 200, "notifications").items()
	if len(list) != 4 || list[0]["kind"] != "test" || list[3]["title"] != "Buyurtma №1 to‘landi" || list[3]["read"] != false {
		t.Fatalf("notifications = %v", list)
	}
	if u := a.expect(a.do("GET", "/client/notifications/unread", client, nil), 200, "unread"); u.Body["count"].(float64) != 4 {
		t.Fatalf("unread = %v", u.Body)
	}
	a.expect(a.do("POST", "/client/notifications/read", client, map[string]any{}), 400, "read nothing")
	if r := a.expect(a.do("POST", "/client/notifications/read", client, map[string]any{"ids": []any{list[3]["id"]}}), 200, "read one"); r.Body["count"].(float64) != 3 {
		t.Fatalf("read one = %v", r.Body)
	}
	if r := a.expect(a.do("POST", "/client/notifications/read", client, map[string]any{"all": true}), 200, "read all"); r.Body["count"].(float64) != 0 {
		t.Fatalf("read all = %v", r.Body)
	}
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM notifications_outbox WHERE kind = 'later' AND read_at IS NULL`); n != "1" {
		t.Fatalf("future notification marked read: %s", n)
	}
	a.expect(a.do("GET", "/client/notifications", tok, nil), 403, "store token")

	// Выключенные уведомления о заказах — в очередь ничего не попадает.
	a.expect(a.do("PATCH", "/client/me", client, map[string]any{"notifications": map[string]any{"orders": false}}), 200, "mute")
	o2 := a.expect(a.do("POST", "/client/orders", client, map[string]any{"store_id": store, "address_id": addr, "payment_provider": "payme",
		"items": []map[string]any{{"product_id": cola, "qty": 2}}}), 201, "order 2")
	o2id := o2.str("order", "id")
	prov.payme(paymeKey, "CreateTransaction", map[string]any{"id": "pm-2", "time": now, "amount": amount, "account": map[string]any{"order_id": o2id}})
	prov.payme(paymeKey, "PerformTransaction", map[string]any{"id": "pm-2"})
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM notifications_outbox WHERE data->>'order_id' = $1`, o2id); n != "0" {
		t.Fatalf("muted notifications = %s", n)
	}

	// Статистика и удаление аккаунта.
	st := a.expect(a.do("GET", "/client/me/stats", client, nil), 200, "stats")
	if st.Body["orders_count"].(float64) != 2 || st.Body["addresses_count"].(float64) != 1 ||
		st.Body["active_order"].(map[string]any)["id"] != o2id {
		t.Fatalf("stats = %v", st.Body)
	}
	if ao := st.Body["active_order"].(map[string]any); ao["courier_name"] != nil || ao["eta_at"] != nil {
		t.Fatalf("active order without courier = %v", ao)
	}
	a.expect(a.do("DELETE", "/client/me", client, nil), 409, "delete with active order")
	if _, err := pool.Exec(ctx, `UPDATE orders SET status = 'delivered', discount = 1500 WHERE id = $1`, o2id); err != nil {
		t.Fatal(err)
	}
	if st := a.expect(a.do("GET", "/client/me/stats", client, nil), 200, "stats 2"); st.str("saved") != "1500.00" || st.Body["active_order"] != nil {
		t.Fatalf("stats 2 = %v", st.Body)
	}
	oldUser := sqlStr(t, pool, `SELECT id::text FROM users WHERE phone = $1`, phone)
	a.expect(a.do("DELETE", "/client/me", client, nil), 204, "delete")
	a.expect(a.do("GET", "/client/me", client, nil), 401, "old session")
	if s := sqlStr(t, pool, `SELECT full_name || '|' || left(phone, 4) FROM users WHERE id = $1`, oldUser); s != "|+999" {
		t.Fatalf("user after delete = %s", s)
	}
	if s := sqlStr(t, pool, `SELECT string_agg(DISTINCT customer_phone || '|' || address || '|' || apartment, ',') FROM orders WHERE customer_id = $1`, oldUser); s != "|Адрес удалён|" {
		t.Fatalf("orders after delete = %s", s)
	}
	for _, tbl := range []string{"customer_addresses", "devices", "favorites"} {
		if n := sqlStr(t, pool, `SELECT count(*)::text FROM `+tbl+` WHERE user_id = $1`, oldUser); n != "0" {
			t.Fatalf("%s left: %s", tbl, n)
		}
	}
	// Новый вход с тем же номером — новый пустой аккаунт.
	client2, _ := a.login(phone, identity.AppClient)
	if st := a.expect(a.do("GET", "/client/me/stats", client2, nil), 200, "new stats"); st.Body["orders_count"].(float64) != 0 {
		t.Fatalf("new account sees old orders: %v", st.Body)
	}
	if me := a.expect(a.do("GET", "/client/me", client2, nil), 200, "new me"); me.str("full_name") != "" || me.str("language") != "ru" {
		t.Fatalf("new me = %v", me.Body)
	}
	// Выход удаляет устройство сессии.
	a.expect(a.do("POST", "/client/devices", client2, map[string]any{"token": devToken, "platform": "ios"}), 204, "device 3")
	a.expect(a.do("POST", "/auth/client/logout", client2, nil), 204, "logout")
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM devices`); n != "0" {
		t.Fatalf("devices after logout = %s", n)
	}
}
