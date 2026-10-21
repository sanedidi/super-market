package server_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// fakeTranslator — ИИ-сервис (протокол OpenAI), который «переводит» тексты
// по словарю; незнакомое — с префиксом "uz:".
type fakeTranslator struct {
	mu    sync.Mutex
	key   string
	dict  map[string]string
	calls int
	texts int
}

func (f *fakeTranslator) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if r.Header.Get("Authorization") != "Bearer "+f.key {
		w.WriteHeader(401)
		return
	}
	if r.Method != "POST" || r.URL.Path != "/v1/chat/completions" {
		w.WriteHeader(404)
		return
	}
	var body struct {
		Messages []struct {
			Content json.RawMessage `json:"content"`
		} `json:"messages"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	var parts []struct {
		Text string `json:"text"`
	}
	if len(body.Messages) < 2 || json.Unmarshal(body.Messages[1].Content, &parts) != nil || len(parts) == 0 {
		w.WriteHeader(400)
		return
	}
	prompt := parts[0].Text
	var in struct {
		Texts []string `json:"texts"`
	}
	if i := strings.Index(prompt, "{"); i < 0 || json.Unmarshal([]byte(prompt[i:]), &in) != nil {
		w.WriteHeader(400)
		return
	}
	f.calls++
	f.texts += len(in.Texts)
	out := make([]string, len(in.Texts))
	for i, t := range in.Texts {
		if v, ok := f.dict[t]; ok {
			out[i] = v
		} else {
			out[i] = "uz:" + t
		}
	}
	reply, _ := json.Marshal(map[string]any{"texts": out})
	res, _ := json.Marshal(map[string]any{
		"choices": []any{map[string]any{"message": map[string]any{"content": string(reply)}}},
		"usage":   map[string]any{"prompt_tokens": 100, "completion_tokens": 50},
	})
	_, _ = w.Write(res)
}

// byID — элемент списка с данным id.
func byID(items []map[string]any, id string) map[string]any {
	for _, it := range items {
		if it["id"] == id {
			return it
		}
	}
	return nil
}

// TestI18nData — двуязычные данные: справочники и товары с узбекскими
// названиями, ответы на языке запроса, поиск по обоим языкам, массовый
// автоперевод у супер-админа.
func TestI18nData(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	ctx := context.Background()
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)

	// ---------------------------------------------------------- справочники
	drinks := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{
		"name": "Напитки", "name_uz": "Ichimliklar",
	}), 201, "category with uz")
	if drinks.str("name") != "Напитки" || drinks.str("name_ru") != "Напитки" || drinks.str("name_uz") != "Ichimliklar" {
		t.Fatalf("category = %v", drinks.Body)
	}
	soda := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{
		"name": "Газировка", "name_uz": "Gazli ichimliklar", "parent_id": drinks.str("id"),
	}), 201, "subcategory")
	// Только узбекское название — оно же и основное.
	fruits := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name_uz": "Mevalar"}), 201, "uz only")
	if fruits.str("name") != "Mevalar" || fruits.str("name_ru") != "Mevalar" || fruits.str("name_uz") != "Mevalar" {
		t.Fatalf("uz-only category = %v", fruits.Body)
	}
	a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": " "}), 400, "empty name")
	a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "", "name_uz": ""}), 400, "both empty")
	a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name_uz": 5}), 400, "name_uz not a string")
	bread := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Хлеб"}), 201, "ru only")

	cats := a.expect(a.doLang("uz", "GET", "/admin/catalog/categories", adminTok, nil), 200, "categories uz").items()
	if c := byID(cats, soda.str("id")); c["name"] != "Gazli ichimliklar" || c["parent_name"] != "Ichimliklar" ||
		c["name_ru"] != "Газировка" || c["name_uz"] != "Gazli ichimliklar" {
		t.Fatalf("soda uz = %v", c)
	}
	if c := byID(cats, bread.str("id")); c["name"] != "Хлеб" || c["name_uz"] != "" {
		t.Fatalf("fallback to ru = %v", c)
	}
	cats = a.expect(a.do("GET", "/admin/catalog/categories", adminTok, nil), 200, "categories ru").items()
	if c := byID(cats, soda.str("id")); c["name"] != "Газировка" || c["parent_name"] != "Напитки" {
		t.Fatalf("soda ru = %v", c)
	}
	// Поиск по узбекскому названию.
	found := a.expect(a.do("GET", "/admin/catalog/categories?q=gazli", adminTok, nil), 200, "search uz").items()
	if len(found) != 1 || found[0]["id"] != soda.str("id") {
		t.Fatalf("search category by uz = %v", found)
	}
	// Правка: только перевод; пустое русское название с переводом — берётся перевод.
	upd := a.expect(a.do("PATCH", "/admin/catalog/categories/"+bread.str("id"), adminTok, map[string]any{"name_uz": "Non"}), 200, "patch uz")
	if upd.str("name") != "Хлеб" || upd.str("name_uz") != "Non" {
		t.Fatalf("patch uz = %v", upd.Body)
	}
	if r := a.expect(a.doLang("uz", "PATCH", "/admin/catalog/categories/"+fruits.str("id"), adminTok,
		map[string]any{"name": "", "name_uz": "Meva"}), 200, "patch empty ru"); r.str("name_ru") != "Meva" || r.str("name") != "Meva" {
		t.Fatalf("patch empty ru = %v", r.Body)
	}
	a.expect(a.do("PATCH", "/admin/catalog/categories/"+bread.str("id"), adminTok, map[string]any{"name": ""}), 400, "patch empty name")

	box := a.expect(a.do("POST", "/admin/catalog/units", adminTok, map[string]any{
		"name": "Ящик", "name_uz": "Yashik", "short_name": "ящ", "short_name_uz": "yash",
	}), 201, "unit")
	if box.str("short_name_ru") != "ящ" || box.str("short_name_uz") != "yash" || box.str("short_name") != "ящ" {
		t.Fatalf("unit = %v", box.Body)
	}
	a.expect(a.do("POST", "/admin/catalog/units", adminTok, map[string]any{"name": "Пачка", "short_name_uz": "pachka"}), 201, "unit short uz only")
	var pcs string
	for _, u := range a.expect(a.doLang("uz", "GET", "/store/catalog/units", mustAdminNetwork(t, a, adminTok), nil), 200, "units uz").items() {
		if u["short_name_ru"] == "шт" {
			pcs = u["id"].(string)
			if u["short_name"] != "dona" || u["name"] != "Dona" {
				t.Fatalf("seed unit uz = %v", u)
			}
		}
		if u["id"] == box.str("id") && (u["short_name"] != "yash" || u["name"] != "Yashik") {
			t.Fatalf("unit uz = %v", u)
		}
	}
	if pcs == "" {
		t.Fatal("no шт")
	}
	red := a.expect(a.do("POST", "/admin/catalog/colors", adminTok, map[string]any{"name": "Красный", "name_uz": "Qizil", "hex": "#FF0000"}), 201, "color")
	if c := byID(a.expect(a.doLang("uz", "GET", "/admin/catalog/colors", adminTok, nil), 200, "colors").items(), red.str("id")); c["name"] != "Qizil" || c["name_ru"] != "Красный" {
		t.Fatalf("color uz = %v", c)
	}
	// Бренды не переводятся.
	a.expect(a.do("POST", "/admin/catalog/brands", adminTok, map[string]any{"name": "Nestle", "name_uz": "x"}), 400, "brand name_uz")

	// --------------------------------------------------------------- товары
	lemon := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
		"name": "Лимонад", "name_uz": "Limonad", "description": "Сладкий", "description_uz": "Shirin",
		"category_id": soda.str("id"), "unit_id": pcs, "base_price": 9000, "color_id": red.str("id"),
	}), 201, "product")
	if lemon.str("name") != "Лимонад" || lemon.str("name_ru") != "Лимонад" || lemon.str("name_uz") != "Limonad" ||
		lemon.str("description_ru") != "Сладкий" || lemon.str("description_uz") != "Shirin" || lemon.str("unit_short") != "шт" {
		t.Fatalf("product = %v", lemon.Body)
	}
	lemonID := lemon.str("id")
	p := a.expect(a.doLang("uz", "GET", "/admin/products/"+lemonID, adminTok, nil), 200, "product uz")
	if p.str("name") != "Limonad" || p.str("description") != "Shirin" || p.str("category_name") != "Gazli ichimliklar" ||
		p.str("unit_short") != "dona" || p.str("name_ru") != "Лимонад" || p.str("name_uz") != "Limonad" {
		t.Fatalf("product uz = %v", p.Body)
	}
	nonID := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
		"name_uz": "Non", "description_uz": "Issiq", "category_id": bread.str("id"), "unit_id": pcs, "base_price": 3000,
	}), 201, "product uz only")
	if nonID.str("name") != "Non" || nonID.str("description") != "Issiq" || nonID.str("name_uz") != "Non" {
		t.Fatalf("uz-only product = %v", nonID.Body)
	}
	a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
		"name": "", "name_uz": " ", "category_id": bread.str("id"), "unit_id": pcs,
	}), 400, "product without name")
	plain := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
		"name": "Батон", "description": "Белый", "category_id": bread.str("id"), "unit_id": pcs, "base_price": 4000,
	}), 201, "product ru only")
	if r := a.expect(a.doLang("uz", "GET", "/admin/products/"+plain.str("id"), adminTok, nil), 200, "fallback"); r.str("name") != "Батон" ||
		r.str("description") != "Белый" || r.str("category_name") != "Non" {
		t.Fatalf("fallback product = %v", r.Body)
	}
	// Частичная правка: только перевод, русское не меняется.
	upd = a.expect(a.do("PATCH", "/admin/products/"+lemonID, adminTok, map[string]any{"name_uz": "Limonad yangi"}), 200, "patch product uz")
	if upd.str("name") != "Лимонад" || upd.str("name_uz") != "Limonad yangi" || upd.str("description_uz") != "Shirin" {
		t.Fatalf("patch product = %v", upd.Body)
	}
	// Поиск у супер-админа — по обоим языкам.
	for _, q := range []string{"limonad", "ЛИМОН"} {
		if it := a.expect(a.do("GET", "/admin/products?q="+q, adminTok, nil), 200, "admin search").items(); len(it) != 1 || it[0]["id"] != lemonID {
			t.Fatalf("admin search %q = %v", q, it)
		}
	}

	// Магазин предлагает товар с переводом — модерация его сохраняет.
	ownerTok, storeID := setupNetwork(t, a, adminTok, "+998900000002")
	somsa := a.expect(a.do("POST", "/store/products", ownerTok, map[string]any{
		"name": "Самса", "name_uz": "Somsa", "category_id": bread.str("id"), "unit_id": pcs,
	}), 201, "store proposes")
	if somsa.str("moderation_status") != "pending" || somsa.str("name_uz") != "Somsa" {
		t.Fatalf("proposal = %v", somsa.Body)
	}
	a.expect(a.do("PATCH", "/store/products/"+somsa.str("id"), ownerTok, map[string]any{"description_uz": "Tandirda"}), 200, "store edits")
	ok := a.expect(a.do("POST", "/admin/products/"+somsa.str("id")+"/approve", adminTok, nil), 200, "approve")
	if ok.str("name_uz") != "Somsa" || ok.str("description_uz") != "Tandirda" || ok.str("moderation_status") != "approved" {
		t.Fatalf("approved = %v", ok.Body)
	}
	// Панель магазина: список для правки — оба языка, поиск по узбекскому.
	list := a.expect(a.doLang("uz", "GET", "/store/products?q=limonad", ownerTok, nil), 200, "store search uz").items()
	if len(list) != 1 || list[0]["name"] != "Limonad yangi" || list[0]["name_ru"] != "Лимонад" || list[0]["category_name"] != "Gazli ichimliklar" {
		t.Fatalf("store search = %v", list)
	}
	list = a.expect(a.do("GET", "/store/products?q=limonad&store_id="+storeID, ownerTok, nil), 200, "store search ru").items()
	if len(list) != 1 || list[0]["name"] != "Лимонад" || list[0]["name_uz"] != "Limonad yangi" || list[0]["price"] != "9000.00" {
		t.Fatalf("store search ru = %v", list)
	}
	groups := a.expect(a.doLang("uz", "GET", "/store/products/groups?q=limonad", ownerTok, nil), 200, "groups uz")
	if b, _ := groups.Body["brands"].([]any); len(b) != 1 || !strings.Contains(fmt.Sprint(b[0]), "Gazli ichimliklar") {
		t.Fatalf("groups = %v", groups.Body)
	}

	// --------------------------------------------------------------- витрина
	const lat, lng = 41.2995, 69.2401
	a.expect(a.do("PATCH", "/store/stores/"+storeID, ownerTok, map[string]any{"lat": lat, "lng": lng, "address": "Центр"}), 200, "location")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+storeID, ownerTok, nil), 200, "wh").items()[0]["id"].(string)
	d := a.expect(a.do("POST", "/store/inventory/documents", ownerTok, map[string]any{"type": "posting", "warehouse_id": wh,
		"items": []map[string]any{{"product_id": lemonID, "qty": 10, "price": 5000}, {"product_id": plain.str("id"), "qty": 5, "price": 2000}}}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+d.str("id")+"/post", ownerTok, nil), 200, "post")
	a.expect(a.do("PUT", "/store/stores/"+storeID+"/delivery", ownerTok, map[string]any{
		"accepts_online": true, "min_order_amount": 0, "delivery_radius_m": 5000,
	}), 200, "delivery")

	doc := a.expect(a.doLang("uz", "GET", "/store/inventory/documents/"+d.str("id"), ownerTok, nil), 200, "doc uz")
	if items, _ := doc.Body["items"].([]any); len(items) != 2 || !strings.Contains(fmt.Sprint(items), "Limonad yangi") {
		t.Fatalf("doc items uz = %v", doc.Body["items"])
	}
	stock := a.expect(a.doLang("uz", "GET", "/store/inventory/stock?q=limonad", ownerTok, nil), 200, "stock uz").items()
	if len(stock) != 1 || !strings.Contains(fmt.Sprint(stock[0]), "Limonad yangi") || !strings.Contains(fmt.Sprint(stock[0]), "dona") {
		t.Fatalf("stock uz = %v", stock)
	}

	prods := a.expect(a.doLang("uz", "GET", "/client/stores/"+storeID+"/products", "", nil), 200, "client products uz").items()
	if c := byID(prods, lemonID); c == nil || c["name"] != "Limonad yangi" || c["description"] != "Shirin" || c["unit_short"] != "dona" {
		t.Fatalf("client uz = %v", prods)
	}
	if c := byID(prods, plain.str("id")); c == nil || c["name"] != "Батон" {
		t.Fatalf("client fallback = %v", prods)
	}
	prods = a.expect(a.do("GET", "/client/stores/"+storeID+"/products", "", nil), 200, "client products ru").items()
	if c := byID(prods, lemonID); c == nil || c["name"] != "Лимонад" || c["unit_short"] != "шт" {
		t.Fatalf("client ru = %v", prods)
	}
	for _, q := range []string{"limonad", "лимон"} {
		if it := a.expect(a.doLang("uz", "GET", "/client/stores/"+storeID+"/products?q="+q, "", nil), 200, "client search").items(); len(it) != 1 || it[0]["id"] != lemonID {
			t.Fatalf("client search %q = %v", q, it)
		}
	}
	card := a.expect(a.doLang("uz", "GET", "/client/stores/"+storeID+"/products/"+lemonID, "", nil), 200, "card uz")
	if card.str("name") != "Limonad yangi" || card.str("category_name") != "Gazli ichimliklar" {
		t.Fatalf("card uz = %v", card.Body)
	}
	ccats := a.expect(a.doLang("uz", "GET", "/client/stores/"+storeID+"/categories", "", nil), 200, "client categories").items()
	names := map[string]bool{}
	for _, c := range ccats {
		names[c["name"].(string)] = true
	}
	if !names["Ichimliklar"] || !names["Gazli ichimliklar"] || !names["Non"] {
		t.Fatalf("client categories uz = %v", ccats)
	}
	sr := a.expect(a.doLang("uz", "GET", fmt.Sprintf("/client/search?lat=%v&lng=%v&q=limonad", lat, lng), "", nil), 200, "global search uz")
	if items, _ := sr.Body["items"].([]any); len(items) != 1 || items[0].(map[string]any)["product"].(map[string]any)["name"] != "Limonad yangi" {
		t.Fatalf("global search = %v", sr.Body)
	}

	// Касса: название на языке запроса, для поиска — оба языка, в чек — русское.
	dev := a.expect(a.do("POST", "/store/pos/devices", ownerTok, map[string]any{"store_id": storeID, "name": "Касса 1"}), 201, "device")
	dt := a.expect(a.do("POST", "/pos/activate", "", map[string]any{"code": dev.str("activation_code")}), 200, "activate").str("token")
	pc := a.expect(a.doLang("uz", "GET", "/pos/catalog", dt, nil), 200, "pos catalog uz")
	var posLemon map[string]any
	for _, x := range pc.Body["products"].([]any) {
		if m := x.(map[string]any); m["id"] == lemonID {
			posLemon = m
		}
	}
	if posLemon == nil || posLemon["name"] != "Limonad yangi" || posLemon["name_ru"] != "Лимонад" || posLemon["name_uz"] != "Limonad yangi" ||
		posLemon["unit"] != "dona" || posLemon["category"] != "Ichimliklar" {
		t.Fatalf("pos lemon = %v", posLemon)
	}

	// ------------------------------------------------------ автоперевод
	a.expect(a.do("GET", "/admin/i18n/stats", ownerTok, nil), 403, "store token on stats")
	stats := map[string][2]int{}
	readStats := func() {
		t.Helper()
		for _, it := range a.expect(a.do("GET", "/admin/i18n/stats", adminTok, nil), 200, "stats").items() {
			stats[it["entity"].(string)] = [2]int{int(it["total"].(float64)), int(it["missing"].(float64))}
		}
	}
	readStats()
	// Без перевода: категории «Продукты»? — нет; «Хлеб» переведён; units: «Пачка» без name_uz;
	// товары: «Батон» (название и описание). Категорий 4 + служебная «Блюда и
	// заготовки кафе» (миграция 0068, переведена).
	if stats["categories"] != [2]int{5, 0} || stats["units"][1] != 1 || stats["colors"] != [2]int{1, 0} || stats["products"] != [2]int{4, 1} {
		t.Fatalf("stats = %v", stats)
	}
	if _, err := pool.Exec(ctx, `UPDATE categories SET name_uz = '' WHERE id = $1`, bread.str("id")); err != nil {
		t.Fatal(err)
	}
	a.expect(a.do("POST", "/admin/i18n/translate-missing", adminTok, map[string]any{"entity": "brands"}), 400, "bad entity")
	a.expect(a.do("POST", "/admin/i18n/translate-missing", adminTok, map[string]any{"entity": "products", "limit": 201}), 400, "bad limit")
	a.expect(a.do("POST", "/admin/i18n/translate-missing", adminTok, map[string]any{"entity": "categories"}), 409, "ai not configured")

	fai := &fakeTranslator{key: "sk-tr-1", dict: map[string]string{"Хлеб": "Non", "Батон": "Baton", "Белый": "Oq", "Пачка": "Pachka"}}
	aisrv := httptest.NewServer(fai)
	t.Cleanup(aisrv.Close)
	a.expect(a.do("PUT", "/admin/ai", adminTok, map[string]any{"provider": "openai", "base_url": aisrv.URL + "/v1", "api_key": fai.key, "model": "gpt-4o"}), 200, "ai settings")

	// Кнопка «Перевести автоматически»: POST /translate.
	if r := a.expect(a.do("POST", "/translate", adminTok, map[string]any{"texts": []string{"Батон", ""}, "to": "uz"}), 200, "translate button"); fmt.Sprint(r.Body["texts"]) != "[Baton ]" {
		t.Fatalf("translate button = %v", r.Body)
	}
	var trUsage int
	if err := pool.QueryRow(context.Background(), `SELECT count(*) FROM ai_usage WHERE kind = 'translate'`).Scan(&trUsage); err != nil || trUsage != 1 {
		t.Fatalf("translate usage %d %v", trUsage, err)
	}

	tr := a.expect(a.do("POST", "/admin/i18n/translate-missing", adminTok, map[string]any{"entity": "categories"}), 200, "translate categories")
	if tr.Body["translated"] != float64(1) || tr.Body["remaining"] != float64(0) {
		t.Fatalf("translate categories = %v", tr.Body)
	}
	tr = a.expect(a.do("POST", "/admin/i18n/translate-missing", adminTok, map[string]any{"entity": "products", "limit": 200}), 200, "translate products")
	if tr.Body["translated"] != float64(1) || tr.Body["remaining"] != float64(0) {
		t.Fatalf("translate products = %v", tr.Body)
	}
	tr = a.expect(a.do("POST", "/admin/i18n/translate-missing", adminTok, map[string]any{"entity": "units"}), 200, "translate units")
	if tr.Body["translated"] != float64(1) || tr.Body["remaining"] != float64(0) {
		t.Fatalf("translate units = %v", tr.Body)
	}
	if r := a.expect(a.doLang("uz", "GET", "/admin/products/"+plain.str("id"), adminTok, nil), 200, "translated product"); r.str("name") != "Baton" || r.str("description") != "Oq" || r.str("name_ru") != "Батон" {
		t.Fatalf("translated product = %v", r.Body)
	}
	// Уже заполненное не трогается: у «Пачки» короткое имя было своё.
	var unitUz, shortUz string
	if err := pool.QueryRow(ctx, `SELECT name_uz, short_name_uz FROM units WHERE name = 'Пачка'`).Scan(&unitUz, &shortUz); err != nil || unitUz != "Pachka" || shortUz != "pachka" {
		t.Fatalf("unit translated: %q %q %v", unitUz, shortUz, err)
	}
	calls := fai.calls
	// Повтор — ничего не переводит и не ходит в ИИ.
	tr = a.expect(a.do("POST", "/admin/i18n/translate-missing", adminTok, map[string]any{"entity": "products"}), 200, "translate again")
	if tr.Body["translated"] != float64(0) || tr.Body["remaining"] != float64(0) || fai.calls != calls {
		t.Fatalf("translate again = %v (calls %d → %d)", tr.Body, calls, fai.calls)
	}
	readStats()
	for k, v := range stats {
		if v[1] != 0 {
			t.Fatalf("still missing %s: %v", k, stats)
		}
	}
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM ai_usage WHERE kind = 'translate' AND ok`).Scan(&n); err != nil || n != 4 { // 3 пачки + кнопка «Перевести»
		t.Fatalf("ai_usage translate rows = %d %v", n, err)
	}

	// Импорт из каталога ИКПУ с переводами: товар, путь категорий, единица по-узбекски.
	imp := a.expect(a.do("POST", "/admin/catalog-import", adminTok, map[string]any{"source": "tasnif", "items": []map[string]any{
		{"barcode": "4780000000017", "name_uz": "Qatiq 1 l", "category": []string{"Напитки", "Кисломолочные"},
			"category_uz": []string{"Boshqa", "Sut mahsulotlari"}, "unit": "dona", "description_uz": "Tabiiy"},
		{"barcode": "4780000000024", "name": "Кефир 1 л", "name_uz": "Kefir 1 l", "category": []string{"Напитки"}, "unit": "шт"},
	}}), 200, "import")
	if imp.Body["created"] != float64(2) {
		t.Fatalf("import = %v", imp.Body)
	}
	found = a.expect(a.doLang("uz", "GET", "/admin/products?barcode=4780000000017", adminTok, nil), 200, "imported").items()
	if len(found) != 1 || found[0]["name"] != "Qatiq 1 l" || found[0]["name_ru"] != "Qatiq 1 l" || found[0]["description"] != "Tabiiy" ||
		found[0]["category_name"] != "Sut mahsulotlari" || found[0]["unit_short"] != "dona" {
		t.Fatalf("imported uz = %v", found)
	}
	// Существующая категория «Напитки» перевод не меняет.
	if r := byID(a.expect(a.doLang("uz", "GET", "/admin/catalog/categories?q=Напитки", adminTok, nil), 200, "drinks").items(), drinks.str("id")); r["name"] != "Ichimliklar" {
		t.Fatalf("drinks after import = %v", r)
	}
}

// mustAdminNetwork — токен владельца отдельной сети (для справочников панели магазина).
func mustAdminNetwork(t *testing.T, a api, adminTok string) string {
	t.Helper()
	tok, _ := setupNetwork(t, a, adminTok, "+998900000077")
	return tok
}
