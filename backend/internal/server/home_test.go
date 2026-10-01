package server_test

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/orders"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// TestStoreHome — главная из блоков: шаблон платформы с данными полок и
// баннеров, пустые блоки скрыты; витрина сети заменяет шаблон, выключенные
// и просроченные блоки не показываются, подборка «вручную» в своём порядке.
func TestStoreHome(t *testing.T) {
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
	a := api{t: t, srv: srv}

	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, sugar := catalogBasics(t, a, adminTok)
	openStore := func(phone string) (tok, store string) {
		tok, store = setupNetwork(t, a, adminTok, phone)
		a.expect(a.do("PATCH", "/store/stores/"+store, tok, map[string]any{"lat": 41.2995, "lng": 69.2401}), 200, "store")
		wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
		doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{"type": "posting", "warehouse_id": wh,
			"items": []map[string]any{{"product_id": cola, "qty": 20, "price": 10000}, {"product_id": sugar, "qty": 10, "price": 8000}}}), 201, "posting")
		a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post")
		a.expect(a.do("PUT", "/store/stores/"+store+"/delivery", tok, map[string]any{
			"accepts_online": true, "delivery_radius_m": 5000,
			"rules": []map[string]any{{"type": "fixed", "params": map[string]any{"price": 9000}}},
		}), 200, "delivery")
		return tok, store
	}
	types := func(r resp) []string {
		out := []string{}
		for _, b := range r.Body["blocks"].([]any) {
			out = append(out, b.(map[string]any)["type"].(string))
		}
		return out
	}
	block := func(r resp, i int) map[string]any { return r.Body["blocks"].([]any)[i].(map[string]any) }

	// Шаблон платформы: скидок и баннеров ещё нет — их блоки скрыты;
	// «Хиты» без продаж показывают популярные товары.
	tok, store := openStore("+998900000002")
	now := time.Now()
	a.expect(a.do("POST", "/store/promotions", tok, map[string]any{
		"name": "Скидки", "starts_at": now.Add(-time.Minute), "ends_at": now.Add(24 * time.Hour),
		"items": []map[string]any{{"product_id": cola, "price": 12000}},
	}), 201, "promotion")
	a.expect(a.do("POST", "/admin/banners", adminTok, map[string]any{"title": "Осень", "image_url": "https://cdn.example.com/b.jpg"}), 201, "banner")
	h := a.expect(a.do("GET", "/client/stores/"+store+"/home", "", nil), 200, "home")
	got := types(h)
	want := []string{"category_icons", "promo", "banners", "shelf", "shelf", "catalog_sections"}
	if len(got) != len(want) {
		t.Fatalf("blocks = %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("blocks = %v", got)
		}
	}
	if hits := block(h, 3); hits["title"] != "Хиты недели" || len(hits["products"].([]any)) != 2 {
		t.Fatalf("hits = %v", hits)
	}
	if deals := block(h, 4); len(deals["products"].([]any)) != 1 || deals["products"].([]any)[0].(map[string]any)["id"] != cola {
		t.Fatalf("deals = %v", deals)
	}
	if b := block(h, 2); b["banners"].([]any)[0].(map[string]any)["title"] != "Осень" {
		t.Fatalf("banners = %v", b)
	}
	a.expect(a.do("GET", "/client/stores/00000000-0000-0000-0000-000000000000/home", "", nil), 404, "unknown store")

	// Витрина сети заменяет шаблон.
	_, store2 := openStore("+998900000003")
	var network string
	if err := pool.QueryRow(ctx, `SELECT network_id::text FROM stores WHERE id = $1`, store2).Scan(&network); err != nil {
		t.Fatal(err)
	}
	past := now.Add(-time.Hour)
	layout, _ := json.Marshal([]orders.HomeBlock{
		{ID: "b0000000-0000-4000-8000-000000000001", Type: "shelf", Title: "Подборка", Source: "manual", ProductIDs: []string{sugar, cola}, Limit: 5, View: "row"},
		{ID: "b0000000-0000-4000-8000-000000000002", Type: "promo", Kind: "custom", Title: "Выключено", Color: "red", Disabled: true},
		{ID: "b0000000-0000-4000-8000-000000000003", Type: "promo", Kind: "custom", Title: "Прошло", Color: "red", EndsAt: &past},
		{ID: "b0000000-0000-4000-8000-000000000004", Type: "shelf", Title: "Новинки", Source: "category", CategoryID: "00000000-0000-4000-8000-000000000009", Limit: 5, View: "grid2"},
	})
	if _, err := pool.Exec(ctx, `INSERT INTO home_layouts (scope, network_id, blocks, version) VALUES ('network', $1, $2, 3)`, network, layout); err != nil {
		t.Fatal(err)
	}
	h2 := a.expect(a.do("GET", "/client/stores/"+store2+"/home", "", nil), 200, "network home")
	if h2.Body["version"].(float64) != 3 || len(types(h2)) != 1 {
		t.Fatalf("network home = %v", h2.Body)
	}
	ps := block(h2, 0)["products"].([]any)
	if len(ps) != 2 || ps[0].(map[string]any)["id"] != sugar || ps[1].(map[string]any)["id"] != cola {
		t.Fatalf("manual order = %v", ps)
	}
}

