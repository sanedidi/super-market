package server_test

import (
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// Весы и товары без штрихкода (Figma «Панель · Весы и товары без штрихкода»,
// «Касса · Весовой товар и товары без штрихкода»).
func TestScales(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, sugar := catalogBasics(t, a, adminTok)
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	colaP := a.expect(a.do("GET", "/admin/products/"+cola, adminTok, nil), 200, "cola")
	sugarP := a.expect(a.do("GET", "/admin/products/"+sugar, adminTok, nil), 200, "sugar")
	pcs, kg, cat := colaP.str("unit_id"), sugarP.str("unit_id"), colaP.str("category_id")
	bread := a.expect(a.do("POST", "/store/products", tok, map[string]any{
		"name": "Лепёшка тандырная", "category_id": cat, "unit_id": pcs, "base_price": 5000,
	}), 201, "own bread").str("id")
	persimmon := a.expect(a.do("POST", "/store/products", tok, map[string]any{
		"name": "Хурма", "category_id": cat, "unit_id": kg, "base_price": 22000,
	}), 201, "own persimmon").str("id")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
	doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "posting", "warehouse_id": wh,
		"items": []map[string]any{
			{"product_id": cola, "qty": 10, "price": 10000}, {"product_id": sugar, "qty": 38.4, "price": 8000},
			{"product_id": bread, "qty": 20, "price": 3000}, {"product_id": persimmon, "qty": 5, "price": 15000},
		},
	}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post posting")

	// Настройки: по умолчанию префикс 22, 5 цифр, вес в граммах; 20 весам не даём.
	set := a.expect(a.do("GET", "/store/scales/settings", tok, nil), 200, "scale settings")
	if set.str("prefix") != "22" || set.Body["item_digits"].(float64) != 5 || set.str("value") != "weight" || set.Body["enabled"] != false {
		t.Fatalf("default scale settings = %v", set.Body)
	}
	good := map[string]any{"enabled": true, "prefix": "22", "item_digits": 5, "value": "weight", "weight_step": 1}
	bad := map[string]any{"enabled": true, "prefix": "20", "item_digits": 5, "value": "weight", "weight_step": 1}
	a.expect(a.do("PUT", "/store/scales/settings", tok, bad), 400, "prefix 20 is for own barcodes")
	a.expect(a.do("PUT", "/store/scales/settings", tok, good), 200, "save scale settings")

	// «Как продаётся»: на развес — номер сам, следующий свободный; у товара общей
	// базы единицу не меняем; свой товар — шт ↔ кг.
	sm := a.expect(a.do("PUT", "/store/products/"+sugar+"/sell-mode", tok, map[string]any{"mode": "weight"}), 200, "sugar weight")
	if sm.str("mode") != "weight" || sm.Body["plu"].(float64) != 1 {
		t.Fatalf("sugar sell mode = %v", sm.Body)
	}
	a.expect(a.do("PUT", "/store/products/"+cola+"/sell-mode", tok, map[string]any{"mode": "weight"}), 409, "shared product unit")
	bm := a.expect(a.do("PUT", "/store/products/"+bread+"/sell-mode", tok, map[string]any{"mode": "weight", "plu": 15}), 200, "bread by weight")
	if bm.Body["plu"].(float64) != 15 || bm.str("unit") != "кг" {
		t.Fatalf("bread by weight = %v", bm.Body)
	}
	bm = a.expect(a.do("PUT", "/store/products/"+bread+"/sell-mode", tok, map[string]any{"mode": "piece"}), 200, "bread back to piece")
	if bm.Body["plu"] != nil || bm.str("unit") != "шт" {
		t.Fatalf("bread back to piece = %v", bm.Body)
	}

	// «На весах»: сахар №1 — «введите в весы»; хурма без номера; №15 у лепёшки снят — следующий 2.
	scales := func() (map[string]map[string]any, float64) {
		r := a.expect(a.do("GET", "/store/scales/products?store_id="+store, tok, nil), 200, "scale products")
		out := map[string]map[string]any{}
		for _, x := range r.items() {
			out[x["product_id"].(string)] = x
		}
		return out, r.Body["next_plu"].(float64)
	}
	list, next := scales()
	if list[sugar]["status"] != "new" || list[sugar]["stock"] != "38.400" || list[persimmon]["status"] != "no_plu" || next != 2 {
		t.Fatalf("scales = %v, next %v", list, next)
	}
	if _, ok := list[cola]; ok {
		t.Fatalf("piece product on scales: %v", list[cola])
	}
	a.expect(a.do("POST", "/store/scales/entered", tok, map[string]any{"store_id": store, "product_ids": []string{sugar}}), 200, "entered")
	if list, _ = scales(); list[sugar]["status"] != "entered" {
		t.Fatalf("sugar after entered = %v", list[sugar])
	}
	pts := a.expect(a.do("GET", "/store/price-types", tok, nil), 200, "price types").items()
	pd := a.expect(a.do("POST", "/store/price-documents", tok, map[string]any{
		"price_type_id": pts[0]["id"], "store_id": store, "items": []map[string]any{{"product_id": sugar, "new_price": 24000}},
	}), 201, "price doc")
	a.expect(a.do("POST", "/store/price-documents/"+pd.str("id")+"/post", tok, nil), 200, "post price")
	if list, _ = scales(); list[sugar]["status"] != "changed" || list[sugar]["price"] != "24000.00" || list[sugar]["price_at"] == nil {
		t.Fatalf("sugar after price change = %v", list[sugar])
	}

	// «Без штрихкода»: кола и лепёшка — штучные без заводского штрихкода.
	nb := a.expect(a.do("GET", "/store/scales/no-barcode?store_id="+store, tok, nil), 200, "no barcode").items()
	if len(nb) != 2 {
		t.Fatalf("no barcode = %v", nb)
	}
	cnt := a.expect(a.do("GET", "/store/scales/counts?store_id="+store, tok, nil), 200, "counts")
	if cnt.Body["scales"].(float64) != 2 || cnt.Body["no_barcode"].(float64) != 2 || cnt.Body["to_update"].(float64) != 1 {
		t.Fatalf("counts = %v", cnt.Body)
	}
	own := a.expect(a.do("POST", "/store/own-barcodes", tok, map[string]any{"product_ids": []string{bread, cola, bread}}), 200, "issue own").items()
	if len(own) != 2 || own[0]["barcode"] != "2000000000015" || own[1]["barcode"] != "2000000000022" || own[0]["new"] != true {
		t.Fatalf("own barcodes = %v", own)
	}
	again := a.expect(a.do("POST", "/store/own-barcodes", tok, map[string]any{"product_ids": []string{bread}}), 200, "issue again").items()
	if again[0]["barcode"] != "2000000000015" || again[0]["new"] != false {
		t.Fatalf("own barcode again = %v", again)
	}
	a.expect(a.do("POST", "/store/own-barcodes", tok, map[string]any{"product_ids": []string{sugar}}), 409, "weighted gets no own barcode")

	// Касса: свой штрихкод — в штрихкодах товара, формат наклейки — в настройках.
	dev := a.expect(a.do("POST", "/store/pos/devices", tok, map[string]any{"store_id": store, "name": "Касса 1"}), 201, "device")
	dt := a.expect(a.do("POST", "/pos/activate", "", map[string]any{"code": dev.str("activation_code")}), 200, "activate").str("token")
	catl := a.expect(posDo(a, "GET", "/pos/catalog", dt, "", nil), 200, "catalog")
	prods := map[string]map[string]any{}
	for _, x := range catl.Body["products"].([]any) {
		m := x.(map[string]any)
		prods[m["id"].(string)] = m
	}
	if bc := prods[bread]["barcodes"].([]any); len(bc) != 1 || bc[0] != "2000000000015" {
		t.Fatalf("bread on register = %v", prods[bread])
	}
	st := catl.Body["settings"].(map[string]any)
	if wp := st["weight_prefixes"].([]any); len(wp) != 1 || wp[0] != "22" {
		t.Fatalf("register weight prefixes = %v", st["weight_prefixes"])
	}
	if st["scale_item_digits"].(float64) != 5 || st["scale_value"] != "weight" || st["scale_weight_step"].(float64) != 1 {
		t.Fatalf("register settings = %v", st)
	}
	ver := catl.str("version")

	// К2: на наклейке №27 — кассир выбирает хурму, касса запоминает.
	var owner string
	for _, e := range a.expect(a.do("GET", "/store/employees", tok, nil), 200, "employees").items() {
		owner = e["id"].(string)
	}
	a.expect(posDo(a, "POST", "/pos/scales/plu", dt, "", map[string]any{"product_id": persimmon, "plu": 27}), 401, "no cashier")
	rp := a.expect(posDo(a, "POST", "/pos/scales/plu", dt, owner, map[string]any{"product_id": persimmon, "plu": 27}), 200, "remember plu")
	if rp.Body["plu"].(float64) != 27 {
		t.Fatalf("remembered = %v", rp.Body)
	}
	a.expect(posDo(a, "POST", "/pos/scales/plu", dt, owner, map[string]any{"product_id": sugar, "plu": 28}), 409, "sugar already has a number")
	a.expect(posDo(a, "POST", "/pos/scales/plu", dt, owner, map[string]any{"product_id": cola, "plu": 29}), 409, "piece product")
	a.expect(posDo(a, "POST", "/pos/scales/plu", dt, owner, map[string]any{"product_id": bread, "plu": 1}), 409, "piece bread")
	if list, _ = scales(); list[persimmon]["status"] != "entered" || list[persimmon]["from_pos"] != true {
		t.Fatalf("persimmon after register = %v", list[persimmon])
	}
	if c := a.expect(posDo(a, "GET", "/pos/catalog/changed?since="+ver, dt, "", nil), 200, "changed"); c.Body["changed"] != true {
		t.Fatalf("changed after remember = %v", c.Body)
	}
}
