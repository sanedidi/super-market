package server_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// webGemini — Gemini для «Фото из сети»: текстовая модель отвечает на
// проверку и сверку по названию товара в запросе, картинки рисует fakeGemini.
type webGemini struct {
	*fakeGemini
	mu      sync.Mutex
	checks  map[string]string // товар → verdict
	best    map[string]int    // товар → лучший кандидат (0 — ни одного)
	text    []string          // запросы к текстовой модели
	nImages []int             // сколько фото в запросе сверки
}

func (g *webGemini) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/models/gemini-2.5-flash:generateContent" {
		g.fakeGemini.ServeHTTP(w, r)
		return
	}
	var body struct {
		Contents []struct {
			Parts []struct {
				Text       string          `json:"text"`
				InlineData json.RawMessage `json:"inlineData"`
			} `json:"parts"`
		} `json:"contents"`
		Gen struct {
			Mime string `json:"responseMimeType"`
		} `json:"generationConfig"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	parts := body.Contents[0].Parts
	prompt := parts[len(parts)-1].Text
	g.mu.Lock()
	defer g.mu.Unlock()
	g.text = append(g.text, prompt)
	answer := `{}`
	for name, v := range g.checks {
		if !strings.Contains(prompt, name) {
			continue
		}
		if strings.HasPrefix(prompt, "You check product photos") {
			answer = fmt.Sprintf(`{"verdict":%q,"note":""}`, v)
		} else {
			g.nImages = append(g.nImages, len(parts)-1)
			b := g.best[name]
			items := []string{}
			for i := 1; i < len(parts); i++ {
				items = append(items, fmt.Sprintf(`{"n":%d,"ok":%v,"note":"%s"}`, i, i == b, map[bool]string{true: "тот же товар", false: "другой товар"}[i == b]))
			}
			answer = fmt.Sprintf(`{"best":%d,"seen_name":"%s","name":%v,"brand":true,"volume":null,"items":[%s]}`, b, name, b > 0, strings.Join(items, ","))
		}
	}
	out, _ := json.Marshal(map[string]any{
		"candidates":    []any{map[string]any{"content": map[string]any{"parts": []any{map[string]any{"text": "```json\n" + answer + "\n```"}}}, "finishReason": "STOP"}},
		"usageMetadata": map[string]any{"promptTokenCount": 1000, "candidatesTokenCount": 100},
	})
	_, _ = w.Write(out)
}

// jpegOf — фото w×h одного цвета.
func jpegOf(w, h int, c color.RGBA) []byte {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, c)
		}
	}
	var buf bytes.Buffer
	_ = jpeg.Encode(&buf, img, nil)
	return buf.Bytes()
}

func uploadBytes(t *testing.T, srv *httptest.Server, tok string, data []byte) string {
	t.Helper()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	fw, _ := mw.CreateFormFile("file", "photo.jpg")
	_, _ = fw.Write(data)
	_ = mw.Close()
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/v1/admin/uploads", &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+tok)
	res, err := srv.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	out := map[string]any{}
	_ = json.NewDecoder(res.Body).Decode(&out)
	if res.StatusCode != 201 {
		t.Fatalf("upload: %d %v", res.StatusCode, out)
	}
	return out["url"].(string)
}

// TestPhotoWeb — «Фото из сети»: Super Market проверяет фото каталога,
// плохие заменяет найденными (Open Food Facts → Google через Serper), не
// нашли — «Не нашли»; оборот без находок — лицевая сторона из своего фото.
// «Вернуть старое», «Выбрать другое», «Поискать ещё», лимит расходов.
func TestPhotoWeb(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	s3 := &fakeS3{buckets: map[string]bool{}, objects: map[string][]byte{}, types: map[string]string{}}
	s3srv := httptest.NewServer(s3)
	t.Cleanup(s3srv.Close)
	gem := &webGemini{fakeGemini: &fakeGemini{key: "AIzaSyTest-Xq7c"}, checks: map[string]string{
		"Coca-Cola 0,33": "back", "Вода Wellness": "drawing", "Печенье Юбилейное": "drawing", "Сок Rich": "ok", "Plus 18 Energy": "back",
	}, best: map[string]int{"Coca-Cola 0,33": 1, "Вода Wellness": 2, "Печенье Юбилейное": 0, "Plus 18 Energy": 0}}
	gemsrv := httptest.NewServer(gem)
	t.Cleanup(gemsrv.Close)

	// Картинки «в интернете».
	pics := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/tiny.jpg":
			_, _ = w.Write(jpegOf(40, 40, color.RGBA{200, 0, 0, 255}))
		case "/page.html":
			_, _ = w.Write([]byte("<html></html>"))
		default:
			_, _ = w.Write(jpegOf(400, 400, color.RGBA{200, 20, 20, 255}))
		}
	}))
	t.Cleanup(pics.Close)
	// Open Food Facts: знает только Coca-Cola.
	var offCalls []string
	var offMu sync.Mutex
	off := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		offMu.Lock()
		offCalls = append(offCalls, r.URL.Path)
		offMu.Unlock()
		if r.URL.Path == "/api/v2/product/5000112545326.json" {
			fmt.Fprintf(w, `{"status":1,"product":{"product_name":"Coca-Cola Original Taste","brands":"Coca-Cola","image_front_url":"%s/coke-front.jpg"}}`, pics.URL)
			return
		}
		w.WriteHeader(404)
		_, _ = w.Write([]byte(`{"status":0}`))
	}))
	t.Cleanup(off.Close)
	// Serper: картинки Google.
	var serperMu sync.Mutex
	var serperQ []map[string]any
	serper := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-API-KEY") != "serper-key-a91f" || r.URL.Path != "/images" {
			w.WriteHeader(403)
			return
		}
		var q map[string]any
		_ = json.NewDecoder(r.Body).Decode(&q)
		serperMu.Lock()
		serperQ = append(serperQ, q)
		serperMu.Unlock()
		fmt.Fprintf(w, `{"images":[
			{"title":"tiny","imageUrl":"%[1]s/tiny.jpg","imageWidth":40,"imageHeight":40,"link":"%[1]s/page.html"},
			{"title":"не фото","imageUrl":"%[1]s/page.html","link":"%[1]s/page.html"},
			{"title":"A","imageUrl":"%[1]s/a.jpg","imageWidth":800,"imageHeight":800,"link":"https://shop.example/a"},
			{"title":"B","imageUrl":"%[1]s/b.jpg","imageWidth":800,"imageHeight":800,"link":"https://shop.example/b"}]}`, pics.URL)
	}))
	t.Cleanup(serper.Close)

	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	cfg.S3Endpoint, cfg.S3AccessKey, cfg.S3SecretKey, cfg.S3Bucket = s3srv.URL, "minio", "secret", "media"
	cfg.OpenFoodFactsURL, cfg.SerperURL, cfg.PhotoWebAllowPrivate = off.URL, serper.URL, true
	server.InvoicesSync = true
	t.Cleanup(func() { server.InvoicesSync = false })
	app, err := server.Build(ctx, cfg, pool, &fakeTelegram{}, quietLog())
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app.Handler)
	t.Cleanup(srv.Close)
	a := api{t: t, srv: srv, pool: pool}
	tok, _ := a.login("+998900000001", identity.AppAdmin)

	// Gemini не подключён — проверка не идёт.
	sum := a.expect(a.do("GET", "/admin/ai-photo/web/summary", tok, nil), 200, "summary")
	if sum.Body["configured"] != false || sum.Body["enabled"] != true {
		t.Fatalf("summary off = %v", sum.Body)
	}
	a.expect(a.do("PUT", "/admin/ai-photo", tok, map[string]any{
		"mode": "gemini", "base_url": gemsrv.URL, "api_key": gem.key, "model": "gemini-3-pro-image", "background": "white", "size": 1000,
	}), 200, "save gemini")

	cat := a.expect(a.do("POST", "/admin/catalog/categories", tok, map[string]any{"name": "Напитки"}), 201, "category").str("id")
	var pcs string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", tok, nil), 200, "units").items() {
		if u["short_name"] == "шт" {
			pcs = u["id"].(string)
		}
	}
	prods := map[string]string{}
	olds := map[string]string{}
	for i, p := range []struct{ name, barcode string }{
		{"Coca-Cola 0,33 л ж/б", "5000112545326"}, {"Вода Wellness 0,5 л", "4780012340056"}, {"Печенье Юбилейное 112 г", "4600000123456"},
		{"Сок Rich яблочный 1 л", "4823063101234"}, {"Plus 18 Energy Drink 0,45 л", "4780101734276"},
	} {
		photo := uploadBytes(t, srv, tok, jpegOf(300, 300, color.RGBA{uint8(40 * i), 100, 100, 255}))
		id := a.expect(a.do("POST", "/admin/products", tok, map[string]any{
			"name": p.name, "category_id": cat, "unit_id": pcs, "base_price": 10000, "images": []string{photo}, "barcodes": []string{p.barcode},
		}), 201, "product").str("id")
		prods[p.name], olds[p.name] = id, photo
	}

	// Лимит 0 $ — ничего не делается.
	s := a.expect(a.do("PUT", "/admin/ai-photo/web", tok, map[string]any{"limit_usd": 0, "serper_key": "serper-key-a91f"}), 200, "web settings")
	web := s.Body["web"].(map[string]any)
	if web["check"] != true || web["auto"] != true || web["has_serper"] != true || web["serper_last4"] != "a91f" || web["limit_usd"] != 0.0 {
		t.Fatalf("web settings = %v", web)
	}
	if len(gem.text) != 0 {
		t.Fatalf("limit 0, but Gemini called %d", len(gem.text))
	}
	sum = a.expect(a.do("GET", "/admin/ai-photo/web/summary", tok, nil), 200, "summary")
	// Остальной каталог не одобрен, а в магазинах товаров нет — ждать нечего.
	if sum.Body["total"] != 5.0 || sum.Body["checked"] != 0.0 || sum.Body["queued"] != 0.0 || sum.Body["rest_queued"] != 5.0 ||
		sum.Body["rest"] != false || sum.Body["paused"] != true {
		t.Fatalf("summary limit = %v", sum.Body)
	}
	if r := a.do("PUT", "/admin/ai-photo/web", tok, map[string]any{"limit_usd": -1}); r.Status != 400 {
		t.Fatalf("limit -1 = %d", r.Status)
	}

	// Сначала — товары, которые есть в магазинах: Coca-Cola и вода в магазине.
	_, storeID := setupNetwork(t, a, tok, "+998900000002")
	if _, err := pool.Exec(ctx, `INSERT INTO store_products (network_id, store_id, product_id)
		SELECT s.network_id, s.id, p FROM stores s, unnest($2::uuid[]) p WHERE s.id = $1`,
		storeID, []string{prods["Coca-Cola 0,33 л ж/б"], prods["Вода Wellness 0,5 л"]}); err != nil {
		t.Fatal(err)
	}
	a.expect(a.do("PUT", "/admin/ai-photo/web", tok, map[string]any{"limit_usd": 100}), 200, "web settings")
	sum = a.expect(a.do("GET", "/admin/ai-photo/web/summary", tok, nil), 200, "summary stores")
	if sum.Body["stores_total"] != 2.0 || sum.Body["stores_checked"] != 2.0 || sum.Body["stores_queued"] != 0.0 || sum.Body["checked"] != 2.0 ||
		sum.Body["rest_queued"] != 3.0 || sum.Body["queued"] != 0.0 {
		t.Fatalf("summary stores = %v", sum.Body)
	}
	// Остальной каталог — после одобрения.
	s = a.expect(a.do("PUT", "/admin/ai-photo/web", tok, map[string]any{"rest": true}), 200, "rest")
	if s.Body["web"].(map[string]any)["rest"] != true {
		t.Fatalf("rest = %v", s.Body["web"])
	}
	jobs := a.expect(a.do("GET", "/admin/ai-photo/web/jobs?status=all", tok, nil), 200, "jobs").items()
	byName := map[string]map[string]any{}
	for _, j := range jobs {
		byName[j["name"].(string)] = j
	}
	if len(byName) != 5 {
		t.Fatalf("jobs = %v", jobs)
	}
	images := func(name string) []string {
		var imgs []string
		if err := pool.QueryRow(ctx, `SELECT images FROM products WHERE id = $1`, prods[name]).Scan(&imgs); err != nil {
			t.Fatal(err)
		}
		return imgs
	}
	// Coca-Cola: оборот → Open Food Facts по штрихкоду.
	j := byName["Coca-Cola 0,33 л ж/б"]
	if j["status"] != "replaced" || j["reason"] != "back" || j["reason_text"] != "Оборот: штрихкод и состав" || j["found_source"] != "off" ||
		j["placed"] != true || j["origin"] != "catalog" || !strings.Contains(j["result_image"].(string), "/api/v1/media/") ||
		!strings.HasSuffix(j["found_page"].(string), "/product/5000112545326") || j["verdict"].(map[string]any)["barcode"] != true {
		t.Fatalf("coke = %v", j)
	}
	if imgs := images("Coca-Cola 0,33 л ж/б"); len(imgs) != 1 || imgs[0] != j["result_image"] {
		t.Fatalf("coke images = %v, result %v", imgs, j["result_image"])
	}
	// Вода: чертёж → в Open Food Facts нет → Google, второй из годных (маленькие и не фото — мимо).
	j = byName["Вода Wellness 0,5 л"]
	cands := j["candidates"].([]any)
	if j["status"] != "replaced" || j["found_source"] != "google" || j["found_page"] != "https://shop.example/b" || len(cands) != 2 ||
		cands[1].(map[string]any)["best"] != true || cands[0].(map[string]any)["ok"] != false {
		t.Fatalf("water = %v", j)
	}
	// Печенье: ничего не подошло → «Не нашли», старое фото на месте.
	j = byName["Печенье Юбилейное 112 г"]
	if j["status"] != "not_found" || j["attempts"] != 1.0 || j["next_at"] == nil || len(j["candidates"].([]any)) != 2 {
		t.Fatalf("cookie = %v", j)
	}
	if imgs := images("Печенье Юбилейное 112 г"); len(imgs) != 1 || imgs[0] != olds["Печенье Юбилейное 112 г"] {
		t.Fatalf("cookie images = %v", imgs)
	}
	// Сок: фото в порядке.
	if j = byName["Сок Rich яблочный 1 л"]; j["status"] != "ok" || j["reason"] != "ok" {
		t.Fatalf("juice = %v", j)
	}
	// Energy: оборот, в сети не нашли → лицевая сторона из своего фото.
	if j = byName["Plus 18 Energy Drink 0,45 л"]; j["status"] != "replaced" || j["found_source"] != "own" {
		t.Fatalf("energy = %v", j)
	}
	// В Gemini ушли запросы: проверка — по одному на товар, лицевая сторона — в инструкции.
	checks := 0
	for _, p := range gem.text {
		if strings.HasPrefix(p, "You check product photos") {
			checks++
		}
	}
	if checks != 5 {
		t.Fatalf("checks = %d", checks)
	}
	if len(gem.prompts) != 3 || !strings.Contains(gem.prompts[0], "Front side:") {
		t.Fatalf("image prompts = %d %q", len(gem.prompts), gem.prompts)
	}
	serperMu.Lock()
	if len(serperQ) != 3 || serperQ[0]["page"] != 1.0 {
		t.Fatalf("serper = %v", serperQ)
	}
	serperMu.Unlock()

	sum = a.expect(a.do("GET", "/admin/ai-photo/web/summary", tok, nil), 200, "summary")
	if sum.Body["checked"] != 5.0 || sum.Body["bad"] != 4.0 || sum.Body["replaced"] != 3.0 || sum.Body["replaced_off"] != 1.0 ||
		sum.Body["replaced_google"] != 1.0 || sum.Body["replaced_own"] != 1.0 || sum.Body["not_found"] != 1.0 || sum.Body["queued"] != 0.0 ||
		sum.Body["paused"] != false || sum.Body["month_search_usd"].(float64) < 0.0019 || sum.Body["month_gemini_usd"].(float64) <= 0 {
		t.Fatalf("summary = %v", sum.Body)
	}
	// Список по умолчанию — все плохие; фильтр и поиск.
	if items := a.expect(a.do("GET", "/admin/ai-photo/web/jobs", tok, nil), 200, "bad").Body; items["total"] != 4.0 {
		t.Fatalf("bad = %v", items)
	}
	if items := a.expect(a.do("GET", "/admin/ai-photo/web/jobs?status=replaced&q=5000112545326", tok, nil), 200, "q").items(); len(items) != 1 {
		t.Fatalf("q = %v", items)
	}
	if r := a.do("GET", "/admin/ai-photo/web/jobs?status=xxx", tok, nil); r.Status != 400 {
		t.Fatalf("bad status = %d", r.Status)
	}

	// «Вернуть старое» — старое фото на месте, больше не трогаем.
	coke := byName["Coca-Cola 0,33 л ж/б"]["id"].(string)
	rv := a.expect(a.do("POST", "/admin/ai-photo/web/jobs/"+coke+"/revert", tok, nil), 200, "revert")
	if rv.Body["status"] != "reverted" || rv.Body["placed"] != false {
		t.Fatalf("revert = %v", rv.Body)
	}
	if imgs := images("Coca-Cola 0,33 л ж/б"); len(imgs) != 1 || imgs[0] != olds["Coca-Cola 0,33 л ж/б"] {
		t.Fatalf("reverted images = %v", imgs)
	}
	// «Поставить» обратно.
	if ap := a.expect(a.do("POST", "/admin/ai-photo/web/jobs/"+coke+"/apply", tok, nil), 200, "apply"); ap.Body["status"] != "replaced" || ap.Body["placed"] != true {
		t.Fatalf("apply = %v", ap.Body)
	}

	// Печенье: «Выбрать» первое из найденных.
	cookie := byName["Печенье Юбилейное 112 г"]["id"].(string)
	if r := a.do("POST", "/admin/ai-photo/web/jobs/"+cookie+"/pick", tok, map[string]any{"candidate": 7}); r.Status != 400 {
		t.Fatalf("pick 7 = %d", r.Status)
	}
	pk := a.expect(a.do("POST", "/admin/ai-photo/web/jobs/"+cookie+"/pick", tok, map[string]any{"candidate": 0}), 200, "pick")
	if pk.Body["status"] != "replaced" || pk.Body["found_source"] != "google" || pk.Body["placed"] != true {
		t.Fatalf("pick = %v", pk.Body)
	}
	if imgs := images("Печенье Юбилейное 112 г"); len(imgs) != 1 || imgs[0] != pk.Body["result_image"] {
		t.Fatalf("picked images = %v", imgs)
	}
	// Своё фото.
	own := uploadBytes(t, srv, tok, jpegOf(300, 300, color.RGBA{10, 200, 10, 255}))
	pk = a.expect(a.do("POST", "/admin/ai-photo/web/jobs/"+cookie+"/pick", tok, map[string]any{"image": own}), 200, "pick own")
	if pk.Body["status"] != "replaced" || pk.Body["found_source"] != "own" {
		t.Fatalf("pick own = %v", pk.Body)
	}
	if imgs := images("Печенье Юбилейное 112 г"); len(imgs) != 1 || imgs[0] != pk.Body["result_image"] {
		t.Fatalf("own images = %v", imgs)
	}

	// «Поискать ещё» — следующая страница Google; найденное не подходит → «Не нашли».
	gem.mu.Lock()
	gem.best["Вода Wellness"] = 0
	gem.mu.Unlock()
	water := byName["Вода Wellness 0,5 л"]["id"].(string)
	rs := a.expect(a.do("POST", "/admin/ai-photo/web/jobs/"+water+"/research", tok, nil), 200, "research")
	if rs.Body["status"] != "not_found" {
		t.Fatalf("research = %v", rs.Body)
	}
	serperMu.Lock()
	if last := serperQ[len(serperQ)-1]; last["page"] != 2.0 {
		t.Fatalf("research page = %v", last)
	}
	serperMu.Unlock()
	// «Повторить «Не нашли»».
	gem.mu.Lock()
	gem.best["Вода Wellness"] = 1
	gem.mu.Unlock()
	rt := a.expect(a.do("POST", "/admin/ai-photo/web/retry-not-found", tok, nil), 200, "retry")
	if rt.Body["queued"] != 1.0 {
		t.Fatalf("retry = %v", rt.Body)
	}
	if w := a.expect(a.do("GET", "/admin/ai-photo/web/jobs/"+water, tok, nil), 200, "water").Body; w["status"] != "replaced" {
		t.Fatalf("water retry = %v", w)
	}

	// «Ставить сразу» выключено — найденное ждёт решения.
	a.expect(a.do("PUT", "/admin/ai-photo/web", tok, map[string]any{"auto": false}), 200, "auto off")
	juice := byName["Сок Rich яблочный 1 л"]["id"].(string)
	gem.mu.Lock()
	gem.checks["Сок Rich"] = "wrong"
	gem.best["Сок Rich"] = 1
	gem.mu.Unlock()
	ck := a.expect(a.do("POST", "/admin/ai-photo/web/check", tok, map[string]any{"product_id": prods["Сок Rich яблочный 1 л"]}), 200, "check")
	if ck.Body["id"] != juice || ck.Body["status"] != "pending" || ck.Body["placed"] != false {
		t.Fatalf("pending = %v", ck.Body)
	}
	if imgs := images("Сок Rich яблочный 1 л"); imgs[0] != olds["Сок Rich яблочный 1 л"] {
		t.Fatalf("pending images = %v", imgs)
	}

	// Новый товар — проверяется при следующем проходе; ключ Serper можно убрать.
	s = a.expect(a.do("PUT", "/admin/ai-photo/web", tok, map[string]any{"serper_key": ""}), 200, "no serper")
	if s.Body["web"].(map[string]any)["has_serper"] != false {
		t.Fatalf("serper removed = %v", s.Body["web"])
	}
	// Расход записан по видам.
	var webN, searchN int
	if err := pool.QueryRow(ctx, `SELECT count(*) FILTER (WHERE kind = 'photo_web'), count(*) FILTER (WHERE kind = 'web_search') FROM ai_usage`).Scan(&webN, &searchN); err != nil {
		t.Fatal(err)
	}
	if webN == 0 || searchN != 6 {
		t.Fatalf("usage photo_web=%d web_search=%d", webN, searchN)
	}
}
