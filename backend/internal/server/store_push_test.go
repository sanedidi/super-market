package server_test

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/push"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// TestStorePush — push сотрудникам в приложение магазина: новый заказ уходит
// на устройство сотрудника, покупательский статус — только покупателю.
func TestStorePush(t *testing.T) {
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

	const storeToken = "store-fcm-token-0123456789-abcdef"
	const clientToken = "client-fcm-token-0123456789-abcdef"
	a.expect(a.do("POST", "/store/devices", tok, map[string]any{"token": "short", "platform": "ios"}), 400, "short token")
	a.expect(a.do("POST", "/store/devices", tok, map[string]any{"token": storeToken, "platform": "ios"}), 204, "store device")
	client, _ := a.login("+998900000050", identity.AppClient)
	a.expect(a.do("POST", "/client/devices", client, map[string]any{"token": clientToken, "platform": "android"}), 204, "client device")
	a.expect(a.do("POST", "/store/devices", client, map[string]any{"token": storeToken, "platform": "ios"}), 403, "client token on store")

	addr := a.expect(a.do("POST", "/client/addresses", client, map[string]any{"address": "Чиланзар 5", "lat": lat + 0.005, "lng": lng}), 201, "address").str("id")
	o := a.expect(a.do("POST", "/client/orders", client, map[string]any{"store_id": store, "address_id": addr, "payment_provider": "cash",
		"items": []map[string]any{{"product_id": cola, "qty": 2}}}), 201, "order")
	orderID := o.str("order", "id")

	fcm := &fakeFCM{}
	if _, err := push.NewDispatcher(pool, fcm, quietLog()).Tick(ctx); err != nil {
		t.Fatal(err)
	}
	var toStore, toClient []string
	for _, s := range fcm.sent {
		switch {
		case strings.HasPrefix(s, storeToken):
			toStore = append(toStore, s)
		case strings.HasPrefix(s, clientToken):
			toClient = append(toClient, s)
		}
	}
	if len(toStore) != 1 || !strings.Contains(toStore[0], "Новый заказ №1|"+orderID) {
		t.Fatalf("store push = %v (all %v)", toStore, fcm.sent)
	}
	if len(toClient) != 1 || strings.Contains(toClient[0], "Новый заказ") {
		t.Fatalf("client push = %v", toClient)
	}
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM notifications_outbox WHERE app = 'store' AND kind = 'store_order' AND status = 'sent'`); n != "1" {
		t.Fatalf("store outbox = %s", n)
	}

	// Выход: устройство удалено — новые push сотруднику не ставятся.
	a.expect(a.do("DELETE", "/store/devices/"+storeToken, tok, nil), 204, "remove device")
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM devices WHERE app = 'store'`); n != "0" {
		t.Fatalf("store devices = %s", n)
	}
	if push.Sum("186500.00") != "186 500" || push.Sum("1500.50") != "1 500,50" {
		t.Fatalf("sum = %s %s", push.Sum("186500.00"), push.Sum("1500.50"))
	}
}
