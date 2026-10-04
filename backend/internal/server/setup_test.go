package server_test

import (
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// TestStoreSetup — мастер первой настройки: магазин с точкой, часы работы,
// доставка; пока нет магазина с точкой и часами — мастер обязателен.
func TestStoreSetup(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	a.expect(a.do("POST", "/admin/networks", adminTok, map[string]string{
		"name": "Чиланзар Маркет", "kind": "chain", "owner_phone": "+998900000002", "owner_name": "Азиз",
	}), 201, "network")
	owner, _ := a.login("+998900000002", identity.AppStore)

	st := a.expect(a.do("GET", "/store/setup", owner, nil), 200, "state")
	if st.Body["required"] != true || st.Body["can_setup"] != true || st.Body["store"] != nil {
		t.Fatalf("initial = %v", st.Body)
	}

	// Шаг 1.
	a.expect(a.do("POST", "/store/setup/store", owner, map[string]any{"name": "Чиланзар Маркет", "address": "9-й квартал, 12"}), 400, "no point")
	a.expect(a.do("POST", "/store/setup/store", owner, map[string]any{"name": "X", "address": "Y", "lat": 41.28, "lng": 69.2, "phone": "123"}), 400, "bad phone")
	body := map[string]any{"name": "Чиланзар Маркет", "address": "Чиланзар, 9-й квартал, 12", "phone": "+998 90 123 45 67", "lat": 41.2856, "lng": 69.2034}
	st = a.expect(a.do("POST", "/store/setup/store", owner, body), 200, "store")
	storeID := st.str("store", "id")
	steps := st.Body["steps"].(map[string]any)
	if storeID == "" || steps["store"] != true || steps["hours"] != false || st.Body["required"] != true || st.str("store", "phone") != "+998901234567" {
		t.Fatalf("after store = %v", st.Body)
	}
	body["name"] = "Чиланзар Маркет 1"
	a.expect(a.do("POST", "/store/setup/store", owner, body), 200, "store again")
	if n := len(a.expect(a.do("GET", "/store/stores", owner, nil), 200, "stores").items()); n != 1 {
		t.Fatalf("stores = %d, want 1", n)
	}
	if wh := a.expect(a.do("GET", "/store/warehouses?store_id="+storeID, owner, nil), 200, "wh").items(); len(wh) != 1 {
		t.Fatalf("warehouses = %v", wh)
	}

	// Шаг 2.
	a.expect(a.do("PUT", "/store/setup/hours", owner, map[string]any{"store_id": storeID,
		"working_hours": []map[string]any{{"weekday": 1, "opens": "08:00", "closes": "08:00"}}}), 400, "bad hours")
	hours := []map[string]any{}
	for d := 1; d <= 6; d++ {
		hours = append(hours, map[string]any{"weekday": d, "opens": "08:00", "closes": "22:00"})
	}
	st = a.expect(a.do("PUT", "/store/setup/hours", owner, map[string]any{"store_id": storeID, "working_hours": hours}), 200, "hours")
	steps = st.Body["steps"].(map[string]any)
	if st.Body["required"] != false || steps["hours"] != true || steps["delivery"] != false || steps["done"] != false ||
		len(st.Body["working_hours"].([]any)) != 6 {
		t.Fatalf("after hours = %v", st.Body)
	}

	// Магазин виден покупателям как «не доставляет»; «Хочу доставку» попадает в чек-лист.
	client, _ := a.login("+998900000050", identity.AppClient)
	a.expect(a.do("POST", "/client/stores/"+storeID+"/wish", client, map[string]any{"lat": 41.29, "lng": 69.21}), 200, "wish")
	if w := a.expect(a.do("GET", "/store/setup", owner, nil), 200, "state").Body["wishes"].(float64); w != 1 {
		t.Fatalf("wishes = %v", w)
	}

	// Шаг 3: пока без доставки.
	a.expect(a.do("PUT", "/store/setup/delivery", owner, map[string]any{"store_id": storeID, "mode": "maybe"}), 400, "bad mode")
	st = a.expect(a.do("PUT", "/store/setup/delivery", owner, map[string]any{"store_id": storeID, "mode": "none"}), 200, "none")
	if st.Body["steps"].(map[string]any)["done"] != true || st.Body["delivery"].(map[string]any)["declined"] != true {
		t.Fatalf("none = %v", st.Body)
	}
	// Доставляем сами; зоны из раздела «Доставка» сохраняются.
	a.expect(a.do("PUT", "/store/stores/"+storeID+"/delivery", owner, map[string]any{
		"rules": []map[string]any{{"type": "distance", "params": map[string]any{"base": 5000, "per_km": 1000}, "sort": 0}}}), 200, "custom rules")
	a.expect(a.do("PUT", "/store/setup/delivery", owner, map[string]any{"store_id": storeID, "mode": "deliver", "delivery_radius_m": 50, "fee": 1}), 400, "small radius")
	st = a.expect(a.do("PUT", "/store/setup/delivery", owner, map[string]any{"store_id": storeID, "mode": "deliver",
		"delivery_radius_m": 3000, "fee": 10000, "free_from": 150000, "min_order_amount": 50000, "eta_min": 25, "eta_max": 35}), 200, "deliver")
	d := st.Body["delivery"].(map[string]any)
	if d["accepts_online"] != true || d["delivery_radius_m"].(float64) != 3000 || d["fee"] != "10000" || d["free_from"] != "150000" ||
		d["eta_min"].(float64) != 25 || d["min_order_amount"] != "50000.00" {
		t.Fatalf("deliver = %v", d)
	}
	rules := a.expect(a.do("GET", "/store/stores/"+storeID+"/delivery", owner, nil), 200, "settings").Body["rules"].([]any)
	if len(rules) != 3 || rules[0].(map[string]any)["type"] != "distance" {
		t.Fatalf("rules = %v", rules)
	}

	// Второй магазин без точки — мастер уже не обязателен, но шаги видны.
	s2 := a.expect(a.do("POST", "/store/stores", owner, map[string]any{"name": "Магазин 2"}), 201, "store 2").str("id")
	st = a.expect(a.do("GET", "/store/setup?store_id="+s2, owner, nil), 200, "store 2 state")
	if st.Body["required"] != false || st.Body["steps"].(map[string]any)["store"] != false || st.str("store", "id") != s2 {
		t.Fatalf("store 2 = %v", st.Body)
	}
	if st = a.expect(a.do("GET", "/store/setup", owner, nil), 200, "default"); st.str("store", "id") != storeID {
		t.Fatalf("default store = %v", st.Body)
	}
	a.expect(a.do("GET", "/store/setup?store_id=00000000-0000-0000-0000-000000000000", owner, nil), 404, "foreign store")
}
