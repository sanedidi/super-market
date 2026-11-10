package server_test

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"sync"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/catalognorm"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// fakeNormAI — ИИ-сервис (протокол OpenAI) для автонормализации: по
// названию товара отдаёт заранее заданную карточку; перенос в другой раздел
// подтверждает, если товар в moveOK; модерация — по названию.
type fakeNormAI struct {
	mu     sync.Mutex
	cards  map[string]map[string]any // исходное название → карточка (category — путь)
	moveOK map[string]bool           // название (новое) → подтвердить перенос
	mod    map[string]map[string]any // название (новое) → решение
	calls  map[string]int
}

var catLineRe = regexp.MustCompile(`(?m)^(c\d+) \| (.+)$`)

func (f *fakeNormAI) reply(prompt string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.calls == nil {
		f.calls = map[string]int{}
	}
	// Первый JSON-массив после from (дальше в правилах тоже есть скобки).
	firstArray := func(from string) []map[string]any {
		var out []map[string]any
		_ = json.NewDecoder(strings.NewReader(from[strings.Index(from, "["):])).Decode(&out)
		return out
	}
	products := func() []map[string]any { return firstArray(prompt) }
	switch {
	case strings.Contains(prompt, "return a clean card"):
		f.calls["norm"]++
		codes := map[string]string{}
		for _, m := range catLineRe.FindAllStringSubmatch(prompt, -1) {
			codes[strings.TrimSpace(m[2])] = m[1]
		}
		// Список товаров — после строки «Products (JSON…».
		ps := firstArray(prompt[strings.Index(prompt, "Products (JSON"):])
		var items []map[string]any
		for _, p := range ps {
			card, ok := f.cards[p["name"].(string)]
			if !ok {
				continue
			}
			it := map[string]any{"id": p["id"]}
			for k, v := range card {
				it[k] = v
			}
			if path, ok := card["category"].(string); ok {
				it["category"] = codes[path]
			} else {
				it["category"] = p["category"]
			}
			items = append(items, it)
		}
		b, _ := json.Marshal(map[string]any{"items": items})
		return string(b)
	case strings.Contains(prompt, "it is proposed to move it"):
		f.calls["move"]++
		var items []map[string]any
		for _, p := range products() {
			items = append(items, map[string]any{"id": p["id"], "move": f.moveOK[p["name"].(string)]})
		}
		b, _ := json.Marshal(map[string]any{"items": items})
		return string(b)
	case strings.Contains(prompt, "Shops sent corrections"):
		f.calls["suggestion"]++
		var items []map[string]any
		for _, p := range products() {
			ok := !strings.Contains(p["product"].(string), "Fruzo")
			items = append(items, map[string]any{"id": p["id"], "approve": ok, "reason": "Это другой товар"})
		}
		b, _ := json.Marshal(map[string]any{"items": items})
		return string(b)
	case strings.Contains(prompt, "wait for moderation"):
		f.calls["moderation"]++
		var items []map[string]any
		for _, p := range products() {
			d := map[string]any{"id": p["id"], "decision": "approve"}
			if m, ok := f.mod[p["name"].(string)]; ok {
				for k, v := range m {
					d[k] = v
				}
				if d["decision"] == "duplicate" {
					if sim, _ := p["similar"].([]any); len(sim) > 0 {
						d["duplicate_of"] = sim[0].(map[string]any)["id"]
					}
				}
			}
			items = append(items, d)
		}
		b, _ := json.Marshal(map[string]any{"items": items})
		return string(b)
	}
	return `{}`
}

func (f *fakeNormAI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.Method == "GET" && r.URL.Path == "/v1/models":
		_, _ = w.Write([]byte(`{"data":[{"id":"gpt-4o"}]}`))
	case r.Method == "POST" && r.URL.Path == "/v1/chat/completions":
		var body struct {
			Messages []struct {
				Content any `json:"content"`
			} `json:"messages"`
		}
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)
		prompt := ""
		if len(body.Messages) > 1 {
			if parts, ok := body.Messages[1].Content.([]any); ok && len(parts) > 0 {
				prompt, _ = parts[0].(map[string]any)["text"].(string)
			}
		}
		out, _ := json.Marshal(map[string]any{"choices": []any{map[string]any{"message": map[string]any{"content": f.reply(prompt)}}},
			"usage": map[string]any{"prompt_tokens": 1000, "completion_tokens": 200}})
		_, _ = w.Write(out)
	default:
		w.WriteHeader(404)
	}
}

