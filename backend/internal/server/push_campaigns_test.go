package server_test

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/push"
	"github.com/sanedidi/super-market/backend/internal/server"
)

type dataFCM struct {
	mu   sync.Mutex
	sent []push.Message
	err  error
}

func (f *dataFCM) Send(_ context.Context, _ string, m push.Message) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return f.err
	}
	f.sent = append(f.sent, m)
	return nil
}

// TestPushCampaigns — рассылки супер-админа: охват по фильтрам, ночная пауза,
// переходы, отмена, отправка воркером, получатели и тестовый push.
func TestPushCampaigns(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	fcm := &dataFCM{}
	server.PushOverride = fcm
	t.Cleanup(func() { server.PushOverride = nil })
	a := newAPI(t, paymeConfig(), pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	shop := newAdminShop(t, a, adminTok, "+998900000002", "+998901234567")

	// Покупатель 1: с заказом и iPhone. Покупатель 2: без заказов и без push.
	a.expect(a.do("POST", "/client/devices", shop.client, map[string]any{"token": "fcm-token-0123456789-abcdefghij", "platform": "ios"}), 204, "device")
	orderID, _ := shop.order(t)
	if _, err := pool.Exec(ctx, `UPDATE orders SET status = 'delivered' WHERE id = $1`, orderID); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `UPDATE stores SET city = 'Ташкент' WHERE id = $1`, shop.store); err != nil {
		t.Fatal(err)
	}
	client2, _ := a.login("+998901111111", identity.AppClient)
	a.expect(a.do("PATCH", "/client/me", client2, map[string]any{"language": "uz"}), 200, "lang")
	user1 := sqlStr(t, pool, `SELECT id::text FROM users WHERE phone = '+998901234567'`)
	category := sqlStr(t, pool, `SELECT category_id::text FROM products WHERE id = $1`, shop.cola)

	ov := a.expect(a.do("GET", "/admin/push/overview", adminTok, nil), 200, "overview")
	if ov.Body["with_push"].(float64) != 1 || ov.Body["without_push"].(float64) != 1 || ov.Body["push_enabled"] != true {
		t.Fatalf("overview = %v", ov.Body)
	}

	msg := func(target, audience map[string]any, sendAt any) map[string]any {
		return map[string]any{"title": "Скидки выходных", "body": "Фрукты дешевле", "target": target, "audience": audience, "send_at": sendAt}
	}
	home := map[string]any{"type": "home"}
	reach := func(aud map[string]any) float64 {
		t.Helper()
		return a.expect(a.do("POST", "/admin/push/campaigns/preview", adminTok, msg(home, aud, nil)), 200, "preview").Body["recipients"].(float64)
	}
	if n := reach(map[string]any{"type": "all"}); n != 2 {
		t.Fatalf("all = %v", n)
	}
	for aud, want := range map[string]float64{
		`within`: 1, `never`: 1, `not_within`: 0, `uz`: 1, `store`: 1, `city`: 1,
	} {
		f := map[string]any{"type": "filter"}
		switch aud {
		case "within", "not_within":
			f["orders"], f["days"] = aud, 30
		case "never":
			f["orders"] = "never"
		case "uz":
			f["language"] = "uz"
		case "store":
			f["store_id"] = shop.store
		case "city":
			f["city"] = "Ташкент"
		}
		if n := reach(f); n != want {
			t.Fatalf("%s = %v, want %v", aud, n, want)
		}
	}
	// Отписавшиеся от акций не получают рассылку, но «одному клиенту» можно.
	if _, err := pool.Exec(ctx, `UPDATE customers SET notify_promos = false WHERE user_id = $1`, user1); err != nil {
		t.Fatal(err)
	}
	if n := reach(map[string]any{"type": "all"}); n != 1 {
		t.Fatalf("promos off = %v", n)
	}
	if n := reach(map[string]any{"type": "one", "user_id": user1}); n != 1 {
		t.Fatalf("one = %v", n)
	}
	if _, err := pool.Exec(ctx, `UPDATE customers SET notify_promos = true WHERE user_id = $1`, user1); err != nil {
		t.Fatal(err)
	}

	// Проверки перехода и текста.
	for name, tgt := range map[string]map[string]any{
		"http url":      {"type": "url", "url": "http://example.com"},
		"no store":      {"type": "category", "category_id": category},
		"bad block":     {"type": "block", "block_id": "a0000000-0000-4000-8000-00000000ffff"},
		"store nearest": {"type": "store", "store_id": "nearest"},
		"unknown":       {"type": "settings"},
	} {
		a.expect(a.do("POST", "/admin/push/campaigns/preview", adminTok, msg(tgt, nil, nil)), 400, name)
	}
	a.expect(a.do("POST", "/admin/push/campaigns/preview", adminTok, map[string]any{"title": "", "body": "x"}), 400, "empty title")
	p := a.expect(a.do("POST", "/admin/push/campaigns/preview", adminTok,
		msg(map[string]any{"type": "category", "store_id": shop.store, "category_id": category}, nil, nil)), 200, "category target")
	if tt := p.str("target_title"); !strings.HasSuffix(tt, "→ Продукты") {
		t.Fatalf("target title = %q", tt)
	}
	blocks := a.expect(a.do("GET", "/admin/push/blocks", adminTok, nil), 200, "blocks").items()
	hits := ""
	for _, b := range blocks {
		if b["title"] == "Полка «Хиты недели»" {
			hits = b["id"].(string)
		}
	}
	if hits == "" {
		t.Fatalf("blocks = %v", blocks)
	}
	a.expect(a.do("POST", "/admin/push/campaigns/preview", adminTok, msg(map[string]any{"type": "block", "block_id": hits}, nil, nil)), 200, "block target")

	// Ночь: 23:00 по Ташкенту переносится на 08:00 следующего дня.
	tomorrow := time.Now().In(push.Tashkent).AddDate(0, 0, 1)
	night := time.Date(tomorrow.Year(), tomorrow.Month(), tomorrow.Day(), 23, 0, 0, 0, push.Tashkent)
	p = a.expect(a.do("POST", "/admin/push/campaigns/preview", adminTok, msg(home, nil, night.Format(time.RFC3339))), 200, "night")
	if at, _ := time.Parse(time.RFC3339, p.str("send_at")); p.Body["shifted"] != true || at.In(push.Tashkent).Hour() != 8 || at.In(push.Tashkent).Day() != night.AddDate(0, 0, 1).Day() {
		t.Fatalf("night = %v", p.Body)
	}

	// Запланированная рассылка: отменить можно один раз.
	noon := time.Date(tomorrow.Year(), tomorrow.Month(), tomorrow.Day(), 12, 0, 0, 0, push.Tashkent)
	later := a.expect(a.do("POST", "/admin/push/campaigns", adminTok, msg(home, nil, noon.Format(time.RFC3339))), 201, "scheduled")
	if later.str("status") != "scheduled" || later.Body["recipients"].(float64) != 2 {
		t.Fatalf("scheduled = %v", later.Body)
	}
	a.expect(a.do("POST", "/admin/push/campaigns/"+later.str("id")+"/cancel", adminTok, nil), 200, "cancel")
	a.expect(a.do("POST", "/admin/push/campaigns/"+later.str("id")+"/cancel", adminTok, nil), 409, "cancel twice")

	// Рассылка сейчас с переходом в категорию. Ночью «сейчас» тоже ждёт утра —
	// для теста время подменяем запросом.
	now := a.expect(a.do("POST", "/admin/push/campaigns", adminTok,
		msg(map[string]any{"type": "category", "store_id": shop.store, "category_id": category}, nil, nil)), 201, "now")
	id := now.str("id")
	if _, err := pool.Exec(ctx, `UPDATE push_campaigns SET send_at = now() WHERE id = $1`, id); err != nil {
		t.Fatal(err)
	}
	d := push.NewDispatcher(pool, fcm, quietLog())
	if _, err := d.Tick(ctx); err != nil {
		t.Fatal(err)
	}
	c := a.expect(a.do("GET", "/admin/push/campaigns/"+id, adminTok, nil), 200, "campaign")
	st := c.Body["stats"].(map[string]any)
	if c.str("status") != "sent" || st["sent"].(float64) != 1 || st["no_push"].(float64) != 1 {
		t.Fatalf("campaign = %v", c.Body)
	}
	if len(fcm.sent) != 1 || fcm.sent[0].Data["target"] != "category" || fcm.sent[0].Data["category_id"] != category ||
		fcm.sent[0].Data["store_id"] != shop.store || fcm.sent[0].Data["campaign_id"] != id || fcm.sent[0].Data["type"] != "open" {
		t.Fatalf("fcm = %+v", fcm.sent)
	}
	notSent := a.expect(a.do("GET", "/admin/push/campaigns/"+id+"/recipients?status=not_sent", adminTok, nil), 200, "not sent").items()
	if len(notSent) != 1 || notSent[0]["phone"] != "+998901111111" || !strings.HasPrefix(notSent[0]["reason"].(string), "Нет push") {
		t.Fatalf("not sent = %v", notSent)
	}
	sent := a.expect(a.do("GET", "/admin/push/campaigns/"+id+"/recipients?status=sent&q=1234", adminTok, nil), 200, "sent").items()
	if len(sent) != 1 || sent[0]["devices"] != "iPhone" {
		t.Fatalf("sent = %v", sent)
	}
	if list := a.expect(a.do("GET", "/admin/push/campaigns", adminTok, nil), 200, "list").items(); len(list) != 2 {
		t.Fatalf("list = %v", list)
	}
	// Рассылка видна покупателю в колокольчике.
	bell := a.expect(a.do("GET", "/client/notifications", client2, nil), 200, "bell").items()
	if len(bell) != 1 || bell[0]["kind"] != "campaign" {
		t.Fatalf("bell = %v", bell)
	}

	// Тестовый push: поиск покупателя, ответ по устройству, ошибка APNs.
	cu := a.expect(a.do("GET", "/admin/push/customer?phone=901234567", adminTok, nil), 200, "customer")
	if cu.str("user_id") != user1 || len(cu.Body["devices"].([]any)) != 1 || cu.Body["orders"].(float64) != 1 {
		t.Fatalf("customer = %v", cu.Body)
	}
	a.expect(a.do("GET", "/admin/push/customer", adminTok, nil), 404, "admin is not a customer")
	r := a.expect(a.do("POST", "/admin/push/test", adminTok, map[string]any{"phone": "+998901234567"}), 200, "test")
	if res := r.Body["results"].([]any); len(res) != 1 || res[0].(map[string]any)["ok"] != true {
		t.Fatalf("test = %v", r.Body)
	}
	fcm.err = push.ErrAPNsAuth
	r = a.expect(a.do("POST", "/admin/push/test", adminTok, map[string]any{"phone": "+998901234567", "title": "Ещё"}), 200, "test apns")
	if res := r.Body["results"].([]any)[0].(map[string]any); res["ok"] != false || res["reason"] != "APNs-ключ не настроен в Firebase" {
		t.Fatalf("test apns = %v", r.Body)
	}
	a.expect(a.do("POST", "/admin/push/test", adminTok, map[string]any{"phone": "+998901111111"}), 409, "no devices")
	log := a.expect(a.do("GET", "/admin/notifications?kind=test", adminTok, nil), 200, "journal").items()
	if len(log) != 2 || log[0]["status"] != "failed" || log[1]["devices"] != "iPhone" {
		t.Fatalf("journal = %v", log)
	}
	a.expect(a.do("GET", "/admin/push/campaigns", shop.client, nil), 403, "client token")
}
