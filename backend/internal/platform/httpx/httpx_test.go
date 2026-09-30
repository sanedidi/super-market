package httpx

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-chi/chi/v5"
)

type fakeDB struct{ err error }

func (f fakeDB) Ping(context.Context) error { return f.err }

type pingModule struct{}

func (pingModule) Routes(r chi.Router) {
	r.Get("/ping", func(w http.ResponseWriter, _ *http.Request) {
		WriteJSON(w, http.StatusOK, map[string]string{"pong": "1"})
	})
}

func do(t *testing.T, h http.Handler, method, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(method, path, nil))
	return rec
}

func quiet() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func TestHealthz(t *testing.T) {
	rec := do(t, NewRouter(quiet(), fakeDB{}), http.MethodGet, "/healthz")
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, want 200", rec.Code)
	}
}

func TestReadyz(t *testing.T) {
	if rec := do(t, NewRouter(quiet(), fakeDB{}), http.MethodGet, "/readyz"); rec.Code != http.StatusOK {
		t.Errorf("db ok: status %d, want 200", rec.Code)
	}

	rec := do(t, NewRouter(quiet(), fakeDB{err: errors.New("down")}), http.MethodGet, "/readyz")
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("db down: status %d, want 503", rec.Code)
	}
	var body ErrorBody
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Error.Code != "db_unavailable" {
		t.Errorf("error code %q, want db_unavailable", body.Error.Code)
	}
}

func TestModuleRoutesAndNotFound(t *testing.T) {
	h := NewRouter(quiet(), fakeDB{}, pingModule{})
	if rec := do(t, h, http.MethodGet, "/api/v1/ping"); rec.Code != http.StatusOK {
		t.Errorf("module route: status %d, want 200", rec.Code)
	}
	rec := do(t, h, http.MethodGet, "/api/v1/nope")
	if rec.Code != http.StatusNotFound {
		t.Errorf("unknown route: status %d, want 404", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json; charset=utf-8" {
		t.Errorf("404 content-type %q", ct)
	}
}

func TestPageSlice(t *testing.T) {
	items := []int{1, 2, 3, 4, 5}
	cases := map[string][]int{
		"/x":                  {1, 2, 3, 4, 5}, // без limit — весь список
		"/x?limit=2":          {1, 2},
		"/x?limit=2&offset=2": {3, 4},
		"/x?limit=2&offset=4": {5},
		"/x?limit=2&offset=9": {},
		"/x?limit=0":          {1, 2, 3, 4, 5}, // limit по умолчанию — 50
	}
	for url, want := range cases {
		got := PageSlice(httptest.NewRequest(http.MethodGet, url, nil), items)
		if len(got) != len(want) {
			t.Fatalf("%s: got %v, want %v", url, got, want)
		}
		for i := range got {
			if got[i] != want[i] {
				t.Fatalf("%s: got %v, want %v", url, got, want)
			}
		}
	}
}
