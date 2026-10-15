package server_test

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/notify"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/telegram"
	"github.com/sanedidi/super-market/backend/internal/push"
	"github.com/sanedidi/super-market/backend/internal/server"
	"github.com/sanedidi/super-market/backend/internal/summary"
)

// TestI18nErrorTexts — типичные ошибки: с Accept-Language: uz — по-узбекски,
// без заголовка — по-русски, как раньше.
func TestI18nErrorTexts(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	owner, storeID := setupNetwork(t, a, adminTok, "+998900000002")

	check := func(r resp, status int, code, msg string) {
		t.Helper()
		if r.Status != status || r.str("error", "code") != code || r.str("error", "message") != msg {
			t.Fatalf("want %d %s %q, got %d %v", status, code, msg, r.Status, r.Body)
		}
	}

	// Валидация (текст собран из частей).
	bad := map[string]any{"name": "Кассир", "permissions": []string{"nope"}}
	check(a.doLang("uz", "POST", "/store/roles", owner, bad), 400, "validation", "permissions: nomaʼlum huquq nope")
	check(a.do("POST", "/store/roles", owner, bad), 400, "validation", "permissions: неизвестное право nope")

	// Ошибка разбора значения в JSON (курс) — перевод доходит и сквозь «неверный JSON».
	check(a.doLang("uz", "POST", "/store/finance/rates", owner, map[string]any{"rate": "0"}), 400, "validation",
		"JSON notoʻgʻri: kurs musbat son boʻlishi kerak")
	check(a.do("POST", "/store/finance/rates", owner, map[string]any{"rate": "0"}), 400, "validation",
		"неверный JSON: курс должен быть положительным числом")

	// Не найдено.
	const missing = "00000000-0000-4000-8000-000000000001"
	check(a.doLang("uz", "DELETE", "/store/price-types/"+missing, owner, nil), 404, "not_found", "yozuv topilmadi")
	check(a.do("DELETE", "/store/price-types/"+missing, owner, nil), 404, "not_found", "запись не найдена")

	// Бизнес-конфликт: тип цен по умолчанию не удаляется.
	var def string
	for _, pt := range a.expect(a.do("GET", "/store/price-types", owner, nil), 200, "price types").items() {
		if pt["is_default"] == true {
			def = pt["id"].(string)
		}
	}
	check(a.doLang("uz", "DELETE", "/store/price-types/"+def, owner, nil), 409, "default_price_type",
		"Asosiy narx turini oʻchirib boʻlmaydi — avval boshqasini asosiy qiling")
	check(a.do("DELETE", "/store/price-types/"+def, owner, nil), 409, "default_price_type",
		"Тип цен по умолчанию удалить нельзя — сначала сделайте основным другой")

	// Нет права: продавец не управляет ролями.
	role := a.expect(a.do("POST", "/store/roles", owner, map[string]any{"name": "Продавец", "permissions": []string{identity.PermOrdersManage}}), 201, "role").str("id")
	a.expect(a.do("POST", "/store/employees", owner, map[string]any{
		"phone": "+998900000060", "full_name": "Дилноза Каримова", "role_id": role, "store_ids": []string{storeID},
	}), 201, "employee")
	seller, _ := a.login("+998900000060", identity.AppStore)
	check(a.doLang("uz", "POST", "/store/roles", seller, map[string]any{"name": "X", "permissions": []string{}}), 403, "forbidden", "huquqlar yetarli emas")
	check(a.do("POST", "/store/roles", seller, map[string]any{"name": "X", "permissions": []string{}}), 403, "forbidden", "недостаточно прав")

	// Неверный логин или пароль.
	wrong := map[string]string{"login": "t998900000002", "password": "wrong-password-1"}
	check(a.doLang("uz", "POST", "/auth/store/login", "", wrong), 401, "invalid_credentials", "login yoki parol notoʻgʻri")
	check(a.do("POST", "/auth/store/login", "", wrong), 401, "invalid_credentials", "неверный логин или пароль")

	// Названия прав для экрана ролей — на языке запроса.
	title := func(lang string) string {
		for _, p := range a.expect(a.doLang(lang, "GET", "/store/permissions", owner, nil), 200, "permissions").items() {
			if p["code"] == identity.PermStaffManage {
				return p["title"].(string)
			}
		}
		return ""
	}
	if uz, ru := title("uz"), title(""); uz != "Rollar va xodimlar" || ru != "Роли и сотрудники" {
		t.Fatalf("permission titles: %q / %q", uz, ru)
	}
}

