package server_test

import (
	"bytes"
	"context"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/identity"
)

type memUploader struct {
	mu    sync.Mutex
	files map[string][]byte
}

func (m *memUploader) Upload(_ context.Context, data []byte) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := fmt.Sprintf("2026/10/%032x.jpg", len(m.files)+1)
	m.files[key] = data
	return key, nil
}

func TestCatalogImportAndPhotos(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)

	// Товар, который уже есть в каталоге (из Лавки) — к нему привяжется штрихкод.
	cat := a.expect(a.do("POST", "/admin/catalog/categories", adminTok, map[string]any{"name": "Масло, соусы и специи"}), 201, "category")
	units := a.expect(a.do("GET", "/admin/catalog/units", adminTok, nil), 200, "units").items()
	var pcs string
	for _, u := range units {
		if u["short_name"] == "шт" {
			pcs = u["id"].(string)
		}
	}
	heinz := a.expect(a.do("POST", "/admin/products", adminTok, map[string]any{
		"name": "Кетчуп томатный Heinz", "category_id": cat.str("id"), "unit_id": pcs,
		"images": []string{"https://example.com/heinz.png"},
	}), 201, "existing product")

	items := []map[string]any{
		{"barcode": "4780069000017", "name": "Coca-Cola, сладкий, стеклянная бутылка 0,25 л", "brand": "Coca-Cola",
			"category": []string{"Напитки", "Газированные напитки"}, "unit": "шт", "ikpu": "02202002001010021",
			"attributes": map[string]any{"ikpu_name": "Безалкогольные напитки: COCA-COLA"}},
		{"barcode": "4780069000024", "name": "Coca-Cola, 1 л", "brand": "coca-cola",
			"category": []string{"напитки", "Газированные напитки"}, "unit": "шт", "ikpu": "02202002001010099"},
		{"barcode": "4601674084288", "name": "Heinz, томатный 460г", "brand": "Heinz",
			"category": []string{"Масло, соусы и специи", "Кетчуп"}, "ikpu": "02103004001001001", "attach_to": "Кетчуп томатный Heinz"},
		{"barcode": "12", "name": "Плохой", "category": []string{"Напитки"}},
		{"barcode": "4780000000001", "name": "Весы", "category": []string{"Напитки"}, "unit": "парсек"},
	}
	res := a.expect(a.do("POST", "/admin/catalog-import", adminTok, map[string]any{"source": "tasnif", "items": items}), 200, "import")
	errs, _ := res.Body["errors"].([]any)
	if num(res, "created") != 2 || num(res, "attached") != 1 || len(errs) != 2 {
		t.Fatalf("import = %v", res.Body)
	}
	// Повтор — ничего не создаётся.
	res = a.expect(a.do("POST", "/admin/catalog-import", adminTok, map[string]any{"source": "tasnif", "items": items[:3]}), 200, "reimport")
	if num(res, "skipped") != 3 || num(res, "created") != 0 {
		t.Fatalf("reimport = %v", res.Body)
	}
	a.expect(a.do("POST", "/admin/catalog-import", adminTok, map[string]any{"source": "lavka", "items": items[:1]}), 400, "bad source")

	// Бренд один на двоих (без учёта регистра), раздел «Напитки» — один.
	var brands, drinks int
	if err := pool.QueryRow(context.Background(), `SELECT count(*) FROM brands WHERE lower(name) = 'coca-cola'`).Scan(&brands); err != nil || brands != 1 {
		t.Fatalf("brands = %d %v", brands, err)
	}
	if err := pool.QueryRow(context.Background(), `SELECT count(*) FROM categories WHERE lower(name) = 'напитки' AND parent_id IS NULL`).Scan(&drinks); err != nil || drinks != 1 {
		t.Fatalf("drinks sections = %d %v", drinks, err)
	}
	found := a.expect(a.do("GET", "/admin/products?barcode=4601674084288", adminTok, nil), 200, "attached").items()
	if len(found) != 1 || found[0]["id"] != heinz.str("id") {
		t.Fatalf("attached = %v", found)
	}

	// Фото: у первого товара два фото в источнике, у второго — нет.
	var hits sync.Map
	tasnif := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Store(r.URL.Path, true)
		switch {
		case strings.HasSuffix(r.URL.Path, "/picture-names"):
			if r.URL.Query().Get("mxik_code") == "02202002001010021" {
				_, _ = w.Write([]byte(`["02202002001010021_a.jpg","02202002001010021_b.jpg","02202002001010021_c.jpg"]`))
				return
			}
			_, _ = w.Write([]byte(`[]`))
		case strings.Contains(r.URL.Path, "/get/file/"):
			img := image.NewNRGBA(image.Rect(0, 0, 2400, 1200))
			for x := 0; x < 2400; x++ {
				img.Set(x, 600, color.NRGBA{R: 200, A: 255})
			}
			var buf bytes.Buffer
			_ = png.Encode(&buf, img)
			_, _ = w.Write(buf.Bytes())
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer tasnif.Close()
	store := &memUploader{files: map[string][]byte{}}
	f := catalog.NewPhotoFetcher(pool, store, "https://media.test", tasnif.URL, 2, quietLog())
	n, err := f.Batch(context.Background(), 10)
	if err != nil || n != 2 {
		t.Fatalf("batch = %d %v", n, err)
	}
	if len(store.files) != 2 {
		t.Fatalf("uploaded %d files", len(store.files))
	}
	for _, data := range store.files {
		cfgImg, format, err := image.DecodeConfig(bytes.NewReader(data))
		if err != nil || format != "jpeg" || cfgImg.Width != 1000 || cfgImg.Height != 500 {
			t.Fatalf("photo %s %dx%d %v", format, cfgImg.Width, cfgImg.Height, err)
		}
	}
	cola := a.expect(a.do("GET", "/admin/products?barcode=4780069000017", adminTok, nil), 200, "cola").items()
	imgs, _ := cola[0]["images"].([]any)
	if len(imgs) != 2 || !strings.HasPrefix(imgs[0].(string), "https://media.test/api/v1/media/2026/10/") {
		t.Fatalf("cola images = %v", cola[0]["images"])
	}

	// Фильтр «с фото / без фото» и статус импорта.
	with := a.expect(a.do("GET", "/admin/products?photo=with", adminTok, nil), 200, "with photo").items()
	without := a.expect(a.do("GET", "/admin/products?photo=without", adminTok, nil), 200, "without photo").items()
	if len(with) != 2 || len(without) != 1 {
		t.Fatalf("with = %d, without = %d", len(with), len(without))
	}
	a.expect(a.do("GET", "/admin/products?photo=maybe", adminTok, nil), 400, "bad photo filter")
	st := a.expect(a.do("GET", "/admin/catalog-import/status", adminTok, nil), 200, "status")
	jobs, _ := st.Body["photo_jobs"].(map[string]any)
	if jobs["done"] != float64(1) || jobs["none"] != float64(1) || num(st, "with_photo") != 2 || num(st, "without_photo") != 1 {
		t.Fatalf("status = %v", st.Body)
	}
	// Список фото Heinz не запрашивался: у товара уже было своё фото.
	if n, _ := f.Batch(context.Background(), 10); n != 0 {
		t.Fatalf("second batch = %d", n)
	}
	a.expect(a.do("POST", "/admin/catalog-import/retry-photos", adminTok, nil), 200, "retry")
}

func num(r resp, key string) int {
	v, _ := r.Body[key].(float64)
	return int(v)
}
