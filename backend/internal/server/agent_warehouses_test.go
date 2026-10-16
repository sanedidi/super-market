package server_test

import (
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// TestAgentWarehouses — несколько складов агента (Figma «Правки 16 окт» → А2–А4):
// магазины видны в 15 км от любого склада, расход по умолчанию — с ближайшего
// склада, где есть товар, основной склад переносит точку агента.
func TestAgentWarehouses(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, _ := catalogBasics(t, a, adminTok)

	a.expect(a.do("POST", "/admin/networks", adminTok, map[string]string{
		"name": "Baraka", "kind": "chain", "owner_phone": "+998900000002", "owner_name": "Владелец",
	}), 201, "store network")
	storeTok, _ := a.login("+998900000002", identity.AppStore)
	// Ташкент (рядом с точкой агента) и Чирчик (~32 км, рядом со вторым складом).
	near := a.expect(a.do("POST", "/store/stores", storeTok, map[string]any{"name": "Baraka Чиланзар", "lat": 41.30, "lng": 69.24}), 201, "near").str("id")
	far := a.expect(a.do("POST", "/store/stores", storeTok, map[string]any{"name": "Baraka Чирчик", "lat": 41.47, "lng": 69.58}), 201, "far").str("id")
	distTok, _, mainWh := setupDistributor(t, a, adminTok, "+998900000003", 41.305, 69.245)

	visible := func(what string) map[string]bool {
		out := map[string]bool{}
		for _, s := range a.expect(a.do("GET", "/store/supply/stores", distTok, nil), 200, what).items() {
			out[s["id"].(string)] = true
		}
		return out
	}
	if v := visible("stores before"); !v[near] || v[far] {
		t.Fatalf("до второго склада: %v", v)
	}

	ws := a.expect(a.do("GET", "/store/supply/warehouses", distTok, nil), 200, "warehouses").items()
	if len(ws) != 1 || ws[0]["id"] != mainWh || ws[0]["is_default"] != true || ws[0]["lat"] == nil {
		t.Fatalf("склады = %v", ws)
	}
	a.expect(a.do("POST", "/store/supply/warehouses", distTok, map[string]any{"name": "Чирчик", "address": "Чирчик, ул. Амира Темура, 1"}), 400, "no point")
	second := a.expect(a.do("POST", "/store/supply/warehouses", distTok, map[string]any{
		"name": "Чирчик", "address": "Чирчик, ул. Амира Темура, 1", "lat": 41.468, "lng": 69.582,
	}), 201, "second").str("id")
	a.expect(a.do("POST", "/store/supply/warehouses", distTok, map[string]any{
		"name": "Чирчик", "address": "x", "lat": 41.4, "lng": 69.5,
	}), 409, "same name")
	if v := visible("stores after"); !v[near] || !v[far] {
		t.Fatalf("после второго склада: %v", v)
	}
	if d := a.expect(a.do("GET", "/store/supply/stores/"+far, distTok, nil), 200, "far detail"); d.Body["distance_km"].(float64) > 1 {
		t.Fatalf("расстояние до ближайшего склада = %v", d.Body["distance_km"])
	}

	// Товар есть только на основном складе: для дальнего магазина первым
	// идёт основной (весь товар есть), хоть он и дальше.
	maker := a.expect(a.do("POST", "/store/finance/counterparties", distTok, map[string]any{"name": "Coca-Cola Bottlers"}), 201, "maker").str("id")
	inc := a.expect(a.do("POST", "/store/inventory/documents", distTok, map[string]any{
		"type": "income", "warehouse_id": mainWh, "counterparty_id": maker,
		"items": []map[string]any{{"product_id": cola, "qty": 100, "price": 9800}},
	}), 201, "income")
	a.expect(a.do("POST", "/store/inventory/documents/"+inc.str("id")+"/post", distTok, nil), 200, "post income")
	pick := a.expect(a.do("GET", "/store/supply/stores/"+far+"/warehouses?products="+cola, distTok, nil), 200, "pick").items()
	if len(pick) != 2 || pick[0]["id"] != mainWh || pick[0]["missing"].(float64) != 0 || pick[1]["missing"].(float64) != 1 || pick[1]["distance_km"].(float64) > 1 {
		t.Fatalf("выбор склада = %v", pick)
	}
	// Без товаров — просто ближайший.
	if pick := a.expect(a.do("GET", "/store/supply/stores/"+far+"/warehouses", distTok, nil), 200, "pick nearest").items(); pick[0]["id"] != second {
		t.Fatalf("ближайший = %v", pick)
	}
	ws = a.expect(a.do("GET", "/store/supply/warehouses", distTok, nil), 200, "warehouses 2").items()
	if len(ws) != 2 || ws[0]["products"].(float64) != 1 || ws[0]["stock_cost"] != "980000.00" || ws[1]["stores_in_zone"].(float64) != 0 {
		t.Fatalf("склады 2 = %v", ws)
	}

	// Основной — второй склад; старый основной нельзя «не основным», основной нельзя отключить.
	a.expect(a.do("PATCH", "/store/supply/warehouses/"+mainWh, distTok, map[string]any{"is_default": false}), 409, "unset default")
	a.expect(a.do("PATCH", "/store/supply/warehouses/"+second, distTok, map[string]any{"is_default": true, "is_active": false}), 409, "default inactive")
	up := a.expect(a.do("PATCH", "/store/supply/warehouses/"+second, distTok, map[string]any{"is_default": true, "name": "Чирчик — основной"}), 200, "make default")
	if up.Body["is_default"] != true || up.str("name") != "Чирчик — основной" {
		t.Fatalf("основной = %v", up.Body)
	}
	a.expect(a.do("PATCH", "/store/supply/warehouses/"+mainWh, distTok, map[string]any{"is_active": false}), 200, "deactivate old")
	// Старый склад отключён: ближний магазин теперь за 15 км от всех складов.
	if v := visible("stores after move"); v[near] || !v[far] {
		t.Fatalf("после переноса: %v", v)
	}
	a.expect(a.do("GET", "/store/supply/warehouses", storeTok, nil), 403, "store side")
}
