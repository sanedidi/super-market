package server_test

import (
	"context"
	"net/http/httptest"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/appversions"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

func TestCompareVersions(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want int
	}{
		{"0.9.0", "0.9.2", -1}, {"0.9.2", "0.9.2", 0}, {"0.10.0", "0.9.9", 1},
		{"1.2", "1.2.0", 0}, {"0.9.0+23", "0.9.0", 0}, {"1.1.1", "1.1.10", -1},
	} {
		if got := appversions.Compare(c.a, c.b); got != c.want {
			t.Errorf("Compare(%s, %s) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
}

// ОБ1 · «Есть обновление»: супер-админ вписывает версию из стора — приложение
// старее неё получает update: true, «Что нового» на своём языке и ссылку.
func TestAppVersions(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	app, err := server.Build(context.Background(), cfg, pool, &fakeTelegram{}, quietLog())
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app.Handler)
	t.Cleanup(srv.Close)
	a := api{t: t, srv: srv, pool: pool}
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)

	// Ничего не задано — обновления нет.
	if c := a.expect(a.do("GET", "/public/app-version?app=store&platform=ios&version=0.9.0", "", nil), 200, "empty check"); c.Body["update"] != false {
		t.Fatalf("empty check = %v", c.Body)
	}
	if l := a.expect(a.do("GET", "/admin/app-versions", adminTok, nil), 200, "list").items(); len(l) != 10 || l[2]["app"] != "store" || l[2]["platform"] != "ios" || l[2]["latest"] != "" {
		t.Fatalf("list = %v", l)
	}

	a.expect(a.do("PUT", "/admin/app-versions/store/ios", adminTok, map[string]any{"latest": "0.9.x"}), 400, "bad version")
	a.expect(a.do("PUT", "/admin/app-versions/store/ios", adminTok, map[string]any{"store_url": "http://x"}), 400, "bad url")
	a.expect(a.do("PUT", "/admin/app-versions/pos/ios", adminTok, map[string]any{"latest": "1.0.0"}), 400, "bad app")
	v := a.expect(a.do("PUT", "/admin/app-versions/store/ios", adminTok, map[string]any{
		"latest": " 0.9.2 ", "store_url": "https://apps.apple.com/app/id1", "notes_ru": "• Приход вручную\n\n- Цена закупки из прошлого прихода", "notes_uz": "Qoʻlda kirim",
	}), 200, "save")
	if v.str("latest") != "0.9.2" || v.Body["updated_at"] == nil {
		t.Fatalf("save = %v", v.Body)
	}
	// Только «Что нового» — версия и ссылка остаются.
	a.expect(a.do("PUT", "/admin/app-versions/store/ios", adminTok, map[string]any{"notes_uz": "Qoʻlda kirim\nXarid narxi"}), 200, "notes only")

	c := a.expect(a.doLang("ru", "GET", "/public/app-version?app=store&platform=ios&version=0.9.0%2B23", "", nil), 200, "check old")
	notes, _ := c.Body["notes"].([]any)
	if c.Body["update"] != true || c.str("latest") != "0.9.2" || c.str("store_url") != "https://apps.apple.com/app/id1" || len(notes) != 2 || notes[0] != "Приход вручную" {
		t.Fatalf("check old = %v", c.Body)
	}
	if c := a.expect(a.doLang("uz", "GET", "/public/app-version?app=store&platform=ios&version=0.9.0", "", nil), 200, "check uz"); len(c.Body["notes"].([]any)) != 2 || c.Body["notes"].([]any)[1] != "Xarid narxi" {
		t.Fatalf("check uz = %v", c.Body)
	}
	if c := a.expect(a.do("GET", "/public/app-version?app=store&platform=ios&version=0.9.2", "", nil), 200, "check fresh"); c.Body["update"] != false {
		t.Fatalf("check fresh = %v", c.Body)
	}
	// Android отдельно: там версия ещё не задана.
	if c := a.expect(a.do("GET", "/public/app-version?app=store&platform=android&version=0.9.0", "", nil), 200, "check android"); c.Body["update"] != false {
		t.Fatalf("check android = %v", c.Body)
	}
	a.expect(a.do("GET", "/public/app-version?app=store&platform=ios&version=abc", "", nil), 400, "bad app version")
	a.expect(a.do("GET", "/admin/app-versions", "", nil), 401, "list without token")
}
