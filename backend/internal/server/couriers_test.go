package server_test

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// TestCouriers — курьер магазина: смена, назначение, «забрал», геопозиция,
// время прибытия и отслеживание у покупателя, «доставил».
func TestCouriers(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	cfg.PaymeMerchantID, cfg.PaymeKey = "merchant-1", paymeKey
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
	a.expect(a.do("PATCH", "/store/stores/"+store, tok, map[string]any{"lat": lat, "lng": lng, "phone": "+998712000000"}), 200, "store")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
	doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{"type": "posting", "warehouse_id": wh,
		"items": []map[string]any{{"product_id": cola, "qty": 20, "price": 10000}}}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post")
	a.expect(a.do("PUT", "/store/stores/"+store+"/delivery", tok, map[string]any{
		"accepts_online": true, "delivery_radius_m": 5000,
		"rules": []map[string]any{{"type": "fixed", "params": map[string]any{"price": 5000}}},
	}), 200, "delivery")

	// Роль «Курьер» и сотрудник; кассир курьером не является.
	role := a.expect(a.do("POST", "/store/roles", tok, map[string]any{"name": "Курьер", "permissions": []string{identity.PermOrdersDeliver}}), 201, "role").str("id")
	courier := a.expect(a.do("POST", "/store/employees", tok, map[string]any{
		"phone": "+998900000070", "full_name": "Жасур", "role_id": role, "store_ids": []string{store},
	}), 201, "courier").str("id")
	cashRole := a.expect(a.do("POST", "/store/roles", tok, map[string]any{"name": "Кассир", "permissions": []string{identity.PermSalesPOS}}), 201, "cash role").str("id")
	cashier := a.expect(a.do("POST", "/store/employees", tok, map[string]any{
		"phone": "+998900000071", "full_name": "Кассир", "role_id": cashRole, "store_ids": []string{store},
	}), 201, "cashier").str("id")
	if _, err := pool.Exec(ctx, `INSERT INTO telegram_links (phone, chat_id, tg_user_id) VALUES ('+998900000070', 7070, 7070)`); err != nil {
		t.Fatal(err)
	}
	cTok, _ := a.login("+998900000070", identity.AppStore)
	cashTok, _ := a.login("+998900000071", identity.AppStore)
	a.expect(a.do("GET", "/courier/me", cashTok, nil), 403, "cashier is not a courier")

	me := a.expect(a.do("POST", "/courier/shift", cTok, map[string]any{"on_shift": true, "vehicle": "scooter"}), 200, "shift")
	if me.Body["on_shift"] != true || me.str("vehicle") != "scooter" || me.str("full_name") != "Жасур" {
		t.Fatalf("courier me = %v", me.Body)
	}
	a.expect(a.do("POST", "/courier/shift", cTok, map[string]any{"vehicle": "plane"}), 400, "bad vehicle")
	list := a.expect(a.do("GET", "/store/couriers?store_id="+store, tok, nil), 200, "couriers").items()
	if len(list) != 1 || list[0]["employee_id"] != courier || list[0]["on_shift"] != true {
		t.Fatalf("couriers = %v", list)
	}

	// Заказ покупателя, оплата, приём.
	client, _ := a.login("+998900000050", identity.AppClient)
	const clat = lat + 0.018 // ~2 км
	addr := a.expect(a.do("POST", "/client/addresses", client, map[string]any{"address": "Юнусабад", "lat": clat, "lng": lng}), 201, "address").str("id")
	o := a.expect(a.do("POST", "/client/orders", client, map[string]any{"store_id": store, "address_id": addr, "payment_provider": "payme",
		"items": []map[string]any{{"product_id": cola, "qty": 2}}}), 201, "order")
	id := o.str("order", "id")
	prov.payme(paymeKey, "CreateTransaction", map[string]any{"id": "pm-1", "time": time.Now().UnixMilli(), "amount": 3500000, "account": map[string]any{"order_id": id}})
	prov.payme(paymeKey, "PerformTransaction", map[string]any{"id": "pm-1"})
	a.expect(a.do("POST", "/store/orders/"+id+"/accept", tok, nil), 200, "accept")

	a.expect(a.do("POST", "/store/orders/"+id+"/assign-courier", tok, map[string]any{"courier_id": cashier}), 400, "assign cashier")
	as := a.expect(a.do("POST", "/store/orders/"+id+"/assign-courier", tok, map[string]any{"courier_id": courier}), 200, "assign")
	if as.str("courier_name") != "Жасур" {
		t.Fatalf("assigned = %v", as.Body)
	}
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM notifications_outbox`); n != "2" { // оплачен, принят — назначение без push
		t.Fatalf("outbox = %s", n)
	}
	deadline := time.Now().Add(3 * time.Second)
	for {
		if m := tg.last(); m.chatID == 7070 && strings.Contains(m.text, "назначен заказ") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("courier was not notified")
		}
		time.Sleep(20 * time.Millisecond)
	}

	// Курьер видит заказ с магазином; забрать можно только собранный.
	co := a.expect(a.do("GET", "/courier/orders", cTok, nil), 200, "courier orders").items()
	if len(co) != 1 || co[0]["store"].(map[string]any)["phone"] != "+998712000000" {
		t.Fatalf("courier orders = %v", co)
	}
	a.expect(a.do("POST", "/courier/orders/"+id+"/picked-up", cTok, nil), 409, "pick up before picked")
	a.expect(a.do("GET", "/courier/orders/"+id, cashTok, nil), 403, "other employee")

	// Покупатель: курьер назначен, телефон и точка пока скрыты.
	tr := a.expect(a.do("GET", "/client/orders/"+id+"/tracking", client, nil), 200, "tracking")
	if c := tr.Body["courier"].(map[string]any); c["name"] != "Жасур" || c["phone"] != nil || c["location"] != nil {
		t.Fatalf("tracking before = %v", tr.Body)
	}

	if _, err := pool.Exec(ctx, `UPDATE orders SET status = 'picked' WHERE id = $1`, id); err != nil {
		t.Fatal(err)
	}
	pu := a.expect(a.do("POST", "/courier/orders/"+id+"/picked-up", cTok, nil), 200, "picked up")
	if pu.str("order", "status") != "delivering" || pu.str("order", "eta_at") == "" {
		t.Fatalf("picked up = %v", pu.Body)
	}
	// Точка курьера на полпути: ETA ≈ 1 км × 1,35 на скутере + 2 мин ≈ 6 мин.
	a.expect(a.do("POST", "/courier/location", cTok, map[string]any{"lat": 0, "lng": 0}), 400, "bad point")
	a.expect(a.do("POST", "/courier/location", cTok, map[string]any{"lat": lat + 0.009, "lng": lng, "accuracy": 8, "heading": 10}), 204, "location")
	tr = a.expect(a.do("GET", "/client/orders/"+id+"/tracking", client, nil), 200, "tracking delivering")
	c := tr.Body["courier"].(map[string]any)
	if c["phone"] != "+998900000070" || c["location"] == nil || c["vehicle"] != "scooter" {
		t.Fatalf("tracking courier = %v", c)
	}
	if m := tr.Body["eta_minutes"].(float64); m < 5 || m > 7 {
		t.Fatalf("eta minutes = %v", m)
	}
	if tr.Body["destination"].(map[string]any)["lat"].(float64) != clat {
		t.Fatalf("destination = %v", tr.Body["destination"])
	}

	dv := a.expect(a.do("POST", "/courier/orders/"+id+"/delivered", cTok, nil), 200, "delivered")
	if dv.str("order", "status") != "delivered" {
		t.Fatalf("delivered = %v", dv.Body)
	}
	if s := sqlStr(t, pool, `SELECT status FROM balance_entries WHERE order_id = $1`, id); s != "available" {
		t.Fatalf("balance = %s", s)
	}
	tr = a.expect(a.do("GET", "/client/orders/"+id+"/tracking", client, nil), 200, "tracking done")
	if tr.Body["courier"] != nil {
		t.Fatalf("courier shown after delivery: %v", tr.Body)
	}
	// Ушёл со смены — точка стирается.
	a.expect(a.do("POST", "/courier/shift", cTok, map[string]any{"on_shift": false}), 200, "off shift")
	if s := sqlStr(t, pool, `SELECT (location IS NULL)::text FROM couriers WHERE employee_id = $1`, courier); s != "true" {
		t.Fatalf("location kept after shift: %s", s)
	}
}
