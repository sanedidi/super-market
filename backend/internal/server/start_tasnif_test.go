package server_test

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// fakeCategoryAI — ИИ-сервис (протокол OpenAI) для подбора категории и
// перевода названия: на перевод отвечает translate, на остальное — category.
type fakeCategoryAI struct {
	mu        sync.Mutex
	category  string
	translate string
	calls     int
}

func (f *fakeCategoryAI) set(category, translate string) {
	f.mu.Lock()
	f.category, f.translate = category, translate
	f.mu.Unlock()
}

func (f *fakeCategoryAI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	switch {
	case r.Method == "GET" && r.URL.Path == "/v1/models":
		_, _ = w.Write([]byte(`{"data":[{"id":"gpt-4o"}]}`))
	case r.Method == "POST" && r.URL.Path == "/v1/chat/completions":
		b, _ := io.ReadAll(r.Body)
		f.calls++
		reply := f.category
		if strings.Contains(string(b), "Translate every item") {
			reply = f.translate
		}
		out, _ := json.Marshal(map[string]any{"choices": []any{map[string]any{"message": map[string]any{"content": reply}}},
			"usage": map[string]any{"prompt_tokens": 900, "completion_tokens": 100}})
		_, _ = w.Write(out)
	default:
		w.WriteHeader(404)
	}
}

// Записи tasnif.soliq.uz в том виде, в каком их присылает браузер магазина.
func tasnifItem(ikpu, barcode, brand, attr, sub string) map[string]any {
	return map[string]any{"mxikCode": ikpu, "mxikName": sub + ": " + brand + ", " + attr, "groupCode": ikpu[:3], "classCode": ikpu[:5],
		"groupName": "ГРУППА", "className": "Класс", "positionName": "Позиция", "subPositionName": sub,
		"brandName": brand, "attributeName": attr, "internationalCode": barcode, "label": 0}
}

func TestTasnifName(t *testing.T) {
	cases := []struct {
		it   catalog.TasnifItem
		want string
	}{
		{catalog.TasnifItem{BrandName: "COCA-COLA", AttributeName: "сладкий, стеклянная бутылка 0,25 л", SubPositionName: "Безалкогольные напитки (газированные и негазированные)"},
			"Безалкогольные напитки Coca-Cola, сладкий, стеклянная бутылка 0,25 л"},
		{catalog.TasnifItem{BrandName: "Hochland", AttributeName: "55% сливочный 200г", SubPositionName: "Сыры (всех видов)"},
			"Сыры Hochland, 55% сливочный 200г"},
		{catalog.TasnifItem{BrandName: "Pampers", AttributeName: "Active Baby Dry, размер 3, 14 шт", SubPositionName: "Подгузники"},
			"Подгузники Pampers, Active Baby Dry, размер 3, 14 шт"},
		{catalog.TasnifItem{BrandName: "Nutella", AttributeName: "Nutella паста ореховая 350 г", SubPositionName: "Пасты шоколадные"},
			"Nutella паста ореховая 350 г"},
		{catalog.TasnifItem{BrandName: "Musaffo", AttributeName: "МОЛОКО ПАСТЕРИЗОВАННОЕ 3,2% 1 Л", SubPositionName: "Молоко"},
			"Musaffo, молоко пастеризованное 3,2% 1 л"},
		{catalog.TasnifItem{MxikName: "Хлеб пшеничный", SubPositionName: "Хлеб"}, "Хлеб пшеничный"},
	}
	for _, c := range cases {
		if got := c.it.Name(); got != c.want {
			t.Errorf("Name(%q, %q) = %q, want %q", c.it.BrandName, c.it.AttributeName, got, c.want)
		}
	}
	if !(catalog.TasnifItem{MxikCode: "02204001001001001"}).Alcohol() || (catalog.TasnifItem{MxikCode: "02202002001010021"}).Alcohol() {
		t.Error("alcohol by class")
	}
}

