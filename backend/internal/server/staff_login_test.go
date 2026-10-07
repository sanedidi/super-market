package server_test

import (
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// TestStoreLoginByPassword — вход в панель магазина по логину и паролю:
// супер-админ выдаёт владельцу логин и временный пароль, владелец при первом
// входе придумывает свой; вход по коду для магазина закрыт; сброс пароля и
// смена телефона владельца — только у супер-админа; логины сотрудникам
// выдаёт владелец.
func TestStoreLoginByPassword(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)

	create := func(body map[string]any) resp { return a.do("POST", "/admin/networks", adminTok, body) }
	base := func(extra map[string]any) map[string]any {
		b := map[string]any{"name": "Olma", "kind": "chain", "owner_phone": "+998900000002", "owner_name": "Бахтиёр"}
		for k, v := range extra {
			b[k] = v
		}
		return b
	}
	a.expect(create(base(map[string]any{"owner_login": "olma"})), 400, "login without password")
	a.expect(create(base(map[string]any{"owner_login": "O l", "owner_password": "Temp-1234"})), 400, "bad login")
	a.expect(create(base(map[string]any{"owner_login": "olma", "owner_password": "short"})), 400, "short password")
	net := a.expect(create(base(map[string]any{"owner_login": " Olma ", "owner_password": "Temp-1234"})), 201, "create network")
	netID := net.str("id")
	if net.str("owner_login") != "olma" || net.Body["owner_temp_password"] != true {
		t.Fatalf("network = %v", net.Body)
	}
	if got := a.expect(a.do("GET", "/admin/networks?q=OLMA", adminTok, nil), 200, "search by login").items(); len(got) != 1 {
		t.Fatalf("search = %v", got)
	}
	a.expect(create(map[string]any{"name": "Korzinka", "kind": "single", "owner_phone": "+998900000003", "owner_name": "Б",
		"owner_login": "olma", "owner_password": "Temp-1234"}), 409, "login taken")

	// Код из Telegram в магазин больше не пускает.
	a.expect(a.do("POST", "/auth/otp/request", "", map[string]string{"phone": "+998900000002"}), 200, "request code")
	if r := a.expect(a.do("POST", "/auth/otp/verify", "", map[string]string{"phone": "+998900000002", "code": "111111", "app": "store"}),
		403, "code into store"); r.str("error", "code") != "password_login_required" {
		t.Fatalf("code login = %v", r.Body)
	}

	login := func(l, p string) resp {
		return a.do("POST", "/auth/store/login", "", map[string]any{"login": l, "password": p})
	}
	a.expect(login("olma", ""), 400, "empty password")
	a.expect(login("nobody", "Temp-1234"), 401, "unknown login")
	if r := a.expect(login("olma", "wrong-pass"), 401, "wrong password"); r.Body["error"].(map[string]any)["details"].(map[string]any)["attempts_left"] != 4.0 {
		t.Fatalf("wrong = %v", r.Body)
	}

	// Первый вход: только смена пароля.
	r := a.expect(login("OLMA", "Temp-1234"), 200, "owner login")
	if r.Body["password_change_required"] != true {
		t.Fatalf("login = %v", r.Body)
	}
	tok := r.str("access_token")
	me := a.expect(a.do("GET", "/store/me", tok, nil), 200, "me with temp password")
	if me.Body["must_change_password"] != true || me.Body["is_owner"] != true {
		t.Fatalf("me = %v", me.Body)
	}
	if r := a.expect(a.do("GET", "/store/stores", tok, nil), 403, "panel with temp password"); r.str("error", "code") != "password_change_required" {
		t.Fatalf("stores = %v", r.Body)
	}
	change := func(tok, cur, next string) resp {
		return a.do("POST", "/auth/store/password", tok, map[string]any{"current_password": cur, "new_password": next})
	}
	a.expect(change(tok, "", "short1"), 400, "short new password")
	a.expect(change(tok, "", "onlyletters"), 400, "no digits")
	a.expect(change(tok, "", "Temp-1234"), 400, "same as temp")
	a.expect(change(tok, "", "Olma2026sm"), 204, "own password")
	if me := a.expect(a.do("GET", "/store/me", tok, nil), 200, "me"); me.Body["must_change_password"] != false {
		t.Fatalf("me after change = %v", me.Body)
	}
	a.expect(a.do("GET", "/store/stores", tok, nil), 200, "panel after change")
	a.expect(login("olma", "Temp-1234"), 401, "temp password is gone")
	// Обычная смена пароля — с текущим.
	if r := a.expect(change(tok, "wrong", "Olma2027sm"), 422, "wrong current"); r.str("error", "code") != "wrong_password" {
		t.Fatalf("change = %v", r.Body)
	}
	other := a.expect(login("olma", "Olma2026sm"), 200, "second device").str("access_token")
	a.expect(change(tok, "Olma2026sm", "Olma2027sm"), 204, "change with current")
	a.expect(a.do("GET", "/store/me", other, nil), 401, "other sessions closed")
	a.expect(a.do("GET", "/store/me", tok, nil), 200, "own session kept")
	n := a.expect(a.do("GET", "/admin/networks/"+netID, adminTok, nil), 200, "network")
	if n.Body["owner_temp_password"] != false || n.Body["owner_last_login_at"] == nil {
		t.Fatalf("network after change = %v", n.Body)
	}

	// Сотруднику логин выдаёт владелец; владельцу — только супер-админ.
	ownerID := me.str("employee_id")
	role := a.expect(a.do("POST", "/store/roles", tok, map[string]any{"name": "Менеджер",
		"permissions": []string{identity.PermOrdersManage, identity.PermOrdersDeliver}}), 201, "role").str("id")
	mgr := a.expect(a.do("POST", "/store/employees", tok, map[string]any{
		"phone": "+998900000005", "full_name": "Менеджер", "role_id": role,
	}), 201, "manager").str("id")
	a.expect(a.do("PUT", "/store/employees/"+ownerID+"/login", tok, map[string]any{"login": "boss", "password": "Pass-1234"}), 403, "owner login from panel")
	a.expect(a.do("PUT", "/store/couriers/"+ownerID+"/login", tok, map[string]any{"login": "boss", "password": "Pass-1234"}), 403, "owner login as courier")
	a.expect(a.do("GET", "/store/employees/"+mgr+"/login", tok, nil), 404, "no login yet")
	a.expect(a.do("PUT", "/store/employees/"+mgr+"/login", tok, map[string]any{"login": "olma", "password": "Pass-1234"}), 409, "taken")
	info := a.expect(a.do("PUT", "/store/employees/"+mgr+"/login", tok, map[string]any{"login": "olma.manager", "password": "Pass-1234"}), 200, "manager login")
	if info.Body["must_change_password"] != true {
		t.Fatalf("manager login = %v", info.Body)
	}
	mr := a.expect(login("olma.manager", "Pass-1234"), 200, "manager signs in")
	if mr.Body["password_change_required"] != true {
		t.Fatalf("manager = %v", mr.Body)
	}
	mTok := mr.str("access_token")
	a.expect(change(mTok, "", "Manager2026"), 204, "manager own password")
	// Менеджер с правом заказов не трогает вход владельца и сотрудников с доступом к панели.
	a.expect(a.do("PUT", "/store/couriers/"+ownerID+"/login", mTok, map[string]any{"login": "boss", "password": "Pass-1234"}), 403, "manager vs owner")
	a.expect(a.do("PUT", "/store/couriers/"+mgr+"/login", mTok, map[string]any{"login": "x.y.z", "password": "Pass-1234"}), 403, "manager vs panel staff")
	a.expect(a.do("PUT", "/store/employees/"+mgr+"/login", mTok, map[string]any{"login": "x.y.z", "password": "Pass-1234"}), 403, "no staff.manage")
	a.expect(a.do("DELETE", "/store/employees/"+mgr+"/login", tok, nil), 204, "disable manager")
	a.expect(a.do("GET", "/store/me", mTok, nil), 401, "manager session closed")
	a.expect(login("olma.manager", "Manager2026"), 401, "manager login gone")

	// Супер-админ: сброс пароля владельца.
	a.expect(a.do("PUT", "/admin/networks/"+netID+"/owner/login", tok, map[string]any{"login": "olma", "password": "Reset-123"}), 403, "store token")
	n = a.expect(a.do("PUT", "/admin/networks/"+netID+"/owner/login", adminTok, map[string]any{"login": "olma", "password": "Reset-123"}), 200, "reset")
	if n.Body["owner_temp_password"] != true {
		t.Fatalf("reset = %v", n.Body)
	}
	a.expect(a.do("GET", "/store/me", tok, nil), 401, "owner sessions closed by reset")
	tok = a.expect(login("olma", "Reset-123"), 200, "login after reset").str("access_token")
	a.expect(a.do("GET", "/store/stores", tok, nil), 403, "temp again")
	a.expect(change(tok, "", "Olma2028sm"), 204, "own again")
	// Только логин, без пароля.
	n = a.expect(a.do("PUT", "/admin/networks/"+netID+"/owner/login", adminTok, map[string]any{"login": "olma.uz"}), 200, "rename login")
	if n.str("owner_login") != "olma.uz" || n.Body["owner_temp_password"] != false {
		t.Fatalf("rename = %v", n.Body)
	}
	a.expect(a.do("GET", "/store/stores", tok, nil), 200, "rename keeps session")
	a.expect(login("olma.uz", "Olma2028sm"), 200, "new login")

	// Телефон владельца меняет только супер-админ.
	a.expect(a.do("PATCH", "/store/employees/"+ownerID, tok, map[string]any{"phone": "+998900000009"}), 400, "owner phone from panel")
	a.expect(a.do("PATCH", "/admin/networks/"+netID+"/owner", adminTok, map[string]any{"phone": "bad"}), 400, "bad phone")
	a.expect(a.do("PATCH", "/admin/networks/"+netID+"/owner", adminTok, map[string]any{"phone": "+998900000005"}), 409, "phone of an employee")
	n = a.expect(a.do("PATCH", "/admin/networks/"+netID+"/owner", adminTok, map[string]any{"phone": "+998 93 777-40-40", "full_name": "Бахтиёр Каримов"}), 200, "owner phone")
	if n.str("owner_phone") != "+998937774040" || n.str("owner_name") != "Бахтиёр Каримов" || n.str("owner_login") != "olma.uz" {
		t.Fatalf("owner = %v", n.Body)
	}
	a.expect(a.do("GET", "/store/me", tok, nil), 401, "old phone sessions closed")
	tok = a.expect(login("olma.uz", "Olma2028sm"), 200, "same login after phone change").str("access_token")
	if me := a.expect(a.do("GET", "/store/me", tok, nil), 200, "me"); me.str("phone") != "+998937774040" || me.Body["is_owner"] != true {
		t.Fatalf("me = %v", me.Body)
	}

	// Сеть без логина можно создать — логин выдадут позже.
	single := a.expect(create(map[string]any{"name": "Dokon", "kind": "single", "owner_phone": "+998900000020", "owner_name": "Азиз"}), 201, "network without login")
	if single.str("owner_login") != "" {
		t.Fatalf("single = %v", single.Body)
	}
	a.expect(a.do("PUT", "/admin/networks/"+single.str("id")+"/owner/login", adminTok, map[string]any{"login": "dokon"}), 400, "first login needs password")
	a.expect(a.do("PUT", "/admin/networks/"+single.str("id")+"/owner/login", adminTok, map[string]any{"login": "dokon", "password": "Dokon-123"}), 200, "first login")
	a.expect(login("dokon", "Dokon-123"), 200, "single owner")

	// Блокировка после 5 неверных паролей.
	for i := 0; i < 4; i++ {
		a.expect(login("dokon", "wrong-pass"), 401, "wrong")
	}
	a.expect(login("dokon", "wrong-pass"), 429, "locked")
	a.expect(login("dokon", "Dokon-123"), 429, "still locked")
}

