package server_test

import (
	"context"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// TestCourierLogin — вход курьера по логину и паролю: магазин задаёт логин,
// курьер входит, видит только свои маршруты; неверные пароли блокируют
// вход на 15 минут; смена пароля и отключение закрывают сессии. История
// доставок с наличными.
func TestCourierLogin(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	a := newAPI(t, paymeConfig(), pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	shop := newAdminShop(t, a, adminTok, "+998900000002", "+998901234567")
	tok, _ := a.login("+998900000002", identity.AppStore)
	if _, err := pool.Exec(ctx, `UPDATE stores SET phone = '+998712000000' WHERE id = $1`, shop.store); err != nil {
		t.Fatal(err)
	}

	role := a.expect(a.do("POST", "/store/roles", tok, map[string]any{"name": "Курьер", "permissions": []string{identity.PermOrdersDeliver}}), 201, "role").str("id")
	courier := a.expect(a.do("POST", "/store/employees", tok, map[string]any{
		"phone": "+998900000070", "full_name": "Азиз Каримов", "role_id": role, "store_ids": []string{shop.store},
	}), 201, "courier").str("id")
	other := a.expect(a.do("POST", "/store/employees", tok, map[string]any{
		"phone": "+998900000072", "full_name": "Жасур", "role_id": role, "store_ids": []string{shop.store},
	}), 201, "courier 2").str("id")
	cashRole := a.expect(a.do("POST", "/store/roles", tok, map[string]any{"name": "Кассир", "permissions": []string{identity.PermSalesPOS}}), 201, "cash role").str("id")
	cashier := a.expect(a.do("POST", "/store/employees", tok, map[string]any{
		"phone": "+998900000071", "full_name": "Кассир", "role_id": cashRole, "store_ids": []string{shop.store},
	}), 201, "cashier").str("id")

	// Логин и пароль задаёт магазин.
	set := func(id string, login, password string) resp {
		return a.do("PUT", "/store/couriers/"+id+"/login", tok, map[string]any{"login": login, "password": password})
	}
	a.expect(set(cashier, "kassir", "password1"), 400, "cashier is not a courier")
	a.expect(set(courier, "A b", "password1"), 400, "bad login")
	a.expect(set(courier, "aziz", "short"), 400, "short password")
	a.expect(a.do("GET", "/store/couriers/"+courier+"/login", tok, nil), 404, "no login yet")
	info := a.expect(set(courier, " Aziz.Baraka ", "secret-123"), 200, "set login")
	if info.str("login") != "aziz.baraka" {
		t.Fatalf("login = %v", info.Body)
	}
	a.expect(set(other, "aziz.baraka", "password2"), 409, "login taken")
	list := a.expect(a.do("GET", "/store/couriers?store_id="+shop.store, tok, nil), 200, "couriers").items()
	logins := map[string]any{}
	for _, c := range list {
		logins[c["employee_id"].(string)] = c["login"]
	}
	if logins[courier] != "aziz.baraka" || logins[other] != nil {
		t.Fatalf("couriers = %v", list)
	}

	login := func(l, p string) resp {
		return a.do("POST", "/auth/courier/login", "", map[string]any{"login": l, "password": p})
	}
	bad := a.expect(login("aziz.baraka", "wrong-pass"), 401, "wrong password")
	if bad.Body["error"].(map[string]any)["details"].(map[string]any)["attempts_left"].(float64) != 4 {
		t.Fatalf("bad = %v", bad.Body)
	}
	a.expect(login("nobody", "secret-123"), 401, "unknown login")
	ok := a.expect(login("AZIZ.baraka", "secret-123"), 200, "login")
	cTok := ok.str("access_token")

	me := a.expect(a.do("GET", "/courier/me", cTok, nil), 200, "me")
	stores := me.Body["stores"].([]any)
	if me.str("login") != "aziz.baraka" || me.str("phone") != "+998900000070" || len(stores) != 1 ||
		stores[0].(map[string]any)["phone"] != "+998712000000" {
		t.Fatalf("me = %v", me.Body)
	}
	// Токен курьера — только для /courier/*.
	a.expect(a.do("GET", "/store/orders", cTok, nil), 403, "store route")
	a.expect(a.do("GET", "/store/me", cTok, nil), 403, "store me")
	// Обновление токена сохраняет приложение курьера.
	ref := a.expect(a.do("POST", "/auth/refresh", "", map[string]any{"refresh_token": ok.str("refresh_token")}), 200, "refresh")
	cTok = ref.str("access_token")
	a.expect(a.do("GET", "/courier/me", cTok, nil), 200, "me after refresh")

	// Заказ наличными: забрал, доставил — в истории с суммой наличных.
	a.expect(a.do("POST", "/courier/shift", cTok, map[string]any{"on_shift": true, "vehicle": "bike"}), 200, "shift")
	o := a.expect(a.do("POST", "/client/orders", shop.client, map[string]any{
		"store_id": shop.store, "address_id": shop.addr, "payment_provider": "cash",
		"items": []map[string]any{{"product_id": shop.cola, "qty": 2}},
	}), 201, "cash order")
	id := o.str("order", "id")
	a.expect(a.do("POST", "/store/orders/"+id+"/accept", tok, nil), 200, "accept")
	a.expect(a.do("POST", "/store/orders/"+id+"/assign-courier", tok, map[string]any{"courier_id": courier}), 200, "assign")
	co := a.expect(a.do("GET", "/courier/orders", cTok, nil), 200, "orders").items()
	if len(co) != 1 || co[0]["cash"] != true || co[0]["items_count"].(float64) != 1 {
		t.Fatalf("courier orders = %v", co)
	}
	if _, err := pool.Exec(ctx, `UPDATE orders SET status = 'picked' WHERE id = $1`, id); err != nil {
		t.Fatal(err)
	}
	a.expect(a.do("POST", "/courier/orders/"+id+"/picked-up", cTok, nil), 200, "picked up")
	dv := a.expect(a.do("POST", "/courier/orders/"+id+"/delivered", cTok, nil), 200, "delivered")
	if dv.str("order", "status") != "delivered" || dv.Body["picked_up_at"] == nil {
		t.Fatalf("delivered = %v", dv.Body)
	}
	h := a.expect(a.do("GET", "/courier/history?period=today", cTok, nil), 200, "history")
	if h.Body["delivered"].(float64) != 1 || h.str("cash_total") != o.str("order", "total") || len(h.Body["items"].([]any)) != 1 {
		t.Fatalf("history = %v (total %s)", h.Body, o.str("order", "total"))
	}
	if y := a.expect(a.do("GET", "/courier/history?period=yesterday", cTok, nil), 200, "yesterday"); y.Body["delivered"].(float64) != 0 {
		t.Fatalf("yesterday = %v", y.Body)
	}
	a.expect(a.do("GET", "/courier/history?period=month", cTok, nil), 400, "bad period")

	// Новый пароль — старая сессия закрыта, старый пароль не подходит.
	a.expect(set(courier, "aziz.baraka", "new-secret-1"), 200, "new password")
	a.expect(a.do("GET", "/courier/me", cTok, nil), 401, "old session")
	a.expect(login("aziz.baraka", "secret-123"), 401, "old password")
	cTok = a.expect(login("aziz.baraka", "new-secret-1"), 200, "new login").str("access_token")
	// Смена только логина пароль и сессии не трогает.
	a.expect(set(courier, "aziz.k", ""), 200, "rename")
	a.expect(a.do("GET", "/courier/me", cTok, nil), 200, "session after rename")

	// Пять неверных паролей — вход закрыт даже с верным.
	for i := 0; i < 4; i++ {
		a.expect(login("aziz.k", "nope-nope"), 401, "wrong")
	}
	a.expect(login("aziz.k", "nope-nope"), 429, "locked")
	a.expect(login("aziz.k", "new-secret-1"), 429, "still locked")
	if l := a.expect(a.do("GET", "/store/couriers/"+courier+"/login", tok, nil), 200, "login info"); l.Body["locked"] != true {
		t.Fatalf("locked = %v", l.Body)
	}
	// Магазин сбрасывает пароль — блокировка снята.
	a.expect(set(courier, "aziz.k", "reset-pass-2"), 200, "reset")
	cTok = a.expect(login("aziz.k", "reset-pass-2"), 200, "after reset").str("access_token")

	// Отключили вход — сессия и логин больше не работают.
	a.expect(a.do("DELETE", "/store/couriers/"+courier+"/login", tok, nil), 204, "disable")
	a.expect(a.do("GET", "/courier/me", cTok, nil), 401, "disabled session")
	a.expect(login("aziz.k", "reset-pass-2"), 401, "disabled login")
	a.expect(a.do("DELETE", "/store/couriers/"+courier+"/login", tok, nil), 404, "disable twice")

	// Право доставки убрали из роли — вход не пускает.
	a.expect(set(courier, "aziz.k", "reset-pass-3"), 200, "again")
	a.expect(a.do("PATCH", "/store/roles/"+role, tok, map[string]any{"permissions": []string{identity.PermSalesPOS}}), 200, "role without deliver")
	a.expect(login("aziz.k", "reset-pass-3"), 403, "no deliver right")
}
