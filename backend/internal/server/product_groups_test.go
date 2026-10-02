package server_test

import (
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// Дерево «бренд → категория → товар» в панелях.
func TestProductGroups(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)

	cola := a.expect(a.do("POST", "/admin/catalog/brands", adminTok, map[string]any{"name": "Coca-Cola"}), 201, "brand").str("id")
	aqua := a.expect(a.do("POST", "/admin/catalog/brands", adminTok, map[string]any{"name": "Aqua"}), 201, "brand").str("id")
	drinks := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Напитки"}), 201, "category").str("id")
	soda := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Газировка", "parent_id": drinks}), 201, "sub").str("id")
	bread := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Хлеб"}), 201, "category").str("id")
	var pcs string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		if u["short_name"] == "шт" {
			pcs = u["id"].(string)
		}
	}
	add := func(name string, brand *string, cat string) {
		t.Helper()
		body := map[string]any{"name": name, "category_id": cat, "unit_id": pcs, "base_price": 1000}
		if brand != nil {
			body["brand_id"] = *brand
		}
		a.expect(a.do("POST", "/admin/products", adminTok, body), 201, "product "+name)
	}
	add("Cola 1 л", &cola, soda)
	add("Cola 0,5 л", &cola, soda)
	add("Cola сок", &cola, drinks)
	add("Aqua 1 л", &aqua, drinks)
	add("Лепёшка", nil, bread)

	ownerTok, store := setupNetwork(t, a, adminTok, "+998900000002")
	a.expect(a.do("POST", "/store/products", ownerTok, map[string]any{
		"name": "Своя кола", "brand_id": cola, "category_id": soda, "unit_id": pcs, "base_price": "900",
	}), 201, "own product")

	g := a.expect(a.do("GET", "/admin/products/groups", adminTok, nil), 200, "admin groups")
	brands := g.Body["brands"].([]any)
	if len(brands) != 3 || g.Body["total"].(float64) != 6 {
		t.Fatalf("groups = %v", g.Body)
	}
	first := brands[0].(map[string]any)
	last := brands[2].(map[string]any)
	if first["brand_name"] != "Aqua" || last["brand_id"] != nil || last["brand_name"] != "Без бренда" {
		t.Fatalf("order = %v", brands)
	}
	colaGroup := brands[1].(map[string]any)
	cats := colaGroup["categories"].([]any)
	if colaGroup["count"].(float64) != 4 || colaGroup["pending"].(float64) != 1 || len(cats) != 2 {
		t.Fatalf("cola = %v", colaGroup)
	}

	// Поиск сужает дерево.
	g = a.expect(a.do("GET", "/admin/products/groups?q=лепёш", adminTok, nil), 200, "search groups")
	if len(g.Body["brands"].([]any)) != 1 {
		t.Fatalf("search = %v", g.Body)
	}

	// Товары группы: бренд + точная категория (без подкатегорий).
	items := a.expect(a.do("GET", "/admin/products?brand_id="+cola+"&leaf_category_id="+soda+"&sort=name", adminTok, nil), 200, "group items").items()
	if len(items) != 3 || items[0]["name"] != "Cola 0,5 л" {
		t.Fatalf("items = %v", items)
	}
	if n := len(a.expect(a.do("GET", "/admin/products?brand_id="+cola+"&leaf_category_id="+drinks, adminTok, nil), 200, "leaf").items()); n != 1 {
		t.Fatalf("leaf drinks = %d", n)
	}
	if n := len(a.expect(a.do("GET", "/admin/products?brand_id=none", adminTok, nil), 200, "no brand").items()); n != 1 {
		t.Fatalf("no brand = %d", n)
	}
	a.expect(a.do("GET", "/admin/products?brand_id=x", adminTok, nil), 400, "bad brand")

	// Магазин: свой товар на модерации считается в pending, цены — в списке группы.
	sg := a.expect(a.do("GET", "/store/products/groups", ownerTok, nil), 200, "store groups")
	if sg.Body["total"].(float64) != 6 || sg.Body["brands"].([]any)[1].(map[string]any)["pending"].(float64) != 1 {
		t.Fatalf("store groups = %v", sg.Body)
	}
	si := a.expect(a.do("GET", "/store/products?store_id="+store+"&brand_id=none", ownerTok, nil), 200, "store group items").items()
	if len(si) != 1 || si[0]["price"] != "1000.00" {
		t.Fatalf("store items = %v", si)
	}
	otherTok, _ := setupNetwork(t, a, adminTok, "+998900000003")
	if total := a.expect(a.do("GET", "/store/products/groups", otherTok, nil), 200, "other").Body["total"].(float64); total != 5 {
		t.Fatalf("other network sees %v", total)
	}
}
