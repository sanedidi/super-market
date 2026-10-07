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
	a := api{t: t, srv: srv, pool: pool}

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

// TestHomeEditor — редактор главной: черновик не виден приложению,
// публикация даёт версию и сразу меняет главную, откат кладёт старую версию
// в черновик, сеть начинает с шаблона и может вернуться к нему.
func TestHomeEditor(t *testing.T) {
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
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	a.expect(a.do("PATCH", "/store/stores/"+store, tok, map[string]any{"lat": 41.2995, "lng": 69.2401}), 200, "store")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
	doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{"type": "posting", "warehouse_id": wh,
		"items": []map[string]any{{"product_id": cola, "qty": 20, "price": 10000}, {"product_id": sugar, "qty": 10, "price": 8000}}}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post")
	a.expect(a.do("PUT", "/store/stores/"+store+"/delivery", tok, map[string]any{
		"accepts_online": true, "delivery_radius_m": 5000,
		"rules": []map[string]any{{"type": "fixed", "params": map[string]any{"price": 9000}}},
	}), 200, "delivery")
	var network string
	if err := pool.QueryRow(ctx, `SELECT network_id::text FROM stores WHERE id = $1`, store).Scan(&network); err != nil {
		t.Fatal(err)
	}

	tpl := a.expect(a.do("GET", "/admin/home", adminTok, nil), 200, "template")
	if tpl.Body["version"].(float64) != 1 || len(tpl.Body["blocks"].([]any)) != 6 || tpl.Body["draft"] != nil {
		t.Fatalf("template = %v", tpl.Body)
	}
	a.expect(a.do("GET", "/admin/home", tok, nil), 403, "store token")
	a.expect(a.do("POST", "/admin/home/publish", adminTok, nil), 409, "nothing to publish")

	shelf := map[string]any{"id": "d0000000-0000-4000-8000-000000000001", "type": "shelf", "title": "Подборка", "source": "manual",
		"product_ids": []string{sugar}, "limit": 6, "view": "row"}
	a.expect(a.do("PUT", "/admin/home/draft", adminTok, map[string]any{"blocks": []any{map[string]any{"id": "x", "type": "shelf"}}}), 400, "invalid")
	d := a.expect(a.do("PUT", "/admin/home/draft", adminTok, map[string]any{"blocks": []any{shelf}}), 200, "draft")
	if len(d.Body["draft"].([]any)) != 1 {
		t.Fatalf("draft = %v", d.Body)
	}
	// Предпросмотр — с товарами, приложению черновик не виден.
	pv := a.expect(a.do("POST", "/admin/home/preview", adminTok, map[string]any{"store_id": store, "blocks": []any{shelf}}), 200, "preview")
	if len(pv.Body["blocks"].([]any)[0].(map[string]any)["products"].([]any)) != 1 {
		t.Fatalf("preview = %v", pv.Body)
	}
	if h := a.expect(a.do("GET", "/client/stores/"+store+"/home", "", nil), 200, "home"); h.Body["version"].(float64) != 1 {
		t.Fatalf("draft leaked: %v", h.Body)
	}
	if st := a.expect(a.do("GET", "/admin/home/stores", adminTok, nil), 200, "stores").items(); len(st) != 1 || st[0]["id"] != store {
		t.Fatalf("stores = %v", st)
	}

	p := a.expect(a.do("POST", "/admin/home/publish", adminTok, nil), 200, "publish")
	if p.Body["version"].(float64) != 2 || p.Body["draft"] != nil {
		t.Fatalf("published = %v", p.Body)
	}
	h := a.expect(a.do("GET", "/client/stores/"+store+"/home", "", nil), 200, "home v2")
	if h.Body["version"].(float64) != 2 || len(h.Body["blocks"].([]any)) != 1 {
		t.Fatalf("home v2 = %v", h.Body)
	}
	vs := a.expect(a.do("GET", "/admin/home/versions", adminTok, nil), 200, "versions").items()
	if len(vs) != 2 || vs[0]["version"].(float64) != 2 || vs[1]["blocks"].(float64) != 6 {
		t.Fatalf("versions = %v", vs)
	}
	r := a.expect(a.do("POST", "/admin/home/restore", adminTok, map[string]any{"version": 1}), 200, "restore")
	if len(r.Body["draft"].([]any)) != 6 {
		t.Fatalf("restore = %v", r.Body)
	}
	a.expect(a.do("DELETE", "/admin/home/draft", adminTok, nil), 200, "discard")
	a.expect(a.do("POST", "/admin/home/restore", adminTok, map[string]any{"version": 9}), 404, "no version")

	// Сеть: начинает с шаблона, черновик не меняет главную, публикация — меняет.
	q := "?network_id=" + network
	n := a.expect(a.do("GET", "/admin/home"+q, adminTok, nil), 200, "network")
	if n.Body["inherited"] != true || n.Body["version"].(float64) != 0 || n.Body["network_name"] == "" {
		t.Fatalf("network = %v", n.Body)
	}
	promo := map[string]any{"id": "d0000000-0000-4000-8000-000000000002", "type": "promo", "kind": "custom", "title": "−10%", "color": "green"}
	a.expect(a.do("PUT", "/admin/home/draft"+q, adminTok, map[string]any{"blocks": []any{promo}}), 200, "network draft")
	if h := a.expect(a.do("GET", "/client/stores/"+store+"/home", "", nil), 200, "home"); h.Body["version"].(float64) != 2 {
		t.Fatalf("network draft leaked: %v", h.Body)
	}
	a.expect(a.do("POST", "/admin/home/publish"+q, adminTok, nil), 200, "network publish")
	h = a.expect(a.do("GET", "/client/stores/"+store+"/home", "", nil), 200, "network home")
	if h.Body["version"].(float64) != 1 || h.Body["blocks"].([]any)[0].(map[string]any)["type"] != "promo" {
		t.Fatalf("network home = %v", h.Body)
	}
	a.expect(a.do("DELETE", "/admin/home"+q, adminTok, nil), 200, "reset")
	if h := a.expect(a.do("GET", "/client/stores/"+store+"/home", "", nil), 200, "home"); h.Body["version"].(float64) != 2 {
		t.Fatalf("after reset = %v", h.Body)
	}
	a.expect(a.do("GET", "/admin/home?network_id=00000000-0000-0000-0000-000000000000", adminTok, nil), 404, "unknown network")
}