func TestValidateHomeBlocks(t *testing.T) {
	ok := []orders.HomeBlock{
		{ID: "c0000000-0000-4000-8000-000000000001", Type: "shelf", Title: "Хиты", Source: "hits", Limit: 6, View: "grid2"},
		{ID: "c0000000-0000-4000-8000-000000000002", Type: "banners", Size: "big"},
		{ID: "c0000000-0000-4000-8000-000000000003", Type: "promo", Kind: "custom", Title: "−15%", Color: "yellow", Link: &orders.BlockLink{Type: "url", URL: "https://super-market.uz"}},
		{ID: "c0000000-0000-4000-8000-000000000004", Type: "category_icons", Mode: "auto", Shape: "circle"},
		{ID: "c0000000-0000-4000-8000-000000000005", Type: "catalog_sections", Mode: "all", View: "list"},
	}
	if err := orders.ValidateBlocks(ok); err != nil {
		t.Fatal(err)
	}
	bad := map[string]orders.HomeBlock{
		"type":    {ID: "c0000000-0000-4000-8000-000000000009", Type: "stories"},
		"view":    {ID: "c0000000-0000-4000-8000-000000000009", Type: "shelf", Title: "X", Source: "hits", Limit: 6, View: "grid4"},
		"limit":   {ID: "c0000000-0000-4000-8000-000000000009", Type: "shelf", Title: "X", Source: "hits", Limit: 50, View: "row"},
		"manual":  {ID: "c0000000-0000-4000-8000-000000000009", Type: "shelf", Title: "X", Source: "manual", Limit: 6, View: "row"},
		"color":   {ID: "c0000000-0000-4000-8000-000000000009", Type: "promo", Kind: "custom", Title: "X", Color: "pink"},
		"link":    {ID: "c0000000-0000-4000-8000-000000000009", Type: "promo", Kind: "custom", Title: "X", Color: "red", Link: &orders.BlockLink{Type: "url", URL: "http://x"}},
		"icons":   {ID: "c0000000-0000-4000-8000-000000000009", Type: "category_icons", Mode: "manual", Shape: "circle"},
		"badid":   {ID: "1", Type: "banners", Size: "big"},
		"size":    {ID: "c0000000-0000-4000-8000-000000000009", Type: "banners", Size: "medium"},
		"catalog": {ID: "c0000000-0000-4000-8000-000000000009", Type: "catalog_sections", Mode: "selected", View: "list"},
	}
	for name, b := range bad {
		if orders.ValidateBlocks([]orders.HomeBlock{b}) == nil {
			t.Errorf("%s: want error", name)
		}
	}
	dup := []orders.HomeBlock{ok[1], ok[1]}
	if orders.ValidateBlocks(dup) == nil {
		t.Error("duplicate id: want error")
	}
}