// TestStaffLoginScope — сбросом пароля нельзя войти под сотрудником с
// бо́льшим доступом: менеджер одного магазина не трогает вход сотрудника
// всех магазинов; логин из «Курьеров» в панель пускает только после смены
// пароля; параллельные неверные пароли не дают больше 5 попыток.
func TestStaffLoginScope(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	owner, storeA := setupNetwork(t, a, adminTok, "+998900000002")
	storeB := a.expect(a.do("POST", "/store/stores", owner, map[string]any{"name": "Магазин 2"}), 201, "store B").str("id")

	staffRole := a.expect(a.do("POST", "/store/roles", owner, map[string]any{"name": "Управляющий",
		"permissions": []string{identity.PermStaffManage, identity.PermOrdersManage}}), 201, "role").str("id")
	courierRole := a.expect(a.do("POST", "/store/roles", owner, map[string]any{"name": "Курьер",
		"permissions": []string{identity.PermOrdersDeliver}}), 201, "courier role").str("id")
	emp := func(phone, role string, all bool, stores ...string) string {
		return a.expect(a.do("POST", "/store/employees", owner, map[string]any{
			"phone": phone, "full_name": phone, "role_id": role, "all_stores": all, "store_ids": stores,
		}), 201, "employee "+phone).str("id")
	}
	emp("+998900000010", staffRole, false, storeA)
	boss := emp("+998900000011", staffRole, true)
	both := emp("+998900000012", staffRole, false, storeA, storeB)
	localA := emp("+998900000013", staffRole, false, storeA)
	courierAll := emp("+998900000014", courierRole, true)
	courierA := emp("+998900000015", courierRole, false, storeA)

	mTok, _ := a.login("+998900000010", identity.AppStore)
	set := func(path, id, login string) resp {
		return a.do("PUT", "/store/"+path+"/"+id+"/login", mTok, map[string]any{"login": login, "password": "Pass-1234"})
	}
	a.expect(set("employees", boss, "boss.x"), 403, "all-stores manager")
	a.expect(set("employees", both, "both.x"), 403, "manager of a foreign store")
	a.expect(set("couriers", courierAll, "courier.all"), 403, "all-stores courier")
	a.expect(set("employees", localA, "local.a"), 200, "same-store manager")

	// Логин из «Курьеров»: в приложение курьера — сразу, в панель — после смены пароля.
	a.expect(set("couriers", courierA, "courier.a"), 200, "courier login")
	a.expect(a.do("POST", "/auth/courier/login", "", map[string]any{"login": "courier.a", "password": "Pass-1234"}), 200, "courier app")
	r := a.expect(a.do("POST", "/auth/store/login", "", map[string]any{"login": "courier.a", "password": "Pass-1234"}), 200, "panel")
	if r.Body["password_change_required"] != true {
		t.Fatalf("courier login in panel = %v", r.Body)
	}

	// Параллельные неверные пароли: не больше 5 проверок за блокировку.
	const n = 12
	codes := make(chan int, n)
	for i := 0; i < n; i++ {
		go func() {
			codes <- a.do("POST", "/auth/store/login", "", map[string]any{"login": "local.a", "password": "wrong-pass"}).Status
		}()
	}
	wrong := 0
	for i := 0; i < n; i++ {
		if <-codes == 401 {
			wrong++
		}
	}
	if wrong > 4 {
		t.Fatalf("parallel wrong passwords checked = %d, want ≤ 4 (5-я закрывает вход)", wrong)
	}
	a.expect(a.do("POST", "/auth/store/login", "", map[string]any{"login": "local.a", "password": "Pass-1234"}), 429, "locked after burst")
}
