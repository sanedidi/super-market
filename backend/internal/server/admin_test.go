package server_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/config"
)

// TestAdminCategoryTree — категорию нельзя вложить в саму себя или в потомка;
// список категорий ищет, исключает поддерево и отдаёт страницы.
func TestAdminCategoryTree(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)

	mk := func(name, parent string) string {
		body := map[string]any{"name": name}
		if parent != "" {
			body["parent_id"] = parent
		}
		return a.expect(a.do("POST", "/admin/catalog/categories", adminTok, body), 201, "category "+name).str("id")
	}
	top := mk("Еда", "")
	mid := mk("Молочное", top)
	leaf := mk("Сыры", mid)
	other := mk("Бытовая химия", "")

	for what, parent := range map[string]string{"self": top, "child": mid, "grandchild": leaf} {
		r := a.expect(a.do("PATCH", "/admin/catalog/categories/"+top, adminTok, map[string]any{"parent_id": parent}), 400, "cycle via "+what)
		if r.str("error", "code") != "validation" {
			t.Fatalf("cycle via %s: %v", what, r.Body)
		}
	}
	a.expect(a.do("PATCH", "/admin/catalog/categories/"+leaf, adminTok, map[string]any{"parent_id": other}), 200, "move leaf")
	a.expect(a.do("PATCH", "/admin/catalog/categories/"+mid, adminTok, map[string]any{"parent_id": nil}), 200, "mid to root")
	a.expect(a.do("PATCH", "/admin/catalog/categories/"+top, adminTok, map[string]any{"parent_id": mid}), 200, "top under mid")

	// Варианты родителя для «Молочного»: без него самого и без «Еды» (теперь его потомка).
	opts := a.expect(a.do("GET", "/admin/catalog/categories?exclude_tree="+mid+"&limit=200", adminTok, nil), 200, "exclude tree").items()
	for _, c := range opts {
		if c["id"] == mid || c["id"] == top {
			t.Fatalf("subtree not excluded: %v", opts)
		}
	}
	found := a.expect(a.do("GET", "/admin/catalog/categories?q=еда", adminTok, nil), 200, "search").items()
	if len(found) != 1 || found[0]["id"] != top || found[0]["parent_name"] != "Молочное" {
		t.Fatalf("search = %v", found)
	}
	a.expect(a.do("GET", "/admin/catalog/brands?exclude_tree="+mid, adminTok, nil), 400, "exclude_tree on brands")

	// Страницы справочника.
	for i := 0; i < 3; i++ {
		a.expect(a.do("POST", "/admin/catalog/brands", adminTok, map[string]any{"name": fmt.Sprintf("Бренд %d", i)}), 201, "brand")
	}
	p1 := a.expect(a.do("GET", "/admin/catalog/brands?limit=2", adminTok, nil), 200, "brands p1").items()
	p2 := a.expect(a.do("GET", "/admin/catalog/brands?limit=2&offset=2", adminTok, nil), 200, "brands p2").items()
	if len(p1) != 2 || len(p2) != 1 || p2[0]["id"] == p1[0]["id"] || p2[0]["id"] == p1[1]["id"] {
		t.Fatalf("brand pages = %v / %v", p1, p2)
	}
}

