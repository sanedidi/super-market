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

// TestStorefront — витрина приложения: акции магазина, скидки в каталоге и
// корзине, сортировки и фильтры, карточка товара с характеристиками,
// «С этим покупают», главная с баннерами и скидками, избранное, логотип и
// время доставки магазина.
func TestStorefront(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	cfg.PaymeMerchantID, cfg.PaymeKey = "merchant-1", paymeKey
	app, err := server.Build(ctx, cfg, pool, &fakeTelegram{}, quietLog())
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app.Handler)
	t.Cleanup(srv.Close)
	a := api{t: t, srv: srv}

	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, sugar := catalogBasics(t, a, adminTok)
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")

	const lat, lng = 41.2995, 69.2401
	a.expect(a.do("PATCH", "/store/stores/"+store, tok, map[string]any{
		"lat": lat, "lng": lng, "logo_url": "https://cdn.example.com/logo.png",
	}), 200, "store")
	a.expect(a.do("PATCH", "/store/stores/"+store, tok, map[string]any{"logo_url": "ftp://x"}), 400, "bad logo")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
	doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{"type": "posting", "warehouse_id": wh,
		"items": []map[string]any{{"product_id": cola, "qty": 20, "price": 10000}, {"product_id": sugar, "qty": 10, "price": 8000}}}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post")
	a.expect(a.do("PUT", "/store/stores/"+store+"/delivery", tok, map[string]any{
		"accepts_online": true, "delivery_radius_m": 5000, "eta_min": 25, "eta_max": 35,
		"rules": []map[string]any{{"type": "fixed", "params": map[string]any{"price": 9000}}},
	}), 200, "delivery")
	a.expect(a.do("PUT", "/store/stores/"+store+"/delivery", tok, map[string]any{"eta_min": 50, "eta_max": 40}), 400, "eta order")

	near := a.expect(a.do("GET", fmt.Sprintf("/client/stores/nearby?lat=%v&lng=%v", lat, lng), "", nil), 200, "nearby").items()
	if len(near) != 1 || near[0]["logo_url"] != "https://cdn.example.com/logo.png" || near[0]["eta_min"].(float64) != 25 {
		t.Fatalf("nearby = %v", near)
	}

	// Характеристики товара ведёт супер-админ.
	a.expect(a.do("PATCH", "/admin/products/"+cola, adminTok, map[string]any{
		"attributes": map[string]any{"country": "Узбекистан", "nutrition": map[string]any{"kcal": 42, "carbs": 10.6}},
	}), 200, "attributes")
	a.expect(a.do("PATCH", "/admin/products/"+cola, adminTok, map[string]any{"attributes": map[string]any{"color": "red"}}), 400, "unknown attribute")
	a.expect(a.do("PATCH", "/admin/products/"+cola, adminTok, map[string]any{"attributes": map[string]any{"nutrition": map[string]any{"kcal": "много"}}}), 400, "bad nutrition")

	// Акция: кола 15 000 → 12 000 (−20%), сахар 12 000 → 13 000 не повышает цену.
	now := time.Now()
	a.expect(a.do("POST", "/store/promotions", tok, map[string]any{
		"name": "Плохая", "starts_at": now, "ends_at": now.Add(-time.Hour),
	}), 400, "ends before start")
	promo := a.expect(a.do("POST", "/store/promotions", tok, map[string]any{
		"name": "Скидки недели", "starts_at": now.Add(-time.Minute), "ends_at": now.Add(7 * 24 * time.Hour),
		"items": []map[string]any{{"product_id": cola, "price": 12000}, {"product_id": sugar, "price": 13000}},
	}), 201, "promotion")
	if promo.str("status") != "running" || len(promo.Body["items"].([]any)) != 2 {
		t.Fatalf("promotion = %v", promo.Body)
	}
	if n := len(a.expect(a.do("GET", "/store/promotions?status=running", tok, nil), 200, "promotions").items()); n != 1 {
		t.Fatalf("running promotions = %d", n)
	}

	byID := func(items []map[string]any) map[string]map[string]any {
		m := map[string]map[string]any{}
		for _, it := range items {
			m[it["id"].(string)] = it
		}
		return m
	}
	cat := byID(a.expect(a.do("GET", "/client/stores/"+store+"/products", "", nil), 200, "catalog").items())
	if c := cat[cola]; c["price"] != "12000.00" || c["old_price"] != "15000.00" || c["discount_percent"].(float64) != 20 || c["is_new"] != true {
		t.Fatalf("cola in catalog = %v", c)
	}
	if s := cat[sugar]; s["price"] != "12000.00" || s["old_price"] != nil {
		t.Fatalf("sugar in catalog = %v", s)
	}
	if d := a.expect(a.do("GET", "/client/stores/"+store+"/products?discount=1", "", nil), 200, "discounts").items(); len(d) != 1 || d[0]["id"] != cola {
		t.Fatalf("discount filter = %v", d)
	}
	if asc := a.expect(a.do("GET", "/client/stores/"+store+"/products?sort=price_desc&ids="+sugar, "", nil), 200, "ids").items(); len(asc) != 1 {
		t.Fatalf("ids filter = %v", asc)
	}
	a.expect(a.do("GET", "/client/stores/"+store+"/products?sort=random", "", nil), 400, "bad sort")

	// Карточка товара.
	card := a.expect(a.do("GET", "/client/stores/"+store+"/products/"+cola, "", nil), 200, "product")
	if card.str("category_name") != "Продукты" || card.Body["attributes"].(map[string]any)["country"] != "Узбекистан" || card.str("old_price") != "15000.00" {
		t.Fatalf("product card = %v", card.Body)
	}

	// Корзина считает акционную цену и скидку, заказ её сохраняет.
	client, _ := a.login("+998900000050", identity.AppClient)
	addr := a.expect(a.do("POST", "/client/addresses", client, map[string]any{"address": "Рядом", "lat": lat + 0.005, "lng": lng}), 201, "address").str("id")
	cart := map[string]any{"store_id": store, "address_id": addr, "payment_provider": "payme",
		"items": []map[string]any{{"product_id": cola, "qty": 2}, {"product_id": sugar, "qty": 1}}}
	pv := a.expect(a.do("POST", "/client/checkout/preview", client, cart), 200, "preview")
	if pv.str("subtotal") != "36000.00" || pv.str("discount") != "6000.00" || pv.str("total") != "45000.00" {
		t.Fatalf("preview = %v", pv.Body)
	}
	o := a.expect(a.do("POST", "/client/orders", client, cart), 201, "order")
	if o.str("order", "discount") != "6000.00" {
		t.Fatalf("order = %v", o.Body)
	}
	if it := o.Body["order"].(map[string]any)["items"].([]any)[0].(map[string]any); it["old_price"] != "15000.00" || it["price"] != "12000.00" {
		t.Fatalf("order item = %v", it)
	}
	if _, err := pool.Exec(ctx, `UPDATE orders SET status = 'delivered' WHERE id = $1`, o.str("order", "id")); err != nil {
		t.Fatal(err)
	}

	// Популярность и «С этим покупают».
	if err := app.Orders.RefreshPopularity(ctx); err != nil {
		t.Fatal(err)
	}
	if s := sqlStr(t, pool, `SELECT qty::text FROM product_popularity WHERE store_id = $1 AND product_id = $2`, store, cola); s != "2.000" {
		t.Fatalf("popularity = %s", s)
	}
	pop := a.expect(a.do("GET", "/client/stores/"+store+"/products?sort=popular", "", nil), 200, "popular").items()
	if pop[0]["id"] != cola {
		t.Fatalf("popular first = %v", pop[0])
	}
	rel := a.expect(a.do("GET", "/client/stores/"+store+"/products/"+cola+"/related", "", nil), 200, "related").items()
	if len(rel) != 1 || rel[0]["id"] != sugar {
		t.Fatalf("related = %v", rel)
	}

	// Баннер сети и главная.
	netID := sqlStr(t, pool, `SELECT network_id::text FROM stores WHERE id = $1`, store)
	a.expect(a.do("POST", "/admin/banners", adminTok, map[string]any{"title": "Без ссылки", "link_type": "store"}), 400, "banner without link")
	a.expect(a.do("POST", "/admin/banners", adminTok, map[string]any{
		"title": "−20% на колу", "subtitle": "Только неделю", "link_type": "promotion", "link_id": promo.str("id"), "network_id": netID,
	}), 201, "banner")
	a.expect(a.do("POST", "/admin/banners", adminTok, map[string]any{"title": "Чужая сеть", "network_id": "00000000-0000-0000-0000-000000000000"}), 400, "banner unknown network")
	home := a.expect(a.do("GET", fmt.Sprintf("/client/home?lat=%v&lng=%v", lat, lng), "", nil), 200, "home")
	if len(home.Body["banners"].([]any)) != 1 || len(home.Body["stores"].([]any)) != 1 {
		t.Fatalf("home = %v", home.Body)
	}
	deals := home.Body["deals"].(map[string]any)
	if deals["store_id"] != store || len(deals["items"].([]any)) != 1 {
		t.Fatalf("deals = %v", deals)
	}

	// Избранное.
	a.expect(a.do("POST", "/client/favorites", client, map[string]any{"product_id": cola}), 200, "fav add")
	a.expect(a.do("POST", "/client/favorites", client, map[string]any{"product_id": cola}), 200, "fav add twice")
	a.expect(a.do("POST", "/client/favorites", client, map[string]any{"product_id": "00000000-0000-0000-0000-000000000000"}), 400, "fav unknown")
	fav := a.expect(a.do("GET", "/client/favorites", client, nil), 200, "fav list")
	if fmt.Sprint(fav.Body["product_ids"]) != "["+cola+"]" {
		t.Fatalf("favorites = %v", fav.Body)
	}
	a.expect(a.do("DELETE", "/client/favorites/"+cola, client, nil), 200, "fav remove")
	a.expect(a.do("GET", "/client/favorites", "", nil), 401, "fav without login")

	// Выключенная акция перестаёт действовать.
	a.expect(a.do("PATCH", "/store/promotions/"+promo.str("id"), tok, map[string]any{"is_active": false}), 200, "disable promo")
	if c := byID(a.expect(a.do("GET", "/client/stores/"+store+"/products", "", nil), 200, "catalog").items())[cola]; c["price"] != "15000.00" || c["old_price"] != nil {
		t.Fatalf("cola after promo off = %v", c)
	}
}