// TestStoreShowcase — витрина сети в панели магазина: пробный «Бизнес»,
// лимиты тарифа при публикации, закреплённые блоки платформы, свои баннеры
// с модерацией, понижение тарифа скрывает витрину, не удаляя её.
func TestStoreShowcase(t *testing.T) {
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
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	a.expect(a.do("PATCH", "/store/stores/"+store, tok, map[string]any{"lat": 41.2995, "lng": 69.2401}), 200, "store")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
	doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{"type": "posting", "warehouse_id": wh,
		"items": []map[string]any{{"product_id": cola, "qty": 20, "price": 10000}, {"product_id": sugar, "qty": 10, "price": 8000}}}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post")
	a.expect(a.do("PUT", "/store/stores/"+store+"/delivery", tok, map[string]any{
		"accepts_online": true, "delivery_radius_m": 5000,
		"rules": []map[string]any{{"type": "fixed", "params": map[string]any{"price": 9000}}},
	}), 200, "delivery")
	home := func() []map[string]any {
		out := []map[string]any{}
		for _, b := range a.expect(a.do("GET", "/client/stores/"+store+"/home", "", nil), 200, "home").Body["blocks"].([]any) {
			out = append(out, b.(map[string]any))
		}
		return out
	}

	// Супер-админ закрепляет промо-полоску «до бесплатной доставки» и
	// добавляет свою полоску в шаблон.
	tpl := a.expect(a.do("GET", "/admin/home", adminTok, nil), 200, "template").Body["blocks"].([]any)
	pinnedPromo := map[string]any{"id": "e0000000-0000-4000-8000-000000000001", "type": "promo", "kind": "custom", "title": "Super Market", "color": "dark", "pinned": true}
	tplBlocks := append([]any{tpl[0], pinnedPromo}, tpl[1:]...)
	a.expect(a.do("PUT", "/admin/home/draft", adminTok, map[string]any{"blocks": tplBlocks}), 200, "template draft")
	a.expect(a.do("POST", "/admin/home/publish", adminTok, nil), 200, "template publish")

	sc := a.expect(a.do("GET", "/store/home", tok, nil), 200, "showcase")
	plan := sc.Body["plan"].(map[string]any)
	if plan["in_trial"] != true || plan["effective"].(map[string]any)["key"] != "business" || plan["chosen"].(map[string]any)["key"] != "start" {
		t.Fatalf("plan = %v", plan)
	}
	if len(sc.Body["template_ids"].([]any)) != 7 || len(sc.Body["pinned_ids"].([]any)) != 1 || sc.Body["can_buy"] != true {
		t.Fatalf("showcase = %v", sc.Body)
	}
	if sc.Body["layout"].(map[string]any)["inherited"] != true {
		t.Fatalf("layout = %v", sc.Body["layout"])
	}

	// Сеть убирает закреплённую полоску и добавляет три свои полки — полоска
	// возвращается, публикация упирается в лимит 2 полок.
	shelf := func(id, title string) map[string]any {
		return map[string]any{"id": id, "type": "shelf", "title": title, "source": "new", "limit": 6, "view": "row"}
	}
	own := []any{
		shelf("f0000000-0000-4000-8000-000000000001", "Свежее"),
		shelf("f0000000-0000-4000-8000-000000000002", "К чаю"),
		shelf("f0000000-0000-4000-8000-000000000003", "Завтрак"),
		tpl[5],
	}
	d := a.expect(a.do("PUT", "/store/home/draft", tok, map[string]any{"blocks": own}), 200, "store draft")
	draft := d.Body["layout"].(map[string]any)["draft"].([]any)
	if len(draft) != 5 || draft[1].(map[string]any)["id"] != pinnedPromo["id"] {
		t.Fatalf("pinned not restored: %v", draft)
	}
	if d.Body["usage"].(map[string]any)["shelves"].(float64) != 3 {
		t.Fatalf("usage = %v", d.Body["usage"])
	}
	lim := a.expect(a.do("POST", "/store/home/publish", tok, nil), 409, "shelves limit")
	if det := lim.Body["error"].(map[string]any)["details"].(map[string]any); det["feature"] != "shelves" || det["limit"].(float64) != 2 || det["used"].(float64) != 3 {
		t.Fatalf("limit = %v", lim.Body)
	}
	a.expect(a.do("PUT", "/store/home/draft", tok, map[string]any{"blocks": own[1:]}), 200, "store draft 2")
	a.expect(a.do("POST", "/store/home/publish", tok, nil), 200, "store publish")
	h := home()
	if len(h) != 4 || h[0]["title"] != "К чаю" || h[1]["id"] != pinnedPromo["id"] || h[2]["title"] != "Завтрак" {
		t.Fatalf("store home = %v", h)
	}

	// «Про» нужен для расписания и витрины отдельного магазина.
	past := time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)
	sched := shelf("f0000000-0000-4000-8000-000000000004", "Акция")
	sched["starts_at"] = past
	a.expect(a.do("PUT", "/store/home/draft", tok, map[string]any{"blocks": []any{sched}}), 200, "sched draft")
	if e := a.expect(a.do("POST", "/store/home/publish", tok, nil), 409, "schedule"); e.Body["error"].(map[string]any)["details"].(map[string]any)["feature"] != "schedule" {
		t.Fatalf("schedule = %v", e.Body)
	}
	a.expect(a.do("DELETE", "/store/home/draft", tok, nil), 200, "discard")
	a.expect(a.do("PUT", "/store/home/draft?store_id="+store, tok, map[string]any{"blocks": own[1:]}), 409, "per store")

	// Свои баннеры: на модерации не видны покупателям, лимит 3.
	var banners []string
	for i := 0; i < 3; i++ {
		b := a.expect(a.do("POST", "/store/banners", tok, map[string]any{"title": "Баннер", "image_url": "https://cdn.example.com/x.jpg"}), 201, "banner")
		if b.str("moderation") != "pending" || b.str("owner") != "network" {
			t.Fatalf("banner = %v", b.Body)
		}
		banners = append(banners, b.str("id"))
	}
	a.expect(a.do("POST", "/store/banners", tok, map[string]any{"title": "Ещё", "image_url": "https://cdn.example.com/y.jpg"}), 409, "banners limit")
	bannerBlock := map[string]any{"id": "f0000000-0000-4000-8000-000000000005", "type": "banners", "size": "big", "banner_ids": banners[:1]}
	a.expect(a.do("PUT", "/store/home/draft", tok, map[string]any{"blocks": []any{bannerBlock}}), 200, "banner draft")
	a.expect(a.do("POST", "/store/home/publish", tok, nil), 200, "banner publish")
	if h := home(); len(h) != 1 {
		t.Fatalf("pending banner leaked: %v", h)
	}
	if q := a.expect(a.do("GET", "/admin/banners?moderation=pending", adminTok, nil), 200, "queue").items(); len(q) != 3 {
		t.Fatalf("queue = %v", q)
	}
	a.expect(a.do("POST", "/admin/banners/"+banners[1]+"/reject", adminTok, map[string]any{}), 400, "reason required")
	a.expect(a.do("POST", "/admin/banners/"+banners[1]+"/reject", adminTok, map[string]any{"reason": "Нечитаемый текст"}), 200, "reject")
	a.expect(a.do("POST", "/admin/banners/"+banners[0]+"/approve", adminTok, nil), 200, "approve")
	// Публикация баннера сбрасывает кэш при следующей публикации — здесь
	// проверяем через предпросмотр (без кэша).
	pv := a.expect(a.do("POST", "/store/home/preview", tok, map[string]any{"store_id": store, "blocks": []any{bannerBlock}}), 200, "preview")
	if len(pv.Body["blocks"].([]any)) != 2 {
		t.Fatalf("preview = %v", pv.Body)
	}

	// Сеть выбирает «Старт» — своя витрина скрыта, но не удалена; «Про» —
	// возвращается.
	a.expect(a.do("POST", "/store/showcase/plan", tok, map[string]any{"plan": "start"}), 200, "start")
	if _, err := pool.Exec(ctx, `UPDATE networks SET showcase_trial_until = current_date - 1`); err != nil {
		t.Fatal(err)
	}
	a.expect(a.do("POST", "/store/showcase/plan", tok, map[string]any{"plan": "start"}), 200, "start again")
	if h := home(); len(h) < 5 {
		t.Fatalf("start should show template: %v", h)
	}
	a.expect(a.do("POST", "/store/showcase/plan", tok, map[string]any{"plan": "pro"}), 200, "pro")
	if h := home(); len(h) != 2 || h[0]["type"] != "banners" {
		t.Fatalf("pro home = %v", h)
	}
	a.expect(a.do("PUT", "/store/home/draft?store_id="+store, tok, map[string]any{"blocks": []any{sched}}), 200, "per store draft on pro")

	// Тарифы правит супер-админ.
	plans := a.expect(a.do("GET", "/admin/showcase/plans", adminTok, nil), 200, "plans").items()
	if len(plans) != 3 || plans[1]["shelves"].(float64) != 2 {
		t.Fatalf("plans = %v", plans)
	}
	p := a.expect(a.do("PATCH", "/admin/showcase/plans/business", adminTok, map[string]any{"shelves": -1, "price_uzs": "199000"}), 200, "plan")
	if p.Body["shelves"] != nil || p.str("price_uzs") != "199000.00" {
		t.Fatalf("plan = %v", p.Body)
	}
}