// TestStartTasnif — товара нет в центральной базе: магазин находит его в
// каталоге ИКПУ и добавляет. Категория — по коду ИКПУ, иначе — предложение
// Super Market (из базы или новая), которое магазин подтверждает.
func TestStartTasnif(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	fai := &fakeCategoryAI{}
	aisrv := httptest.NewServer(fai)
	t.Cleanup(aisrv.Close)

	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	server.InvoicesSync = true
	t.Cleanup(func() { server.InvoicesSync = false })
	app, err := server.Build(ctx, cfg, pool, &fakeTelegram{}, quietLog())
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app.Handler)
	t.Cleanup(srv.Close)
	a := api{t: t, srv: srv, pool: pool}
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	ownerTok, storeID := setupNetwork(t, a, adminTok, "+998900000002")

	// Общий каталог: сыры из ИКПУ (позиция 00406001) и раздел «Сладости».
	a.expect(a.do("POST", "/admin/catalog-import", adminTok, map[string]any{"source": "tasnif", "items": []map[string]any{
		{"barcode": "4607004890999", "name": "Сыр Hochland, плавленый 100 г", "brand": "Hochland", "category": []string{"Молочные продукты", "Сыры"}, "ikpu": "00406001001202099"},
	}}), 200, "import")
	sweets := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Сладости", "name_uz": "Shirinliklar"}), 201, "sweets").str("id")
	choco := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Шоколад и конфеты", "parent_id": sweets}), 201, "choco").str("id")

	cheese := tasnifItem("00406001001202011", "4607004890147", "Hochland", "55% сливочный 200г", "Сыры (всех видов)")
	known := tasnifItem("00406001001202099", "4607004890999", "Hochland", "плавленый 100 г", "Сыры (всех видов)")
	vodka := tasnifItem("02208001001001001", "4780000000999", "Vodka", "0,5 л", "Водка")
	nutella := tasnifItem("01806003001003002", "3017620425035", "Nutella", "паста ореховая с какао 350 г", "Шоколадные пасты")

	// Варианты: алкоголь отброшен, уже имеющийся в базе — с product_id.
	pv := a.expect(a.do("POST", "/store/start/tasnif/preview", ownerTok, map[string]any{"store_id": storeID,
		"items": []any{cheese, vodka, known}}), 200, "preview").items()
	if len(pv) != 2 || pv[0]["index"] != float64(0) || pv[0]["product_id"] != nil || pv[0]["name"] != "Сыры Hochland, 55% сливочный 200г" ||
		pv[1]["index"] != float64(2) || pv[1]["product_id"] == nil || pv[1]["added"] != false {
		t.Fatalf("preview = %v", pv)
	}

	// Категория по коду ИКПУ — товар создаётся в общем каталоге и встаёт в «Мои товары».
	r := a.expect(a.do("POST", "/store/start/tasnif", ownerTok, map[string]any{"store_id": storeID, "item": cheese,
		"image": "https://media.example/cheese.jpg"}), 200, "add cheese")
	line, _ := r.Body["line"].(map[string]any)
	if r.str("status") != "added" || r.Body["created"] != true || line["source"] != "tasnif" || line["barcode"] != "4607004890147" {
		t.Fatalf("add cheese = %v", r.Body)
	}
	var cat, ikpu string
	var nw *string
	var images []string
	if err := pool.QueryRow(ctx, `SELECT c.name, p.attributes->>'ikpu', p.network_id, p.images FROM products p JOIN categories c ON c.id = p.category_id WHERE p.id = $1`,
		r.str("product_id")).Scan(&cat, &ikpu, &nw, &images); err != nil || cat != "Сыры" || ikpu != "00406001001202011" || nw != nil || len(images) != 1 {
		t.Fatalf("cheese product: %s %s %v %v %v", cat, ikpu, nw, images, err)
	}
	// Второй раз — «товар уже добавлен».
	a.expect(a.do("POST", "/store/start/tasnif", ownerTok, map[string]any{"store_id": storeID, "item": cheese}), 409, "again")
	// Уже имеющийся в базе — добавляется он, новый не создаётся.
	r = a.expect(a.do("POST", "/store/start/tasnif", ownerTok, map[string]any{"store_id": storeID, "item": known}), 200, "add known")
	if r.Body["created"] != false || r.str("product_id") != pv[1]["product_id"] {
		t.Fatalf("add known = %v", r.Body)
	}
	a.expect(a.do("POST", "/store/start/tasnif", ownerTok, map[string]any{"store_id": storeID, "item": vodka}), 400, "alcohol")

	// Категорию не определить, ИИ не подключён — магазин выбирает сам.
	r = a.expect(a.do("POST", "/store/start/tasnif", ownerTok, map[string]any{"store_id": storeID, "item": nutella}), 200, "need category")
	if r.str("status") != "need_category" || r.Body["suggestion"] != nil || r.Body["product_id"] != nil {
		t.Fatalf("need category = %v", r.Body)
	}

	// ИИ подключён: подходящей нет — Super Market предлагает новую подкатегорию в «Сладостях».
	a.expect(a.do("PUT", "/admin/ai", adminTok, map[string]any{"provider": "openai", "base_url": aisrv.URL + "/v1", "api_key": "sk-cat", "model": "gpt-4o"}), 200, "ai on")
	fai.set(`{"match":"","alternatives":["`+choco+`","нет-такого"],"new":{"parent_id":"`+sweets+`","name":"Шоколадные пасты","name_uz":"Shokoladli pastalar"},
		"name_uz":"Nutella yongʻoqli pastasi, 350 g"}`, `{"texts":["x"]}`)
	r = a.expect(a.do("POST", "/store/start/tasnif", ownerTok, map[string]any{"store_id": storeID, "item": nutella}), 200, "suggest new")
	sg, _ := r.Body["suggestion"].(map[string]any)
	nc, _ := sg["new"].(map[string]any)
	alts, _ := sg["alternatives"].([]any)
	if r.str("status") != "need_category" || sg["category"] != nil || nc["parent_id"] != sweets || nc["parent_name"] != "Сладости" ||
		nc["name"] != "Шоколадные пасты" || len(alts) != 1 || sg["name_uz"] != "Nutella yongʻoqli pastasi, 350 g" {
		t.Fatalf("suggest new = %v", r.Body)
	}
	// Подтвердили — категория создана, товар добавлен с узбекским названием.
	r = a.expect(a.do("POST", "/store/start/tasnif", ownerTok, map[string]any{"store_id": storeID, "item": nutella,
		"new_category": nc, "name_uz": sg["name_uz"]}), 200, "add with new category")
	var parent *string
	var nameUz string
	if err := pool.QueryRow(ctx, `SELECT c.name, c.parent_id::text, p.name_uz FROM products p JOIN categories c ON c.id = p.category_id WHERE p.id = $1`,
		r.str("product_id")).Scan(&cat, &parent, &nameUz); err != nil || cat != "Шоколадные пасты" || parent == nil || *parent != sweets || nameUz != "Nutella yongʻoqli pastasi, 350 g" {
		t.Fatalf("nutella: %s %v %s %v", cat, parent, nameUz, err)
	}

	// Товар той же позиции ИКПУ уже знает категорию — без вопросов.
	r = a.expect(a.do("POST", "/store/start/tasnif", ownerTok, map[string]any{"store_id": storeID,
		"item": tasnifItem("01806003001003005", "8000500000017", "Nutella", "паста ореховая 630 г", "Шоколадные пасты")}), 200, "same position")
	if r.str("status") != "added" {
		t.Fatalf("same position = %v", r.Body)
	}
	// Предложение «новой», которая уже есть, — это совпадение; без перевода
	// в предложении название переводится после добавления.
	jam := tasnifItem("01806009001009001", "4600000000017", "Mr.Ricco", "шоколадный крем 300 г", "Шоколадные пасты")
	fai.set(`{"match":"","new":{"parent_id":"`+sweets+`","name":"шоколадные пасты","name_uz":""}}`, `{"texts":["Mr.Ricco shokoladli krem, 300 g"]}`)
	r = a.expect(a.do("POST", "/store/start/tasnif", ownerTok, map[string]any{"store_id": storeID, "item": jam}), 200, "suggest existing")
	sg, _ = r.Body["suggestion"].(map[string]any)
	got, _ := sg["category"].(map[string]any)
	if sg["new"] != nil || got["name"] != "Шоколадные пасты" || got["section"] != "Сладости" {
		t.Fatalf("suggest existing = %v", r.Body)
	}
	a.expect(a.do("POST", "/store/start/tasnif", ownerTok, map[string]any{"store_id": storeID, "item": jam, "category_id": got["id"], "unit_id": got["id"]}), 400, "bad unit")
	var kg string
	if err := pool.QueryRow(ctx, `SELECT id FROM units WHERE short_name = 'кг'`).Scan(&kg); err != nil {
		t.Fatal(err)
	}
	r = a.expect(a.do("POST", "/store/start/tasnif", ownerTok, map[string]any{"store_id": storeID, "item": jam, "category_id": got["id"], "unit_id": kg}), 200, "add jam")
	if r.str("line", "unit_short") != "кг" {
		t.Fatalf("jam unit = %v", r.Body["line"])
	}
	if err := pool.QueryRow(ctx, `SELECT name_uz FROM products WHERE id = $1`, r.str("product_id")).Scan(&nameUz); err != nil || nameUz != "Mr.Ricco shokoladli krem, 300 g" {
		t.Fatalf("jam name_uz = %q %v", nameUz, err)
	}
	var usage int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM ai_usage WHERE kind = 'category' AND store_id = $1`, storeID).Scan(&usage); err != nil || usage != 2 {
		t.Fatalf("category usage = %d %v", usage, err)
	}

	// Сотрудник без права на каталог новый товар не создаёт.
	role := a.expect(a.do("POST", "/store/roles", ownerTok, map[string]any{"name": "Кладовщик", "permissions": []string{identity.PermInventoryManage}}), 201, "role")
	a.expect(a.do("POST", "/store/employees", ownerTok, map[string]any{
		"phone": "+998900000009", "full_name": "Кладовщик", "role_id": role.str("id"), "store_ids": []string{storeID},
	}), 201, "clerk")
	clerk, _ := a.login("+998900000009", identity.AppStore)
	other := tasnifItem("00406001001202012", "4607004890185", "Hochland", "55% с грибами 200г", "Сыры (всех видов)")
	a.expect(a.do("POST", "/store/start/tasnif", clerk, map[string]any{"store_id": storeID, "item": other}), 403, "clerk creates")
	a.expect(a.do("POST", "/store/start/tasnif/preview", clerk, map[string]any{"store_id": storeID, "items": []any{other}}), 200, "clerk preview")
}
