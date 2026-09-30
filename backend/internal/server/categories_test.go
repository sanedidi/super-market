package server_test

import (
	"context"
	"net/http/httptest"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// TestStoreCategoryTree — каталог магазина отдаёт разделы (родителей) вместе
// с категориями, где есть товары, и картинки категорий.
func TestStoreCategoryTree(t *testing.T) {
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
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")

	const img = "https://api.super-market.uz/api/v1/media/2026/09/0123456789abcdef0123456789abcdef.png"
	root := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Напитки", "image_url": img}), 201, "root").str("id")
	child := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Газировка", "parent_id": root}), 201, "child").str("id")
	a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Пустая", "parent_id": root}), 201, "empty")
	a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "x", "image_url": "ftp://x"}), 400, "bad image")
	var pcs string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		if u["short_name"] == "шт" {
			pcs = u["id"].(string)
		}
	}
	cola := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
		"name": "Cola", "category_id": child, "unit_id": pcs, "base_price": 12000,
	}), 201, "product").str("id")
	a.expect(a.do("PATCH", "/store/stores/"+store, tok, map[string]any{"lat": 41.3, "lng": 69.24}), 200, "store")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
	doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{"type": "posting", "warehouse_id": wh,
		"items": []map[string]any{{"product_id": cola, "qty": 5, "price": 9000}}}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post")
	a.expect(a.do("PUT", "/store/stores/"+store+"/delivery", tok, map[string]any{"accepts_online": true, "delivery_radius_m": 5000}), 200, "online")

	cats := a.expect(a.do("GET", "/client/stores/"+store+"/categories", "", nil), 200, "categories").items()
	got := map[string]map[string]any{}
	for _, c := range cats {
		got[c["name"].(string)] = c
	}
	if len(cats) != 2 || got["Напитки"] == nil || got["Газировка"] == nil {
		t.Fatalf("categories = %v", cats)
	}
	if got["Напитки"]["image_url"] != img || got["Напитки"]["products_count"].(float64) != 0 || got["Напитки"]["parent_id"] != nil {
		t.Fatalf("root = %v", got["Напитки"])
	}
	if got["Газировка"]["parent_id"] != root || got["Газировка"]["products_count"].(float64) != 1 || got["Газировка"]["image_url"] != "" {
		t.Fatalf("child = %v", got["Газировка"])
	}
}
