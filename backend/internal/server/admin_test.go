package server_test

import (
	"fmt"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
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
