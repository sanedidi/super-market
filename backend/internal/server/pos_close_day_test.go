package server_test

import (
	"context"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/pos"
)

// TestPOSCloseDay — «Закрыть день» одной кнопкой (Figma «Касса · Закрыть
// день», ЗД1–ЗД5): с кассы пересчёт и причина по желанию (pos / pos_quick),
// настройка «Требовать пересчёт» уходит в каталог кассы, смена старше 20 часов
// закрывается сама (auto) — при открытии новой смены и задачей воркера.
func TestPOSCloseDay(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")

	dev := a.expect(a.do("POST", "/store/pos/devices", tok, map[string]any{"store_id": store, "name": "Касса 1"}), 201, "device")
	dt := a.expect(a.do("POST", "/pos/activate", "", map[string]any{"code": dev.str("activation_code"), "app_version": "0.4.5"}), 200, "activate").str("token")
	role := a.expect(a.do("POST", "/store/roles", tok, map[string]any{"name": "Кассир", "permissions": []string{identity.PermSalesPOS}}), 201, "role").str("id")
	cashier := a.expect(a.do("POST", "/store/employees", tok, map[string]any{
		"phone": "+998900000006", "full_name": "Кассир", "role_id": role, "store_ids": []string{store},
	}), 201, "cashier").str("id")
	a.expect(a.do("PUT", "/store/pos/pins/"+cashier, tok, map[string]any{"pin": "1234"}), 200, "pin")

	// Настройка: по умолчанию выключена; включили — касса видит в каталоге.
	st := a.expect(a.do("GET", "/store/pos/settings", tok, nil), 200, "settings")
	if st.Body["require_recount"] != false {
		t.Fatalf("settings = %v", st.Body)
	}
	a.expect(a.do("PUT", "/store/pos/settings", tok, map[string]any{"weight_prefixes": []string{}, "require_recount": true}), 200, "save settings")
	cat := a.expect(posDo(a, "GET", "/pos/catalog", dt, "", nil), 200, "catalog")
	if cat.Body["settings"].(map[string]any)["require_recount"] != true {
		t.Fatalf("catalog settings = %v", cat.Body["settings"])
	}
	// Старая панель без поля — настройку не сбрасывает.
	a.expect(a.do("PUT", "/store/pos/settings", tok, map[string]any{"weight_prefixes": []string{}}), 200, "save old panel")
	if a.expect(a.do("GET", "/store/pos/settings", tok, nil), 200, "settings 2").Body["require_recount"] != true {
		t.Fatal("require_recount сброшен старой панелью")
	}

	// Закрыть день без пересчёта — pos_quick, по расчёту.
	s1 := a.expect(posDo(a, "POST", "/pos/shifts", dt, cashier, map[string]any{"client_uid": "close-day-0001", "opening_cash": 100000}), 201, "open 1").str("id")
	c1 := a.expect(posDo(a, "POST", "/pos/shifts/"+s1+"/close", dt, cashier, map[string]any{}), 200, "quick close")
	if c1.str("closed_via") != "pos_quick" || c1.str("counted_cash") != "100000.00" || c1.str("diff") != "0.00" {
		t.Fatalf("quick close = %v", c1.Body)
	}
	// С пересчётом и расхождением без причины — pos, расхождение записано.
	s2 := a.expect(posDo(a, "POST", "/pos/shifts", dt, cashier, map[string]any{"client_uid": "close-day-0002", "opening_cash": 100000}), 201, "open 2").str("id")
	c2 := a.expect(posDo(a, "POST", "/pos/shifts/"+s2+"/close", dt, cashier, map[string]any{"counted_cash": 95000}), 200, "recount close")
	if c2.str("closed_via") != "pos" || c2.str("diff") != "-5000.00" || c2.str("diff_reason") != "" {
		t.Fatalf("recount close = %v", c2.Body)
	}

	// Вчерашняя смена (открыта 21 час назад): новая открывается без 409, старая — auto.
	s3 := a.expect(posDo(a, "POST", "/pos/shifts", dt, cashier, map[string]any{"client_uid": "close-day-0003", "opening_cash": 50000}), 201, "open 3").str("id")
	if _, err := pool.Exec(context.Background(), `UPDATE pos_shifts SET opened_at = now() - interval '21 hours' WHERE id = $1`, s3); err != nil {
		t.Fatal(err)
	}
	s4 := a.expect(posDo(a, "POST", "/pos/shifts", dt, cashier, map[string]any{"client_uid": "close-day-0004"}), 201, "open after 20h").str("id")
	old := a.expect(a.do("GET", "/store/pos/shifts/"+s3, tok, nil), 200, "old shift")
	if old.str("closed_via") != "auto" || old.str("counted_cash") != "50000.00" || old.Body["closed_at"] == nil {
		t.Fatalf("auto closed = %v", old.Body)
	}
	// Касса потом досылает своё закрытие — повтор безопасен, смена не меняется.
	a.expect(posDo(a, "POST", "/pos/shifts/"+s3+"/close", dt, cashier, map[string]any{"stale": true}), 200, "late close")

	// Задача воркера: смена старше 20 часов закрывается, свежая — нет.
	svc := pos.NewService(pool, nil)
	if err := svc.AutoCloseStale(context.Background()); err != nil {
		t.Fatal(err)
	}
	if a.expect(a.do("GET", "/store/pos/shifts/"+s4, tok, nil), 200, "fresh").Body["closed_at"] != nil {
		t.Fatal("свежая смена закрыта")
	}
	if _, err := pool.Exec(context.Background(), `UPDATE pos_shifts SET opened_at = now() - interval '21 hours' WHERE id = $1`, s4); err != nil {
		t.Fatal(err)
	}
	if err := svc.AutoCloseStale(context.Background()); err != nil {
		t.Fatal(err)
	}
	if sh := a.expect(a.do("GET", "/store/pos/shifts/"+s4, tok, nil), 200, "stale"); sh.str("closed_via") != "auto" {
		t.Fatalf("worker auto close = %v", sh.Body)
	}
	evs := a.expect(a.do("GET", "/store/pos/shifts/"+s4+"/events", tok, nil), 200, "events").items()
	if last := evs[len(evs)-1]; last["kind"] != "close" {
		t.Fatalf("events = %v", evs)
	}
}
