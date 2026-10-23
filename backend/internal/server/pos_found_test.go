package server_test

import (
	"context"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// Касса: штрихкода нет ни в магазине, ни в Super Market — касса нашла его в
// каталоге ИКПУ (tasnif) или Open Food Facts, кассир подтвердил «Это он».
func TestPOSFoundGoods(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	drinks := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Напитки"}), 201, "category").str("id")
	var pcs string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		if u["short_name"] == "шт" {
			pcs = u["id"].(string)
		}
	}
	// Товар общего каталога с ИКПУ того же раздела — по нему найдётся категория.
	fanta := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
		"name": "Fanta 1 л", "category_id": drinks, "unit_id": pcs,
	}), 201, "fanta").str("id")
	if _, err := pool.Exec(context.Background(), `UPDATE products SET attributes = '{"ikpu": "02202002001010001"}' WHERE id = $1`, fanta); err != nil {
		t.Fatal(err)
	}
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	var owner string
	for _, e := range a.expect(a.do("GET", "/store/employees", tok, nil), 200, "employees").items() {
		owner = e["id"].(string)
	}
	a.expect(a.do("PUT", "/store/pos/pins/"+owner, tok, map[string]any{"pin": "9999"}), 200, "owner pin")
	role := a.expect(a.do("POST", "/store/roles", tok, map[string]any{"name": "Кассир", "permissions": []string{identity.PermSalesPOS}}), 201, "role").str("id")
	cashier := a.expect(a.do("POST", "/store/employees", tok, map[string]any{
		"phone": "+998900000006", "full_name": "Дилноза", "role_id": role, "store_ids": []string{store},
	}), 201, "cashier").str("id")
	a.expect(a.do("PUT", "/store/pos/pins/"+cashier, tok, map[string]any{"pin": "1234"}), 200, "cashier pin")
	dev := a.expect(a.do("POST", "/store/pos/devices", tok, map[string]any{"store_id": store, "name": "Касса 1"}), 201, "device")
	dt := a.expect(a.do("POST", "/pos/activate", "", map[string]any{"code": dev.str("activation_code")}), 200, "activate").str("token")
	ver := a.expect(posDo(a, "GET", "/pos/catalog", dt, "", nil), 200, "catalog").str("version")

	coke := map[string]any{
		"mxikCode": "02202002001010021", "mxikName": "Безалкогольные напитки (газированные и негазированные): COCA-COLA, сладкий, стеклянная бутылка 0,25 л.",
		"groupCode": "022", "classCode": "02202", "groupName": "Напитки", "className": "Воды",
		"positionName": "Безалкогольные напитки", "subPositionName": "", "brandName": "COCA-COLA",
		"attributeName": "сладкий, стеклянная бутылка 0,25 л", "internationalCode": "4780069000017", "label": 0,
	}
	wine := map[string]any{"mxikCode": "02204001001000000", "mxikName": "Вино", "classCode": "02204", "internationalCode": "4780069000017", "label": 0}
	off := map[string]any{"product_name": "coca cola 0.25 l", "brands": "Coca-Cola", "quantity": "0.25 l", "image": "https://images.openfoodfacts.org/coke.jpg"}

	// Предпросмотр: запись tasnif (вино отброшено), фото — из Open Food Facts.
	pv := a.expect(posDo(a, "POST", "/pos/products/found/preview", dt, cashier, map[string]any{
		"barcode": "4780069000017", "tasnif": []any{wine, coke}, "off": off,
	}), 200, "preview").items()
	if len(pv) != 1 || pv[0]["source"] != "tasnif" || pv[0]["index"] != float64(1) || pv[0]["ikpu"] != "02202002001010021" ||
		pv[0]["image"] != "https://images.openfoodfacts.org/coke.jpg" || pv[0]["name"] == "" {
		t.Fatalf("preview = %v", pv)
	}
	// Только Open Food Facts.
	nutella := map[string]any{"product_name": "Nutella", "brands": "Nutella, Ferrero", "quantity": "350 g"}
	pv = a.expect(posDo(a, "POST", "/pos/products/found/preview", dt, cashier, map[string]any{"barcode": "3017620422003", "off": nutella}), 200, "preview off").items()
	if len(pv) != 1 || pv[0]["source"] != "off" || pv[0]["name"] != "Nutella 350 г" || pv[0]["ikpu"] != "" {
		t.Fatalf("preview off = %v", pv)
	}
	a.expect(a.do("POST", "/pos/products/found/preview", tok, map[string]any{"barcode": "3017620422003"}), 401, "preview from panel")

	// Кассир без права «Установка цен» — нельзя (на кассе — ПИН старшего).
	add := map[string]any{"barcode": "4780069000017", "source": "tasnif", "tasnif": coke, "off": off, "name": "Coca-Cola 0,25 л стекло", "price": 6000}
	a.expect(posDo(a, "POST", "/pos/products/found", dt, cashier, add), 403, "add without price right")
	a.expect(posDo(a, "POST", "/pos/products/found", dt, owner, map[string]any{"barcode": "4780069000017", "source": "tasnif", "tasnif": wine, "price": 6000}), 400, "alcohol")
	r := a.expect(posDo(a, "POST", "/pos/products/found", dt, owner, add), 201, "add tasnif")
	p := r.Body["product"].(map[string]any)
	if r.Body["created"] != true || p["name"] != "Coca-Cola 0,25 л стекло" || p["price"] != "6000.00" || p["ikpu"] != "02202002001010021" ||
		p["active"] != true || p["image"] != "https://images.openfoodfacts.org/coke.jpg" || p["barcodes"].([]any)[0] != "4780069000017" {
		t.Fatalf("add tasnif = %v", r.Body)
	}
	var net *string
	var cat string
	if err := pool.QueryRow(context.Background(), `SELECT network_id::text, category_id::text FROM products WHERE id = $1`, p["id"]).Scan(&net, &cat); err != nil {
		t.Fatal(err)
	}
	if net != nil || cat != drinks {
		t.Fatalf("tasnif product: network %v, category %s", net, cat)
	}
	// Второй раз (другая касса успела) — тот же товар, без нового.
	if r2 := a.expect(posDo(a, "POST", "/pos/products/found", dt, owner, add), 201, "add again"); r2.Body["created"] != false ||
		r2.Body["product"].(map[string]any)["id"] != p["id"] {
		t.Fatalf("add again = %v", r2.Body)
	}
	// Open Food Facts: свой товар сети на модерации, без ИКПУ.
	r = a.expect(posDo(a, "POST", "/pos/products/found", dt, owner, map[string]any{
		"barcode": "3017620422003", "source": "off", "off": nutella, "price": 52000,
	}), 201, "add off")
	p2 := r.Body["product"].(map[string]any)
	if p2["name"] != "Nutella 350 г" || p2["price"] != "52000.00" || p2["ikpu"] != "" || p2["active"] != true {
		t.Fatalf("add off = %v", r.Body)
	}
	var status string
	if err := pool.QueryRow(context.Background(), `SELECT network_id::text, moderation_status FROM products WHERE id = $1`, p2["id"]).Scan(&net, &status); err != nil {
		t.Fatal(err)
	}
	if net == nil || status != "pending" {
		t.Fatalf("off product: network %v, status %s", net, status)
	}
	// Оба товара — в каталоге кассы (изменения) и в «Мои товары».
	got := map[string]bool{}
	for _, x := range a.expect(posDo(a, "GET", "/pos/catalog?since="+ver, dt, "", nil), 200, "delta").Body["products"].([]any) {
		got[x.(map[string]any)["id"].(string)] = true
	}
	if !got[p["id"].(string)] || !got[p2["id"].(string)] {
		t.Fatalf("delta = %v", got)
	}
	// Штрихкод чужого своего товара другой сети — конфликт.
	a.expect(posDo(a, "POST", "/pos/products/found", dt, owner, map[string]any{"barcode": "460", "source": "off", "off": nutella, "price": 1}), 400, "short barcode")
}
