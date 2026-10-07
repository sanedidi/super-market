package server_test

import (
	"context"
	"fmt"
	"net/http/httptest"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// TestDeliveryWishes — покупатель видит все магазины до 10 км: те, что
// привезут, и те, что не доставляют (их товары можно смотреть, но не
// заказать); «Хочу доставку» — голос, который видит магазин и супер-админ;
// поиск товара по всем магазинам рядом.
func TestDeliveryWishes(t *testing.T) {
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
	cola, sugar := catalogBasics(t, a, adminTok)
	const lat, lng = 41.2995, 69.2401

	// Магазин: точка, остатки, доставка.
	store := func(phone string, dLat float64, delivery map[string]any, stock map[string]int) (tok, id string) {
		tok, id = setupNetwork(t, a, adminTok, phone)
		a.expect(a.do("PATCH", "/store/stores/"+id, tok, map[string]any{"lat": lat + dLat, "lng": lng}), 200, "store point")
		wh := a.expect(a.do("GET", "/store/warehouses?store_id="+id, tok, nil), 200, "wh").items()[0]["id"].(string)
		items := []map[string]any{}
		for p, q := range stock {
			items = append(items, map[string]any{"product_id": p, "qty": q, "price": 9000})
		}
		doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{"type": "posting", "warehouse_id": wh, "items": items}), 201, "posting")
		a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post")
		if delivery != nil {
			a.expect(a.do("PUT", "/store/stores/"+id+"/delivery", tok, delivery), 200, "delivery")
		}
		return tok, id
	}
	_, near := store("+998900000002", 0.002, map[string]any{"accepts_online": true, "delivery_radius_m": 3000, "eta_min": 25, "eta_max": 35}, map[string]int{cola: 5, sugar: 5})
	offTok, off := store("+998900000003", 0.01, nil, map[string]int{cola: 3})
	zoneTok, zone := store("+998900000004", 0.02, map[string]any{"accepts_online": true, "delivery_radius_m": 500}, map[string]int{cola: 7})
	_, far := store("+998900000005", 0.2, nil, map[string]int{cola: 1})

	home := a.expect(a.do("GET", fmt.Sprintf("/client/home?lat=%v&lng=%v", lat, lng), "", nil), 200, "home")
	stores := home.Body["stores"].([]any)
	others := home.Body["others"].([]any)
	if len(stores) != 1 || stores[0].(map[string]any)["id"] != near {
		t.Fatalf("stores = %v", stores)
	}
	if len(others) != 2 {
		t.Fatalf("others = %v", others)
	}
	o0, o1 := others[0].(map[string]any), others[1].(map[string]any)
	if o0["id"] != off || o0["reason"] != "not_online" || o0["is_open"] != true || o0["distance_m"].(float64) < 1000 ||
		o1["id"] != zone || o1["reason"] != "out_of_zone" {
		t.Fatalf("others = %v", others)
	}
	for _, o := range others {
		if o.(map[string]any)["id"] == far {
			t.Fatal("far store shown")
		}
	}

	// Товары магазина без доставки видны, заказать нельзя.
	if items := a.expect(a.do("GET", "/client/stores/"+off+"/products", "", nil), 200, "browse").items(); len(items) != 1 || items[0]["id"] != cola {
		t.Fatalf("browse = %v", items)
	}
	a.expect(a.do("GET", "/client/stores/"+off+"/products/"+cola, "", nil), 200, "product card")
	client, _ := a.login("+998900000050", identity.AppClient)
	addr := a.expect(a.do("POST", "/client/addresses", client, map[string]any{"address": "Дом", "lat": lat, "lng": lng}), 201, "address").str("id")
	a.expect(a.do("POST", "/client/checkout/preview", client, map[string]any{"store_id": off, "address_id": addr, "payment_provider": "payme",
		"items": []map[string]any{{"product_id": cola, "qty": 1}}}), 404, "order from store without delivery")

	// Поиск по всем магазинам: сначала тот, что привезёт.
	res := a.expect(a.do("GET", fmt.Sprintf("/client/search?lat=%v&lng=%v&q=coca", lat, lng), "", nil), 200, "search")
	items := res.Body["items"].([]any)
	if len(items) != 1 || res.Body["stores"].(float64) != 3 {
		t.Fatalf("search = %v", res.Body)
	}
	offers := items[0].(map[string]any)["offers"].([]any)
	if len(offers) != 3 || offers[0].(map[string]any)["store_id"] != near || offers[0].(map[string]any)["delivers"] != true ||
		offers[0].(map[string]any)["eta_min"].(float64) != 25 || offers[1].(map[string]any)["delivers"] != false ||
		offers[0].(map[string]any)["price"] != "15000.00" || items[0].(map[string]any)["product"].(map[string]any)["name"] != "Coca-Cola 1,5 л" {
		t.Fatalf("offers = %v", offers)
	}
	only := a.expect(a.do("GET", fmt.Sprintf("/client/search?lat=%v&lng=%v&q=coca&only_delivering=1", lat, lng), "", nil), 200, "only delivering")
	if o := only.Body["items"].([]any)[0].(map[string]any)["offers"].([]any); len(o) != 1 {
		t.Fatalf("only delivering = %v", o)
	}
	if short := a.expect(a.do("GET", fmt.Sprintf("/client/search?lat=%v&lng=%v&q=c", lat, lng), "", nil), 200, "short").Body["items"].([]any); len(short) != 0 {
		t.Fatalf("short query = %v", short)
	}
	if s := a.expect(a.do("GET", fmt.Sprintf("/client/search?lat=%v&lng=%v&q=сахар", lat, lng), "", nil), 200, "sugar").Body["items"].([]any); len(s) != 1 {
		t.Fatalf("sugar = %v", s)
	}

	// «Хочу доставку».
	a.expect(a.do("POST", "/client/stores/"+off+"/wish", "", map[string]any{"lat": lat, "lng": lng}), 401, "anonymous wish")
	a.expect(a.do("POST", "/client/stores/"+off+"/wish", client, map[string]any{}), 400, "no point")
	if w := a.expect(a.do("POST", "/client/stores/"+off+"/wish", client, map[string]any{"lat": lat, "lng": lng}), 200, "wish"); w.Body["wished"] != true {
		t.Fatalf("wish = %v", w.Body)
	}
	a.expect(a.do("POST", "/client/stores/"+off+"/wish", client, map[string]any{"lat": lat, "lng": lng}), 200, "wish again")
	a.expect(a.do("POST", "/client/stores/"+zone+"/wish", client, map[string]any{"lat": lat, "lng": lng}), 200, "wish zone")
	if mine := a.expect(a.do("GET", "/client/wishes", client, nil), 200, "my wishes").Body["items"].([]any); len(mine) != 2 {
		t.Fatalf("my wishes = %v", mine)
	}
	client2, _ := a.login("+998900000051", identity.AppClient)
	a.expect(a.do("POST", "/client/stores/"+off+"/wish", client2, map[string]any{"lat": lat + 0.001, "lng": lng}), 200, "wish 2")

	st := a.expect(a.do("GET", "/store/stores/"+off+"/wishes", offTok, nil), 200, "store wishes")
	if st.Body["total"].(float64) != 2 || st.Body["week"].(float64) != 2 || st.Body["accepts_online"] != false || st.Body["nearest_m"].(float64) < 900 {
		t.Fatalf("store wishes = %v", st.Body)
	}
	zs := a.expect(a.do("GET", "/store/stores/"+zone+"/wishes", zoneTok, nil), 200, "zone wishes")
	if zs.Body["total"].(float64) != 1 || zs.Body["out_of_zone"].(float64) != 1 || zs.Body["accepts_online"] != true {
		t.Fatalf("zone wishes = %v", zs.Body)
	}
	a.expect(a.do("GET", "/store/stores/"+zone+"/wishes", offTok, nil), 404, "foreign store")

	rep := a.expect(a.do("GET", "/admin/delivery-wishes", adminTok, nil), 200, "admin wishes")
	tot := rep.Body["totals"].(map[string]any)
	ritems := rep.Body["items"].([]any)
	if tot["total"].(float64) != 3 || tot["stores"].(float64) != 2 || len(ritems) != 2 ||
		ritems[0].(map[string]any)["store_id"] != off || ritems[0].(map[string]any)["total"].(float64) != 2 ||
		ritems[1].(map[string]any)["out_of_zone"].(float64) != 1 {
		t.Fatalf("admin wishes = %v", rep.Body)
	}

	if w := a.expect(a.do("DELETE", "/client/stores/"+off+"/wish", client, nil), 200, "unwish"); w.Body["wished"] != false {
		t.Fatalf("unwish = %v", w.Body)
	}
	if n := a.expect(a.do("GET", "/store/stores/"+off+"/wishes", offTok, nil), 200, "after unwish").Body["total"].(float64); n != 1 {
		t.Fatalf("after unwish = %v", n)
	}
}
