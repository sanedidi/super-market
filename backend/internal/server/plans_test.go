package server_test

import (
	"context"
	"testing"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// TestPlans — тарифы магазинов: пробный период новой сети, функции и
// лимиты по тарифу, настройка супер-админом, скрытый тариф, комиссия
// бесплатного тарифа с онлайн-заказа.
func TestPlans(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	a := newAPI(t, paymeConfig(), pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	errDetails := func(r resp) map[string]any {
		return r.Body["error"].(map[string]any)["details"].(map[string]any)
	}

	// Реестр функций и лимитов для экрана тарифов.
	reg := a.expect(a.do("GET", "/admin/plans/registry", adminTok, nil), 200, "registry")
	if len(reg.Body["features"].([]any)) < 10 || len(reg.Body["limits"].([]any)) != 9 || len(reg.Body["groups"].([]any)) != 4 {
		t.Fatalf("registry = %v", reg.Body)
	}
	a.expect(a.do("PATCH", "/admin/plans/start", adminTok, map[string]any{"features": []string{"debts", "teleport"}}), 400, "unknown feature")
	a.expect(a.do("PATCH", "/admin/plans/start", adminTok, map[string]any{"limits": map[string]any{"ads": 5}}), 400, "ads over max")
	a.expect(a.do("POST", "/admin/plans", adminTok, map[string]any{"key": "Bad Key", "name": "x"}), 400, "bad key")

	// Одиночный магазин: «Бесплатный» с пробным «Бизнесом» на 14 дней.
	net := a.expect(a.do("POST", "/admin/networks", adminTok, map[string]string{
		"name": "Дукон", "kind": "single", "owner_phone": "+998900000002", "owner_name": "Владелец",
	}), 201, "network")
	network := net.str("id")
	if net.str("plan_key") != "free" || net.str("effective_plan_key") != "business" || net.Body["plan_trial_until"] == nil {
		t.Fatalf("network = %v", net.Body)
	}
	tok, _ := a.login("+998900000002", identity.AppStore)
	store := a.expect(a.do("POST", "/store/stores", tok, map[string]any{"name": "Дукон"}), 201, "store").str("id")
	mine := a.expect(a.do("GET", "/store/plan", tok, nil), 200, "my plan")
	if mine.Body["in_trial"] != true || mine.str("current", "key") != "business" || mine.str("chosen", "key") != "free" || len(mine.Body["plans"].([]any)) != 4 {
		t.Fatalf("my plan = %v", mine.Body)
	}
	a.expect(a.do("GET", "/store/debtors", tok, nil), 200, "debts in trial")

	// Пробный кончился — «Бесплатный»: долгов и расширенных отчётов нет,
	// ошибка подсказывает, на каком тарифе они есть.
	if _, err := pool.Exec(ctx, `UPDATE networks SET plan_trial_until = current_date - 1 WHERE id = $1`, network); err != nil {
		t.Fatal(err)
	}
	d := a.expect(a.do("GET", "/store/debtors", tok, nil), 403, "debts on free")
	if det := errDetails(d); d.Body["error"].(map[string]any)["code"] != "plan_feature" || det["feature"] != "debts" || det["plan"] != "free" || det["need_plan"] != "start" {
		t.Fatalf("debts on free = %v", d.Body)
	}
	if det := errDetails(a.expect(a.do("GET", "/store/reports/abc-xyz", tok, nil), 403, "abc on free")); det["need_plan"] != "business" {
		t.Fatalf("abc need = %v", det)
	}
	a.expect(a.do("GET", "/store/reports/sales-series", tok, nil), 200, "basic reports stay")
	if det := errDetails(a.expect(a.do("GET", "/store/ads", tok, nil), 403, "brand ads on free")); det["feature"] != "brand_ads" || det["need_plan"] != "business" {
		t.Fatalf("brand ads need = %v", det)
	}

	// Лимит касс: одна на «Бесплатном» и «Старте», три — на «Бизнесе».
	a.expect(a.do("POST", "/store/pos/devices", tok, map[string]any{"store_id": store, "name": "Касса 1"}), 201, "device 1")
	lim := a.expect(a.do("POST", "/store/pos/devices", tok, map[string]any{"store_id": store, "name": "Касса 2"}), 409, "device 2")
	if det := errDetails(lim); lim.Body["error"].(map[string]any)["code"] != "tariff_limit" || det["feature"] != "registers" || det["limit"].(float64) != 1 || det["need_plan"] != "business" {
		t.Fatalf("registers limit = %v", lim.Body)
	}

	// Лимит сотрудников (без курьеров): один на «Бесплатном»; курьер считается отдельно.
	seller := a.expect(a.do("POST", "/store/roles", tok, map[string]any{"name": "Продавец", "permissions": []string{"sales.pos"}}), 201, "role").str("id")
	courierRole := a.expect(a.do("POST", "/store/roles", tok, map[string]any{"name": "Курьер", "permissions": []string{"orders.deliver"}}), 201, "courier role").str("id")
	a.expect(a.do("POST", "/store/employees", tok, map[string]any{"phone": "+998900000011", "full_name": "Продавец 1", "role_id": seller, "all_stores": true}), 201, "staff 1")
	if det := errDetails(a.expect(a.do("POST", "/store/employees", tok, map[string]any{"phone": "+998900000012", "full_name": "Продавец 2", "role_id": seller, "all_stores": true}), 409, "staff 2")); det["feature"] != "staff" {
		t.Fatalf("staff limit = %v", det)
	}
	c1 := a.expect(a.do("POST", "/store/employees", tok, map[string]any{"phone": "+998900000013", "full_name": "Курьер 1", "role_id": courierRole, "all_stores": true}), 201, "courier 1").str("id")
	// Сделать курьера продавцом нельзя — упрётся в лимит сотрудников.
	a.expect(a.do("PATCH", "/store/employees/"+c1, tok, map[string]any{"role_id": seller}), 409, "courier to seller")
	a.expect(a.do("PATCH", "/store/employees/"+c1, tok, map[string]any{"full_name": "Курьер Один"}), 200, "rename is fine")

	// Магазин сам переходит на «Старт»: долги открываются; «Сеть» — от 3 магазинов.
	if e := a.expect(a.do("POST", "/store/plan", tok, map[string]any{"plan": "network"}), 409, "network plan"); errDetails(e)["min_stores"].(float64) != 3 {
		t.Fatalf("min stores = %v", e.Body)
	}
	if m := a.expect(a.do("POST", "/store/plan", tok, map[string]any{"plan": "start"}), 200, "choose start"); m.str("current", "key") != "start" {
		t.Fatalf("chosen = %v", m.Body)
	}
	a.expect(a.do("GET", "/store/debtors", tok, nil), 200, "debts on start")
	a.expect(a.do("POST", "/store/employees", tok, map[string]any{"phone": "+998900000012", "full_name": "Продавец 2", "role_id": seller, "all_stores": true}), 201, "staff 2 on start")

	// Супер-админ убирает долги из «Старта» — закрываются сразу, и на кассе тоже.
	a.expect(a.do("PATCH", "/admin/plans/start", adminTok, map[string]any{"features": []string{"promotions"}}), 200, "start without debts")
	a.expect(a.do("GET", "/store/debtors", tok, nil), 403, "debts removed")
	a.expect(a.do("PATCH", "/admin/plans/start", adminTok, map[string]any{"features": []string{"debts", "promotions"}}), 200, "debts back")
	a.expect(a.do("GET", "/store/debtors", tok, nil), 200, "debts back")

	// Скрытый тариф: магазин выбрать не может, супер-админ назначает.
	vip := a.expect(a.do("POST", "/admin/plans", adminTok, map[string]any{
		"key": "pilot", "name": "Пилот", "name_uz": "Pilot", "is_public": false, "price_uzs": 0,
		"features": []string{"debts", "reports_pro", "abc_xyz"}, "limits": map[string]any{"registers": 2},
	}), 201, "hidden plan")
	if vip.str("key") != "pilot" || vip.Body["limits"].(map[string]any)["registers"].(float64) != 2 {
		t.Fatalf("pilot = %v", vip.Body)
	}
	a.expect(a.do("POST", "/store/plan", tok, map[string]any{"plan": "pilot"}), 404, "hidden plan by store")
	a.expect(a.do("PATCH", "/admin/billing/networks/"+network, adminTok, map[string]any{"plan_key": "pilot"}), 200, "assign pilot")
	a.expect(a.do("GET", "/store/reports/abc-xyz", tok, nil), 200, "abc on pilot")
	a.expect(a.do("POST", "/store/pos/devices", tok, map[string]any{"store_id": store, "name": "Касса 2"}), 201, "device 2 on pilot")
	a.expect(a.do("DELETE", "/admin/plans/pilot", adminTok, nil), 409, "plan in use")
	a.expect(a.do("PATCH", "/admin/plans/business", adminTok, map[string]any{"is_active": false}), 409, "trial plan cannot be archived")
}

// TestPlanCommission — на «Бесплатном» с оплаченного онлайн-заказа
// удерживается комиссия; отмена её снимает, доставка делает доступной.
func TestPlanCommission(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	a := newAPI(t, paymeConfig(), pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	shop := newAdminShop(t, a, adminTok, "+998900000002", "+998900000077")
	if _, err := pool.Exec(ctx, `UPDATE networks SET plan_key = 'free', plan_trial_until = NULL WHERE id = $1`, shop.network); err != nil {
		t.Fatal(err)
	}
	prov := providers{t: t, srv: a.srv}
	pay := func(id string, n int) string {
		total := sqlStr(t, pool, `SELECT (total * 100)::bigint::text FROM orders WHERE id = $1`, id)
		var amount int64
		for _, c := range total {
			amount = amount*10 + int64(c-'0')
		}
		tid := "pm-c" + string(rune('0'+n))
		prov.payme(paymeKey, "CreateTransaction", map[string]any{"id": tid, "time": time.Now().UnixMilli(), "amount": amount, "account": map[string]any{"order_id": id}})
		prov.payme(paymeKey, "PerformTransaction", map[string]any{"id": tid})
		return sqlStr(t, pool, `SELECT total::text FROM orders WHERE id = $1`, id)
	}
	id, _ := shop.order(t)
	total := pay(id, 1)
	commission := sqlStr(t, pool, `SELECT amount::text || ':' || status FROM balance_entries WHERE order_id = $1 AND kind = 'commission'`, id)
	want := sqlStr(t, pool, `SELECT (-round($1::numeric * 5 / 100, 2))::text || ':pending'`, total)
	if commission != want {
		t.Fatalf("commission = %s, want %s", commission, want)
	}
	// Отмена магазином снимает и деньги заказа, и комиссию.
	owner, _ := a.login("+998900000002", identity.AppStore)
	a.expect(a.do("POST", "/store/orders/"+id+"/cancel", owner, map[string]any{"reason": "нет товара"}), 200, "cancel")
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM balance_entries WHERE order_id = $1`, id); n != "0" {
		t.Fatalf("entries after cancel = %s", n)
	}

	// На «Старте» комиссии нет.
	if _, err := pool.Exec(ctx, `UPDATE networks SET plan_key = 'start' WHERE id = $1`, shop.network); err != nil {
		t.Fatal(err)
	}
	id2, _ := shop.order(t)
	pay(id2, 2)
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM balance_entries WHERE order_id = $1 AND kind = 'commission'`, id2); n != "0" {
		t.Fatalf("commission on start = %s", n)
	}
}

// «Бесплатный» выключен супер-админом (как на проде): новая сеть без тарифа
// получает первый действующий тариф, а не ошибку «тариф не найден».
func TestDefaultPlanDisabled(t *testing.T) {
	pool := freshDB(t)
	a := newAPI(t, paymeConfig(), pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	a.expect(a.do("PATCH", "/admin/plans/free", adminTok, map[string]any{"is_active": false}), 200, "disable free")
	net := a.expect(a.do("POST", "/admin/networks", adminTok, map[string]string{
		"name": "Дукон", "kind": "single", "owner_phone": "+998900000002", "owner_name": "Владелец",
	}), 201, "network without plan")
	if net.str("plan_key") != "start" {
		t.Fatalf("network = %v", net.Body)
	}
	// Явно выбранный выключенный тариф — по-прежнему ошибка.
	a.expect(a.do("POST", "/admin/networks", adminTok, map[string]string{
		"name": "Дукон 2", "kind": "single", "owner_phone": "+998900000003", "owner_name": "Владелец", "plan_key": "free",
	}), 400, "explicit disabled plan")
}