// TestHomeStats — показы и нажатия из приложения, заказы с главной; по
// тарифу «Бизнес» — только показы и нажатия, «Про» — всё, «Старт» — нет.
func TestHomeStats(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	a := newAPI(t, paymeConfig(), pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	shop := newAdminShop(t, a, adminTok, "+998900000002", "+998900000077")
	owner, _ := a.login("+998900000002", identity.AppStore)
	hits := "a0000000-0000-4000-8000-000000000004"
	deals := "a0000000-0000-4000-8000-000000000005"

	a.expect(a.do("POST", "/client/home/events", "", map[string]any{"store_id": shop.store, "items": []map[string]any{
		{"block_id": hits, "views": 10, "clicks": 3}, {"block_id": deals, "views": 8, "clicks": 1},
	}}), 204, "events")
	a.expect(a.do("POST", "/client/home/events", "", map[string]any{"store_id": shop.store, "items": []map[string]any{
		{"block_id": hits, "views": 5, "clicks": 1},
	}}), 204, "events 2")
	a.expect(a.do("POST", "/client/home/events", "", map[string]any{"store_id": shop.store, "items": []map[string]any{
		{"block_id": "x", "views": 1},
	}}), 400, "bad block")
	a.expect(a.do("POST", "/client/home/events", "", map[string]any{"store_id": "00000000-0000-0000-0000-000000000000", "items": []map[string]any{
		{"block_id": hits, "views": 1},
	}}), 404, "unknown store")

	o := a.expect(a.do("POST", "/client/orders", shop.client, map[string]any{
		"store_id": shop.store, "address_id": shop.addr, "payment_provider": "payme",
		"items": []map[string]any{{"product_id": shop.cola, "qty": 2, "block_id": hits}},
	}), 201, "order").str("order", "id")
	if _, err := pool.Exec(ctx, `UPDATE orders SET status = 'paid' WHERE id = $1`, o); err != nil {
		t.Fatal(err)
	}

	// «Бизнес» (пробный): показы и нажатия, без заказов.
	a.expect(a.do("GET", "/store/home", owner, nil), 200, "trial")
	b := a.expect(a.do("GET", "/store/home/stats?days=30", owner, nil), 200, "basic")
	if b.str("level") != "basic" || b.Body["days"].(float64) != 7 || b.Body["views"].(float64) != 23 || b.Body["clicks"].(float64) != 5 || b.Body["orders"].(float64) != 0 {
		t.Fatalf("basic = %v", b.Body)
	}
	top := b.Body["blocks"].([]any)[0].(map[string]any)
	if top["title"] != "Полка «Хиты недели»" || top["views"].(float64) != 15 || top["orders"].(float64) != 0 {
		t.Fatalf("basic top = %v", top)
	}

	a.expect(a.do("POST", "/store/showcase/plan", owner, map[string]any{"plan": "pro"}), 200, "pro")
	f := a.expect(a.do("GET", "/store/home/stats?days=30", owner, nil), 200, "full")
	if f.str("level") != "full" || f.Body["orders"].(float64) != 1 || f.str("revenue") != "30000.00" || len(f.Body["series"].([]any)) != 1 {
		t.Fatalf("full = %v", f.Body)
	}
	top = f.Body["blocks"].([]any)[0].(map[string]any)
	if top["block_id"] != hits || top["orders"].(float64) != 1 || f.str("hint") == "" {
		t.Fatalf("full top = %v hint %q", top, f.str("hint"))
	}

	// Супер-админ видит всё.
	ad := a.expect(a.do("GET", "/admin/home/stats?network_id="+shop.network, adminTok, nil), 200, "admin")
	if ad.Body["views"].(float64) != 23 || ad.Body["orders"].(float64) != 1 {
		t.Fatalf("admin = %v", ad.Body)
	}

	// «Старт» после пробного — статистики нет.
	if _, err := pool.Exec(ctx, `UPDATE networks SET showcase_trial_until = current_date - 1`); err != nil {
		t.Fatal(err)
	}
	a.expect(a.do("POST", "/store/showcase/plan", owner, map[string]any{"plan": "start"}), 200, "start")
	if e := a.expect(a.do("GET", "/store/home/stats", owner, nil), 409, "none"); e.Body["error"].(map[string]any)["details"].(map[string]any)["feature"] != "stats" {
		t.Fatalf("none = %v", e.Body)
	}
}
