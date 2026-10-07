package server_test

import (
	"bytes"
	"context"
	"encoding/json"
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

// fakeS3 — бакеты и объекты в памяти; требует подпись AWS4.
type fakeS3 struct {
	mu      sync.Mutex
	buckets map[string]bool
	objects map[string][]byte
	types   map[string]string
}

func (f *fakeS3) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if !strings.HasPrefix(r.Header.Get("Authorization"), "AWS4-HMAC-SHA256 Credential=minio/") || r.Header.Get("X-Amz-Date") == "" {
		w.WriteHeader(http.StatusForbidden)
		return
	}
	path := strings.TrimPrefix(r.URL.Path, "/")
	bucket, key, _ := strings.Cut(path, "/")
	switch {
	case key == "" && r.Method == http.MethodHead:
		if !f.buckets[bucket] {
			w.WriteHeader(http.StatusNotFound)
		}
	case key == "" && r.Method == http.MethodPut:
		f.buckets[bucket] = true
	case !f.buckets[bucket]:
		w.WriteHeader(http.StatusNotFound)
	case r.Method == http.MethodPut:
		b, _ := io.ReadAll(r.Body)
		f.objects[path] = b
		f.types[path] = r.Header.Get("Content-Type")
	case r.Method == http.MethodGet:
		b, ok := f.objects[path]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", f.types[path])
		_, _ = w.Write(b)
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

// PNG 1×1.
var tinyPNG = []byte("\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82")

// TestMediaUpload — фото загружаются магазином и супер-админом в MinIO и
// отдаются по публичной ссылке; не-картинки и чужие приложения — отказ.
func TestMediaUpload(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	s3 := &fakeS3{buckets: map[string]bool{}, objects: map[string][]byte{}, types: map[string]string{}}
	s3srv := httptest.NewServer(s3)
	t.Cleanup(s3srv.Close)

	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	cfg.S3Endpoint, cfg.S3AccessKey, cfg.S3SecretKey, cfg.S3Bucket = s3srv.URL, "minio", "secret", "media"
	app, err := server.Build(ctx, cfg, pool, &fakeTelegram{}, quietLog())
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app.Handler)
	t.Cleanup(srv.Close)
	a := api{t: t, srv: srv, pool: pool}
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	storeTok, _ := setupNetwork(t, a, adminTok, "+998900000002")
	clientTok, _ := a.login("+998900000050", identity.AppClient)

	upload := func(path, tok, name string, data []byte) (int, map[string]any) {
		t.Helper()
		var body bytes.Buffer
		mw := multipart.NewWriter(&body)
		fw, _ := mw.CreateFormFile("file", name)
		_, _ = fw.Write(data)
		_ = mw.Close()
		req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/v1"+path, &body)
		req.Header.Set("Content-Type", mw.FormDataContentType())
		if tok != "" {
			req.Header.Set("Authorization", "Bearer "+tok)
		}
		res, err := srv.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		out := map[string]any{}
		_ = json.NewDecoder(res.Body).Decode(&out)
		return res.StatusCode, out
	}

	st, out := upload("/store/uploads", storeTok, "a.png", tinyPNG)
	if st != 201 {
		t.Fatalf("store upload: %d %v", st, out)
	}
	url, _ := out["url"].(string)
	if !strings.HasPrefix(url, srv.URL+"/api/v1/media/") || !strings.HasSuffix(url, ".png") {
		t.Fatalf("url = %q", url)
	}
	if !s3.buckets["media"] || len(s3.objects) != 1 {
		t.Fatalf("bucket/objects = %v %d", s3.buckets, len(s3.objects))
	}
	res, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != 200 || !bytes.Equal(got, tinyPNG) || res.Header.Get("Content-Type") != "image/png" ||
		!strings.Contains(res.Header.Get("Cache-Control"), "immutable") {
		t.Fatalf("get: %d %q %q", res.StatusCode, res.Header.Get("Content-Type"), res.Header.Get("Cache-Control"))
	}

	if st, _ := upload("/admin/uploads", adminTok, "b.png", tinyPNG); st != 201 {
		t.Fatalf("admin upload: %d", st)
	}
	if st, _ := upload("/store/uploads", storeTok, "x.txt", []byte("hello, not an image")); st != 400 {
		t.Fatalf("text upload: %d", st)
	}
	if st, _ := upload("/store/uploads", clientTok, "a.png", tinyPNG); st != 401 && st != 403 {
		t.Fatalf("client upload: %d", st)
	}
	if st, _ := upload("/store/uploads", "", "a.png", tinyPNG); st != 401 {
		t.Fatalf("anonymous upload: %d", st)
	}
	for _, bad := range []string{"../etc/passwd", "2026/09/zz.png", "x"} {
		r, _ := http.Get(srv.URL + "/api/v1/media/" + bad)
		if r.StatusCode != 404 {
			t.Fatalf("bad key %q: %d", bad, r.StatusCode)
		}
		r.Body.Close()
	}
}