// TestAdminClearFields — бренд/цвет товара и период баннера можно очистить.
func TestAdminClearFields(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)

	cat := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Напитки"}), 201, "category").str("id")
	brand := a.expect(a.do("POST", "/admin/catalog/brands", adminTok, map[string]any{"name": "Nestle"}), 201, "brand").str("id")
	color := a.expect(a.do("POST", "/admin/catalog/colors", adminTok, map[string]any{"name": "Белый", "hex": "#FFFFFF"}), 201, "color").str("id")
	units := a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items()
	p := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
		"name": "Вода", "category_id": cat, "unit_id": units[0]["id"], "brand_id": brand, "color_id": color,
	}), 201, "product")
	id := p.str("id")

	// null — «не менять», пустая строка — «убрать».
	r := a.expect(a.do("PATCH", "/admin/products/"+id, adminTok, map[string]any{"brand_id": nil, "name": "Вода 1 л"}), 200, "keep brand")
	if r.str("brand_id") != brand || r.str("color_id") != color {
		t.Fatalf("brand must stay: %v", r.Body)
	}
	r = a.expect(a.do("PATCH", "/admin/products/"+id, adminTok, map[string]any{"brand_id": "", "color_id": ""}), 200, "clear brand")
	if r.Body["brand_id"] != nil || r.Body["color_id"] != nil {
		t.Fatalf("brand/color not cleared: %v", r.Body)
	}

	b := a.expect(a.do("POST", "/admin/banners", adminTok, map[string]any{
		"title": "Акция", "starts_at": "2026-01-01T00:00:00Z", "ends_at": "2030-01-01T00:00:00Z",
	}), 201, "banner")
	bid := b.str("id")
	r = a.expect(a.do("PATCH", "/admin/banners/"+bid, adminTok, map[string]any{"title": "Акция!"}), 200, "keep period")
	if r.str("starts_at") == "" || r.str("ends_at") == "" {
		t.Fatalf("period must stay: %v", r.Body)
	}
	r = a.expect(a.do("PATCH", "/admin/banners/"+bid, adminTok, map[string]any{"starts_at": nil}), 200, "clear start")
	if r.Body["starts_at"] != nil || r.str("ends_at") == "" {
		t.Fatalf("start not cleared: %v", r.Body)
	}
	a.expect(a.do("PATCH", "/admin/banners/"+bid, adminTok, map[string]any{"starts_at": "2031-01-01T00:00:00Z"}), 400, "start after end")
	r = a.expect(a.do("PATCH", "/admin/banners/"+bid, adminTok, map[string]any{"ends_at": nil}), 200, "clear end")
	if r.Body["ends_at"] != nil {
		t.Fatalf("end not cleared: %v", r.Body)
	}
	a.expect(a.do("POST", "/admin/banners", adminTok, map[string]any{"title": "Второй"}), 201, "banner 2")
	if n := len(a.expect(a.do("GET", "/admin/banners?limit=1&offset=1", adminTok, nil), 200, "banner page").items()); n != 1 {
		t.Fatalf("banner page 2 has %d items", n)
	}
}

// adminShop — сеть с магазином, принимающим онлайн-заказы, и покупатель с
// адресом. order создаёт заказ (ждёт оплаты) и возвращает его id и номер.
type adminShop struct {
	a        api
	store    string
	network  string
	client   string
	clientID string
	addr     string
	cola     string
}

func newAdminShop(t *testing.T, a api, adminTok, ownerPhone, clientPhone string) adminShop {
	t.Helper()
	cola, _ := catalogBasics(t, a, adminTok)
	tok, store := setupNetwork(t, a, adminTok, ownerPhone)
	const lat, lng = 41.2995, 69.2401
	a.expect(a.do("PATCH", "/store/stores/"+store, tok, map[string]any{"lat": lat, "lng": lng, "address": "Центр"}), 200, "store location")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
	d := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{"type": "posting", "warehouse_id": wh,
		"items": []map[string]any{{"product_id": cola, "qty": 100, "price": 10000}}}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+d.str("id")+"/post", tok, nil), 200, "post")
	a.expect(a.do("PUT", "/store/stores/"+store+"/delivery", tok, map[string]any{
		"accepts_online": true, "min_order_amount": 0, "delivery_radius_m": 5000,
	}), 200, "delivery")
	client, _ := a.login(clientPhone, identity.AppClient)
	addr := a.expect(a.do("POST", "/client/addresses", client, map[string]any{
		"label": "Дом", "address": "Чиланзар 5", "lat": 41.3030, "lng": lng,
	}), 201, "address").str("id")
	me := a.expect(a.do("GET", "/store/me", tok, nil), 200, "me")
	if me.str("network", "id") == "" {
		t.Fatalf("me = %v", me.Body)
	}
	return adminShop{a: a, store: store, network: me.str("network", "id"), client: client, addr: addr, cola: cola}
}

