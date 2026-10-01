package server_test

import (
	"context"
	"fmt"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// TestDeliverySlots — окна доставки: настройка магазином, список для
// приложения, заказ ко времени, вместимость окна, сортировка у магазина.
func TestDeliverySlots(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	cfg.PaymeMerchantID, cfg.PaymeKey = "merchant-1", paymeKey
	cfg.PaymentTimeout = 15 * time.Minute
	app, err := server.Build(ctx, cfg, pool, &fakeTelegram{}, quietLog())
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app.Handler)
	t.Cleanup(srv.Close)
	a := api{t: t, srv: srv}

	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, _ := catalogBasics(t, a, adminTok)
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	const lat, lng = 41.2995, 69.2401
	a.expect(a.do("PATCH", "/store/stores/"+store, tok, map[string]any{"lat": lat, "lng": lng}), 200, "store")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
	doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{"type": "posting", "warehouse_id": wh,
		"items": []map[string]any{{"product_id": cola, "qty": 50, "price": 10000}}}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post")

	var hours []map[string]any
	for d := 0; d < 7; d++ {
		hours = append(hours, map[string]any{"weekday": d, "opens": "09:00", "closes": "21:00"})
	}
	settings := map[string]any{
		"accepts_online": true, "delivery_radius_m": 5000, "working_hours": hours,
		"rules": []map[string]any{{"type": "fixed", "params": map[string]any{"price": 5000}}},
	}
	a.expect(a.do("PUT", "/store/stores/"+store+"/delivery", tok, settings), 200, "delivery")

	// Окна выключены по умолчанию.
	sl := a.expect(a.do("GET", "/client/stores/"+store+"/slots", "", nil), 200, "slots off")
	if sl.Body["enabled"] != false || len(sl.Body["days"].([]any)) != 0 {
		t.Fatalf("slots off = %v", sl.Body)
	}
	a.expect(a.do("PUT", "/store/stores/"+store+"/delivery", tok, map[string]any{"slots": map[string]any{"slot_minutes": 10}}), 400, "short slot")
	got := a.expect(a.do("PUT", "/store/stores/"+store+"/delivery", tok, map[string]any{
		"slots": map[string]any{"enabled": true, "slot_minutes": 120, "days_ahead": 2, "capacity": 1},
	}), 200, "enable slots")
	if s := got.Body["slots"].(map[string]any); s["enabled"] != true || s["lead_minutes"].(float64) != 60 {
		t.Fatalf("slot settings = %v", s)
	}

	sl = a.expect(a.do("GET", "/client/stores/"+store+"/slots", "", nil), 200, "slots")
	days := sl.Body["days"].([]any)
	if len(days) != 3 {
		t.Fatalf("days = %v", days)
	}
	tomorrow := days[1].(map[string]any)
	slots := tomorrow["slots"].([]any)
	if len(slots) != 6 { // 09–21, по 2 часа
		t.Fatalf("tomorrow slots = %v", slots)
	}
	first := slots[0].(map[string]any)
	if first["status"] != "free" || first["left"].(float64) != 1 {
		t.Fatalf("first slot = %v", first)
	}
	from, _ := time.Parse(time.RFC3339, first["from"].(string))
	if h := from.In(time.FixedZone("UZ", 5*3600)).Hour(); h != 9 {
		t.Fatalf("slot starts at %d", h)
	}

	client, _ := a.login("+998900000050", identity.AppClient)
	addr := a.expect(a.do("POST", "/client/addresses", client, map[string]any{"address": "Рядом", "lat": lat + 0.005, "lng": lng}), 201, "address").str("id")
	cart := func(deliveryFrom any) map[string]any {
		return map[string]any{"store_id": store, "address_id": addr, "payment_provider": "payme", "delivery_from": deliveryFrom,
			"items": []map[string]any{{"product_id": cola, "qty": 2}}}
	}

	pv := a.expect(a.do("POST", "/client/checkout/preview", client, cart(first["from"])), 200, "preview slot")
	if pv.Body["can_order"] != true || pv.Body["delivery_to"] == nil {
		t.Fatalf("preview = %v", pv.Body)
	}
	bad := a.expect(a.do("POST", "/client/checkout/preview", client, cart(from.Add(30*time.Minute).Format(time.RFC3339))), 200, "preview bad slot")
	if fmt.Sprint(bad.Body["problems"]) != "[slot_unavailable]" {
		t.Fatalf("bad slot preview = %v", bad.Body)
	}
	o := a.expect(a.do("POST", "/client/orders", client, cart(first["from"])), 201, "order slot")
	if o.str("order", "delivery_from") == "" {
		t.Fatalf("order = %v", o.Body)
	}
	// Вместимость 1 — окно занято, второй заказ туда нельзя.
	a.expect(a.do("POST", "/client/orders", client, cart(first["from"])), 409, "slot full")
	sl = a.expect(a.do("GET", "/client/stores/"+store+"/slots", "", nil), 200, "slots after")
	if s := sl.Body["days"].([]any)[1].(map[string]any)["slots"].([]any)[0].(map[string]any); s["status"] != "full" {
		t.Fatalf("slot after order = %v", s)
	}
	// Как можно скорее — как раньше. Магазин открыт круглосуточно, чтобы
	// тест не зависел от времени запуска.
	allDay := make([]map[string]any, 7)
	for d := range allDay {
		allDay[d] = map[string]any{"weekday": d, "opens": "00:00", "closes": "23:59"}
	}
	a.expect(a.do("PUT", "/store/stores/"+store+"/delivery", tok, map[string]any{"working_hours": allDay}), 200, "all day")
	asap := a.expect(a.do("POST", "/client/orders", client, cart(nil)), 201, "asap")
	a.expect(a.do("PUT", "/store/stores/"+store+"/delivery", tok, map[string]any{"working_hours": hours}), 200, "hours back")

	// Магазин видит оба после оплаты; сортировка по времени доставки: сначала «как можно скорее».
	if _, err := pool.Exec(ctx, `UPDATE orders SET status = 'paid', paid_at = now()`); err != nil {
		t.Fatal(err)
	}
	list := a.expect(a.do("GET", "/store/orders?sort=delivery", tok, nil), 200, "store orders").items()
	if len(list) != 2 || list[0]["id"] != asap.str("order", "id") || list[1]["delivery_from"] == nil {
		t.Fatalf("store orders = %v", list)
	}
	a.expect(a.do("GET", "/store/orders?sort=price", tok, nil), 400, "bad sort")

	// Отмена освобождает окно.
	if _, err := pool.Exec(ctx, `UPDATE orders SET status = 'cancelled' WHERE id = $1`, o.str("order", "id")); err != nil {
		t.Fatal(err)
	}
	pv = a.expect(a.do("POST", "/client/checkout/preview", client, cart(first["from"])), 200, "preview freed")
	if pv.Body["can_order"] != true {
		t.Fatalf("freed slot = %v", pv.Body)
	}
}
