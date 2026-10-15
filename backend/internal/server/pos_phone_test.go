package server_test

import (
	"context"
	"strings"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// TestPOSPhone — касса в телефоне («SM Магазин» → «Продать»): токен кассы для
// сотрудника, продажа только от его имени, смена и продажа через API кассы,
// чек без фискального признака, в лимит касс тарифа не входит.
func TestPOSPhone(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, _ := catalogBasics(t, a, adminTok)
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
	doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "posting", "warehouse_id": wh, "items": []map[string]any{{"product_id": cola, "qty": 2, "price": 10000}},
	}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post posting")

	a.expect(a.do("POST", "/store/pos/phone", tok, map[string]any{"store_id": "x"}), 400, "bad store")
	ph := a.expect(a.do("POST", "/store/pos/phone", tok, map[string]any{"store_id": store, "app_version": "sm_store 0.9.0"}), 200, "phone kassa")
	dt, owner := ph.str("token"), ph.str("employee_id")
	if !strings.HasPrefix(dt, "pd_") || owner == "" || ph.str("device_name") != "Телефон · Владелец" || ph.str("store_id") != store {
		t.Fatalf("phone kassa = %v", ph.Body)
	}

	// Каталог и смена — без ПИНа: касса-телефон сама знает своего сотрудника.
	cat := a.expect(posDo(a, "GET", "/pos/catalog", dt, "", nil), 200, "catalog")
	if cat.Body["settings"].(map[string]any)["device_name"] != "Телефон · Владелец" {
		t.Fatalf("settings = %v", cat.Body["settings"])
	}
	var cash string
	for _, x := range cat.Body["payment_methods"].([]any) {
		if m := x.(map[string]any); m["kind"] == "cash" {
			cash = m["id"].(string)
		}
	}
	a.expect(posDo(a, "GET", "/pos/shifts/current", dt, "", nil), 200, "no shift yet")
	sh := a.expect(posDo(a, "POST", "/pos/shifts", dt, "", map[string]any{"client_uid": "phone-shift-1"}), 201, "auto open shift")
	if sh.str("opened_by") != owner || sh.str("opening_cash") != "0.00" {
		t.Fatalf("shift = %v", sh.Body)
	}

	// Чужой сотрудник в заголовке — отказ, даже владелец сети не подменяет кассира.
	role := a.expect(a.do("POST", "/store/roles", tok, map[string]any{"name": "Кладовщик", "permissions": []string{identity.PermOrdersManage}}), 201, "role").str("id")
	staff := a.expect(a.do("POST", "/store/employees", tok, map[string]any{
		"phone": "+998900000004", "full_name": "Дильноза", "role_id": role, "store_ids": []string{store},
	}), 201, "staff").str("id")
	a.expect(posDo(a, "GET", "/pos/catalog", dt, staff, nil), 401, "other cashier on phone kassa")

	// Продажа: больше, чем на складе — проходит (как на кассе), чек ждёт фискализации.
	sale := a.expect(posDo(a, "POST", "/pos/sales", dt, "", map[string]any{
		"client_uid": "phone-sale-0001", "shift_id": sh.str("id"),
		"items":    []map[string]any{{"product_id": cola, "qty": 3}},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 45000}},
	}), 201, "phone sale")
	if sale.str("total") != "45000.00" || sale.str("fiscal_status") != "pending" || sale.str("cashier") != "Владелец" {
		t.Fatalf("phone sale = %v", sale.Body)
	}
	rep := a.expect(posDo(a, "GET", "/pos/shifts/"+sh.str("id"), dt, "", nil), 200, "x report")
	if r := rep.Body["report"].(map[string]any); r["expected_cash"] != "45000.00" || r["sales_count"].(float64) != 1 {
		t.Fatalf("report = %v", r)
	}

	// Повторный вход (другой телефон того же сотрудника): та же касса, новый токен, старый не действует.
	ph2 := a.expect(a.do("POST", "/store/pos/phone", tok, map[string]any{"store_id": store}), 200, "phone again")
	if ph2.str("device_id") != ph.str("device_id") || ph2.str("token") == dt {
		t.Fatalf("phone again = %v", ph2.Body)
	}
	a.expect(posDo(a, "GET", "/pos/catalog", dt, "", nil), 401, "old phone token")
	if cur := a.expect(posDo(a, "GET", "/pos/shifts/current", ph2.str("token"), "", nil), 200, "shift kept"); cur.Body["shift"].(map[string]any)["id"] != sh.str("id") {
		t.Fatalf("current shift = %v", cur.Body)
	}

	// Без права «Продажа» — нельзя; с правом — своя касса-телефон.
	staffTok, _ := a.login("+998900000004", identity.AppStore)
	a.expect(a.do("POST", "/store/pos/phone", staffTok, map[string]any{"store_id": store}), 403, "no sales.pos")
	a.expect(a.do("PATCH", "/store/roles/"+role, tok, map[string]any{"permissions": []string{identity.PermSalesPOS}}), 200, "grant sales.pos")
	sp := a.expect(a.do("POST", "/store/pos/phone", staffTok, map[string]any{"store_id": store}), 200, "staff phone")
	if sp.str("device_id") == ph.str("device_id") || sp.str("device_name") != "Телефон · Дильноза" || sp.str("employee_id") != staff {
		t.Fatalf("staff phone = %v", sp.Body)
	}
	devs := a.expect(a.do("GET", "/store/pos/devices", tok, nil), 200, "devices").items()
	if len(devs) != 2 || devs[0]["phone"] != true || devs[0]["status"] != "active" {
		t.Fatalf("devices = %v", devs)
	}

	// Телефоны в лимит касс не входят: на «Бесплатном» одна касса POS всё равно доступна.
	if _, err := pool.Exec(context.Background(), `UPDATE networks SET plan_key = 'free', plan_trial_until = current_date - 1`); err != nil {
		t.Fatal(err)
	}
	a.expect(a.do("POST", "/store/pos/devices", tok, map[string]any{"store_id": store, "name": "Касса 1"}), 201, "pos device despite phones")
	a.expect(a.do("POST", "/store/pos/devices", tok, map[string]any{"store_id": store, "name": "Касса 2"}), 409, "registers limit")
	a.expect(a.do("POST", "/store/pos/phone", tok, map[string]any{"store_id": store}), 200, "phone still free")
}