func (s adminShop) order(t *testing.T) (id string, number float64) {
	t.Helper()
	o := s.a.expect(s.a.do("POST", "/client/orders", s.client, map[string]any{
		"store_id": s.store, "address_id": s.addr, "payment_provider": "payme",
		"items": []map[string]any{{"product_id": s.cola, "qty": 1}},
	}), 201, "order")
	return o.str("order", "id"), o.Body["order"].(map[string]any)["number"].(float64)
}

func paymeConfig() config.Config {
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	cfg.PaymeMerchantID, cfg.PaymeKey = "merchant-1", paymeKey
	cfg.PaymentTimeout, cfg.AcceptTimeout = 15*time.Minute, 10*time.Minute
	return cfg
}

// TestAdminOrdersAndStats — фильтры заказов супер-админа и сводка.
func TestAdminOrdersAndStats(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	a := newAPI(t, paymeConfig(), pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	shop := newAdminShop(t, a, adminTok, "+998900000002", "+998901234567")

	o1, n1 := shop.order(t)
	o2, _ := shop.order(t)
	o3, _ := shop.order(t)
	// o1 оплачен давно (не принят вовремя), o2 — только что, o3 ждёт оплаты.
	if _, err := pool.Exec(ctx, `UPDATE orders SET status = 'paid', paid_at = now() - interval '11 minutes' WHERE id = $1`, o1); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `UPDATE orders SET status = 'paid', paid_at = now() WHERE id = $1`, o2); err != nil {
		t.Fatal(err)
	}

	ids := func(path string) []string {
		t.Helper()
		var out []string
		for _, o := range a.expect(a.do("GET", path, adminTok, nil), 200, path).items() {
			out = append(out, o["id"].(string))
		}
		return out
	}
	if got := ids(fmt.Sprintf("/admin/orders?q=%d", int64(n1))); len(got) != 1 || got[0] != o1 {
		t.Fatalf("by number = %v", got)
	}
	if got := ids("/admin/orders?q=1234567"); len(got) != 3 {
		t.Fatalf("by phone = %v", got)
	}
	if got := ids("/admin/orders?q=7654321"); len(got) != 0 {
		t.Fatalf("by other phone = %v", got)
	}
	a.expect(a.do("GET", "/admin/orders?q=ab", adminTok, nil), 400, "bad q")
	if got := ids("/admin/orders?network_id=00000000-0000-0000-0000-000000000000"); len(got) != 0 {
		t.Fatalf("by other network = %v", got)
	}
	if got := ids("/admin/orders?network_id=" + shop.network + "&store_id=" + shop.store + "&payment_provider=payme"); len(got) != 3 {
		t.Fatalf("by network/store/provider = %v", got)
	}
	if got := ids("/admin/orders?payment_provider=click"); len(got) != 0 {
		t.Fatalf("by click = %v", got)
	}
	a.expect(a.do("GET", "/admin/orders?payment_provider=cash", adminTok, nil), 400, "bad provider")
	today := time.Now().In(time.FixedZone("UZT", 5*3600))
	if got := ids("/admin/orders?from=" + today.AddDate(0, 0, 1).Format("2006-01-02")); len(got) != 0 {
		t.Fatalf("from tomorrow = %v", got)
	}
	if got := ids("/admin/orders?from=" + today.Format("2006-01-02") + "&to=" + today.AddDate(0, 0, 1).Format("2006-01-02")); len(got) != 3 {
		t.Fatalf("today = %v", got)
	}
	stores := a.expect(a.do("GET", "/admin/networks/"+shop.network+"/stores", adminTok, nil), 200, "network stores").items()
	if len(stores) != 1 || stores[0]["id"] != shop.store {
		t.Fatalf("network stores = %v", stores)
	}
	a.expect(a.do("GET", "/admin/networks/00000000-0000-0000-0000-000000000000/stores", adminTok, nil), 404, "unknown network stores")
	stale := a.expect(a.do("GET", "/admin/orders?stale=true", adminTok, nil), 200, "stale").items()
	if len(stale) != 1 || stale[0]["id"] != o1 || stale[0]["accept_overdue"] != true {
		t.Fatalf("stale = %v", stale)
	}
	if got := ids("/admin/orders?status=paid&limit=1&offset=1"); len(got) != 1 {
		t.Fatalf("paid page 2 = %v", got)
	}
	if o := a.expect(a.do("GET", "/admin/orders/"+o2, adminTok, nil), 200, "fresh order"); o.Body["accept_overdue"] != nil {
		t.Fatalf("fresh order overdue: %v", o.Body)
	}
	_ = o3

	st := a.expect(a.do("GET", "/admin/stats", adminTok, nil), 200, "stats").Body
	// o1 оплачен 11 минут назад — сразу после полуночи по Ташкенту он «вчерашний».
	if n := st["today_orders"].(float64); n < 1 || n > 2 {
		t.Fatalf("today_orders = %v", n)
	}
	want := map[string]float64{"stale_orders": 1, "paid_waiting": 2, "accept_timeout_min": 10,
		"refunds_pending": 0, "payouts_requested": 0, "products_pending": 0, "overdue_networks": 0}
	for k, v := range want {
		if st[k] != v {
			t.Fatalf("stats[%s] = %v, want %v (%v)", k, st[k], v, st)
		}
	}
	if st["today_gmv"] == "0.00" || st["today_gmv"] == nil {
		t.Fatalf("today_gmv = %v", st["today_gmv"])
	}
}

