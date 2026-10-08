package server_test

import (
	"context"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// TestBrandAds — реклама бренда: блок с пометкой «Реклама» в магазине, где
// есть товар; оплачиваемый показ — один вошедший покупатель в день; сеть
// скрывает бренд, на «Про» выключает рекламу; доля сети за прошлый месяц
// уменьшает счёт за подписку, остаток — на баланс; счёт и акт бренду.
func TestBrandAds(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	app, err := server.Build(ctx, paymeConfig(), pool, &fakeTelegram{}, quietLog())
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app.Handler)
	t.Cleanup(srv.Close)
	a := api{t: t, srv: srv, pool: pool}
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	shop := newAdminShop(t, a, adminTok, "+998900000002", "+998900000077")
	owner, _ := a.login("+998900000002", identity.AppStore)

	brand := a.expect(a.do("POST", "/admin/catalog/brands", adminTok, map[string]any{"name": "Coca-Cola"}), 201, "brand").str("id")
	a.expect(a.do("PATCH", "/admin/products/"+shop.cola, adminTok, map[string]any{"brand_id": brand}), 200, "product brand")
	adv := a.expect(a.do("POST", "/admin/ads/advertisers", adminTok, map[string]any{"name": "ООО «Кока-Кола Ичимликлари»", "inn": "200000001"}), 201, "advertiser").str("id")
	now := time.Now()
	camp := a.expect(a.do("POST", "/admin/ads/campaigns", adminTok, map[string]any{
		"advertiser_id": adv, "brand_id": brand, "format": "shelf", "title": "Освежиться",
		"product_ids": []string{shop.cola}, "starts_at": now.Add(-time.Hour), "ends_at": now.Add(30 * 24 * time.Hour),
		"pricing": "cpm", "price": "50000",
	}), 201, "campaign")
	cid := camp.str("id")
	if camp.str("status") != "running" || camp.str("brand_name") != "Coca-Cola" {
		t.Fatalf("campaign = %v", camp.Body)
	}
	a.expect(a.do("POST", "/admin/ads/campaigns", adminTok, map[string]any{
		"advertiser_id": adv, "brand_id": brand, "format": "shelf", "title": "Чужой товар",
		"product_ids": []string{"00000000-0000-4000-8000-000000000001"}, "starts_at": now, "ends_at": now.Add(time.Hour),
		"pricing": "cpm", "price": "1",
	}), 400, "foreign product")

	adBlock := func() map[string]any {
		for _, b := range a.expect(a.do("GET", "/client/stores/"+shop.store+"/home", "", nil), 200, "home").Body["blocks"].([]any) {
			if m := b.(map[string]any); m["id"] == cid {
				return m
			}
		}
		return nil
	}
	b := adBlock()
	if b == nil || b["ad"].(map[string]any)["label"] != "Реклама" || b["ad"].(map[string]any)["brand"] != "Coca-Cola" || len(b["products"].([]any)) != 1 {
		t.Fatalf("ad block = %v", b)
	}

	// Города: кампания только для Самарканда — в магазине без города её нет.
	a.expect(a.do("PATCH", "/admin/ads/campaigns/"+cid, adminTok, map[string]any{"cities": []string{"Самарканд"}}), 200, "cities")
	if adBlock() != nil {
		t.Fatal("city filter ignored")
	}
	a.expect(a.do("PATCH", "/store/stores/"+shop.store, owner, map[string]any{"city": " самарканд "}), 200, "store city")
	// Правка кампании сбрасывает минутный кэш главной.
	a.expect(a.do("PATCH", "/admin/ads/campaigns/"+cid, adminTok, map[string]any{"cities": []string{"Самарканд", "Бухара"}}), 200, "cities 2")
	if adBlock() == nil {
		t.Fatal("city match failed")
	}
	if c := a.expect(a.do("GET", "/admin/ads/cities", adminTok, nil), 200, "cities list").Body["items"].([]any); len(c) != 1 || c[0] != "самарканд" {
		t.Fatalf("cities = %v", c)
	}
	a.expect(a.do("PATCH", "/admin/ads/campaigns/"+cid, adminTok, map[string]any{"cities": []string{}}), 200, "all cities")

	// Показы: вошедший покупатель — один оплачиваемый в день, аноним — не в оплату.
	ev := map[string]any{"store_id": shop.store, "items": []map[string]any{{"block_id": cid, "views": 1}}}
	a.expect(a.do("POST", "/client/home/events", shop.client, ev), 204, "views 1")
	a.expect(a.do("POST", "/client/home/events", shop.client, ev), 204, "views 2")
	a.expect(a.do("POST", "/client/home/events", "", ev), 204, "anonymous")
	c := a.expect(a.do("GET", "/admin/ads/campaigns/"+cid, adminTok, nil), 200, "campaign stats")
	if c.Body["views"].(float64) != 3 || c.Body["billable_views"].(float64) != 1 {
		t.Fatalf("stats = %v", c.Body)
	}
	if l := a.expect(a.do("GET", "/admin/ads/campaigns?status=running", adminTok, nil), 200, "list").items(); len(l) != 1 || l[0]["id"] != cid {
		t.Fatalf("list = %v", l)
	}
	if s := a.expect(a.do("GET", "/admin/ads/summary", adminTok, nil), 200, "summary"); s.Body["active"].(float64) != 1 {
		t.Fatalf("summary = %v", s.Body)
	}
	// Реклама не попадает в статистику витрины.
	a.expect(a.do("GET", "/store/home", owner, nil), 200, "trial")
	if bl := a.expect(a.do("GET", "/store/home/stats", owner, nil), 200, "stats").Body["blocks"].([]any); len(bl) != 0 {
		t.Fatalf("ads leaked into showcase stats: %v", bl)
	}

	// Сеть скрывает бренд — рекламы нет; на «Бизнес» выключить рекламу нельзя, на «Сеть» — можно.
	if _, err := pool.Exec(ctx, `UPDATE networks SET plan_key = 'business' WHERE id = $1`, shop.network); err != nil {
		t.Fatal(err)
	}
	n := a.expect(a.do("GET", "/store/ads", owner, nil), 200, "store ads")
	if n.str("share_pct") != "25.00" || len(n.Body["campaigns"].([]any)) != 1 || n.Body["ads_max"].(float64) != 2 {
		t.Fatalf("store ads = %v", n.Body)
	}
	a.expect(a.do("PUT", "/store/ads", owner, map[string]any{"hidden_brands": []string{brand}}), 200, "hide")
	if adBlock() != nil {
		t.Fatal("hidden brand still shown")
	}
	a.expect(a.do("PUT", "/store/ads", owner, map[string]any{"hidden_brands": []string{}}), 200, "unhide")
	if adBlock() == nil {
		t.Fatal("brand not back")
	}
	a.expect(a.do("PUT", "/store/ads", owner, map[string]any{"ads_max": 0}), 409, "business cannot")
	a.expect(a.do("PATCH", "/admin/billing/networks/"+shop.network, adminTok, map[string]any{"plan_key": "network"}), 200, "network plan")
	a.expect(a.do("PUT", "/store/ads", owner, map[string]any{"ads_max": 0}), 200, "pro off")
	if adBlock() != nil {
		t.Fatal("ads off on pro")
	}
	a.expect(a.do("PUT", "/store/ads", owner, map[string]any{"ads_max": -1}), 200, "back to plan")
	a.expect(a.do("POST", "/store/showcase/plan", owner, map[string]any{"plan": "start"}), 200, "start")

	// Прошлый месяц: кампания за период 4 000 000 сум, все показы — в этой сети.
	if _, err := pool.Exec(ctx, `UPDATE networks SET plan_trial_until = NULL, billing_from = date_trunc('month', now() AT TIME ZONE 'Asia/Tashkent')`); err != nil {
		t.Fatal(err)
	}
	var p0, p1 time.Time
	if err := pool.QueryRow(ctx, `SELECT (date_trunc('month', now() AT TIME ZONE 'Asia/Tashkent') - interval '1 month') AT TIME ZONE 'Asia/Tashkent',
		date_trunc('month', now() AT TIME ZONE 'Asia/Tashkent') AT TIME ZONE 'Asia/Tashkent'`).Scan(&p0, &p1); err != nil {
		t.Fatal(err)
	}
	prev := a.expect(a.do("POST", "/admin/ads/campaigns", adminTok, map[string]any{
		"advertiser_id": adv, "brand_id": brand, "format": "banner", "title": "Лето", "image_url": "https://cdn.example.com/cola.jpg",
		"product_ids": []string{shop.cola}, "starts_at": p0, "ends_at": p1, "pricing": "period", "price": "4000000",
	}), 201, "prev campaign").str("id")
	if _, err := pool.Exec(ctx, `INSERT INTO ad_views (campaign_id, day, user_id, store_id)
		SELECT $1, ($2::timestamptz AT TIME ZONE 'Asia/Tashkent')::date + 3, gen_random_uuid(), $3 FROM generate_series(1, 600)`, prev, p0, shop.store); err != nil {
		t.Fatal(err)
	}
	if _, err := app.Billing.GenerateInvoices(ctx, now); err != nil {
		t.Fatal(err)
	}
	var amount, applied, credited, invAmount, invShare, invStatus string
	if err := pool.QueryRow(ctx, `SELECT amount::text, applied::text, credited::text FROM network_ad_shares WHERE network_id = $1`, shop.network).
		Scan(&amount, &applied, &credited); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `SELECT amount_uzs::text, ad_share_uzs::text, status FROM subscription_invoices WHERE network_id = $1`, shop.network).
		Scan(&invAmount, &invShare, &invStatus); err != nil {
		t.Fatal(err)
	}
	// 4 000 000 × 25% = 1 000 000; счёт 1 магазин × «Старт» 149 000 закрыт, 851 000 — на баланс.
	if amount != "1000000.00" || applied != "149000.00" || credited != "851000.00" || invAmount != "0.00" || invShare != "149000.00" || invStatus != "paid" {
		t.Fatalf("share = %s/%s/%s invoice = %s/%s/%s", amount, applied, credited, invAmount, invShare, invStatus)
	}
	if s := sqlStr(t, pool, `SELECT amount::text FROM balance_entries WHERE kind = 'ad_share'`); s != "851000.00" {
		t.Fatalf("balance = %s", s)
	}
	if _, err := app.Billing.GenerateInvoices(ctx, now); err != nil {
		t.Fatal(err)
	}
	if s := sqlStr(t, pool, `SELECT count(*)::text FROM balance_entries WHERE kind = 'ad_share'`); s != "1" {
		t.Fatalf("share credited twice: %s", s)
	}
	if r := a.expect(a.do("GET", "/store/ads", owner, nil), 200, "shares").Body["shares"].([]any); len(r) != 1 || r[0].(map[string]any)["credited"] != "851000.00" {
		t.Fatalf("store shares = %v", r)
	}

	// Счёт и акт бренду.
	from, to := p0.In(time.FixedZone("T", 5*3600)).Format("2006-01-02"), p1.Add(-time.Second).In(time.FixedZone("T", 5*3600)).Format("2006-01-02")
	est := a.expect(a.do("GET", "/admin/ads/campaigns/"+prev+"/estimate?from="+from+"&to="+to, adminTok, nil), 200, "estimate")
	if est.str("amount") != "4000000.00" || est.Body["views"].(float64) != 600 {
		t.Fatalf("estimate = %v", est.Body)
	}
	a.expect(a.do("GET", "/admin/ads/advertisers?q=Кока", adminTok, nil), 200, "advertisers")
	inv := a.expect(a.do("POST", "/admin/ads/invoices", adminTok, map[string]any{"campaign_id": prev, "period_from": from, "period_to": to}), 201, "invoice")
	a.expect(a.do("GET", "/admin/ads/invoices/"+inv.str("id")+"/document?kind=act", adminTok, nil), 409, "no act before payment")
	a.expect(a.do("POST", "/admin/ads/invoices/"+inv.str("id")+"/paid", adminTok, nil), 200, "paid")
	act := a.expect(a.do("GET", "/admin/ads/invoices/"+inv.str("id")+"/document?kind=act", adminTok, nil), 200, "act")
	if act.str("advertiser", "inn") != "200000001" || act.str("subject") == "" || act.Body["number"].(float64) != 1 {
		t.Fatalf("act = %v", act.Body)
	}
	if l := a.expect(a.do("GET", "/admin/ads/invoices", adminTok, nil), 200, "invoices").items(); len(l) != 1 || l[0]["status"] != "paid" {
		t.Fatalf("invoices = %v", l)
	}
	a.expect(a.do("GET", "/admin/ads/settings", adminTok, nil), 200, "settings")
	a.expect(a.do("PUT", "/admin/ads/settings", adminTok, map[string]any{"network_share_pct": "30", "company_name": "ООО «Super Market»"}), 200, "save settings")
	// Отчёт: 600 оплачиваемых показов без покупок — подозрительно.
	rep := a.expect(a.do("GET", "/admin/ads/campaigns/"+prev+"/report", adminTok, nil), 200, "report").items()
	if len(rep) != 1 || rep[0]["suspicious"] != true {
		t.Fatalf("report = %v", rep)
	}
}
