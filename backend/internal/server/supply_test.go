package server_test

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// setupDistributor — сеть-дистрибьютор с точкой (складом) рядом с координатами.
func setupDistributor(t *testing.T, a api, adminTok, ownerPhone string, lat, lng float64) (tok, pointID, whID string) {
	t.Helper()
	a.expect(a.do("POST", "/admin/networks", adminTok, map[string]string{
		"name": "Hydrolife Eco", "kind": "distributor", "owner_phone": ownerPhone, "owner_name": "Дистрибьютор",
	}), 201, "create distributor")
	tok, _ = a.login(ownerPhone, identity.AppStore)
	pt := a.expect(a.do("POST", "/store/stores", tok, map[string]any{"name": "Склад Hydrolife", "lat": lat, "lng": lng, "phone": "+998901112233"}), 201, "point")
	a.expect(a.do("POST", "/store/stores", tok, map[string]any{"name": "Второй склад"}), 409, "distributor has one point")
	whs := a.expect(a.do("GET", "/store/warehouses?store_id="+pt.str("id"), tok, nil), 200, "warehouses").items()
	return tok, pt.str("id"), whs[0]["id"].(string)
}

func jsonOf(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

// TestSupplyFlow — дистрибьютор и магазин: связь по коду, заказ, расход →
// приход у магазина, расхождение, «кому чего не хватает», запрос и отключение.
func TestSupplyFlow(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, sugar := catalogBasics(t, a, adminTok)

	// Магазин (сеть из двух магазинов) рядом с дистрибьютором.
	a.expect(a.do("POST", "/admin/networks", adminTok, map[string]string{
		"name": "Baraka", "kind": "chain", "owner_phone": "+998900000002", "owner_name": "Владелец",
	}), 201, "create store network")
	storeTok, _ := a.login("+998900000002", identity.AppStore)
	store1 := a.expect(a.do("POST", "/store/stores", storeTok, map[string]any{"name": "Baraka Market", "lat": 41.30, "lng": 69.24, "phone": "+998901234567"}), 201, "store1").str("id")
	store2 := a.expect(a.do("POST", "/store/stores", storeTok, map[string]any{"name": "Baraka 2", "lat": 41.31, "lng": 69.25}), 201, "store2").str("id")
	storeWh := a.expect(a.do("GET", "/store/warehouses?store_id="+store1, storeTok, nil), 200, "store wh").items()[0]["id"].(string)

	distTok, point, distWh := setupDistributor(t, a, adminTok, "+998900000003", 41.305, 69.245)

	// Разделы не перепутать: магазину — поставщики, дистрибьютору — supply.
	a.expect(a.do("GET", "/store/supply/stores", storeTok, nil), 403, "store cannot use distributor api")
	a.expect(a.do("GET", "/store/suppliers?store_id="+point, distTok, nil), 403, "distributor cannot use store api")

	// Покупатели точку дистрибьютора не видят.
	near := a.expect(a.do("GET", "/client/stores/nearby?lat=41.305&lng=69.245", "", nil), 200, "nearby")
	if strings.Contains(jsonOf(near.Body), point) {
		t.Fatalf("distributor point visible to clients: %v", near.Body)
	}

	// Дистрибьютор: приход от производителя и отпускная цена.
	cp := a.expect(a.do("POST", "/store/finance/counterparties", distTok, map[string]any{"name": "Coca-Cola Bottlers"}), 201, "maker").str("id")
	inc := a.expect(a.do("POST", "/store/inventory/documents", distTok, map[string]any{
		"type": "income", "warehouse_id": distWh, "counterparty_id": cp,
		"items": []map[string]any{{"product_id": cola, "qty": 100, "price": 9800}},
	}), 201, "dist income")
	a.expect(a.do("POST", "/store/inventory/documents/"+inc.str("id")+"/post", distTok, nil), 200, "post dist income")
	pts := a.expect(a.do("GET", "/store/price-types", distTok, nil), 200, "price types").items()
	pd := a.expect(a.do("POST", "/store/price-documents", distTok, map[string]any{
		"price_type_id": pts[0]["id"], "items": []map[string]any{{"product_id": cola, "new_price": 11200}},
	}), 201, "price doc")
	a.expect(a.do("POST", "/store/price-documents/"+pd.str("id")+"/post", distTok, nil), 200, "post price doc")

	// Магазин рядом — не подключён, данных нет.
	stores := a.expect(a.do("GET", "/store/supply/stores", distTok, nil), 200, "dist stores").items()
	if len(stores) != 2 || stores[0]["status"] != "not_linked" {
		t.Fatalf("stores before link = %v", stores)
	}
	det := a.expect(a.do("GET", "/store/supply/stores/"+store1, distTok, nil), 200, "store detail")
	if det.str("status") != "not_linked" || det.str("phone") != "" {
		t.Fatalf("not linked detail = %v", det.Body)
	}
	a.expect(a.do("POST", "/store/supply/stores/"+store1+"/shipment", distTok, nil), 409, "shipment without link")

	// Договориться на месте: код → магазин вводит его.
	code := a.expect(a.do("POST", "/store/supply/stores/"+store1+"/code", distTok, nil), 201, "code")
	a.expect(a.do("POST", "/store/suppliers/connect", storeTok, map[string]any{"store_id": store1, "code": "0000x"}), 400, "bad code")
	a.expect(a.do("POST", "/store/suppliers/connect", storeTok, map[string]any{"store_id": store2, "code": code.str("code")}), 400, "code of other store")
	link := a.expect(a.do("POST", "/store/suppliers/connect", storeTok, map[string]any{"store_id": store1, "code": code.str("qr")}), 200, "connect")
	if link.str("status") != "active" {
		t.Fatalf("link = %v", link.Body)
	}
	a.expect(a.do("POST", "/store/suppliers/connect", storeTok, map[string]any{"store_id": store1, "code": code.str("code")}), 400, "code is single-use")

	det = a.expect(a.do("GET", "/store/supply/stores/"+store1, distTok, nil), 200, "store detail linked")
	if det.str("status") != "no_brand" || det.str("phone") == "" {
		t.Fatalf("linked detail = %v", det.Body)
	}
	if m := det.Body["missing"].([]any); len(m) != 1 {
		t.Fatalf("missing = %v", m)
	}

	// Магазин видит поставщика и его прайс.
	sup := a.expect(a.do("GET", "/store/suppliers?store_id="+store1, storeTok, nil), 200, "suppliers").items()
	if len(sup) != 1 || sup[0]["link_status"] != "active" || sup[0]["products_count"].(float64) != 1 {
		t.Fatalf("suppliers = %v", sup)
	}
	distID := sup[0]["id"].(string)
	cat := a.expect(a.do("GET", "/store/suppliers/"+distID+"/catalog?store_id="+store1, storeTok, nil), 200, "catalog").items()
	if len(cat) != 1 || cat[0]["price"] != "11200.00" || cat[0]["available"] != true || cat[0]["carried"] != false {
		t.Fatalf("catalog = %v", cat)
	}
	found := a.expect(a.do("GET", "/store/suppliers/search?store_id="+store2+"&q=coca", storeTok, nil), 200, "search").items()
	if len(found) != 1 || found[0]["matched"].(float64) != 1 || found[0]["phone"] != "" {
		t.Fatalf("search = %v", found)
	}

	// Заказ: сахара в прайсе нет.
	a.expect(a.do("POST", "/store/supplier-orders", storeTok, map[string]any{
		"store_id": store1, "distributor_id": distID, "items": []map[string]any{{"product_id": sugar, "qty": 2}},
	}), 400, "product not in price list")
	a.expect(a.do("POST", "/store/supplier-orders", storeTok, map[string]any{
		"store_id": store2, "distributor_id": distID, "items": []map[string]any{{"product_id": cola, "qty": 2}},
	}), 409, "order without link")
	ord := a.expect(a.do("POST", "/store/supplier-orders", storeTok, map[string]any{
		"store_id": store1, "distributor_id": distID, "deliver_by": "2030-01-01", "note": "до обеда",
		"items": []map[string]any{{"product_id": cola, "qty": 24}},
	}), 201, "order")
	if ord.str("status") != "new" || ord.str("total") != "268800.00" {
		t.Fatalf("order = %v", ord.Body)
	}
	orderID := ord.str("id")

	sum := a.expect(a.do("GET", "/store/supply/summary", distTok, nil), 200, "summary")
	if sum.Body["new_orders"].(float64) != 1 || sum.Body["linked_stores"].(float64) != 1 || sum.Body["no_brand_stores"].(float64) != 1 {
		t.Fatalf("summary = %v", sum.Body)
	}
	dOrd := a.expect(a.do("GET", "/store/supply/orders/"+orderID, distTok, nil), 200, "dist order")
	if it := dOrd.Body["items"].([]any)[0].(map[string]any); it["in_stock"] != "100.000" {
		t.Fatalf("dist order item = %v", it)
	}
	if it := a.expect(a.do("GET", "/store/supplier-orders/"+orderID, storeTok, nil), 200, "store order").Body["items"].([]any)[0].(map[string]any); it["in_stock"] != nil {
		t.Fatalf("store must not see distributor stock: %v", it)
	}

	// Отгрузим 20 из 24, принять → доставлен.
	a.expect(a.do("PATCH", "/store/supply/orders/"+orderID, distTok, map[string]any{
		"items": []map[string]any{{"product_id": cola, "ship_qty": 30}},
	}), 400, "ship more than ordered")
	a.expect(a.do("PATCH", "/store/supply/orders/"+orderID, distTok, map[string]any{
		"items": []map[string]any{{"product_id": cola, "ship_qty": 20}},
	}), 200, "ship qty")
	a.expect(a.do("POST", "/store/supply/orders/"+orderID+"/accept", distTok, nil), 200, "accept")
	a.expect(a.do("POST", "/store/supply/orders/"+orderID+"/accept", distTok, nil), 409, "accept twice")
	done := a.expect(a.do("POST", "/store/supply/orders/"+orderID+"/deliver", distTok, nil), 200, "deliver")
	if done.str("status") != "delivered" || done.str("shipment_id") == "" {
		t.Fatalf("delivered = %v", done.Body)
	}
	a.expect(a.do("POST", "/store/supplier-orders/"+orderID+"/cancel", storeTok, nil), 409, "cancel delivered")
	if q, _ := stockOf(t, a, distTok, distWh, cola); q != "80.000" {
		t.Fatalf("distributor stock = %s", q)
	}
	ship := a.expect(a.do("GET", "/store/inventory/documents/"+done.str("shipment_id"), distTok, nil), 200, "shipment")
	if ship.str("type") != "shipment" || ship.str("total") != "224000.00" || ship.str("to_store_id") != store1 {
		t.Fatalf("shipment = %v", ship.Body)
	}

	// У магазина — черновик прихода от дистрибьютора; принимаем 19 из 20.
	incs := a.expect(a.do("GET", "/store/inventory/documents?type=income&store_id="+store1, storeTok, nil), 200, "store incomes").items()
	if len(incs) != 1 || incs[0]["status"] != "draft" || incs[0]["source_shipment_id"] != done.str("shipment_id") || incs[0]["counterparty_name"] != "Hydrolife Eco" {
		t.Fatalf("store incomes = %v", incs)
	}
	storeInc := incs[0]["id"].(string)
	a.expect(a.do("PATCH", "/store/inventory/documents/"+storeInc, storeTok, map[string]any{
		"items": []map[string]any{{"product_id": cola, "qty": 19, "price": 11200}},
	}), 200, "store edits income")
	a.expect(a.do("POST", "/store/inventory/documents/"+storeInc+"/post", storeTok, nil), 200, "store posts income")
	if q, c := stockOf(t, a, storeTok, storeWh, cola); q != "19.000" || c != "11200.00" {
		t.Fatalf("store stock = %s @ %s", q, c)
	}
	ship = a.expect(a.do("GET", "/store/inventory/documents/"+done.str("shipment_id"), distTok, nil), 200, "shipment after receive")
	if ship.str("received_diff") != "-1.000" || ship.Body["received_at"] == nil {
		t.Fatalf("received = %v", ship.Body)
	}

	// Взаиморасчёты: магазин должен дистрибьютору, у дистрибьютора — долг магазина.
	for _, c := range a.expect(a.do("GET", "/store/finance/counterparties", distTok, nil), 200, "dist cps").items() {
		if c["name"] == "Baraka Market" && c["balance"] != "-224000.00" {
			t.Fatalf("distributor sees store balance %v", c["balance"])
		}
	}
	for _, c := range a.expect(a.do("GET", "/store/finance/counterparties", storeTok, nil), 200, "store cps").items() {
		if c["name"] == "Hydrolife Eco" && c["balance"] != "212800.00" {
			t.Fatalf("store owes distributor %v", c["balance"])
		}
	}

	// Продажи 10 шт в день (280 за 28 дней): 19 шт не хватит до поставки — «мало».
	if _, err := pool.Exec(t.Context(), `
		INSERT INTO stock_movements (network_id, warehouse_id, product_id, batch_id, qty, unit_cost, unit_cost_usd, doc_type, doc_id)
		SELECT b.network_id, b.warehouse_id, b.product_id, b.id, -280, b.unit_cost, 0, 'sale', gen_random_uuid()
		FROM batches b WHERE b.warehouse_id = $1 LIMIT 1`, storeWh); err != nil {
		t.Fatal(err)
	}
	det = a.expect(a.do("GET", "/store/supply/stores/"+store1, distTok, nil), 200, "detail with sales")
	if l := det.Body["lacking"].([]any); det.str("status") != "low" || len(l) != 1 || l[0].(map[string]any)["recommend"] != "71" || l[0].(map[string]any)["per_day"] != "10.0" {
		t.Fatalf("low = %v", det.Body)
	}

	// Магазин всё списал — у дистрибьютора «закончилось» и рекомендация.
	wo := a.expect(a.do("POST", "/store/inventory/documents", storeTok, map[string]any{
		"type": "write_off", "warehouse_id": storeWh, "reason": "Продано мимо кассы",
		"items": []map[string]any{{"product_id": cola, "qty": 19}},
	}), 201, "write off")
	a.expect(a.do("POST", "/store/inventory/documents/"+wo.str("id")+"/post", storeTok, nil), 200, "post write off")
	det = a.expect(a.do("GET", "/store/supply/stores/"+store1, distTok, nil), 200, "detail after write off")
	lacking := det.Body["lacking"].([]any)
	if det.str("status") != "out" || len(lacking) != 1 || lacking[0].(map[string]any)["recommend"] != "90" {
		t.Fatalf("lacking = %v", det.Body)
	}
	draft := a.expect(a.do("POST", "/store/supply/stores/"+store1+"/shipment", distTok, nil), 201, "shipment from recommendations")
	if draft.str("type") != "shipment" || draft.str("status") != "draft" || draft.Body["items_count"].(float64) != 1 {
		t.Fatalf("draft shipment = %v", draft.Body)
	}
	reorder := a.expect(a.do("GET", "/store/suppliers/reorder?store_id="+store1, storeTok, nil), 200, "reorder").items()
	if len(reorder) != 1 || reorder[0]["distributor_id"] != distID || len(reorder[0]["items"].([]any)) != 1 {
		t.Fatalf("reorder = %v", reorder)
	}

	// Ручной расход магазину без связи нельзя.
	a.expect(a.do("POST", "/store/inventory/documents", distTok, map[string]any{
		"type": "shipment", "warehouse_id": distWh, "to_store_id": store2,
		"items": []map[string]any{{"product_id": cola, "qty": 1, "price": 11200}},
	}), 409, "shipment to not linked store")
	a.expect(a.do("POST", "/store/inventory/documents", storeTok, map[string]any{
		"type": "shipment", "warehouse_id": storeWh, "to_store_id": store2,
		"items": []map[string]any{{"product_id": cola, "qty": 1, "price": 11200}},
	}), 400, "store cannot ship")

	// Запрос от дистрибьютора второму магазину → магазин принимает.
	req := a.expect(a.do("POST", "/store/supply/stores/"+store2+"/request", distTok, map[string]any{"message": "Возим воду, доставка 1–2 дня"}), 200, "request")
	if req.str("status") != "requested" {
		t.Fatalf("request = %v", req.Body)
	}
	a.expect(a.do("POST", "/store/supply/links/"+req.str("id")+"/accept", distTok, nil), 409, "distributor cannot accept own request")
	sup2 := a.expect(a.do("GET", "/store/suppliers?store_id="+store2, storeTok, nil), 200, "suppliers 2").items()
	if len(sup2) != 1 || sup2[0]["waits_for_me"] != true {
		t.Fatalf("suppliers 2 = %v", sup2)
	}
	a.expect(a.do("POST", "/store/suppliers/links/"+req.str("id")+"/accept", storeTok, nil), 200, "store accepts")

	// Запрос магазина при встречном запросе сразу подключает.
	a.expect(a.do("POST", "/store/suppliers/"+distID+"/disconnect", storeTok, map[string]any{"store_id": store2}), 204, "disconnect store2")
	a.expect(a.do("POST", "/store/suppliers/"+distID+"/request", storeTok, map[string]any{"store_id": store2}), 200, "store requests")
	both := a.expect(a.do("POST", "/store/supply/stores/"+store2+"/request", distTok, map[string]any{}), 200, "mutual request")
	if both.str("status") != "active" {
		t.Fatalf("mutual = %v", both.Body)
	}

	// Отключение отменяет незакрытые заказы и закрывает прайс.
	open := a.expect(a.do("POST", "/store/supplier-orders", storeTok, map[string]any{
		"store_id": store1, "distributor_id": distID, "items": []map[string]any{{"product_id": cola, "qty": 6}},
	}), 201, "open order")
	a.expect(a.do("POST", "/store/supply/stores/"+store1+"/disconnect", distTok, nil), 204, "distributor disconnects")
	if st := a.expect(a.do("GET", "/store/supplier-orders/"+open.str("id"), storeTok, nil), 200, "cancelled").str("status"); st != "cancelled" {
		t.Fatalf("open order after disconnect = %s", st)
	}
	a.expect(a.do("GET", "/store/suppliers/"+distID+"/catalog?store_id="+store1, storeTok, nil), 409, "catalog after disconnect")
	list := a.expect(a.do("GET", "/store/supplier-orders?store_id="+store1, storeTok, nil), 200, "store orders").items()
	if len(list) != 2 {
		t.Fatalf("store orders = %v", list)
	}
}
