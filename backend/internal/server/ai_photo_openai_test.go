package server_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// fakeOpenAIImages — OpenAI: список моделей и images/edits (multipart) с картинкой в ответе.
type fakeOpenAIImages struct {
	mu     sync.Mutex
	key    string
	calls  int
	fields []map[string]string // поля последних запросов
	images []int               // сколько фото было в запросе
	no2048 bool                // отвечать 400 на size 2048x2048
}

func (f *fakeOpenAIImages) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if r.Header.Get("Authorization") != "Bearer "+f.key {
		w.WriteHeader(401)
		_, _ = w.Write([]byte(`{"error":{"message":"Incorrect API key provided"}}`))
		return
	}
	switch {
	case r.Method == "GET" && r.URL.Path == "/v1/models":
		_, _ = w.Write([]byte(`{"data":[{"id":"gpt-5-mini"},{"id":"gpt-image-2"},{"id":"dall-e-3"},{"id":"gpt-4o-mini"}]}`))
	case r.Method == "POST" && r.URL.Path == "/v1/images/edits":
		if err := r.ParseMultipartForm(20 << 20); err != nil {
			w.WriteHeader(400)
			return
		}
		got := map[string]string{}
		for k, v := range r.MultipartForm.Value {
			got[k] = v[0]
		}
		files := r.MultipartForm.File["image[]"]
		if got["model"] != "gpt-image-2" || got["prompt"] == "" || len(files) == 0 {
			w.WriteHeader(400)
			_, _ = w.Write([]byte(`{"error":{"message":"bad request"}}`))
			return
		}
		if got["size"] == "2048x2048" && f.no2048 {
			w.WriteHeader(400)
			_, _ = w.Write([]byte(`{"error":{"message":"Invalid size"}}`))
			return
		}
		f.calls++
		f.fields = append(f.fields, got)
		f.images = append(f.images, len(files))
		img := image.NewRGBA(image.Rect(0, 0, 64, 48))
		for i := range img.Pix {
			img.Pix[i] = 200
			if i%4 == 3 {
				img.Pix[i] = 255
			}
		}
		var buf bytes.Buffer
		_ = png.Encode(&buf, img)
		out, _ := json.Marshal(map[string]any{"data": []any{map[string]any{"b64_json": base64.StdEncoding.EncodeToString(buf.Bytes())}},
			"usage": map[string]any{"input_tokens": 500, "output_tokens": 4160}})
		_, _ = w.Write(out)
	default:
		w.WriteHeader(404)
	}
}

// TestAIPhotoOpenAI — «ИИ для фото» через OpenAI (Figma Ф3): модели GPT Image
// ключа, качество, без поиска в интернете, расход по прайсу OpenAI.
func TestAIPhotoOpenAI(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	oa := &fakeOpenAIImages{key: "sk-proj-Test9Zq1", no2048: true}
	oasrv := httptest.NewServer(oa)
	t.Cleanup(oasrv.Close)

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
	base := oasrv.URL + "/v1"

	if r := a.do("POST", "/admin/ai-photo/models", adminTok, map[string]any{"mode": "openai", "base_url": base, "api_key": `{"type":"service_account"}`}); r.Status != 400 {
		t.Fatalf("json key = %d %v", r.Status, r.Body)
	}
	models := a.expect(a.do("POST", "/admin/ai-photo/models", adminTok, map[string]any{"mode": "openai", "base_url": base, "api_key": oa.key}), 200, "models").items()
	if len(models) != 1 || models[0]["id"] != "gpt-image-2" {
		t.Fatalf("models = %v", models)
	}
	if r := a.do("PUT", "/admin/ai-photo", adminTok, map[string]any{"mode": "openai", "base_url": base, "api_key": oa.key, "model": "gpt-image-2", "quality": "ultra"}); r.Status != 400 {
		t.Fatalf("quality ultra = %d", r.Status)
	}
	s := a.expect(a.do("PUT", "/admin/ai-photo", adminTok, map[string]any{
		"mode": "openai", "base_url": base, "api_key": oa.key, "model": "gpt-image-2", "quality": "high", "size": 2000, "web_search": true,
	}), 200, "save")
	if s.Body["configured"] != true || s.Body["mode"] != "openai" || s.Body["quality"] != "high" || s.Body["web_search"] != false || s.Body["key_last4"] != "9Zq1" {
		t.Fatalf("saved = %v", s.Body)
	}

	job := a.expect(a.do("POST", "/admin/ai-photo/test", adminTok, map[string]any{}), 202, "test")
	if job.Body["ok"] != true || !strings.HasPrefix(job.Body["message"].(string), "OpenAI работает") {
		t.Fatalf("test job = %v", job.Body)
	}
	res := job.Body["items"].([]any)[0].(map[string]any)["result"].(string)
	raw, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(res, "data:image/jpeg;base64,"))
	if err != nil {
		t.Fatalf("result = %.60s", res)
	}
	checkSquare(t, raw, 2000, color.RGBA{255, 255, 255, 255})
	// 2048 модель не умеет — повтор в 1024; качество — из настроек; поиска нет.
	if oa.calls != 1 || oa.fields[0]["size"] != "1024x1024" || oa.fields[0]["quality"] != "high" || oa.images[0] != 1 ||
		strings.Contains(oa.fields[0]["prompt"], "Google Search") {
		t.Fatalf("request = %v", oa.fields)
	}
	var cost float64
	var provider string
	if err := pool.QueryRow(ctx, `SELECT cost::float8, provider FROM ai_usage WHERE kind = 'photo_test'`).Scan(&cost, &provider); err != nil {
		t.Fatal(err)
	}
	// 500 входных × $8 + 4160 выходных × $32 за 1 млн.
	if provider != "openai" || cost < 0.1371 || cost > 0.1372 {
		t.Fatalf("usage: provider=%s cost=%v", provider, cost)
	}
}
