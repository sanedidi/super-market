package server_test

import (
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// TestProductEdit — «Изменить товар» (Figma «SM Магазин · Изменить товар»,
// И1–И3): свой товар правится сразу, товар общей базы — исправлением на
// проверку супер-админу; «Убрать из «Моих товаров»» — только без остатка.
func TestProductEdit(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	ownerTok, storeID := setupNetwork(t, a, adminTok, "+998900000002")
	cat := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Замороженное"}), 201, "category").str("id")
	cat2 := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Сладости"}), 201, "category 2").str("id")
	units := map[string]string{}
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		units[u["short_name"].(string)] = u["id"].(string)
	}
	central := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{"name": "Замороженное манго в шоколаде Fruzo, 120 г", "category_id": cat,
		"unit_id": units["шт"], "base_price": 18000, "barcodes": []string{"4870207310152"}}), 201, "central").str("id")
	own := a.expect(a.do("POST", "/store/products", ownerTok, map[string]any{"name": "Сомса домашняя", "category_id": cat, "unit_id": units["шт"],
		"barcodes": []string{"2000000000015"}, "store_id": storeID}), 201, "own").str("id")

	// И2 · Товар общей базы: исправление — на проверку, только изменённое.
	sg := a.expect(a.do("POST", "/store/products/"+central+"/suggestion", ownerTok, map[string]any{"store_id": storeID,
		"name": "Манго в шоколаде замороженное Fruzo, 120 г", "barcodes": []string{"4870207310152"}, "category_id": cat2}), 201, "suggest")
	ch := sg.Body["changes"].(map[string]any)
	if sg.str("status") != "pending" || ch["name"] != "Манго в шоколаде замороженное Fruzo, 120 г" || ch["barcodes"] != nil || ch["category_id"] != cat2 || sg.Body["category_name"] != "Сладости" {
		t.Fatalf("suggestion = %v", sg.Body)
	}
	a.expect(a.do("POST", "/store/products/"+central+"/suggestion", ownerTok, map[string]any{"name": "Замороженное манго в шоколаде Fruzo, 120 г"}), 400, "nothing changed")
	a.expect(a.do("POST", "/store/products/"+central+"/suggestion", ownerTok, map[string]any{"barcodes": []string{"4870207310152", "2000000000015"}}), 409, "barcode of another product")
	// Новое исправление заменяет прежнее, ещё не проверенное.
	a.expect(a.do("POST", "/store/products/"+central+"/suggestion", ownerTok, map[string]any{"name": "Манго в шоколаде замороженное Fruzo, 120 г", "category_id": cat2, "unit_id": units["кг"]}), 201, "suggest again")
	list := a.expect(a.do("GET", "/store/products/"+central+"/suggestions", ownerTok, nil), 200, "store list").items()
	if len(list) != 1 || list[0]["status"] != "pending" {
		t.Fatalf("store suggestions = %v", list)
	}

	// И1 · Свой товар — сразу, исправление не нужно.
	a.expect(a.do("POST", "/store/products/"+own+"/suggestion", ownerTok, map[string]any{"name": "Сомса"}), 409, "own product")
	if p := a.expect(a.do("PATCH", "/store/products/"+own, ownerTok, map[string]any{"name": "Сомса с мясом", "barcodes": []string{"2000000000015", "2000000000022"}}), 200, "own edit"); p.str("name") != "Сомса с мясом" {
		t.Fatalf("own edit = %v", p.Body)
	}

	// Супер-админ: «Исправления от магазинов» — принять.
	adm := a.expect(a.do("GET", "/admin/product-suggestions", adminTok, nil), 200, "admin list").items()
	if len(adm) != 1 || adm[0]["current"].(map[string]any)["name"] != "Замороженное манго в шоколаде Fruzo, 120 г" || adm[0]["current_category_name"] != "Замороженное" {
		t.Fatalf("admin list = %v", adm)
	}
	done := a.expect(a.do("POST", "/admin/product-suggestions/"+adm[0]["id"].(string)+"/approve", adminTok, map[string]any{}), 200, "approve")
	if done.str("status") != "approved" {
		t.Fatalf("approve = %v", done.Body)
	}
	p := a.expect(a.do("GET", "/admin/products/"+central, adminTok, nil), 200, "product")
	if p.str("name_ru") != "Манго в шоколаде замороженное Fruzo, 120 г" || p.str("category_id") != cat2 || p.str("unit_id") != units["кг"] {
		t.Fatalf("product after approve = %v", p.Body)
	}
	a.expect(a.do("POST", "/admin/product-suggestions/"+adm[0]["id"].(string)+"/reject", adminTok, map[string]any{"reason": "поздно"}), 409, "already reviewed")
	// Отклонить — с причиной.
	sg = a.expect(a.do("POST", "/store/products/"+central+"/suggestion", ownerTok, map[string]any{"name_uz": "Mango"}), 201, "suggest uz")
	rej := a.expect(a.do("POST", "/admin/product-suggestions/"+sg.str("id")+"/reject", adminTok, map[string]any{"reason": "Название с упаковки"}), 200, "reject")
	if rej.str("status") != "rejected" || rej.str("reject_reason") != "Название с упаковки" {
		t.Fatalf("reject = %v", rej.Body)
	}

	// «Убрать из «Моих товаров»»: остатка нет — можно; второй раз — нечего убирать.
	a.expect(a.do("DELETE", "/store/inventory/my-products/"+own+"?store_id="+storeID, ownerTok, nil), 200, "remove")
	a.expect(a.do("DELETE", "/store/inventory/my-products/"+own+"?store_id="+storeID, ownerTok, nil), 404, "remove again")
}
