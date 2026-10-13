package server_test

import (
	"bytes"
	"context"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// TestStorePhotos — нормализация фото для магазина: Super Market сам делает
// чистое фото нового товара после распознавания и фото строки инвентаризации,
// если у товара фото не было. Магазин ничего не нажимает; «Оставить моё
// фото» и «Переделать» — по желанию; лимит — по тарифу в месяц.
func TestStorePhotos(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	s3 := &fakeS3{buckets: map[string]bool{}, objects: map[string][]byte{}, types: map[string]string{}}
	s3srv := httptest.NewServer(s3)
	t.Cleanup(s3srv.Close)
	fai := &fakeCategoryAI{}
	aisrv := httptest.NewServer(fai)
	t.Cleanup(aisrv.Close)
	gem := &fakeGemini{key: "AIzaSyTest-Xq7c"}
	gemsrv := httptest.NewServer(gem)
	t.Cleanup(gemsrv.Close)

	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	cfg.S3Endpoint, cfg.S3AccessKey, cfg.S3SecretKey, cfg.S3Bucket = s3srv.URL, "minio", "secret", "media"
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
	otherTok, _ := setupNetwork(t, a, adminTok, "+998900000003")

	drinks := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Напитки"}), 201, "drinks").str("id")
	juices := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Соки и нектары", "parent_id": drinks}), 201, "juices").str("id")
	var pcs string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		if u["short_name"] == "шт" {
			pcs = u["id"].(string)
		}
	}
	upload := func() string {
		t.Helper()
		var body bytes.Buffer
		mw := multipart.NewWriter(&body)
		fw, _ := mw.CreateFormFile("file", "item.png")
		_, _ = fw.Write(tinyPNG)
		_ = mw.Close()
		req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/v1/store/uploads", &body)
		req.Header.Set("Content-Type", mw.FormDataContentType())
		req.Header.Set("Authorization", "Bearer "+ownerTok)
		res, err := srv.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		out := map[string]any{}
		_ = json.NewDecoder(res.Body).Decode(&out)
		return out["url"].(string)
	}
	images := func(productID string) []string {
		t.Helper()
		var imgs []string
		if err := pool.QueryRow(ctx, `SELECT images FROM products WHERE id = $1`, productID).Scan(&imgs); err != nil {
			t.Fatal(err)
		}
		return imgs
	}
	quota := func() resp {
		return a.expect(a.do("GET", "/store/start/photo-quota?store_id="+storeID, ownerTok, nil), 200, "quota")
	}
	recognize := func(name string) {
		fai.set(`{"product":true,"name":"`+name+`","name_uz":"`+name+`","brand":"Bliss","unit":"шт","match":"`+juices+`","alternatives":[]}`, `{"texts":["x"]}`)
	}
	front, label := upload(), upload()

	// Распознавание подключено, «ИИ для фото» — нет: фото не делаются.
	a.expect(a.do("PUT", "/admin/ai", adminTok, map[string]any{"provider": "openai", "base_url": aisrv.URL + "/v1", "api_key": "sk-cat", "model": "gpt-4o"}), 200, "ai on")
	recognize("Сок Bliss вишнёвый, 1 л")
	r := a.expect(a.do("POST", "/store/start/new-items", ownerTok, map[string]any{"store_id": storeID, "images": []string{front}}), 202, "no photo ai")
	if r.str("status") != "ready" || r.Body["photo"] != nil {
		t.Fatalf("no photo ai = %v", r.Body)
	}
	if q := quota(); q.Body["enabled"] != false || q.Body["used"] != 0.0 {
		t.Fatalf("quota off = %v", q.Body)
	}

	s := a.expect(a.do("PUT", "/admin/ai-photo", adminTok, map[string]any{
		"mode": "gemini", "base_url": gemsrv.URL, "api_key": gem.key, "model": "gemini-3-pro-image",
		"background": "white", "size": 1000, "outpaint": true, "web_search": false,
	}), 200, "photo ai on")
	if s.Body["store_enabled"] != true || s.Body["store_new_items"] != true || s.Body["store_lines"] != true || s.Body["store_model"] != "" {
		t.Fatalf("store settings = %v", s.Body)
	}
	if q := quota(); q.Body["enabled"] != true || q.Body["used"] != 0.0 || q.Body["limit"] != 300.0 || q.str("resets_on") == "" {
		t.Fatalf("quota = %v", q.Body)
	}
	a.expect(a.do("GET", "/store/start/photo-quota?store_id="+storeID, otherTok, nil), 404, "foreign quota")

	// Новый товар по 2 фото: Super Market сам делает одно чистое фото лицевой стороны.
	recognize("Сок Bliss яблочный, 1 л")
	r = a.expect(a.do("POST", "/store/start/new-items", ownerTok, map[string]any{"store_id": storeID, "images": []string{front, label}}), 202, "new item")
	clean := r.str("photo", "image")
	if r.str("status") != "ready" || r.str("photo", "status") != "done" || !strings.HasPrefix(clean, srv.URL+"/api/v1/media/") {
		t.Fatalf("new item photo = %v", r.Body)
	}
	if gem.calls != 1 || gem.images[0] != 2 || !strings.Contains(gem.prompts[0], "These 2 photos") || !strings.Contains(gem.prompts[0], "Сок Bliss яблочный") {
		t.Fatalf("gemini: calls=%d images=%v prompt=%q", gem.calls, gem.images, gem.prompts)
	}
	// Подтвердили со своими фото (старое приложение): чистое фото встаёт первым.
	c := a.expect(a.do("POST", "/store/start/new-items/"+r.str("id")+"/confirm", ownerTok, map[string]any{
		"store_id": storeID, "name": "Сок Bliss яблочный, 1 л", "category_id": juices, "unit_id": pcs, "images": []string{front, label},
	}), 200, "confirm")
	if imgs := images(c.str("product_id")); len(imgs) != 3 || imgs[0] != clean || imgs[1] != front {
		t.Fatalf("confirm images = %v", imgs)
	}
	if c.str("line", "photo") != "done" || c.str("line", "image") != clean {
		t.Fatalf("confirm line = %v", c.Body["line"])
	}

	// «Оставить моё фото» — чистое фото не ставится.
	recognize("Сок Bliss грушевый, 1 л")
	r = a.expect(a.do("POST", "/store/start/new-items", ownerTok, map[string]any{"store_id": storeID, "images": []string{front}}), 202, "pear")
	c = a.expect(a.do("POST", "/store/start/new-items/"+r.str("id")+"/confirm", ownerTok, map[string]any{
		"store_id": storeID, "name": "Сок Bliss грушевый, 1 л", "category_id": juices, "unit_id": pcs, "images": []string{front}, "keep_own_photo": true,
	}), 200, "keep own")
	if imgs := images(c.str("product_id")); len(imgs) != 1 || imgs[0] != front || c.str("line", "photo") != "" {
		t.Fatalf("keep own = %v | %v", imgs, c.Body["line"])
	}

	// «Переделать» — ещё одно фото (считается в лимит); чужой магазин не может.
	recognize("Сок Bliss персиковый, 1 л")
	peach := a.expect(a.do("POST", "/store/start/new-items", ownerTok, map[string]any{"store_id": storeID, "images": []string{front}}), 202, "peach")
	a.expect(a.do("POST", "/store/start/new-items/"+peach.str("id")+"/photo", otherTok, nil), 404, "foreign redo")
	redo := a.expect(a.do("POST", "/store/start/new-items/"+peach.str("id")+"/photo", ownerTok, nil), 202, "redo")
	if redo.str("photo", "status") != "done" || redo.str("photo", "image") == peach.str("photo", "image") || gem.calls != 4 {
		t.Fatalf("redo = %v (calls %d)", redo.Body, gem.calls)
	}
	if q := quota(); q.Body["used"] != 4.0 {
		t.Fatalf("quota used = %v", q.Body)
	}

	// Gemini не справился — осталось фото магазина, карточку можно подтвердить.
	gem.fail = true
	recognize("Сок Bliss манговый, 1 л")
	r = a.expect(a.do("POST", "/store/start/new-items", ownerTok, map[string]any{"store_id": storeID, "images": []string{front}}), 202, "gemini fail")
	gem.fail = false
	if r.str("photo", "status") != "failed" || r.Body["photo"].(map[string]any)["image"] != nil {
		t.Fatalf("gemini fail = %v", r.Body)
	}
	c = a.expect(a.do("POST", "/store/start/new-items/"+r.str("id")+"/confirm", ownerTok, map[string]any{
		"store_id": storeID, "name": "Сок Bliss манговый, 1 л", "category_id": juices, "unit_id": pcs, "images": []string{front},
	}), 200, "confirm failed photo")
	if imgs := images(c.str("product_id")); len(imgs) != 1 || imgs[0] != front {
		t.Fatalf("failed photo images = %v", imgs)
	}

	// Лимит тарифа на месяц кончился — фото магазина, «Переделать» нельзя.
	if _, err := pool.Exec(ctx, `UPDATE plans SET limits = limits || '{"ai_photos": 4}' WHERE key = (SELECT network_plan(network_id) FROM stores WHERE id = $1)`, storeID); err != nil {
		t.Fatal(err)
	}
	calls := gem.calls
	recognize("Сок Bliss ананасовый, 1 л")
	lim := a.expect(a.do("POST", "/store/start/new-items", ownerTok, map[string]any{"store_id": storeID, "images": []string{front}}), 202, "limit")
	if lim.str("photo", "status") != "limit" || gem.calls != calls {
		t.Fatalf("limit = %v", lim.Body)
	}
	if r := a.do("POST", "/store/start/new-items/"+lim.str("id")+"/photo", ownerTok, nil); r.Status != 409 || errCode(r) != "photo_limit" {
		t.Fatalf("redo over limit = %d %v", r.Status, r.Body)
	}
	if q := quota(); q.Body["used"] != 4.0 || q.Body["limit"] != 4.0 {
		t.Fatalf("quota at limit = %v", q.Body)
	}
	if _, err := pool.Exec(ctx, `UPDATE plans SET limits = limits || '{"ai_photos": 100}'`); err != nil {
		t.Fatal(err)
	}

	// Инвентаризация: товар без фото — магазин снял, Super Market делает чистое.
	tea := a.expect(a.do("POST", "/store/products", ownerTok, map[string]any{"name": "Чай Ахмад, 100 г", "category_id": juices, "unit_id": pcs, "start_draft": true}), 201, "tea").str("id")
	a.expect(a.do("POST", "/store/start/lines", ownerTok, map[string]any{"store_id": storeID, "items": []map[string]any{{"product_id": tea, "add": true, "source": "new"}}}), 200, "tea line")
	lp := a.expect(a.do("POST", "/store/start/lines/"+tea+"/photo", ownerTok, map[string]any{"store_id": storeID, "images": []string{label}}), 200, "line photo")
	teaImgs := images(tea)
	if len(teaImgs) != 2 || teaImgs[1] != label || !strings.HasPrefix(teaImgs[0], srv.URL+"/api/v1/media/") || teaImgs[0] == label {
		t.Fatalf("line photo images = %v", teaImgs)
	}
	// Ответ — сразу, пока фото делается; потом строка показывает фото Super Market.
	if l := lp.Body["lines"].([]any)[0].(map[string]any); l["photo"] != "processing" || l["image"] != label {
		t.Fatalf("line photo = %v", l)
	}
	for _, l := range a.expect(a.do("GET", "/store/start?store_id="+storeID, ownerTok, nil), 200, "draft").Body["lines"].([]any) {
		if m := l.(map[string]any); m["product_id"] == tea && (m["photo"] != "done" || m["image"] != teaImgs[0]) {
			t.Fatalf("draft line photo = %v", m)
		}
	}
	if gem.images[len(gem.images)-1] != 1 || !strings.Contains(gem.prompts[len(gem.prompts)-1], "Чай Ахмад") {
		t.Fatalf("line gemini: %v %q", gem.images, gem.prompts[len(gem.prompts)-1])
	}
	// Фото уже есть — повторный снимок товар не меняет, новое фото не делается.
	calls = gem.calls
	a.expect(a.do("POST", "/store/start/lines/"+tea+"/photo", ownerTok, map[string]any{"store_id": storeID, "images": []string{front}}), 200, "line photo again")
	if gem.calls != calls || len(images(tea)) != 2 {
		t.Fatalf("line photo again: calls %d → %d, images %v", calls, gem.calls, images(tea))
	}

	// Магазин поменял фото, пока Super Market рисовал, — чистое фото ложится вторым.
	coffee := a.expect(a.do("POST", "/store/products", ownerTok, map[string]any{"name": "Кофе Жокей, 100 г", "category_id": juices, "unit_id": pcs, "start_draft": true}), 201, "coffee").str("id")
	a.expect(a.do("POST", "/store/start/lines", ownerTok, map[string]any{"store_id": storeID, "items": []map[string]any{{"product_id": coffee, "add": true, "source": "new"}}}), 200, "coffee line")
	gem.onCall = func() {
		if _, err := pool.Exec(ctx, `UPDATE products SET images = ARRAY[$2::text] WHERE id = $1`, coffee, front); err != nil {
			t.Error(err)
		}
	}
	a.expect(a.do("POST", "/store/start/lines/"+coffee+"/photo", ownerTok, map[string]any{"store_id": storeID, "images": []string{label}}), 200, "coffee photo")
	gem.onCall = nil
	if imgs := images(coffee); len(imgs) != 2 || imgs[0] != front || !strings.HasPrefix(imgs[1], srv.URL+"/api/v1/media/") {
		t.Fatalf("changed meanwhile = %v", imgs)
	}

	// Супер-админ выключил «Фото для магазинов» — фото не делаются.
	s = a.expect(a.do("PUT", "/admin/ai-photo/store", adminTok, map[string]any{"store_enabled": false, "store_model": "gemini-2.5-flash-image"}), 200, "store off")
	if s.Body["store_enabled"] != false || s.Body["store_model"] != "gemini-2.5-flash-image" || s.Body["model"] != "gemini-3-pro-image" {
		t.Fatalf("store off = %v", s.Body)
	}
	a.expect(a.do("PUT", "/admin/ai-photo/store", ownerTok, map[string]any{"store_enabled": true}), 403, "store settings by store")
	calls = gem.calls
	recognize("Сок Bliss лимонный, 1 л")
	r = a.expect(a.do("POST", "/store/start/new-items", ownerTok, map[string]any{"store_id": storeID, "images": []string{front}}), 202, "store off item")
	if r.Body["photo"] != nil || gem.calls != calls {
		t.Fatalf("store off item = %v", r.Body)
	}
	if r := a.do("POST", "/store/start/new-items/"+r.str("id")+"/photo", ownerTok, nil); r.Status != 409 || errCode(r) != "photo_off" {
		t.Fatalf("redo off = %d %v", r.Status, r.Body)
	}

	// Расход — отдельной строкой «Фото магазинов», с магазином.
	s = a.expect(a.do("GET", "/admin/ai-photo", adminTok, nil), 200, "settings")
	top, _ := s.Body["store_top"].([]any)
	if s.Body["store_photos"] != float64(gem.calls) || s.Body["store_failed"] != 1.0 || s.Body["store_networks"] != 1.0 || len(top) != 1 ||
		top[0].(map[string]any)["limit"] != 100.0 || top[0].(map[string]any)["used"] != top[0].(map[string]any)["photos"] || s.Body["month_photos"] != 0.0 {
		t.Fatalf("store month = %v", s.Body)
	}
	u := a.expect(a.do("GET", "/admin/ai/usage", adminTok, nil), 200, "usage")
	if u.Body["totals"].(map[string]any)["store_photos"] != float64(gem.calls) {
		t.Fatalf("usage = %v", u.Body["totals"])
	}
	var withStore int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM ai_usage WHERE kind = 'photo_store' AND store_id = $1 AND network_id IS NOT NULL`, storeID).Scan(&withStore); err != nil || withStore != gem.calls {
		t.Fatalf("usage rows = %d %v", withStore, err)
	}
	// Тариф магазина показывает, сколько фото уже сделано.
	plan := a.expect(a.do("GET", "/store/plan", ownerTok, nil), 200, "plan")
	found := false
	for _, l := range plan.Body["current"].(map[string]any)["limits"].([]any) {
		if m := l.(map[string]any); m["key"] == "ai_photos" {
			found = m["used"] != nil && m["value"] == 100.0
		}
	}
	if !found {
		t.Fatalf("plan limits = %v", plan.Body["current"])
	}
}

// TestStorePhotosWorker — без Sync: фото делает фоновый воркер очереди;
// задание, взятое до перезапуска сервера («processing» давно), берётся снова.
func TestStorePhotosWorker(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	s3 := &fakeS3{buckets: map[string]bool{}, objects: map[string][]byte{}, types: map[string]string{}}
	s3srv := httptest.NewServer(s3)
	t.Cleanup(s3srv.Close)
	gem := &fakeGemini{key: "AIzaSyTest-Xq7c"}
	gemsrv := httptest.NewServer(gem)
	t.Cleanup(gemsrv.Close)

	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	cfg.MediaBaseURL = "https://cdn.example"
	cfg.S3Endpoint, cfg.S3AccessKey, cfg.S3SecretKey, cfg.S3Bucket = s3srv.URL, "minio", "secret", "media"
	app, err := server.Build(ctx, cfg, pool, &fakeTelegram{}, quietLog())
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app.Handler)
	t.Cleanup(srv.Close)
	a := api{t: t, srv: srv, pool: pool}
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	ownerTok, storeID := setupNetwork(t, a, adminTok, "+998900000002")
	cat := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Чай"}), 201, "category").str("id")
	var pcs string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		if u["short_name"] == "шт" {
			pcs = u["id"].(string)
		}
	}
	a.expect(a.do("PUT", "/admin/ai-photo", adminTok, map[string]any{
		"mode": "gemini", "base_url": gemsrv.URL, "api_key": gem.key, "model": "gemini-3-pro-image", "web_search": false,
	}), 200, "photo ai on")
	photo := adminUpload(t, srv, adminTok)
	var network string
	if err := pool.QueryRow(ctx, `SELECT network_id FROM stores WHERE id = $1`, storeID).Scan(&network); err != nil {
		t.Fatal(err)
	}
	add := func(name string) string {
		id := a.expect(a.do("POST", "/store/products", ownerTok, map[string]any{"name": name, "category_id": cat, "unit_id": pcs, "start_draft": true}), 201, name).str("id")
		a.expect(a.do("POST", "/store/start/lines", ownerTok, map[string]any{"store_id": storeID, "items": []map[string]any{{"product_id": id, "add": true, "source": "new"}}}), 200, name+" line")
		return id
	}
	green, black := add("Чай зелёный, 100 г"), add("Чай чёрный, 100 г")
	// Задание чёрного чая «взяли» 20 минут назад, и сервер перезапустился.
	key := strings.TrimPrefix(photo, "https://cdn.example/api/v1/media/")
	if _, err := pool.Exec(ctx, `UPDATE products SET images = ARRAY[$2] WHERE id = $1`, black, photo); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO photo_jobs (network_id, store_id, product_id, sources, status, attempts, started_at)
		VALUES ($1, $2, $3, ARRAY[$4], 'processing', 1, now() - interval '20 minutes')`, network, storeID, black, key); err != nil {
		t.Fatal(err)
	}
	r := a.expect(a.do("POST", "/store/start/lines/"+green+"/photo", ownerTok, map[string]any{"store_id": storeID, "images": []string{photo}}), 200, "line photo")
	if r.Body["lines"].([]any)[0].(map[string]any)["photo"] != "processing" {
		t.Fatalf("line photo = %v", r.Body)
	}
	deadline := time.Now().Add(15 * time.Second)
	for {
		var pending int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM photo_jobs WHERE status <> 'done'`).Scan(&pending); err != nil {
			t.Fatal(err)
		}
		if pending == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("jobs not done: %d", pending)
		}
		time.Sleep(100 * time.Millisecond)
	}
	for _, id := range []string{green, black} {
		var imgs []string
		if err := pool.QueryRow(ctx, `SELECT images FROM products WHERE id = $1`, id).Scan(&imgs); err != nil {
			t.Fatal(err)
		}
		if len(imgs) != 2 || imgs[1] != photo || !strings.HasPrefix(imgs[0], "https://cdn.example/api/v1/media/") {
			t.Fatalf("product %s images = %v", id, imgs)
		}
	}
}