// TestCatalogNorm — автонормализация: названия без типа ИКПУ, чипсы из
// «Замороженных овощей» в «Картофельные чипсы» (перенос подтверждён вторым
// мнением), группа вариаций Lay's собрана и подтверждена сама, товар
// магазина одобрен, дубль отклонён; правленый человеком товар не тронут;
// «только посмотреть» → применить → откатить.
func TestCatalogNorm(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	fai := &fakeNormAI{}
	aisrv := httptest.NewServer(fai)
	t.Cleanup(aisrv.Close)

	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	server.InvoicesSync = true
	catalognorm.Sync = true
	t.Cleanup(func() { server.InvoicesSync = false; catalognorm.Sync = false })
	app, err := server.Build(ctx, cfg, pool, &fakeTelegram{}, quietLog())
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app.Handler)
	t.Cleanup(srv.Close)
	a := api{t: t, srv: srv, pool: pool}
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	ownerTok, storeID := setupNetwork(t, a, adminTok, "+998900000002")

	frozen := []string{"Полуфабрикаты", "Замороженные овощи и фрукты"}
	attrs := func(sub string) map[string]any { return map[string]any{"ikpu_name": sub + ": …"} }
	a.expect(a.do("POST", "/admin/catalog-import", adminTok, map[string]any{"source": "tasnif", "items": []map[string]any{
		{"barcode": "4690388016050", "name": "Не замороженные овощи Lay's, С солью 150г", "brand": "Lay's", "category": frozen, "ikpu": "02005200001000001", "attributes": attrs("Не замороженные овощи")},
		{"barcode": "4690388016051", "name": "Не замороженные овощи Lay's, Сметана и лук 150г", "brand": "Lay's", "category": frozen, "ikpu": "02005200001000002", "attributes": attrs("Не замороженные овощи")},
		{"barcode": "4690388016052", "name": "Не замороженные овощи Lay's, С солью 90г", "brand": "Lay's", "category": frozen, "ikpu": "02005200001000003", "attributes": attrs("Не замороженные овощи")},
		{"barcode": "4690388016053", "name": "Замороженная клубника Fruzo, 300 г", "brand": "Fruzo", "category": frozen, "ikpu": "00811002001000001"},
		{"barcode": "5449000000011", "name": "Безалкогольные напитки Coca-Cola, 0.15 л", "brand": "Coca-Cola", "category": []string{"Напитки", "Газированные напитки"}, "ikpu": "02202002001010021"},
		{"barcode": "5449000000012", "name": "Безалкогольные напитки Fanta, 0.5 л", "brand": "Fanta", "category": []string{"Напитки", "Газированные напитки"}, "ikpu": "02202002001010022"},
		{"barcode": "4000000000001", "name": "Чипсы Pringles, 165 г", "brand": "Pringles", "category": []string{"Снеки", "Картофельные чипсы"}},
	}}), 200, "import")

	id := func(name string) string {
		var s string
		if err := pool.QueryRow(ctx, `SELECT id::text FROM products WHERE name = $1`, name).Scan(&s); err != nil {
			t.Fatalf("product %q: %v", name, err)
		}
		return s
	}
	field := func(pid, col string) string {
		var s string
		if err := pool.QueryRow(ctx, `SELECT `+col+`::text FROM products WHERE id = $1`, pid).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}
	salt150, sour, salt90 := id("Не замороженные овощи Lay's, С солью 150г"), id("Не замороженные овощи Lay's, Сметана и лук 150г"), id("Не замороженные овощи Lay's, С солью 90г")
	cola, fanta, berry := id("Безалкогольные напитки Coca-Cola, 0.15 л"), id("Безалкогольные напитки Fanta, 0.5 л"), id("Замороженная клубника Fruzo, 300 г")
	chips := field(id("Чипсы Pringles, 165 г"), "category_id")
	frozenCat := field(salt150, "category_id")

	// Fanta поправил человек — автонормализация её не трогает.
	a.expect(a.do("PATCH", "/admin/products/"+fanta, adminTok, map[string]any{"name": "Fanta Апельсин, 0,5 л"}), 200, "manual edit")

	// Товары магазина на модерации: нормальный и дубль Coca-Cola.
	var pcs string
	if err := pool.QueryRow(ctx, `SELECT id::text FROM units WHERE short_name = 'шт'`).Scan(&pcs); err != nil {
		t.Fatal(err)
	}
	good := a.expect(a.do("POST", "/store/products", ownerTok, map[string]any{"name": "Лепёшка домашняя", "category_id": chips, "unit_id": pcs,
		"barcodes": []string{"2000000000001"}}), 201, "own product").str("id")
	dup := a.expect(a.do("POST", "/store/products", ownerTok, map[string]any{"name": "Coca-Cola, 0,15 л", "category_id": chips, "unit_id": pcs}), 201, "dup").str("id")

	snack := "Снеки / Картофельные чипсы"
	fai.cards = map[string]map[string]any{
		"Не замороженные овощи Lay's, С солью 150г": {"name": "Lay's, С солью, 150 г", "name_uz": "Lay's, Tuzli, 150 g", "category": snack, "food": true,
			"line": "Lay's", "line_uz": "Lay's", "flavor": "С солью", "flavor_uz": "Tuzli", "weight": "150 г", "weight_uz": "150 g"},
		"Не замороженные овощи Lay's, Сметана и лук 150г": {"name": "Lay's, Сметана и лук, 150 г", "name_uz": "Lay's, Smetana va piyoz, 150 g", "category": snack, "food": true,
			"line": "Lay's", "flavor": "Сметана и лук", "flavor_uz": "Smetana va piyoz", "weight": "150 г"},
		// ИИ потерял вес — берётся название без ИИ.
		"Не замороженные овощи Lay's, С солью 90г": {"name": "Lay's, С солью", "name_uz": "Lay's, Tuzli, 90 g", "category": snack, "food": true,
			"line": "Lay's", "flavor": "С солью", "weight": "90 г"},
		// Клубника остаётся в замороженных: перенос в «Снеки» второе мнение не подтверждает.
		"Замороженная клубника Fruzo, 300 г":       {"name": "Fruzo, клубника замороженная, 300 г", "name_uz": "Fruzo, muzlatilgan qulupnay, 300 g", "category": snack, "food": true},
		"Безалкогольные напитки Coca-Cola, 0.15 л": {"name": "Coca-Cola, 0,15 л", "name_uz": "Coca-Cola, 0,15 l", "food": true, "line": "Coca-Cola", "weight": "0,15 л"},
		"Чипсы Pringles, 165 г":                    {"name": "Pringles, Оригинальные, 165 г", "name_uz": "Pringles, Original, 165 g", "food": true},
		"Лепёшка домашняя":                         {"name": "Лепёшка домашняя", "name_uz": "Uy noni", "food": true},
		"Coca-Cola, 0,15 л":                        {"name": "Coca-Cola, 0,15 л", "name_uz": "Coca-Cola, 0,15 l", "food": true},
	}
	fai.moveOK = map[string]bool{"Lay's, С солью, 150 г": true, "Lay's, Сметана и лук, 150 г": true, "Lay's, С солью, 90 г": true}
	fai.mod = map[string]map[string]any{"Coca-Cola, 0,15 л": {"decision": "duplicate"}}
	a.expect(a.do("PUT", "/admin/ai", adminTok, map[string]any{"provider": "openai", "base_url": aisrv.URL + "/v1", "api_key": "sk-norm", "model": "gpt-4o"}), 200, "ai on")

	// 1. «Только посмотреть»: журнал есть, товары не изменились.
	dry := a.expect(a.do("POST", "/admin/catalog-norm/runs", adminTok, map[string]any{"dry_run": true}), 202, "dry run")
	runID := dry.str("id")
	if dry.str("status") != "done" || dry.Body["applied"] != false {
		t.Fatalf("dry run = %v", dry.Body)
	}
	st, _ := dry.Body["stats"].(map[string]any)
	if st["groups"] != float64(1) || st["moves"] != float64(3) || st["moves_kept"] != float64(1) || st["duplicates"] != float64(1) || st["approved"] != float64(1) {
		t.Fatalf("dry stats = %v", st)
	}
	if field(salt150, "name") != "Не замороженные овощи Lay's, С солью 150г" {
		t.Fatal("dry run changed a product")
	}
	ch := a.expect(a.do("GET", "/admin/catalog-norm/runs/"+runID+"/changes?kind=category", adminTok, nil), 200, "changes")
	if ch.Body["total"] != float64(3) || ch.items()[0]["old"] != "Полуфабрикаты / Замороженные овощи и фрукты" || ch.items()[0]["new"] != snack {
		t.Fatalf("category changes = %v", ch.Body)
	}

	// 2. Применить.
	a.expect(a.do("POST", "/admin/catalog-norm/runs/"+runID+"/apply", adminTok, nil), 202, "apply")
	if got := field(salt150, "name"); got != "Lay's, С солью, 150 г" {
		t.Fatalf("name = %q", got)
	}
	if got := field(salt90, "name"); got != "Lay's, С солью, 90 г" {
		t.Fatalf("fallback name = %q", got)
	}
	if field(cola, "name") != "Coca-Cola, 0,15 л" || field(cola, "name_uz") != "Coca-Cola, 0,15 l" {
		t.Fatalf("cola = %q / %q", field(cola, "name"), field(cola, "name_uz"))
	}
	if field(salt150, "category_id") != chips || field(berry, "category_id") != frozenCat {
		t.Fatal("categories not applied as expected")
	}
	if field(fanta, "name") != "Fanta Апельсин, 0,5 л" {
		t.Fatal("locked product changed")
	}
	if g1, g2, g3 := field(salt150, "COALESCE(variant_group_id::text, '')"), field(sour, "COALESCE(variant_group_id::text, '')"),
		field(salt90, "COALESCE(variant_group_id::text, '')"); g1 == "" || g1 != g2 || g1 != g3 {
		t.Fatalf("variant group: %q %q %q", g1, g2, g3)
	}
	if field(salt90, "variant_weight") != "90 г" || field(sour, "variant_flavor") != "Сметана и лук" {
		t.Fatal("variant values")
	}
	if field(good, "moderation_status") != "approved" || field(dup, "moderation_status") != "rejected" ||
		!strings.Contains(field(dup, "rejection_reason"), "Coca-Cola") {
		t.Fatalf("moderation: %s / %s %q", field(good, "moderation_status"), field(dup, "moderation_status"), field(dup, "rejection_reason"))
	}
	if field(salt150, "norm_at IS NOT NULL") != "true" {
		t.Fatal("norm_at")
	}

	// 3. Откат: всё как было.
	rb := a.expect(a.do("POST", "/admin/catalog-norm/runs/"+runID+"/rollback", adminTok, nil), 200, "rollback")
	if rb.str("status") != "rolled_back" {
		t.Fatalf("rollback = %v", rb.Body)
	}
	if field(salt150, "name") != "Не замороженные овощи Lay's, С солью 150г" || field(salt150, "category_id") != frozenCat ||
		field(salt150, "COALESCE(variant_group_id::text, '')") != "" || field(good, "moderation_status") != "pending" ||
		field(dup, "moderation_status") != "pending" || field(good, "network_id IS NOT NULL") != "true" {
		t.Fatal("rollback incomplete")
	}
	var groups int
	if err := pool.QueryRow(ctx, `SELECT count(*)::int FROM variant_groups`).Scan(&groups); err != nil || groups != 0 {
		t.Fatalf("groups after rollback = %d %v", groups, err)
	}

	// 4. Автоматический режим: новый товар разбирается сам и встаёт в группу Lay's.
	a.expect(a.do("POST", "/admin/catalog-norm/runs", adminTok, map[string]any{"section_ids": []string{}}), 202, "full run")
	a.expect(a.do("PUT", "/admin/catalog-norm/settings", adminTok, map[string]any{"auto": true}), 200, "auto on")
	a.expect(a.do("POST", "/admin/catalog-import", adminTok, map[string]any{"source": "tasnif", "items": []map[string]any{
		{"barcode": "4690388016054", "name": "Не замороженные овощи Lay's, Сметана и лук 90г", "brand": "Lay's", "category": frozen, "ikpu": "02005200001000004"},
	}}), 200, "import new")
	fai.cards["Не замороженные овощи Lay's, Сметана и лук 90г"] = map[string]any{"name": "Lay's, Сметана и лук, 90 г", "name_uz": "Lay's, Smetana va piyoz, 90 g",
		"category": snack, "food": true, "line": "Lay's", "flavor": "Сметана и лук", "weight": "90 г"}
	fai.moveOK["Lay's, Сметана и лук, 90 г"] = true
	// Исправления карточек от магазина: одно хорошее, одно — другой товар.
	pringles := id("Pringles, Оригинальные, 165 г")
	a.expect(a.do("POST", "/store/products/"+pringles+"/suggestion", ownerTok, map[string]any{"store_id": storeID,
		"name": "Pringles, Original, 165 г"}), 201, "suggest good")
	a.expect(a.do("POST", "/store/products/"+berry+"/suggestion", ownerTok, map[string]any{"store_id": storeID,
		"name": "Мороженое пломбир, 80 г"}), 201, "suggest bad")
	set := a.expect(a.do("GET", "/admin/catalog-norm/settings", adminTok, nil), 200, "settings")
	if set.Body["pending"] != float64(1) || set.Body["suggestions"] != float64(2) {
		t.Fatalf("pending = %v", set.Body)
	}
	if err := app.CatalogNorm.AutoOnce(ctx); err != nil {
		t.Fatal(err)
	}
	newID := id("Lay's, Сметана и лук, 90 г")
	if g := field(newID, "COALESCE(variant_group_id::text, '')"); g == "" || g != field(salt150, "COALESCE(variant_group_id::text, '')") {
		t.Fatal("new product did not join the group")
	}
	if field(pringles, "name") != "Pringles, Original, 165 г" || field(berry, "name") == "Мороженое пломбир, 80 г" {
		t.Fatal("suggestions not reviewed")
	}
	var left int
	if err := pool.QueryRow(ctx, `SELECT count(*)::int FROM product_suggestions WHERE status = 'pending'`).Scan(&left); err != nil || left != 0 {
		t.Fatalf("pending suggestions = %d %v", left, err)
	}
	runs := a.expect(a.do("GET", "/admin/catalog-norm/runs", adminTok, nil), 200, "runs").items()
	if len(runs) != 3 || runs[0]["trigger"] != "auto" {
		t.Fatalf("runs = %v", runs)
	}
}