// TestAdminCustomers — поиск, карточка, блокировка покупателя.
func TestAdminCustomers(t *testing.T) {
	pool := freshDB(t)
	a := newAPI(t, paymeConfig(), pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	shop := newAdminShop(t, a, adminTok, "+998900000002", "+998901234567")
	a.login("+998907777777", identity.AppClient)
	shop.order(t)

	list := a.expect(a.do("GET", "/admin/customers?q=1234", adminTok, nil), 200, "search").items()
	if len(list) != 1 || list[0]["phone"] != "+998901234567" || list[0]["orders_count"].(float64) != 0 || list[0]["last_order_at"] == nil {
		t.Fatalf("customers = %v", list)
	}
	id := list[0]["id"].(string)
	if all := a.expect(a.do("GET", "/admin/customers?limit=1&offset=1", adminTok, nil), 200, "page").items(); len(all) != 1 {
		t.Fatalf("page 2 = %v", all)
	}
	d := a.expect(a.do("GET", "/admin/customers/"+id, adminTok, nil), 200, "detail")
	if len(d.Body["addresses"].([]any)) != 1 || len(d.Body["recent_orders"].([]any)) != 1 || d.Body["blocked_at"] != nil {
		t.Fatalf("detail = %v", d.Body)
	}
	a.expect(a.do("GET", "/admin/customers/00000000-0000-0000-0000-000000000000", adminTok, nil), 404, "unknown")

	a.expect(a.do("POST", "/admin/customers/"+id+"/block", adminTok, map[string]any{"reason": " "}), 400, "block without reason")
	b := a.expect(a.do("POST", "/admin/customers/"+id+"/block", adminTok, map[string]any{"reason": "мошенничество"}), 200, "block")
	if b.Body["blocked_at"] == nil || b.str("blocked_reason") != "мошенничество" {
		t.Fatalf("blocked = %v", b.Body)
	}
	a.expect(a.do("POST", "/admin/customers/"+id+"/block", adminTok, map[string]any{"reason": "ещё"}), 409, "block twice")
	if bl := a.expect(a.do("GET", "/admin/customers?blocked=true", adminTok, nil), 200, "blocked list").items(); len(bl) != 1 {
		t.Fatalf("blocked list = %v", bl)
	}

	// Заблокированный не оформляет заказ и не входит заново.
	r := a.expect(a.do("POST", "/client/orders", shop.client, map[string]any{
		"store_id": shop.store, "address_id": shop.addr, "payment_provider": "payme",
		"items": []map[string]any{{"product_id": shop.cola, "qty": 1}},
	}), 403, "blocked order")
	if r.str("error", "code") != "customer_blocked" {
		t.Fatalf("order error = %v", r.Body)
	}
	a.expect(a.do("POST", "/auth/otp/request", "", map[string]string{"phone": "+998901234567"}), 200, "request")
	r = a.expect(a.do("POST", "/auth/otp/verify", "", map[string]string{"phone": "+998901234567", "code": "111111", "app": "client"}), 403, "blocked login")
	if r.str("error", "code") != "customer_blocked" {
		t.Fatalf("login error = %v", r.Body)
	}
	a.expect(a.do("GET", "/client/orders", shop.client, nil), 200, "blocked still sees orders")

	a.expect(a.do("POST", "/admin/customers/"+id+"/unblock", adminTok, nil), 200, "unblock")
	a.expect(a.do("POST", "/admin/customers/"+id+"/unblock", adminTok, nil), 409, "unblock twice")
	a.login("+998901234567", identity.AppClient)
	shop.order(t)
}

// TestAdminNotifications — очередь уведомлений и повтор неотправленных.
func TestAdminNotifications(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	a.login("+998901234567", identity.AppClient)
	var failed, sent int64
	if err := pool.QueryRow(ctx, `
		INSERT INTO notifications_outbox (user_id, kind, title, body, status, attempts, last_error)
		SELECT id, 'order_status', 'Заказ №5 оплачен', 'текст', 'failed', 6, 'fcm: unregistered' FROM users WHERE phone = '+998901234567'
		RETURNING id`).Scan(&failed); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `
		INSERT INTO notifications_outbox (user_id, kind, title, body, status, channel, sent_at)
		SELECT id, 'family', 'Просьба купить', 'текст', 'sent', 'push', now() FROM users WHERE phone = '+998901234567'
		RETURNING id`).Scan(&sent); err != nil {
		t.Fatal(err)
	}

	list := a.expect(a.do("GET", "/admin/notifications?status=failed", adminTok, nil), 200, "failed").items()
	if len(list) != 1 || list[0]["id"].(float64) != float64(failed) || list[0]["phone"] != "+998901234567" || list[0]["last_error"] != "fcm: unregistered" {
		t.Fatalf("failed = %v", list)
	}
	if l := a.expect(a.do("GET", "/admin/notifications?q=просьба", adminTok, nil), 200, "by title").items(); len(l) != 1 {
		t.Fatalf("by title = %v", l)
	}
	if l := a.expect(a.do("GET", "/admin/notifications?q=901234", adminTok, nil), 200, "by phone").items(); len(l) != 2 {
		t.Fatalf("by phone = %v", l)
	}
	a.expect(a.do("GET", "/admin/notifications?status=nope", adminTok, nil), 400, "bad status")
	if st := a.expect(a.do("GET", "/admin/stats", adminTok, nil), 200, "stats"); st.Body["failed_notifications"] != 1.0 {
		t.Fatalf("stats = %v", st.Body)
	}

	r := a.expect(a.do("POST", fmt.Sprintf("/admin/notifications/%d/retry", failed), adminTok, nil), 200, "retry")
	if r.str("status") != "pending" || r.Body["attempts"].(float64) != 0 || r.str("last_error") != "" {
		t.Fatalf("retried = %v", r.Body)
	}
	a.expect(a.do("POST", fmt.Sprintf("/admin/notifications/%d/retry", failed), adminTok, nil), 409, "retry pending")
	a.expect(a.do("POST", fmt.Sprintf("/admin/notifications/%d/retry", sent), adminTok, nil), 409, "retry sent")
	a.expect(a.do("POST", "/admin/notifications/999999/retry", adminTok, nil), 404, "retry unknown")
	a.expect(a.do("POST", "/admin/notifications/abc/retry", adminTok, nil), 404, "retry bad id")
}
