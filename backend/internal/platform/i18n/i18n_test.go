package i18n

import (
	"context"
	"net/http/httptest"
	"testing"
)

func TestFromRequest(t *testing.T) {
	cases := map[string]string{
		"":                       "",
		"uz":                     UZ,
		"uz-Latn-UZ,ru;q=0.8":    UZ,
		"ru-RU,ru;q=0.9,en;q=.8": RU,
		"en-US":                  Default,
		"*":                      "",
	}
	for h, want := range cases {
		r := httptest.NewRequest("GET", "/x", nil)
		if h != "" {
			r.Header.Set("Accept-Language", h)
		}
		if got := FromRequest(r); got != want {
			t.Errorf("%q: got %q want %q", h, got, want)
		}
	}
	r := httptest.NewRequest("GET", "/x?lang=uz", nil)
	r.Header.Set("Accept-Language", "ru")
	if FromRequest(r) != UZ {
		t.Error("?lang= wins")
	}
}

func TestPick(t *testing.T) {
	ctx := context.Background()
	if T(ctx, "да", "ha") != "да" {
		t.Error("default ru")
	}
	ctx = WithLang(ctx, "uz")
	if T(ctx, "да", "ha") != "ha" {
		t.Error("uz")
	}
	if T(ctx, "да", "") != "да" {
		t.Error("empty uz falls back to ru")
	}
}
