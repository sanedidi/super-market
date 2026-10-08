package server_test

import (
	"context"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// TestI18nBasics — язык запроса: ошибки, loc() в базе, язык пользователя.
func TestI18nBasics(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	ctx := context.Background()
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	tok, _ := setupNetwork(t, a, adminTok, "+998900000002")

	// Ошибка: без заголовка — по-русски (старые клиенты), uz — по-узбекски.
	r := a.do("GET", "/store/employees/not-a-uuid", tok, nil)
	if r.Status != 404 && r.Status != 405 {
		t.Logf("status %d", r.Status)
	}
	ru := a.do("GET", "/no-such-route", tok, nil)
	if got := ru.str("error", "message"); got != "маршрут не найден" {
		t.Fatalf("ru 404: %q", got)
	}
	uz := a.doLang("uz", "GET", "/no-such-route", tok, nil)
	if got := uz.str("error", "message"); got != "yoʻnalish topilmadi" {
		t.Fatalf("uz 404: %q", got)
	}
	uz = a.doLang("uz-UZ,ru;q=0.5", "POST", "/translate", tok, map[string]any{"texts": []string{}, "to": "uz"})
	if uz.Status != 400 || uz.str("error", "message") != "tarjima uchun matn yoʻq" {
		t.Fatalf("translate validation: %d %v", uz.Status, uz.Body)
	}
	// ИИ не настроен — 409 (ошибка супер-админской настройки).
	r = a.doLang("ru", "POST", "/translate", tok, map[string]any{"texts": []string{"Хлеб"}, "to": "uz"})
	if r.Status != 409 {
		t.Fatalf("translate without ai: %d %v", r.Status, r.Body)
	}

	// loc() в базе следует языку запроса через пул.
	var name string
	if err := pool.QueryRow(ctx, `SELECT loc(name, name_uz) FROM units WHERE short_name = 'шт'`).Scan(&name); err != nil {
		t.Fatal(err)
	}
	if name != "Штука" {
		t.Fatalf("loc default: %q", name)
	}
	for i := 0; i < 3; i++ { // одно и то же соединение пула меняет язык туда и обратно
		if err := pool.QueryRow(i18n.WithLang(ctx, "uz"), `SELECT loc(name, name_uz) FROM units WHERE short_name = 'шт'`).Scan(&name); err != nil || name != "Dona" {
			t.Fatalf("loc uz: %q %v", name, err)
		}
		if err := pool.QueryRow(i18n.WithLang(ctx, "ru"), `SELECT loc(name, name_uz) FROM units WHERE short_name = 'шт'`).Scan(&name); err != nil || name != "Штука" {
			t.Fatalf("loc ru: %q %v", name, err)
		}
	}

	// Язык сотрудника: из настроек приложения.
	a.expect(a.do("PUT", "/me/language", tok, map[string]string{"language": "ru"}), 204, "set lang")
	var lang string
	if err := pool.QueryRow(ctx, `SELECT language FROM users WHERE phone = '+998900000002'`).Scan(&lang); err != nil || lang != "ru" {
		t.Fatalf("lang %q %v", lang, err)
	}
	a.expect(a.doLang("uz", "PUT", "/me/language", tok, map[string]string{"language": "en"}), 400, "bad lang")
}
