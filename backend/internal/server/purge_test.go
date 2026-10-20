package server_test

import (
	"context"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// TestAdminDeleteNetworkAndStore — удаление магазина и сети супер-админом
// (Figma «Супер-админ · удаление сетей и магазинов»): превью, блокировки,
// подтверждение названием, деньги на балансе; одобренные товары сети
// остаются в центральной базе, другая сеть не задета.
func TestAdminDeleteNetworkAndStore(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	a := newAPI(t, paymeConfig(), pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)

	shop := newAdminShop(t, a, adminTok, "+998900000002", "+998900000003")
	tok, _ := a.login("+998900000002", identity.AppStore)
	net, s1 := shop.network, shop.store

	// Соседняя сеть с тем же общим товаром — её ничто не должно задеть.
	otherTok, other := setupNetwork(t, a, adminTok, "+998900000004")
	owh := a.expect(a.do("GET", "/store/warehouses?store_id="+other, otherTok, nil), 200, "other wh").items()[0]["id"].(string)
	od := a.expect(a.do("POST", "/store/inventory/documents", otherTok, map[string]any{"type": "posting", "warehouse_id": owh,
		"items": []map[string]any{{"product_id": shop.cola, "qty": 5, "price": 9000}}}), 201, "other posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+od.str("id")+"/post", otherTok, nil), 200, "other post")

	// Свои товары сети: один одобрен (стал общим), другой ещё на модерации.
	cat := a.expect(a.do("GET", "/admin/products/"+shop.cola, adminTok, nil), 200, "cola").str("category_id")
	var pcs string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		if u["short_name"] == "шт" {
			pcs = u["id"].(string)
		}
	}
	approved := a.expect(a.do("POST", "/store/products", tok, map[string]any{
		"name": "Лепёшка домашняя", "category_id": cat, "unit_id": pcs, "base_price": "4000",
	}), 201, "own product").str("id")
	a.expect(a.do("POST", "/admin/products/"+approved+"/approve", adminTok, nil), 200, "approve")
	pending := a.expect(a.do("POST", "/store/products", tok, map[string]any{
		"name": "Самса", "category_id": cat, "unit_id": pcs, "base_price": "6000",
	}), 201, "pending product").str("id")

	// Продажа в первом магазине: чек, смена денег в кассе.
	var cash string
	for _, m := range a.expect(a.do("GET", "/store/finance/payment-methods?store_id="+s1, tok, nil), 200, "methods").items() {
		if m["name"] == "Наличные" {
			cash = m["id"].(string)
		}
	}
	a.expect(a.do("POST", "/store/sales", tok, map[string]any{
		"client_uid": "purge-sale-1", "store_id": s1, "items": []map[string]any{{"product_id": shop.cola, "qty": 2}},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 30000}},
	}), 201, "sale")

	// ---- Магазин.
	s2 := a.expect(a.do("POST", "/store/stores", tok, map[string]any{"name": "Магазин 2"}), 201, "store 2").str("id")
	wh2 := a.expect(a.do("GET", "/store/warehouses?store_id="+s2, tok, nil), 200, "wh2").items()[0]["id"].(string)
	p := a.expect(a.do("GET", "/admin/stores/"+s2+"/delete-preview", adminTok, nil), 200, "store preview")
	if p.Body["blocked"] != nil || p.str("name") != "Магазин 2" || p.str("network_id") != net {
		t.Fatalf("store preview = %v", p.Body)
	}
	if countOf(p, "stores") != 1 || countOf(p, "warehouses") != 1 {
		t.Fatalf("store preview counts = %v", p.Body["counts"])
	}
	a.expect(a.do("GET", "/admin/stores/"+s2+"/delete-preview", tok, nil), 403, "store token")

	// Второй магазин отдал товар первому — удаляется, а остаток первого
	// магазина и запись о поступлении у него остаются.
	wh1 := a.expect(a.do("GET", "/store/warehouses?store_id="+s1, tok, nil), 200, "wh1").items()[0]["id"].(string)
	post := func(body map[string]any) {
		t.Helper()
		d := a.expect(a.do("POST", "/store/inventory/documents", tok, body), 201, "doc "+body["type"].(string))
		a.expect(a.do("POST", "/store/inventory/documents/"+d.str("id")+"/post", tok, nil), 200, "post "+body["type"].(string))
	}
	post(map[string]any{"type": "posting", "warehouse_id": wh2, "items": []map[string]any{{"product_id": shop.cola, "qty": 10, "price": 10000}}})
	post(map[string]any{"type": "transfer", "warehouse_id": wh2, "to_warehouse_id": wh1, "items": []map[string]any{{"product_id": shop.cola, "qty": 4}}})
	before, _ := stockOf(t, a, tok, wh1, shop.cola)
	del := a.expect(a.do("DELETE", "/admin/stores/"+s2, adminTok, map[string]any{"confirm_name": "Магазин 2"}), 200, "delete store 2")
	if countOf(del, "documents") != 2 {
		t.Fatalf("deleted store 2 = %v", del.Body)
	}
	if after, _ := stockOf(t, a, tok, wh1, shop.cola); after != before {
		t.Fatalf("store 1 stock changed after store 2: %s → %s", before, after)
	}
	a.expect(a.do("GET", "/store/inventory/movements?warehouse_id="+wh1+"&product_id="+shop.cola, tok, nil), 200, "store 1 movements")

	// Третий магазин только получал товар от первого — удаляется; у первого
	// остаток и документ перемещения остаются (получатель — пустой).
	// Неверное название — 400, верное (регистр и пробелы не важны) — 200.
	s3 := a.expect(a.do("POST", "/store/stores", tok, map[string]any{"name": "Магазин 3"}), 201, "store 3").str("id")
	wh3 := a.expect(a.do("GET", "/store/warehouses?store_id="+s3, tok, nil), 200, "wh3").items()[0]["id"].(string)
	post(map[string]any{"type": "transfer", "warehouse_id": wh1, "to_warehouse_id": wh3, "items": []map[string]any{{"product_id": shop.cola, "qty": 3}}})
	before, _ = stockOf(t, a, tok, wh1, shop.cola)
	a.expect(a.do("DELETE", "/admin/stores/"+s3, adminTok, map[string]any{"confirm_name": "Магазин"}), 400, "wrong store name")
	del = a.expect(a.do("DELETE", "/admin/stores/"+s3, adminTok, map[string]any{"confirm_name": " магазин  3 "}), 200, "delete store 3")
	if countOf(del, "stores") != 1 || countOf(del, "stock") != 1 {
		t.Fatalf("deleted store = %v", del.Body)
	}
	if after, _ := stockOf(t, a, tok, wh1, shop.cola); after != before {
		t.Fatalf("store 1 stock changed: %s → %s", before, after)
	}
	if s := sqlStr(t, pool, `SELECT count(*)::text FROM stock_documents WHERE warehouse_id = $1 AND type = 'transfer' AND to_warehouse_id IS NULL`, wh1); s != "1" {
		t.Fatalf("transfer of store 1 = %s", s)
	}
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM stores WHERE network_id = $1`, net); n != "1" {
		t.Fatalf("stores left = %s", n)
	}
	a.expect(a.do("GET", "/admin/stores/"+s3+"/delete-preview", adminTok, nil), 404, "deleted store")

	// ---- Сеть: незавершённый заказ блокирует удаление.
	order, _ := shop.order(t)
	p = a.expect(a.do("GET", "/admin/networks/"+net+"/delete-preview", adminTok, nil), 200, "network preview")
	if p.str("blocked", "code") != "active_orders" || p.Body["active_orders"].(float64) != 1 {
		t.Fatalf("network preview with order = %v", p.Body)
	}
	if p.Body["kept_products"].(float64) != 1 {
		t.Fatalf("kept products = %v", p.Body)
	}
	a.expect(a.do("DELETE", "/admin/networks/"+net, adminTok, map[string]any{"confirm_name": "Сеть +998900000002"}), 409, "active order")
	if _, err := pool.Exec(ctx, `UPDATE orders SET status = 'cancelled' WHERE id = $1`, order); err != nil {
		t.Fatal(err)
	}

	// Деньги на балансе: без подтверждения нельзя.
	if _, err := pool.Exec(ctx, `INSERT INTO balance_entries (network_id, kind, status, amount) VALUES ($1, 'adjustment', 'available', 5000)`, net); err != nil {
		t.Fatal(err)
	}
	p = a.expect(a.do("GET", "/admin/networks/"+net+"/delete-preview", adminTok, nil), 200, "network preview 2")
	if p.Body["blocked"] != nil || p.Body["money_ack_required"] != true || p.str("balance_available") != "5000.00" {
		t.Fatalf("network preview = %v", p.Body)
	}
	for _, k := range []string{"stores", "products", "sales", "orders", "documents"} {
		if countOf(p, k) == 0 {
			t.Fatalf("preview has no %s: %v", k, p.Body["counts"])
		}
	}
	// Превью ничего не удаляет.
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM stores WHERE network_id = $1`, net); n != "1" {
		t.Fatalf("preview deleted stores: %s", n)
	}
	a.expect(a.do("DELETE", "/admin/networks/"+net, adminTok, map[string]any{"confirm_name": "Сеть +998900000002"}), 409, "money ack")
	a.expect(a.do("DELETE", "/admin/networks/"+net, adminTok, map[string]any{"confirm_name": "Другая", "money_ack": true}), 400, "wrong name")
	del = a.expect(a.do("DELETE", "/admin/networks/"+net, adminTok, map[string]any{"confirm_name": "Сеть +998900000002", "money_ack": true}), 200, "delete network")
	if countOf(del, "stores") != 1 || del.Body["total"].(float64) == 0 {
		t.Fatalf("deleted network = %v", del.Body)
	}

	// Сети нет, одобренный товар остался в центральной базе, неодобренный — удалён.
	a.expect(a.do("GET", "/admin/networks/"+net, adminTok, nil), 404, "network gone")
	if s := sqlStr(t, pool, `SELECT moderation_status || '|' || COALESCE(network_id::text, '') || '|' || COALESCE(proposed_by::text, '') FROM products WHERE id = $1`, approved); s != "approved||" {
		t.Fatalf("approved product = %q", s)
	}
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM products WHERE id = $1`, pending); n != "0" {
		t.Fatalf("pending product left: %s", n)
	}
	a.expect(a.do("GET", "/admin/products/"+approved, adminTok, nil), 200, "approved product")
	a.expect(a.do("GET", "/admin/products/"+shop.cola, adminTok, nil), 200, "central product")
	// Владелец остался пользователем, другая сеть и её остаток не задеты.
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM users WHERE phone = '+998900000002'`); n != "1" {
		t.Fatalf("owner user = %s", n)
	}
	if q, _ := stockOf(t, a, otherTok, owh, shop.cola); q != "5.000" && q != "5" {
		t.Fatalf("other network stock = %s", q)
	}
	a.expect(a.do("GET", "/admin/networks/"+sqlStr(t, pool, `SELECT network_id::text FROM stores WHERE id = $1`, other), adminTok, nil), 200, "other network")
	// Журнал.
	if s := sqlStr(t, pool, `SELECT kind || '|' || name || '|' || balance::text || '|' || (deleted_by IS NOT NULL)::text FROM admin_deletions WHERE target_id = $1`, net); s != "network|Сеть +998900000002|5000.00|true" {
		t.Fatalf("journal = %q", s)
	}
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM admin_deletions`); n != "3" {
		t.Fatalf("journal rows = %s", n)
	}

	// Единственный магазин сети отдельно не удаляется.
	p = a.expect(a.do("GET", "/admin/stores/"+other+"/delete-preview", adminTok, nil), 200, "only store preview")
	if p.str("blocked", "code") != "only_store" {
		t.Fatalf("only store preview = %v", p.Body)
	}
	a.expect(a.do("DELETE", "/admin/stores/"+other, adminTok, map[string]any{"confirm_name": "Магазин 1"}), 409, "only store")
}

func countOf(r resp, key string) float64 {
	list, _ := r.Body["counts"].([]any)
	for _, c := range list {
		m := c.(map[string]any)
		if m["key"] == key {
			return m["count"].(float64)
		}
	}
	return 0
}

// agentDeal — магазин и агент (две сети): связь, заказ доставлен (у агента
// расход, у магазина черновик прихода), магазин отдал агенту 100 000.
type agentDeal struct {
	a                           api
	adminTok, storeTok, distTok string
	storeNet, distNet           string
	store, box, cola            string
}

func newAgentDeal(t *testing.T) agentDeal {
	t.Helper()
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	d := agentDeal{a: a}
	d.adminTok, _ = a.login("+998900000001", identity.AppAdmin)
	d.cola, _ = catalogBasics(t, a, d.adminTok)
	d.storeNet = a.expect(a.do("POST", "/admin/networks", d.adminTok, map[string]string{
		"name": "Baraka", "kind": "chain", "owner_phone": "+998900000002", "owner_name": "Владелец",
	}), 201, "store network").str("id")
	d.storeTok, _ = a.login("+998900000002", identity.AppStore)
	d.store = a.expect(a.do("POST", "/store/stores", d.storeTok, map[string]any{"name": "Baraka Market", "lat": 41.30, "lng": 69.24}), 201, "store").str("id")
	var distWh string
	d.distTok, _, distWh = setupDistributor(t, a, d.adminTok, "+998900000003", 41.305, 69.245)
	d.distNet = a.expect(a.do("GET", "/store/me", d.distTok, nil), 200, "dist me").str("network", "id")

	maker := a.expect(a.do("POST", "/store/finance/counterparties", d.distTok, map[string]any{"name": "Coca-Cola Bottlers"}), 201, "maker").str("id")
	inc := a.expect(a.do("POST", "/store/inventory/documents", d.distTok, map[string]any{
		"type": "income", "warehouse_id": distWh, "counterparty_id": maker,
		"items": []map[string]any{{"product_id": d.cola, "qty": 100, "price": 9800}},
	}), 201, "income")
	a.expect(a.do("POST", "/store/inventory/documents/"+inc.str("id")+"/post", d.distTok, nil), 200, "post income")
	pts := a.expect(a.do("GET", "/store/price-types", d.distTok, nil), 200, "price types").items()
	pd := a.expect(a.do("POST", "/store/price-documents", d.distTok, map[string]any{
		"price_type_id": pts[0]["id"], "items": []map[string]any{{"product_id": d.cola, "new_price": 10000}},
	}), 201, "price doc")
	a.expect(a.do("POST", "/store/price-documents/"+pd.str("id")+"/post", d.distTok, nil), 200, "post price")
	code := a.expect(a.do("POST", "/store/supply/stores/"+d.store+"/code", d.distTok, nil), 201, "code").str("code")
	a.expect(a.do("POST", "/store/suppliers/connect", d.storeTok, map[string]any{"store_id": d.store, "code": code}), 200, "connect")
	distID := a.expect(a.do("GET", "/store/suppliers?store_id="+d.store, d.storeTok, nil), 200, "suppliers").items()[0]["id"].(string)
	ord := a.expect(a.do("POST", "/store/supplier-orders", d.storeTok, map[string]any{
		"store_id": d.store, "distributor_id": distID, "items": []map[string]any{{"product_id": d.cola, "qty": 24}},
	}), 201, "order").str("id")
	a.expect(a.do("POST", "/store/supply/orders/"+ord+"/accept", d.distTok, nil), 200, "accept")
	a.expect(a.do("POST", "/store/supply/orders/"+ord+"/deliver", d.distTok, nil), 200, "deliver")

	for _, b := range a.expect(a.do("GET", "/store/finance/cashboxes", d.storeTok, nil), 200, "boxes").items() {
		if b["store_id"] == d.store {
			d.box = b["id"].(string)
		}
	}
	reason := a.expect(a.do("POST", "/store/finance/reasons", d.storeTok, map[string]any{"name": "Выручка", "kind": "income"}), 201, "reason").str("id")
	a.expect(a.do("POST", "/store/finance/operations", d.storeTok, map[string]any{
		"kind": "income", "cashbox_id": d.box, "amount": 1000000, "reason_id": reason,
	}), 201, "cash in")
	p := a.expect(a.do("POST", "/store/suppliers/"+distID+"/pay", d.storeTok, map[string]any{
		"amount": 100000, "cashbox_id": d.box, "method": "cash", "store_id": d.store,
	}), 201, "pay")
	a.expect(a.do("POST", "/store/supply/payments/"+p.str("id")+"/confirm", d.distTok, nil), 200, "confirm")
	return d
}

// rowsOf — сколько строк сети в таблицах (для проверки «не задели»).
func rowsOf(t *testing.T, a api, tok string) map[string]int {
	t.Helper()
	out := map[string]int{}
	out["documents"] = len(a.expect(a.do("GET", "/store/inventory/documents", tok, nil), 200, "documents").items())
	out["counterparties"] = len(a.expect(a.do("GET", "/store/finance/counterparties", tok, nil), 200, "counterparties").items())
	out["operations"] = len(a.expect(a.do("GET", "/store/finance/operations", tok, nil), 200, "operations").items())
	return out
}

// TestAdminDeleteAgentKeepsStore — удаление агента не трогает документы,
// кассу и контрагентов магазина (другой сети).
func TestAdminDeleteAgentKeepsStore(t *testing.T) {
	d := newAgentDeal(t)
	a := d.a
	before := rowsOf(t, a, d.storeTok)
	boxBefore := a.expect(a.do("GET", "/store/finance/cashboxes", d.storeTok, nil), 200, "boxes").items()

	p := a.expect(a.do("GET", "/admin/networks/"+d.distNet+"/delete-preview", d.adminTok, nil), 200, "agent preview")
	if p.Body["blocked"] != nil || countOf(p, "supply") == 0 {
		t.Fatalf("agent preview = %v", p.Body)
	}
	a.expect(a.do("DELETE", "/admin/networks/"+d.distNet, d.adminTok, map[string]any{"confirm_name": "Hydrolife Eco"}), 200, "delete agent")

	if after := rowsOf(t, a, d.storeTok); after["documents"] != before["documents"] || after["counterparties"] != before["counterparties"] || after["operations"] != before["operations"] {
		t.Fatalf("store rows changed: %v → %v", before, after)
	}
	boxAfter := a.expect(a.do("GET", "/store/finance/cashboxes", d.storeTok, nil), 200, "boxes").items()
	if jsonOf(boxAfter) != jsonOf(boxBefore) {
		t.Fatalf("store cash changed: %v → %v", boxBefore, boxAfter)
	}
	a.expect(a.do("GET", "/admin/products/"+d.cola, d.adminTok, nil), 200, "central product")
	if s := a.expect(a.do("GET", "/store/suppliers?store_id="+d.store, d.storeTok, nil), 200, "suppliers").items(); len(s) != 0 {
		t.Fatalf("suppliers after agent deleted = %v", s)
	}
}

// TestAdminDeleteStoreNetworkKeepsAgent — удаление сети магазина не трогает
// расходы, остатки и контрагентов агента.
func TestAdminDeleteStoreNetworkKeepsAgent(t *testing.T) {
	d := newAgentDeal(t)
	a := d.a
	before := rowsOf(t, a, d.distTok)
	a.expect(a.do("DELETE", "/admin/networks/"+d.storeNet, d.adminTok, map[string]any{"confirm_name": "baraka"}), 200, "delete store network")
	if after := rowsOf(t, a, d.distTok); after["documents"] != before["documents"] || after["counterparties"] != before["counterparties"] {
		t.Fatalf("agent rows changed: %v → %v", before, after)
	}
	a.expect(a.do("GET", "/store/me", d.distTok, nil), 200, "agent works")
}

// TestAdminDeleteStoreEdgeCases — строка чужого заказа, собранная с
// удаляемого склада, остаётся; внесение денег в смене кассы и спор по долгу
// не мешают удалить магазин; долги и платежи — копией в журнале.
func TestAdminDeleteStoreEdgeCases(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	a := newAPI(t, paymeConfig(), pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	shop := newAdminShop(t, a, adminTok, "+998900000002", "+998900000003")
	tok, _ := a.login("+998900000002", identity.AppStore)
	s2 := a.expect(a.do("POST", "/store/stores", tok, map[string]any{"name": "Магазин 2"}), 201, "store 2").str("id")
	wh2 := a.expect(a.do("GET", "/store/warehouses?store_id="+s2, tok, nil), 200, "wh2").items()[0]["id"].(string)
	emp := sqlStr(t, pool, `SELECT id::text FROM employees WHERE network_id = $1 LIMIT 1`, shop.network)
	client := sqlStr(t, pool, `SELECT id::text FROM users WHERE phone = '+998900000003'`)

	// Заказ первого магазина доставлен, товар собран со склада второго.
	order, _ := shop.order(t)
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
	}
	exec(`UPDATE order_items SET picked_warehouse_id = $2 WHERE order_id = $1`, order, wh2)
	exec(`UPDATE orders SET status = 'delivered' WHERE id = $1`, order)
	// Смена кассы во втором магазине с внесением денег.
	dev := sqlStr(t, pool, `INSERT INTO pos_devices (network_id, store_id, name) VALUES ($1, $2, 'Касса') RETURNING id::text`, shop.network, s2)
	shift := sqlStr(t, pool, `INSERT INTO pos_shifts (network_id, store_id, device_id, number, client_uid, opened_by, opened_at, opening_cash)
		VALUES ($1, $2, $3, 1, 'shift-0001', $4, now(), 0) RETURNING id::text`, shop.network, s2, dev, emp)
	exec(`INSERT INTO pos_cash_moves (network_id, shift_id, client_uid, kind, amount, created_by, created_at)
		VALUES ($1, $2, 'move-0001', 'in', 50000, $3, now())`, shop.network, shift, emp)
	// Долг покупателя во втором магазине и спор по нему.
	debtor := sqlStr(t, pool, `INSERT INTO debtors (network_id, phone) VALUES ($1, '+998900000003') RETURNING id::text`, shop.network)
	entry := sqlStr(t, pool, `INSERT INTO debt_entries (network_id, debtor_id, store_id, amount, doc_type, doc_id)
		VALUES ($1, $2, $3, 25000, 'sale', gen_random_uuid()) RETURNING id::text`, shop.network, debtor, s2)
	exec(`INSERT INTO debt_disputes (network_id, entry_id, user_id) VALUES ($1, $2::bigint, $3)`, shop.network, entry, client)

	p := a.expect(a.do("GET", "/admin/stores/"+s2+"/delete-preview", adminTok, nil), 200, "preview")
	if p.Body["blocked"] != nil || countOf(p, "shifts") != 1 || countOf(p, "debts") != 1 {
		t.Fatalf("preview = %v", p.Body)
	}
	a.expect(a.do("DELETE", "/admin/stores/"+s2, adminTok, map[string]any{"confirm_name": "Магазин 2"}), 200, "delete")

	if s := sqlStr(t, pool, `SELECT count(*)::text || '|' || bool_and(picked_warehouse_id IS NULL)::text FROM order_items WHERE order_id = $1`, order); s != "1|true" {
		t.Fatalf("order items of store 1 = %q", s)
	}
	if s := sqlStr(t, pool, `SELECT jsonb_array_length(money->'debt_entries')::text FROM admin_deletions WHERE target_id = $1`, s2); s != "1" {
		t.Fatalf("archived debts = %q", s)
	}
}
