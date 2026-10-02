package server_test

import (
	"context"
	"regexp"
	"strings"
	"sync"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

type fakeSMS struct {
	mu   sync.Mutex
	sent []string
}

func (f *fakeSMS) Send(_ context.Context, phone, text string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = append(f.sent, phone+"|"+text)
	return nil
}

// TestCrowdSMSCode — код курьеру «по пути» уходит по SMS, без Telegram.
func TestCrowdSMSCode(t *testing.T) {
	pool := freshDB(t)
	sms := &fakeSMS{}
	server.SMSOverride = sms
	t.Cleanup(func() { server.SMSOverride = nil })
	a := newAPI(t, testConfig(), pool, nil)

	// Покупателю без привязки к боту код не отправить — как и раньше.
	a.expect(a.do("POST", "/auth/otp/request", "", map[string]any{"phone": "+998900000090"}), 409, "client needs telegram")
	r := a.expect(a.do("POST", "/auth/otp/request", "", map[string]any{"phone": "+998900000090", "app": "crowd"}), 200, "crowd sms")
	if r.str("channel") != "sms" || len(sms.sent) != 1 {
		t.Fatalf("resp = %v, sent = %v", r.Body, sms.sent)
	}
	code := regexp.MustCompile(`[0-9]{6}`).FindString(strings.SplitN(sms.sent[0], "|", 2)[1])
	a.expect(a.do("POST", "/auth/otp/verify", "", map[string]any{"phone": "+998900000090", "code": code, "app": "crowd"}), 422, "no terms")
	// Неудачная попытка из-за условий съела код — запросим новый через минуту; здесь проверяем вход с согласием.
	if _, err := pool.Exec(context.Background(), `UPDATE auth_codes SET sent_at = now() - interval '2 minutes'`); err != nil {
		t.Fatal(err)
	}
	a.expect(a.do("POST", "/auth/otp/request", "", map[string]any{"phone": "+998900000090", "app": "crowd"}), 200, "again")
	code = regexp.MustCompile(`[0-9]{6}`).FindString(strings.SplitN(sms.sent[1], "|", 2)[1])
	ok := a.expect(a.do("POST", "/auth/otp/verify", "", map[string]any{
		"phone": "+998900000090", "code": code, "app": "crowd", "terms_accepted": true}), 200, "verify")
	me := a.expect(a.do("GET", "/crowd/me", ok.str("access_token"), nil), 200, "me")
	if me.str("status") != "unverified" || !regexp.MustCompile(`^KR-[0-9]{5}$`).MatchString(me.str("code")) {
		t.Fatalf("me = %v", me.Body)
	}
}

// TestCrowdDelivery — весь путь курьера «по пути»: регистрация, проверка
// личности в магазине, лента, принятие, выдача по коду, вручение по коду
// покупателя, вознаграждение, бонус магазину, выплата; просрочка,
// отказ и блокировка.
func TestCrowdDelivery(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	cfg := paymeConfig()
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	shop := newAdminShop(t, a, adminTok, "+998900000002", "+998901234567")
	tok, _ := a.login("+998900000002", identity.AppStore)

	crowdLogin := func(phone string, terms bool) resp {
		a.expect(a.do("POST", "/auth/otp/request", "", map[string]any{"phone": phone, "app": "crowd"}), 200, "request "+phone)
		return a.do("POST", "/auth/otp/verify", "", map[string]any{"phone": phone, "code": "111111", "app": "crowd", "terms_accepted": terms})
	}
	a.expect(crowdLogin("+998900000080", false), 422, "terms required")
	if _, err := pool.Exec(ctx, `DELETE FROM auth_codes`); err != nil {
		t.Fatal(err)
	}
	cTok := a.expect(crowdLogin("+998900000080", true), 200, "crowd login").str("access_token")
	me := a.expect(a.do("GET", "/crowd/me", cTok, nil), 200, "me")
	code := me.str("code")
	if me.str("status") != "unverified" || me.str("level", "key") != "none" || me.str("balance") != "0.00" {
		t.Fatalf("me = %v", me.Body)
	}
	if f := a.expect(a.do("GET", "/crowd/offers", cTok, nil), 200, "feed"); f.str("state") != "unverified" {
		t.Fatalf("feed = %v", f.Body)
	}
	// Токены разных приложений не смешиваются.
	a.expect(a.do("GET", "/crowd/me", shop.client, nil), 403, "client token")
	a.expect(a.do("GET", "/client/orders", cTok, nil), 403, "crowd token on client")

	// Магазин не подключён — проверять нельзя.
	verify := map[string]any{"code": code, "store_id": shop.store, "decision": "approve", "doc_type": "id_card",
		"full_name": "Рахимов  Азиз Бахтиёрович", "birth_date": "2002-03-14", "doc_last4": "5821", "photo_match": true, "doc_valid": true}
	a.expect(a.do("POST", "/store/crowd/verify", tok, verify), 409, "store not enabled")
	a.expect(a.do("PUT", "/admin/crowd/stores/"+shop.store, adminTok, map[string]any{"crowd_enabled": true}), 200, "enable store")
	pts := a.expect(a.do("GET", "/crowd/points?lat=41.30&lng=69.24", cTok, nil), 200, "points").items()
	if len(pts) != 1 || pts[0]["store_id"] != shop.store || pts[0]["distance_m"] == nil {
		t.Fatalf("points = %v", pts)
	}

	card := a.expect(a.do("POST", "/store/crowd/lookup", tok, map[string]any{"code": "sm-courier:" + code}), 200, "lookup")
	if card.str("status") != "unverified" || card.str("phone") != "+998900000080" {
		t.Fatalf("card = %v", card.Body)
	}
	a.expect(a.do("POST", "/store/crowd/lookup", tok, map[string]any{"code": "KR-00001"}), 404, "unknown code")
	a.expect(a.do("POST", "/store/crowd/verify", tok, map[string]any{"code": code, "store_id": shop.store, "decision": "reject", "doc_type": "passport"}), 400, "reject without reason")
	young := map[string]any{}
	for k, v := range verify {
		young[k] = v
	}
	young["birth_date"] = "2015-01-01"
	a.expect(a.do("POST", "/store/crowd/verify", tok, young), 400, "under 18")
	young["birth_date"], young["photo_match"] = "2002-03-14", false
	a.expect(a.do("POST", "/store/crowd/verify", tok, young), 400, "photo not checked")
	v := a.expect(a.do("POST", "/store/crowd/verify", tok, verify), 200, "verify")
	if v.str("status") != "active" || v.str("full_name") != "Рахимов Азиз Бахтиёрович" || v.str("level") != "Новичок" {
		t.Fatalf("verified = %v", v.Body)
	}
	a.expect(a.do("POST", "/store/crowd/verify", tok, verify), 409, "already verified")
	// Тот же документ у второго курьера не пройдёт.
	c2 := a.expect(crowdLogin("+998900000081", true), 200, "second courier").str("access_token")
	code2 := a.expect(a.do("GET", "/crowd/me", c2, nil), 200, "me2").str("code")
	dup := map[string]any{}
	for k, val := range verify {
		dup[k] = val
	}
	dup["code"] = code2
	a.expect(a.do("POST", "/store/crowd/verify", tok, dup), 409, "same document")

	// Собранный оплаченный заказ — в ленте.
	id, number := shop.order(t)
	if _, err := pool.Exec(ctx, `UPDATE orders SET status = 'picked', paid_at = now(), accepted_at = now(), picked_at = now() WHERE id = $1`, id); err != nil {
		t.Fatal(err)
	}
	so := a.expect(a.do("GET", "/store/orders/"+id, tok, nil), 200, "store order")
	if so.Body["crowd_open"] != true || so.str("delivery_mode") != "staff" {
		t.Fatalf("store order = %v", so.Body)
	}
	if f := a.expect(a.do("GET", "/crowd/offers?lat=41.30&lng=69.24", cTok, nil), 200, "offline feed"); f.str("state") != "offline" {
		t.Fatalf("feed = %v", f.Body)
	}
	a.expect(a.do("PUT", "/crowd/route", cTok, map[string]any{"online": true, "dest": map[string]any{"lat": 41.31, "lng": 69.24, "title": "Метро"}}), 200, "route")
	feed := a.expect(a.do("GET", "/crowd/offers?lat=41.2990&lng=69.2401", cTok, nil), 200, "feed")
	items := feed.items()
	if feed.str("state") != "ok" || len(items) != 1 || items[0]["order_id"] != id || items[0]["reward"] != "10000.00" ||
		items[0]["detour_m"] == nil || items[0]["number"].(float64) != number {
		t.Fatalf("feed = %v", feed.Body)
	}
	if _, has := items[0]["address"]; has {
		t.Fatal("адрес покупателя виден до принятия")
	}

	acc := a.expect(a.do("POST", "/crowd/offers/"+id+"/accept", cTok, nil), 200, "accept")
	pickup := acc.str("pickup_code")
	if len(pickup) != 3 || acc.str("order", "customer_phone") != "" || acc.str("order", "delivery_mode") != "crowd" {
		t.Fatalf("accepted = %v", acc.Body)
	}
	a.expect(a.do("POST", "/crowd/offers/"+id+"/accept", c2, nil), 403, "unverified cannot accept")
	if f := a.expect(a.do("GET", "/crowd/offers?lat=41.2990&lng=69.2401", cTok, nil), 200, "busy feed"); f.str("state") != "busy" {
		t.Fatalf("feed = %v", f.Body)
	}
	// Магазин не может сам отметить «в пути» и не назначит своего курьера.
	a.expect(a.do("POST", "/store/orders/"+id+"/start-delivery", tok, nil), 409, "store start delivery")
	a.expect(a.do("POST", "/store/orders/"+id+"/delivered", tok, nil), 409, "store delivered")
	// Покупатель видит код вручения и курьера.
	co := a.expect(a.do("GET", "/client/orders/"+id, shop.client, nil), 200, "client order")
	handoff := co.str("handoff_code")
	if !regexp.MustCompile(`^[0-9]{4}$`).MatchString(handoff) || co.str("courier_name") != "Рахимов Азиз Бахтиёрович" {
		t.Fatalf("client order = %v", co.Body)
	}
	if so := a.expect(a.do("GET", "/store/orders/"+id, tok, nil), 200, "store order"); so.Body["handoff_code"] != nil {
		t.Fatal("магазин видит код вручения")
	}

	a.expect(a.do("POST", "/store/orders/"+id+"/crowd-handover", tok, map[string]any{"code": "AAA"}), 400, "wrong pickup")
	h := a.expect(a.do("POST", "/store/orders/"+id+"/crowd-handover", tok, map[string]any{"code": "sm-pickup:" + itoa(int(number)) + ":" + pickup}), 200, "handover")
	if h.str("status") != "delivering" {
		t.Fatalf("handover = %v", h.Body)
	}
	tr := a.expect(a.do("GET", "/client/orders/"+id+"/tracking", shop.client, nil), 200, "tracking")
	if tr.Body["courier"].(map[string]any)["crowd"] != true || tr.Body["eta_minutes"] == nil {
		t.Fatalf("tracking = %v", tr.Body)
	}
	a.expect(a.do("POST", "/crowd/location", cTok, map[string]any{"lat": 41.301, "lng": 69.2401}), 204, "location")
	d := a.expect(a.do("GET", "/crowd/orders/"+id, cTok, nil), 200, "crowd order")
	if d.str("order", "customer_phone") != "+998901234567" || d.str("pickup_code") != "" {
		t.Fatalf("crowd order = %v", d.Body)
	}
	bad := a.expect(a.do("POST", "/crowd/orders/"+id+"/deliver", cTok, map[string]any{"code": "0000"}), 400, "wrong handoff")
	if handoff == "0000" || bad.Body["error"].(map[string]any)["details"].(map[string]any)["attempts_left"].(float64) != 4 {
		t.Fatalf("bad = %v", bad.Body)
	}
	dv := a.expect(a.do("POST", "/crowd/orders/"+id+"/deliver", cTok, map[string]any{"code": handoff}), 200, "deliver")
	if dv.str("order", "status") != "delivered" {
		t.Fatalf("delivered = %v", dv.Body)
	}
	earn := a.expect(a.do("GET", "/crowd/earnings", cTok, nil), 200, "earnings")
	if earn.str("balance") != "10000.00" || earn.Body["week_delivered"].(float64) != 1 || len(earn.items()) != 1 {
		t.Fatalf("earnings = %v", earn.Body)
	}
	bon := a.expect(a.do("GET", "/store/crowd/bonuses", tok, nil), 200, "bonuses")
	if bon.str("pending") != "5000.00" || bon.Body["verified"].(float64) != 1 || bon.items()[0]["deliveries"].(float64) != 1 {
		t.Fatalf("bonuses = %v", bon.Body)
	}
	me = a.expect(a.do("GET", "/crowd/me", cTok, nil), 200, "me after")
	if me.Body["stats"].(map[string]any)["delivered"].(float64) != 1 || me.Body["verification"] == nil {
		t.Fatalf("me = %v", me.Body)
	}

	// Не забрал вовремя — заказ снова в ленте, нарушение.
	id2, _ := shop.order(t)
	if _, err := pool.Exec(ctx, `UPDATE orders SET status = 'picked', paid_at = now(), accepted_at = now(), picked_at = now() WHERE id = $1`, id2); err != nil {
		t.Fatal(err)
	}
	a.expect(a.do("POST", "/crowd/offers/"+id2+"/accept", cTok, nil), 200, "accept 2")
	if _, err := pool.Exec(ctx, `UPDATE orders SET crowd_pickup_until = now() - interval '1 minute' WHERE id = $1`, id2); err != nil {
		t.Fatal(err)
	}
	_, _, ord := server.OrderServices(cfg, pool, nil, quietLog())
	if err := ord.CrowdTick(ctx); err != nil {
		t.Fatal(err)
	}
	if so := a.expect(a.do("GET", "/store/orders/"+id2, tok, nil), 200, "after tick"); so.Body["crowd_courier_id"] != nil || so.Body["crowd_open"] != true {
		t.Fatalf("after tick = %v", so.Body)
	}
	me = a.expect(a.do("GET", "/crowd/me", cTok, nil), 200, "me violation")
	if me.Body["stats"].(map[string]any)["violations"].(float64) != 1 {
		t.Fatalf("me = %v", me.Body)
	}
	// Отказ до магазина — не нарушение; магазин тоже может снять курьера.
	a.expect(a.do("POST", "/crowd/offers/"+id2+"/accept", cTok, nil), 200, "accept again")
	a.expect(a.do("POST", "/crowd/orders/"+id2+"/release", cTok, nil), 200, "release")
	a.expect(a.do("POST", "/crowd/offers/"+id2+"/accept", cTok, nil), 200, "accept third")
	a.expect(a.do("POST", "/store/orders/"+id2+"/crowd-release", tok, nil), 200, "store release")

	// Супер-админ: обзор, курьеры, инциденты, выплата, правила, блокировка.
	ov := a.expect(a.do("GET", "/admin/crowd/overview", adminTok, nil), 200, "overview")
	if ov.Body["verified"].(float64) != 1 || ov.Body["unverified"].(float64) != 1 || ov.str("payout_total") != "10000.00" ||
		ov.Body["today_taken"].(float64) < 1 || ov.Body["stores"].(float64) != 1 {
		t.Fatalf("overview = %v", ov.Body)
	}
	cl := a.expect(a.do("GET", "/admin/crowd/couriers?status=active", adminTok, nil), 200, "couriers").items()
	if len(cl) != 1 || cl[0]["delivered"].(float64) != 1 || cl[0]["level"] != "Новичок" {
		t.Fatalf("couriers = %v", cl)
	}
	inc := a.expect(a.do("GET", "/admin/crowd/incidents?status=open", adminTok, nil), 200, "incidents").items()
	if len(inc) != 1 || inc[0]["kind"] != "other" {
		t.Fatalf("incidents = %v", inc)
	}
	a.expect(a.do("POST", "/admin/crowd/incidents/"+inc[0]["id"].(string)+"/resolve", adminTok, map[string]any{"resolution": "Ок", "penalty": 1000}), 200, "resolve")
	pays := a.expect(a.do("GET", "/admin/crowd/payouts", adminTok, nil), 200, "payouts").items()
	if len(pays) != 1 || pays[0]["balance"] != "9000.00" {
		t.Fatalf("payouts = %v", pays)
	}
	if p := a.expect(a.do("POST", "/admin/crowd/payouts", adminTok, map[string]any{"courier_ids": []string{pays[0]["user_id"].(string)}}), 200, "pay"); p.Body["paid"].(float64) != 1 {
		t.Fatalf("pay = %v", p.Body)
	}
	if e := a.expect(a.do("GET", "/crowd/earnings", cTok, nil), 200, "after pay"); e.str("balance") != "0.00" {
		t.Fatalf("after pay = %v", e.Body)
	}
	st := a.expect(a.do("GET", "/admin/crowd/settings", adminTok, nil), 200, "settings")
	st.Body["courier_fee"] = "12000.00"
	st.Body["trusted_after"] = 5
	a.expect(a.do("PUT", "/admin/crowd/settings", adminTok, st.Body), 400, "trusted before reliable")
	st.Body["trusted_after"] = 100
	if s2 := a.expect(a.do("PUT", "/admin/crowd/settings", adminTok, st.Body), 200, "save settings"); s2.str("courier_fee") != "12000.00" {
		t.Fatalf("settings = %v", s2.Body)
	}
	uid := cl[0]["user_id"].(string)
	a.expect(a.do("POST", "/admin/crowd/couriers/"+uid+"/block", adminTok, map[string]any{"reason": "Жалобы"}), 200, "block")
	a.expect(a.do("GET", "/crowd/me", cTok, nil), 401, "blocked session")
	a.expect(crowdLogin("+998900000080", true), 403, "blocked login")
	a.expect(a.do("POST", "/admin/crowd/couriers/"+uid+"/unblock", adminTok, nil), 200, "unblock")
	if _, err := pool.Exec(ctx, `DELETE FROM auth_codes`); err != nil {
		t.Fatal(err)
	}
	cTok = a.expect(crowdLogin("+998900000080", true), 200, "login after unblock").str("access_token")
	if m := a.expect(a.do("GET", "/crowd/me", cTok, nil), 200, "me unblocked"); m.str("status") != "active" {
		t.Fatalf("me = %v", m.Body)
	}
}
