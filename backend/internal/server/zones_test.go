package server_test

import (
	"context"
	"fmt"
	"net/http/httptest"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// TestNestedZones — зоны доставки на карте: цена берётся из самой маленькой
// (внутренней) зоны, в которую попал адрес; вне зон магазин не доставляет,
// даже если адрес в радиусе; «бесплатно от суммы» продолжает действовать.
func TestNestedZones(t *testing.T) {
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
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	const lat, lng = 41.30, 69.24
	a.expect(a.do("PATCH", "/store/stores/"+store, tok, map[string]any{"lat": lat, "lng": lng}), 200, "store")
	a.expect(a.do("PUT", "/store/stores/"+store+"/delivery", tok, map[string]any{
		"accepts_online": true, "delivery_radius_m": 50000,
		"rules": []map[string]any{{"type": "free_from", "params": map[string]any{"amount": 300000}}},
	}), 200, "delivery")

	square := func(d float64) [][2]float64 {
		return [][2]float64{{lng - d, lat - d}, {lng + d, lat - d}, {lng + d, lat + d}, {lng - d, lat + d}}
	}
	zones := "/store/stores/" + store + "/zones"
	// Большая зона дешевле внутренней — выбор всё равно по вложенности, не по цене.
	a.expect(a.do("POST", zones, tok, map[string]any{"name": "Город", "price": 10000, "polygon": square(0.10)}), 201, "outer")
	inner := a.expect(a.do("POST", zones, tok, map[string]any{"name": "Центр", "price": 12000, "polygon": square(0.02)}), 201, "inner").str("id")
	a.expect(a.do("POST", zones, tok, map[string]any{"name": "x", "price": 1, "polygon": [][2]float64{{1, 1}, {2, 2}}}), 400, "2 points")

	fee := func(plat, plng float64) any {
		t.Helper()
		near := a.expect(a.do("GET", fmt.Sprintf("/client/stores/nearby?lat=%v&lng=%v", plat, plng), "", nil), 200, "nearby").items()
		if len(near) == 0 {
			return nil
		}
		return near[0]["delivery"].(map[string]any)["delivery_fee"]
	}
	if f := fee(lat+0.01, lng); f != "12000.00" {
		t.Fatalf("inner fee = %v", f)
	}
	if f := fee(lat+0.05, lng); f != "10000.00" {
		t.Fatalf("outer fee = %v", f)
	}
	if f := fee(lat+0.2, lng); f != nil {
		t.Fatalf("outside zones = %v", f)
	}
	// Отключённая внутренняя зона не участвует.
	a.expect(a.do("PATCH", zones+"/"+inner, tok, map[string]any{"is_active": false}), 200, "disable inner")
	if f := fee(lat+0.01, lng); f != "10000.00" {
		t.Fatalf("fee with inner disabled = %v", f)
	}
}