// TestI18nNotificationTexts — уведомления уходят на языке получателя:
// сотруднику — users.language, покупателю — customers.language; бот — на
// языке интерфейса Telegram.
func TestI18nNotificationTexts(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	tg := &fakeTelegram{}
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, tg)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	owner, storeID := setupNetwork(t, a, adminTok, "+998900000002")
	if _, err := pool.Exec(ctx, `INSERT INTO telegram_links (phone, chat_id, tg_user_id) VALUES ('+998900000002', 2002, 2002)`); err != nil {
		t.Fatal(err)
	}
	a.expect(a.do("POST", "/store/devices", owner, map[string]any{"token": "owner-fcm-token-0123456789-abcdef", "platform": "ios"}), 204, "owner device")
	setLang := func(lang string) {
		t.Helper()
		a.expect(a.do("PUT", "/me/language", owner, map[string]string{"language": lang}), 204, "language "+lang)
	}

	// Сотрудникам — push в приложение магазина на их языке; Telegram — только
	// супер-админам.
	n := notify.New(pool, tg, quietLog())
	networkID := sqlStr(t, pool, `SELECT network_id::text FROM stores WHERE id = $1`, storeID)
	msg := i18n.Text{RU: "Счёт за подписку\nК оплате 149 000 сум", UZ: "Obuna hisobi\nToʻlash uchun 149 000 soʻm"}
	setLang("uz")
	if sent := n.NetworkOwners(ctx, networkID, identity.PermPayoutsManage, msg); sent != 1 {
		t.Fatalf("owners uz: %d", sent)
	}
	if got := sqlStr(t, pool, `SELECT title || '|' || body FROM notifications_outbox WHERE kind = 'staff_notice' ORDER BY id DESC LIMIT 1`); got != "Obuna hisobi|Toʻlash uchun 149 000 soʻm" {
		t.Fatalf("staff push uz: %q", got)
	}
	setLang("ru")
	n.NetworkOwners(ctx, networkID, identity.PermPayoutsManage, msg)
	if got := sqlStr(t, pool, `SELECT title || '|' || body FROM notifications_outbox WHERE kind = 'staff_notice' ORDER BY id DESC LIMIT 1`); got != "Счёт за подписку|К оплате 149 000 сум" {
		t.Fatalf("staff push ru: %q", got)
	}
	if n.StoreStaff(ctx, storeID, identity.PermOrdersManage, i18n.Text{RU: "Новый заказ №5"}) != 0 || len(tg.sent) != 0 {
		t.Fatalf("staff telegram: %v", tg.sent)
	}

	// Push сотрудникам — в очередь на языке получателя.
	enqueue := func(kind string) string {
		t.Helper()
		if err := push.EnqueueStaff(ctx, pool, storeID, identity.PermOrdersManage, kind,
			i18n.Text{RU: "Новый заказ №5", UZ: "Yangi buyurtma №5"}, i18n.Text{RU: "Примите заказ", UZ: "Buyurtmani qabul qiling"}, nil); err != nil {
			t.Fatal(err)
		}
		return sqlStr(t, pool, `SELECT title || '|' || body FROM notifications_outbox WHERE kind = $1`, kind)
	}
	setLang("uz")
	if got := enqueue("test_uz"); got != "Yangi buyurtma №5|Buyurtmani qabul qiling" {
		t.Fatalf("push uz: %q", got)
	}
	setLang("ru")
	if got := enqueue("test_ru"); got != "Новый заказ №5|Примите заказ" {
		t.Fatalf("push ru: %q", got)
	}

	// Покупателю — по customers.language.
	client, _ := a.login("+998900000050", identity.AppClient)
	a.expect(a.do("PATCH", "/client/me", client, map[string]any{"language": "uz"}), 200, "client uz")
	userID := sqlStr(t, pool, `SELECT id::text FROM users WHERE phone = '+998900000050'`)
	if err := push.Enqueue(ctx, pool, userID, "family_test", i18n.Text{RU: "В семье пополнение", UZ: "Oilaga yangi aʼzo qoʻshildi"},
		i18n.Text{RU: "Азиз теперь в «Дом»", UZ: "Aziz endi «Dom» aʼzosi"}, nil); err != nil {
		t.Fatal(err)
	}
	if got := sqlStr(t, pool, `SELECT title FROM notifications_outbox WHERE kind = 'family_test'`); got != "Oilaga yangi aʼzo qoʻshildi" {
		t.Fatalf("client push: %q", got)
	}
	// Статусы заказа по-узбекски — с типографским апострофом.
	if title, ok := push.OrderStatusTitle("uz", "paid", 7); !ok || title != "Buyurtma №7 toʻlandi" {
		t.Fatalf("order status uz: %q", title)
	}

	// Итоги дня владельцу на узбекском.
	pct := 12
	day := time.Date(2026, 10, 2, 21, 0, 0, 0, time.UTC)
	title, body := summary.PushText(summary.Summary{Revenue: "6140000.00", Profit: "1200000.00", ChangePct: &pct,
		Alerts: []summary.Alert{{Kind: "shortage", Title: "Kamomad 45 000 soʻm"}}}, day, i18n.UZ)
	if title != "Kun yakunlari · 2-oktabr" || body != "Tushum 6,1 mln (kechaga nisbatan +12%), foyda 1,2 mln. Kassirda kamomad 45 000 soʻm." {
		t.Fatalf("summary uz: %q / %q", title, body)
	}

	// Бот: язык интерфейса Telegram.
	bot := identity.NewBot(identity.NewService(pool, tg, server.IdentityConfig(cfg), quietLog()), tg, quietLog())
	start := func(lang string) string {
		t.Helper()
		if err := bot.Handle(ctx, telegram.Update{Message: &telegram.Message{
			From: &telegram.User{ID: 777, LanguageCode: lang}, Chat: telegram.Chat{ID: 777, Type: "private"}, Text: "/start",
		}}); err != nil {
			t.Fatal(err)
		}
		return tg.last().text
	}
	if got := start("uz"); !strings.Contains(got, "«Raqamni ulashish»") {
		t.Fatalf("bot uz: %q", got)
	}
	if got := start("ru"); !strings.Contains(got, "«Поделиться номером»") {
		t.Fatalf("bot ru: %q", got)
	}
}
