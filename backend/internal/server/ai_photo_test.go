package server_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// fakeGemini — Gemini API: список моделей и generateContent с картинкой в ответе.
type fakeGemini struct {
	mu       sync.Mutex
	key      string
	calls    int
	prompts  []string
	search   []bool // был ли инструмент googleSearch в запросе
	noSearch bool   // отвечать 400 на запрос с поиском
	images   []int  // сколько фото было в запросе
	fail     bool   // отвечать 500
	onCall   func() // перед ответом (магазин меняет фото, пока Gemini рисует)
}

func (f *fakeGemini) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if r.Header.Get("x-goog-api-key") != f.key {
		w.WriteHeader(403)
		_, _ = w.Write([]byte(`{"error":{"message":"API key not valid"}}`))
		return
	}
	switch {
	case r.Method == "GET" && r.URL.Path == "/models":
		_, _ = w.Write([]byte(`{"models":[
			{"name":"models/gemini-2.5-flash","supportedGenerationMethods":["generateContent"]},
			{"name":"models/imagen-4.0-generate-001","supportedGenerationMethods":["predict"]},
			{"name":"models/gemini-3-pro-image","supportedGenerationMethods":["generateContent","countTokens"]}]}`))
	case r.Method == "POST" && r.URL.Path == "/models/gemini-3-pro-image:generateContent":
		var body struct {
			Contents []struct {
				Parts []struct {
					Text       string `json:"text"`
					InlineData *struct {
						MimeType string `json:"mimeType"`
						Data     string `json:"data"`
					} `json:"inlineData"`
				} `json:"parts"`
			} `json:"contents"`
			GenerationConfig struct {
				Modalities []string `json:"responseModalities"`
				Image      struct {
					Aspect string `json:"aspectRatio"`
					Size   string `json:"imageSize"`
				} `json:"imageConfig"`
			} `json:"generationConfig"`
			Tools []map[string]any `json:"tools"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		parts := body.Contents[0].Parts
		if len(parts) < 2 || parts[0].InlineData == nil || parts[0].InlineData.Data == "" || body.GenerationConfig.Image.Aspect != "1:1" ||
			!strings.Contains(strings.Join(body.GenerationConfig.Modalities, ","), "IMAGE") {
			w.WriteHeader(400)
			_, _ = w.Write([]byte(`{"error":{"message":"bad request"}}`))
			return
		}
		search := len(body.Tools) > 0
		if search && f.noSearch {
			w.WriteHeader(400)
			_, _ = w.Write([]byte(`{"error":{"message":"Search is not supported"}}`))
			return
		}
		if f.fail {
			w.WriteHeader(500)
			_, _ = w.Write([]byte(`{"error":{"message":"internal"}}`))
			return
		}
		if f.onCall != nil {
			f.onCall()
		}
		f.calls++
		f.prompts = append(f.prompts, parts[len(parts)-1].Text+" | size="+body.GenerationConfig.Image.Size)
		f.search = append(f.search, search)
		f.images = append(f.images, len(parts)-1)
		// Картинка 64×48 (не квадрат) — сервер вписывает её в квадрат сам.
		img := image.NewRGBA(image.Rect(0, 0, 64, 48))
		for i := range img.Pix {
			img.Pix[i] = 200
			if i%4 == 3 {
				img.Pix[i] = 255
			}
		}
		var buf bytes.Buffer
		_ = png.Encode(&buf, img)
		out, _ := json.Marshal(map[string]any{
			"candidates": []any{map[string]any{"content": map[string]any{"parts": []any{
				map[string]any{"text": "draft", "thought": true},
				map[string]any{"text": "Here is the photo"},
				map[string]any{"inlineData": map[string]any{"mimeType": "image/png", "data": base64.StdEncoding.EncodeToString(buf.Bytes())}},
			}}, "finishReason": "STOP"}},
			"usageMetadata": map[string]any{"promptTokenCount": 500, "candidatesTokenCount": 1120},
		})
		_, _ = w.Write(out)
	default:
		w.WriteHeader(404)
	}
}

// TestAIPhoto — «ИИ для фото»: супер-админ подключает Gemini отдельно от
// ИИ-сервиса, проверяет на стандартном фото, «Нормализовать фото» товара
// кладёт квадратные фото в хранилище; расход — по прайсу картинок.
func TestAIPhoto(t *testing.T) {
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

	s := a.expect(a.do("GET", "/admin/ai-photo", adminTok, nil), 200, "settings")
	if s.Body["configured"] != false || s.Body["mode"] != "gemini" || !strings.Contains(s.Body["default_prompt"].(string), "12.") {
		t.Fatalf("settings = %v", s.Body)
	}
	if r := a.do("POST", "/admin/ai-photo/normalize", adminTok, map[string]any{"images": []string{"x"}}); r.Status != 409 || errCode(r) != "ai_photo_not_configured" {
		t.Fatalf("normalize off = %d %v", r.Status, r.Body)
	}
	// JSON-ключ сервисного аккаунта — это Vertex AI, не Gemini API.
	if r := a.do("POST", "/admin/ai-photo/models", adminTok, map[string]any{"mode": "gemini", "base_url": gemsrv.URL, "api_key": `{"type":"service_account"}`}); r.Status != 400 {
		t.Fatalf("json key = %d %v", r.Status, r.Body)
	}
	models := a.expect(a.do("POST", "/admin/ai-photo/models", adminTok, map[string]any{"mode": "gemini", "base_url": gemsrv.URL, "api_key": gem.key}), 200, "models").items()
	if len(models) != 1 || models[0]["id"] != "gemini-3-pro-image" {
		t.Fatalf("models = %v", models)
	}
	s = a.expect(a.do("PUT", "/admin/ai-photo", adminTok, map[string]any{
		"mode": "gemini", "base_url": gemsrv.URL, "api_key": gem.key, "model": "gemini-3-pro-image",
		"background": "light", "size": 1500, "outpaint": true, "web_search": true,
	}), 200, "save")
	if s.Body["configured"] != true || s.Body["key_last4"] != "Xq7c" || s.Body["size"] != 1500.0 || s.Body["has_key"] != true {
		t.Fatalf("saved = %v", s.Body)
	}
	if r := a.do("PUT", "/admin/ai-photo", adminTok, map[string]any{"size": 1200}); r.Status != 400 {
		t.Fatalf("size 1200 = %d", r.Status)
	}
	// ИИ-сервис накладных этим не подключился.
	if ai := a.expect(a.do("GET", "/admin/ai", adminTok, nil), 200, "ai"); ai.Body["configured"] != false {
		t.Fatalf("ai = %v", ai.Body)
	}

	// Проверка на стандартном фото: сохранённые настройки, итог записывается.
	job := a.expect(a.do("POST", "/admin/ai-photo/test", adminTok, map[string]any{}), 202, "test")
	if job.Body["running"] != false || job.Body["ok"] != true || !strings.HasPrefix(job.Body["message"].(string), "Gemini работает") {
		t.Fatalf("test job = %v", job.Body)
	}
	item := job.Body["items"].([]any)[0].(map[string]any)
	if !strings.HasPrefix(item["source"].(string), "data:image/jpeg;base64,") {
		t.Fatalf("test source = %.60s", item["source"])
	}
	res := item["result"].(string)
	raw, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(res, "data:image/jpeg;base64,"))
	if err != nil {
		t.Fatalf("result = %.60s", res)
	}
	checkSquare(t, raw, 1500, color.RGBA{242, 242, 242, 255})
	if len(gem.search) != 1 || gem.search[0] || !strings.Contains(gem.prompts[0], "#F2F2F2") || !strings.Contains(gem.prompts[0], "size=2K") ||
		!strings.Contains(gem.prompts[0], "complete the missing part") {
		t.Fatalf("test request: search=%v prompt=%q", gem.search, gem.prompts)
	}
	if got := a.expect(a.do("GET", "/admin/ai-photo/jobs/"+job.str("id"), adminTok, nil), 200, "job"); got.Body["ok"] != true {
		t.Fatalf("job = %v", got.Body)
	}
	if s = a.expect(a.do("GET", "/admin/ai-photo", adminTok, nil), 200, "settings"); s.Body["check_ok"] != true {
		t.Fatalf("checked = %v", s.Body)
	}

	// Товар с фото: «Нормализовать фото».
	cat := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Соки"}), 201, "category").str("id")
	var pcs string
	for _, u := range a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items() {
		if u["short_name"] == "шт" {
			pcs = u["id"].(string)
		}
	}
	photo := adminUpload(t, srv, adminTok)
	prod := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
		"name": "Сок Rich яблочный, 1 л", "category_id": cat, "unit_id": pcs, "base_price": 21000,
		"images": []string{photo}, "barcodes": []string{"4823063101234"},
	}), 201, "product").str("id")

	// Модель не принимает поиск — запрос повторяется без него.
	gem.noSearch = true
	job = a.expect(a.do("POST", "/admin/ai-photo/normalize", adminTok, map[string]any{
		"product_id": prod, "images": []string{photo, "https://example.com/x.jpg"},
	}), 202, "normalize")
	items := job.Body["items"].([]any)
	first, second := items[0].(map[string]any), items[1].(map[string]any)
	if first["error"] != "" || !strings.Contains(first["result"].(string), "/api/v1/media/") || second["result"] != "" ||
		!strings.Contains(second["error"].(string), "хранилища") {
		t.Fatalf("normalize = %v", job.Body)
	}
	last := gem.prompts[len(gem.prompts)-1]
	if !strings.Contains(last, "Сок Rich яблочный, 1 л, barcode 4823063101234") || !strings.Contains(last, "Google Search") || gem.search[len(gem.search)-1] {
		t.Fatalf("normalize prompt = %q search=%v", last, gem.search)
	}
	media, err := http.Get(first["result"].(string))
	if err != nil || media.StatusCode != 200 {
		t.Fatalf("media %s: %v %v", first["result"], err, media)
	}
	data, _ := io.ReadAll(media.Body)
	media.Body.Close()
	checkSquare(t, data, 1500, color.RGBA{242, 242, 242, 255})

	// Расход: проверка и фото товара — по прайсу картинок, отдельно от токенов ИИ-сервиса.
	var photos, tests int
	var cost float64
	var product *string
	if err := pool.QueryRow(ctx, `SELECT count(*) FILTER (WHERE kind = 'photo'), count(*) FILTER (WHERE kind = 'photo_test'),
		sum(cost) FILTER (WHERE kind = 'photo')::float8, max(product_id::text) FROM ai_usage`).Scan(&photos, &tests, &cost, &product); err != nil {
		t.Fatal(err)
	}
	// 500 входных × $2 + 1120 выходных × $120 за 1 млн.
	if photos != 1 || tests != 1 || cost < 0.1353 || cost > 0.1355 || product == nil || *product != prod {
		t.Fatalf("usage: photos=%d tests=%d cost=%v product=%v", photos, tests, cost, product)
	}
	if s = a.expect(a.do("GET", "/admin/ai-photo", adminTok, nil), 200, "settings"); s.Body["month_photos"] != 1.0 {
		t.Fatalf("month = %v", s.Body)
	}
	use := a.expect(a.do("GET", "/admin/ai/usage", adminTok, nil), 200, "usage")
	if tot := use.Body["totals"].(map[string]any); tot["product_photos"] != 1.0 || tot["tests"] != 1.0 {
		t.Fatalf("usage totals = %v", tot)
	}

	// Страница товара: откуда он, налоги, где продаётся.
	ov := a.expect(a.do("GET", "/admin/products/"+prod+"/overview", adminTok, nil), 200, "overview")
	sell := ov.Body["selling"].(map[string]any)
	if ov.Body["source"] != "Super Market" || ov.Body["variants"] != nil || sell["stores"] != 0.0 || ov.Body["tax"].(map[string]any)["vat_rate"] == nil {
		t.Fatalf("overview = %v", ov.Body)
	}
	if r := a.do("GET", "/admin/products/00000000-0000-4000-8000-000000000000/overview", adminTok, nil); r.Status != 404 {
		t.Fatalf("overview 404 = %d", r.Status)
	}

	// Прозрачный фон: настройка сохраняется, проверка отдаёт PNG.
	if s = a.expect(a.do("PUT", "/admin/ai-photo", adminTok, map[string]any{"background": "transparent"}), 200, "transparent"); s.Body["background"] != "transparent" {
		t.Fatalf("transparent = %v", s.Body)
	}
	job = a.expect(a.do("POST", "/admin/ai-photo/test", adminTok, map[string]any{}), 202, "test transparent")
	if res := job.Body["items"].([]any)[0].(map[string]any)["result"].(string); job.Body["ok"] != true || !strings.HasPrefix(res, "data:image/png;base64,") {
		t.Fatalf("transparent test = %v", job.Body)
	}
	if !strings.Contains(gem.prompts[len(gem.prompts)-1], "#FF00FF") {
		t.Fatalf("transparent prompt = %q", gem.prompts[len(gem.prompts)-1])
	}
}

func checkSquare(t *testing.T, raw []byte, size int, bg color.RGBA) {
	t.Helper()
	img, err := jpeg.Decode(bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("jpeg: %v", err)
	}
	if b := img.Bounds(); b.Dx() != size || b.Dy() != size {
		t.Fatalf("size = %v", b)
	}
	// Картинка 4:3 вписана в квадрат — сверху и снизу поля цвета фона.
	r, g, b, _ := img.At(size/2, 3).RGBA()
	if d := int(r>>8) - int(bg.R); d < -6 || d > 6 || int(g>>8) < int(bg.G)-6 || int(b>>8) < int(bg.B)-6 {
		t.Fatalf("top = %d %d %d", r>>8, g>>8, b>>8)
	}
	if r, _, _, _ := img.At(size/2, size/2).RGBA(); int(r>>8) < 190 || int(r>>8) > 210 {
		t.Fatalf("center = %d", r>>8)
	}
}

func adminUpload(t *testing.T, srv *httptest.Server, tok string) string {
	t.Helper()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	fw, _ := mw.CreateFormFile("file", "photo.png")
	_, _ = fw.Write(tinyPNG)
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
