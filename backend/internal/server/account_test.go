package server_test

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

func errCode(r resp) string { return r.str("error", "code") }

func errDetails(r resp) map[string]any {
	e, _ := r.Body["error"].(map[string]any)
	d, _ := e["details"].(map[string]any)
	return d
}

// crowdSignIn — вход курьера «по пути» с dev-кодом.
func crowdSignIn(t *testing.T, a api, phone string, terms bool) resp {
	t.Helper()
	a.expect(a.do("POST", "/auth/otp/request", "", map[string]any{"phone": phone, "app": "crowd"}), 200, "crowd code "+phone)
	return a.do("POST", "/auth/otp/verify", "", map[string]any{"phone": phone, "code": "111111", "app": "crowd", "terms_accepted": terms})
}

// TestCrowdDeleteAccount — курьер «по пути» удаляет аккаунт сам: не раньше,
// чем доставит заказ и получит выплату; профиль обезличивается, история
// остаётся, номер освобождается (если он не нужен покупателю).
func TestCrowdDeleteAccount(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	a := newAPI(t, paymeConfig(), pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	shop := newAdminShop(t, a, adminTok, "+998900000002", "+998901234567")

	cTok := a.expect(crowdSignIn(t, a, "+998900000080", true), 200, "crowd login").str("access_token")
	me := a.expect(a.do("GET", "/crowd/me", cTok, nil), 200, "me")
	uid, code := me.str("user_id"), me.str("code")
	owner := sqlStr(t, pool, `SELECT e.id::text FROM employees e JOIN users u ON u.id = e.user_id WHERE u.phone = '+998900000002'`)
	if _, err := pool.Exec(ctx, `
		UPDATE crowd_couriers SET status = 'active', full_name = 'Рахимов Азиз', birth_date = '2000-01-01',
		       doc_hash = '\x0102', verified_at = now(), verified_store_id = $2 WHERE user_id = $1`, uid, shop.store); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `
		INSERT INTO courier_verifications (courier_id, network_id, store_id, employee_id, doc_type, full_name, birth_date, doc_hash, result)
		VALUES ($1, $2, $3, $4, 'id_card', 'Рахимов Азиз', '2000-01-01', '\x0102', 'approved')`, uid, shop.network, shop.store, owner); err != nil {
		t.Fatal(err)
	}

	// Заказ на руках — удалить нельзя.
	id, number := shop.order(t)
	if _, err := pool.Exec(ctx, `UPDATE orders SET status = 'delivering', paid_at = now(), crowd_courier_id = $2, crowd_accepted_at = now() WHERE id = $1`, id, uid); err != nil {
		t.Fatal(err)
	}
	r := a.expect(a.do("DELETE", "/crowd/me", cTok, nil), 409, "active order")
	if errCode(r) != "active_order" || errDetails(r)["order_number"].(float64) != number || errDetails(r)["account"] != "crowd" ||
		!strings.Contains(r.str("error", "message"), fmt.Sprintf("№%d", int(number))) {
		t.Fatalf("active order = %v", r.Body)
	}

	// Доставил, но вознаграждение не выплачено.
	if _, err := pool.Exec(ctx, `UPDATE orders SET status = 'delivered', delivered_at = now() WHERE id = $1`, id); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO crowd_ledger (courier_id, order_id, kind, amount) VALUES ($1, $2, 'delivery', 10000)`, uid, id); err != nil {
		t.Fatal(err)
	}
	r = a.expect(a.do("DELETE", "/crowd/me", cTok, nil), 409, "unpaid balance")
	if errCode(r) != "unpaid_balance" || errDetails(r)["balance"] != "10000.00" || !strings.Contains(r.str("error", "message"), "10 000") {
		t.Fatalf("unpaid = %v", r.Body)
	}
	a.expect(a.do("POST", "/admin/crowd/payouts", adminTok, map[string]any{"courier_ids": []string{uid}}), 200, "pay")

	a.expect(a.do("DELETE", "/crowd/me", shop.client, nil), 403, "client token")
	a.expect(a.do("DELETE", "/crowd/me", cTok, nil), 204, "delete")
	a.expect(a.do("GET", "/crowd/me", cTok, nil), 401, "session closed")
	a.expect(a.do("DELETE", "/crowd/me", cTok, nil), 401, "delete twice")

	// Профиль обезличен, номер освобождён, история осталась.
	var (
		name, phone, status string
		hasDoc, deleted     bool
		ledger              int
		vname               string
	)
	if err := pool.QueryRow(ctx, `
		SELECT cc.full_name, u.phone, cc.status, cc.doc_hash IS NOT NULL, cc.deleted_at IS NOT NULL,
		       (SELECT count(*) FROM crowd_ledger WHERE courier_id = cc.user_id)::int,
		       (SELECT full_name FROM courier_verifications WHERE courier_id = cc.user_id)
		FROM crowd_couriers cc JOIN users u ON u.id = cc.user_id WHERE cc.user_id = $1`, uid).Scan(
		&name, &phone, &status, &hasDoc, &deleted, &ledger, &vname); err != nil {
		t.Fatal(err)
	}
	if name != "" || !strings.HasPrefix(phone, "+999") || status != "unverified" || hasDoc || !deleted || ledger != 2 || vname != "" {
		t.Fatalf("after delete: name=%q phone=%q status=%q doc=%v deleted=%v ledger=%d verification=%q", name, phone, status, hasDoc, deleted, ledger, vname)
	}
	if o := a.expect(a.do("GET", "/admin/orders/"+id, adminTok, nil), 200, "order kept"); o.str("crowd_courier_id") != uid {
		t.Fatalf("order = %v", o.Body)
	}
	for _, c := range a.expect(a.do("GET", "/admin/crowd/couriers", adminTok, nil), 200, "couriers").items() {
		if c["user_id"] == uid {
			t.Fatal("удалённый курьер в списке")
		}
	}
	a.expect(a.do("POST", "/store/crowd/lookup", mustStoreTok(t, a), map[string]any{"code": code}), 404, "lookup deleted")

	// Тот же номер — новый курьер.
	if _, err := pool.Exec(ctx, `DELETE FROM auth_codes`); err != nil {
		t.Fatal(err)
	}
	a.expect(crowdSignIn(t, a, "+998900000080", false), 422, "new registration needs terms")
	if _, err := pool.Exec(ctx, `DELETE FROM auth_codes`); err != nil {
		t.Fatal(err)
	}
	n := a.expect(crowdSignIn(t, a, "+998900000080", true), 200, "new courier").str("access_token")
	if m := a.expect(a.do("GET", "/crowd/me", n, nil), 200, "new me"); m.str("user_id") == uid || m.str("status") != "unverified" {
		t.Fatalf("new me = %v", m.Body)
	}

	// Курьер, который ещё и покупатель: номер остаётся покупателю, повторная
	// регистрация курьера — с согласием, код прежний, личность — заново.
	c2 := a.expect(crowdSignIn(t, a, "+998901234567", true), 200, "client as courier").str("access_token")
	me2 := a.expect(a.do("GET", "/crowd/me", c2, nil), 200, "me2")
	if _, err := pool.Exec(ctx, `UPDATE crowd_couriers SET status = 'active', verified_at = now() WHERE user_id = $1`, me2.str("user_id")); err != nil {
		t.Fatal(err)
	}
	a.expect(a.do("DELETE", "/crowd/me", c2, nil), 204, "delete courier of client")
	if p := a.expect(a.do("GET", "/client/me", shop.client, nil), 200, "client alive"); p.str("phone") != "+998901234567" {
		t.Fatalf("client = %v", p.Body)
	}
	if _, err := pool.Exec(ctx, `DELETE FROM auth_codes`); err != nil {
		t.Fatal(err)
	}
	a.expect(crowdSignIn(t, a, "+998901234567", false), 422, "re-register needs terms")
	if _, err := pool.Exec(ctx, `DELETE FROM auth_codes`); err != nil {
		t.Fatal(err)
	}
	c3 := a.expect(crowdSignIn(t, a, "+998901234567", true), 200, "re-register").str("access_token")
	if m := a.expect(a.do("GET", "/crowd/me", c3, nil), 200, "me3"); m.str("user_id") != me2.str("user_id") || m.str("code") != me2.str("code") || m.str("status") != "unverified" {
		t.Fatalf("me3 = %v, before = %v", m.Body, me2.Body)
	}

	// Удаление аккаунта покупателя не забирает номер у курьера.
	a.expect(a.do("DELETE", "/client/me", shop.client, nil), 204, "delete client")
	if p := sqlStr(t, pool, `SELECT phone FROM users WHERE id = $1`, me2.str("user_id")); p != "+998901234567" {
		t.Fatalf("phone = %q", p)
	}
	a.expect(a.do("GET", "/crowd/me", c3, nil), 200, "courier alive after client delete")
}

func mustStoreTok(t *testing.T, a api) string {
	t.Helper()
	tok, _ := a.login("+998900000002", identity.AppStore)
	return tok
}

// TestDeletionRequests — сотрудник «SM Магазин», штатный курьер и владелец
// просят удалить аккаунт: запрос уходит супер-админу (и владельцу сети) в
// Telegram, супер-админ видит список и отмечает выполненным или отклонённым.
func TestDeletionRequests(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	tg := &fakeTelegram{}
	a := newAPI(t, paymeConfig(), pool, tg)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	shop := newAdminShop(t, a, adminTok, "+998900000002", "+998901234567")
	ownerTok, _ := a.login("+998900000002", identity.AppStore)
	if _, err := pool.Exec(ctx, `INSERT INTO telegram_links (phone, chat_id, tg_user_id) VALUES ('+998900000001', 1001, 1001), ('+998900000002', 2002, 2002)`); err != nil {
		t.Fatal(err)
	}
	sentTo := func(chat int64) int {
		tg.mu.Lock()
		defer tg.mu.Unlock()
		n := 0
		for _, m := range tg.sent {
			if m.chatID == chat && strings.Contains(m.text, "Запрос на удаление аккаунта") {
				n++
			}
		}
		return n
	}

	role := a.expect(a.do("POST", "/store/roles", ownerTok, map[string]any{"name": "Продавец", "permissions": []string{identity.PermOrdersManage}}), 201, "role").str("id")
	a.expect(a.do("POST", "/store/employees", ownerTok, map[string]any{
		"phone": "+998900000060", "full_name": "Дилноза Каримова", "role_id": role, "store_ids": []string{shop.store},
	}), 201, "employee")
	empTok, _ := a.login("+998900000060", identity.AppStore)

	a.expect(a.do("POST", "/store/me/deletion-request", empTok, map[string]any{"reason": strings.Repeat("я", 501)}), 400, "long reason")
	r := a.expect(a.do("POST", "/store/me/deletion-request", empTok, map[string]any{"reason": " Уволилась "}), 201, "request")
	if r.str("app") != "store" || r.str("source") != "app" || r.str("status") != "pending" || r.Body["is_owner"] != false ||
		r.str("full_name") != "Дилноза Каримова" || r.str("phone") != "+998900000060" || r.str("reason") != "Уволилась" ||
		r.str("network_name") == "" {
		t.Fatalf("request = %v", r.Body)
	}
	if again := a.expect(a.do("POST", "/store/me/deletion-request", empTok, nil), 200, "again"); again.str("id") != r.str("id") {
		t.Fatalf("again = %v", again.Body)
	}
	if sentTo(1001) != 1 || sentTo(2002) != 1 {
		t.Fatalf("telegram = %v", tg.sent)
	}

	// Штатный курьер (вход по логину и паролю).
	dRole := a.expect(a.do("POST", "/store/roles", ownerTok, map[string]any{"name": "Курьер", "permissions": []string{identity.PermOrdersDeliver}}), 201, "courier role").str("id")
	courier := a.expect(a.do("POST", "/store/employees", ownerTok, map[string]any{
		"phone": "+998900000070", "full_name": "Азиз", "role_id": dRole, "store_ids": []string{shop.store},
	}), 201, "courier").str("id")
	a.expect(a.do("PUT", "/store/couriers/"+courier+"/login", ownerTok, map[string]any{"login": "aziz", "password": "secret-123"}), 200, "courier login")
	cTok := a.expect(a.do("POST", "/auth/courier/login", "", map[string]any{"login": "aziz", "password": "secret-123"}), 200, "courier sign in").str("access_token")
	cr := a.expect(a.do("POST", "/courier/me/deletion-request", cTok, nil), 201, "courier request")
	if cr.str("app") != "courier" || cr.str("employee_id") != courier {
		t.Fatalf("courier request = %v", cr.Body)
	}
	a.expect(a.do("POST", "/store/me/deletion-request", cTok, nil), 403, "courier token on store route")

	// Владелец: удаление — закрытие сети, владельцу самому не пишем.
	ow := a.expect(a.do("POST", "/store/me/deletion-request", ownerTok, map[string]any{"reason": "Закрываемся"}), 201, "owner request")
	if ow.Body["is_owner"] != true || sentTo(1001) != 3 || sentTo(2002) != 2 {
		t.Fatalf("owner request = %v, telegram = %v", ow.Body, tg.sent)
	}
	if !strings.Contains(tg.last().text, "закрытие сети") {
		t.Fatalf("owner message = %q", tg.last().text)
	}
	a.expect(a.do("POST", "/store/me/deletion-request", shop.client, nil), 403, "client token")

	// Супер-админ.
	a.expect(a.do("GET", "/admin/account-deletion-requests", ownerTok, nil), 403, "store token on admin")
	a.expect(a.do("GET", "/admin/account-deletion-requests?status=nope", adminTok, nil), 400, "bad status")
	if l := a.expect(a.do("GET", "/admin/account-deletion-requests?status=pending", adminTok, nil), 200, "pending").items(); len(l) != 3 {
		t.Fatalf("pending = %v", l)
	}
	done := a.expect(a.do("POST", "/admin/account-deletion-requests/"+r.str("id")+"/done", adminTok, map[string]any{"note": "Отключена"}), 200, "done")
	if done.str("status") != "done" || done.str("note") != "Отключена" || done.Body["resolved_at"] == nil {
		t.Fatalf("done = %v", done.Body)
	}
	if e := a.expect(a.do("POST", "/admin/account-deletion-requests/"+r.str("id")+"/reject", adminTok, nil), 409, "resolve twice"); errCode(e) != "already_resolved" {
		t.Fatalf("twice = %v", e.Body)
	}
	if rj := a.expect(a.do("POST", "/admin/account-deletion-requests/"+ow.str("id")+"/reject", adminTok, nil), 200, "reject"); rj.str("status") != "rejected" {
		t.Fatalf("reject = %v", rj.Body)
	}
	a.expect(a.do("POST", "/admin/account-deletion-requests/00000000-0000-0000-0000-000000000000/done", adminTok, nil), 404, "unknown")
	if l := a.expect(a.do("GET", "/admin/account-deletion-requests", adminTok, nil), 200, "all").items(); len(l) != 3 || l[0]["status"] != "pending" {
		t.Fatalf("all = %v", l)
	}
	// После обработки можно попросить снова.
	if n := a.expect(a.do("POST", "/store/me/deletion-request", empTok, nil), 201, "new request"); n.str("id") == r.str("id") {
		t.Fatalf("new = %v", n.Body)
	}
}

// TestWebAccountDeletion — удаление аккаунта на сайте по номеру и коду (без
// входа): покупатель и курьер «по пути» удаляются по тем же правилам, что в
// приложениях; сотрудникам и штатным курьерам — запрос супер-админу.
func TestWebAccountDeletion(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	a := newAPI(t, paymeConfig(), pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	shop := newAdminShop(t, a, adminTok, "+998900000002", "+998901234567")
	ownerTok, _ := a.login("+998900000002", identity.AppStore)
	resetCodes := func() {
		t.Helper()
		if _, err := pool.Exec(ctx, `DELETE FROM auth_codes`); err != nil {
			t.Fatal(err)
		}
	}
	request := func(phone string) resp {
		t.Helper()
		return a.do("POST", "/public/account-deletion/request", "", map[string]any{"phone": phone})
	}
	confirm := func(phone, code string) resp {
		t.Helper()
		return a.do("POST", "/public/account-deletion/confirm", "", map[string]any{"phone": phone, "code": code})
	}
	list := func(r resp, key string) string {
		raw, _ := r.Body[key].([]any)
		var out []string
		for _, x := range raw {
			out = append(out, x.(string))
		}
		return strings.Join(out, ",")
	}

	a.expect(request("123"), 400, "bad phone")
	if r := a.expect(request("+998909999999"), 404, "no account"); errCode(r) != "account_not_found" {
		t.Fatalf("no account = %v", r.Body)
	}

	// Покупатель с незавершённым заказом: 409, ничего не удалено.
	shop.order(t)
	if r := a.expect(request("+998 90 123 45 67"), 200, "request"); r.Body["sent"] != true || r.Body["resend_in"].(float64) != 60 {
		t.Fatalf("request = %v", r.Body)
	}
	a.expect(request("+998901234567"), 429, "cooldown")
	a.expect(confirm("+998901234567", "000000"), 400, "wrong code")
	r := a.expect(confirm("+998901234567", "111111"), 409, "active order")
	if errCode(r) != "active_order" || errDetails(r)["account"] != "client" {
		t.Fatalf("active = %v", r.Body)
	}
	a.expect(a.do("GET", "/client/me", shop.client, nil), 200, "client alive")
	a.expect(confirm("+998901234567", "111111"), 400, "code used")
	if _, err := pool.Exec(ctx, `UPDATE orders SET status = 'delivered'`); err != nil {
		t.Fatal(err)
	}
	a.expect(request("+998901234567"), 200, "request again")
	r = a.expect(confirm("+998901234567", "111111"), 200, "deleted")
	if list(r, "deleted") != "client" || list(r, "requested") != "" {
		t.Fatalf("result = %v", r.Body)
	}
	a.expect(a.do("GET", "/client/me", shop.client, nil), 401, "client session closed")
	if n := sqlStr(t, pool, `SELECT count(*)::text FROM users WHERE phone = '+998901234567'`); n != "0" {
		t.Fatal("номер не освобождён")
	}
	a.expect(request("+998901234567"), 404, "deleted account")

	// Покупатель и курьер «по пути» на одном номере: остаток к выплате — 409
	// и не удаляется ни один аккаунт; после выплаты — оба.
	client2, _ := a.login("+998900000081", identity.AppClient)
	resetCodes()
	crowd := a.expect(crowdSignIn(t, a, "+998900000081", true), 200, "crowd").str("access_token")
	uid := sqlStr(t, pool, `SELECT id::text FROM users WHERE phone = '+998900000081'`)
	if _, err := pool.Exec(ctx, `INSERT INTO crowd_ledger (courier_id, kind, amount) VALUES ($1, 'adjustment', 5000)`, uid); err != nil {
		t.Fatal(err)
	}
	resetCodes()
	a.expect(request("+998900000081"), 200, "request crowd")
	r = a.expect(confirm("+998900000081", "111111"), 409, "unpaid")
	if errCode(r) != "unpaid_balance" || errDetails(r)["account"] != "crowd" {
		t.Fatalf("unpaid = %v", r.Body)
	}
	a.expect(a.do("GET", "/client/me", client2, nil), 200, "client2 alive")
	a.expect(a.do("GET", "/crowd/me", crowd, nil), 200, "crowd alive")
	if _, err := pool.Exec(ctx, `INSERT INTO crowd_ledger (courier_id, kind, amount) VALUES ($1, 'payout', -5000)`, uid); err != nil {
		t.Fatal(err)
	}
	a.expect(request("+998900000081"), 200, "request crowd again")
	r = a.expect(confirm("+998900000081", "111111"), 200, "both deleted")
	if list(r, "deleted") != "crowd,client" || list(r, "requested") != "" {
		t.Fatalf("result = %v", r.Body)
	}
	a.expect(a.do("GET", "/client/me", client2, nil), 401, "client2 closed")
	a.expect(a.do("GET", "/crowd/me", crowd, nil), 401, "crowd closed")
	if p := sqlStr(t, pool, `SELECT phone FROM users WHERE id = $1`, uid); !strings.HasPrefix(p, "+999") {
		t.Fatalf("phone = %q", p)
	}

	// Владелец сети, который ещё и покупатель: покупатель удалён, по сети —
	// запрос супер-админу, вход в панель остаётся.
	a.login("+998900000002", identity.AppClient)
	a.expect(request("+998900000002"), 200, "owner request")
	r = a.expect(confirm("+998900000002", "111111"), 200, "owner")
	if list(r, "deleted") != "client" || list(r, "requested") != "store" {
		t.Fatalf("owner = %v", r.Body)
	}
	a.expect(a.do("GET", "/store/me", ownerTok, nil), 200, "owner still in panel")

	// Штатный курьер: только запрос.
	dRole := a.expect(a.do("POST", "/store/roles", ownerTok, map[string]any{"name": "Курьер", "permissions": []string{identity.PermOrdersDeliver}}), 201, "courier role").str("id")
	courier := a.expect(a.do("POST", "/store/employees", ownerTok, map[string]any{
		"phone": "+998900000070", "full_name": "Азиз", "role_id": dRole, "store_ids": []string{shop.store},
	}), 201, "courier").str("id")
	a.expect(a.do("PUT", "/store/couriers/"+courier+"/login", ownerTok, map[string]any{"login": "aziz", "password": "secret-123"}), 200, "courier login")
	a.expect(request("+998900000070"), 200, "courier request")
	r = a.expect(confirm("+998900000070", "111111"), 200, "courier")
	if list(r, "deleted") != "" || list(r, "requested") != "courier" {
		t.Fatalf("courier = %v", r.Body)
	}
	reqs := a.expect(a.do("GET", "/admin/account-deletion-requests", adminTok, nil), 200, "requests").items()
	if len(reqs) != 2 || reqs[0]["source"] != "web" || reqs[1]["source"] != "web" {
		t.Fatalf("requests = %v", reqs)
	}

	// После 5 неверных кодов код сгорает.
	a.login("+998900000082", identity.AppClient)
	a.expect(request("+998900000082"), 200, "request 82")
	for i := range 5 {
		a.expect(confirm("+998900000082", "000000"), 400, fmt.Sprintf("wrong %d", i+1))
	}
	a.expect(confirm("+998900000082", "111111"), 400, "burned")
}

// TestGuestBrowsing — приложение покупателя без входа (Apple 5.1.1): главная,
// магазины рядом, витрина магазина, каталог, карточка товара, поиск и слоты
// доступны без токена; личное — только со входом.
func TestGuestBrowsing(t *testing.T) {
	pool := freshDB(t)
	a := newAPI(t, paymeConfig(), pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	shop := newAdminShop(t, a, adminTok, "+998900000002", "+998901234567")

	const at = "lat=41.2995&lng=69.2401"
	public := []string{
		"/client/config",
		"/client/home?" + at,
		"/client/stores/nearby?" + at,
		"/client/stores/" + shop.store + "/home",
		"/client/stores/" + shop.store + "/categories",
		"/client/stores/" + shop.store + "/products",
		"/client/stores/" + shop.store + "/products?q=coca&sort=price_asc",
		"/client/stores/" + shop.store + "/products/" + shop.cola,
		"/client/stores/" + shop.store + "/products/" + shop.cola + "/related",
		"/client/stores/" + shop.store + "/slots",
		"/client/search?q=coca&" + at,
	}
	for _, path := range public {
		// Без токена, с негодным токеном и с токеном покупателя — одинаково.
		for _, tok := range []string{"", "garbage", shop.client} {
			a.expect(a.do("GET", path, tok, nil), 200, path+" token="+tok[:min(len(tok), 7)])
		}
	}
	if items := a.expect(a.do("GET", "/client/stores/"+shop.store+"/products", "", nil), 200, "catalog").items(); len(items) != 1 || items[0]["id"] != shop.cola {
		t.Fatalf("catalog = %v", items)
	}
	if near := a.expect(a.do("GET", "/client/stores/nearby?"+at, "", nil), 200, "nearby").items(); len(near) != 1 {
		t.Fatalf("nearby = %v", near)
	}
	a.expect(a.do("POST", "/client/home/events", "", map[string]any{"store_id": shop.store, "items": []map[string]any{}}), 204, "events")

	for _, path := range []string{
		"/client/me", "/client/me/stats", "/client/favorites", "/client/addresses", "/client/orders",
		"/client/notifications", "/client/notifications/unread", "/client/debts", "/client/family", "/client/wishes",
	} {
		a.expect(a.do("GET", path, "", nil), 401, path+" without token")
	}
	a.expect(a.do("POST", "/client/checkout/preview", "", map[string]any{}), 401, "preview without token")
	a.expect(a.do("POST", "/client/orders", "", map[string]any{}), 401, "order without token")
	a.expect(a.do("POST", "/client/favorites", "", map[string]any{"product_id": shop.cola}), 401, "favorite without token")
}

// TestPromoConsent — рекламные push у нового покупателя выключены (Apple
// 4.5.4); включение — явное согласие с отметкой времени.
func TestPromoConsent(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	tok, _ := a.login("+998900000050", identity.AppClient)

	notif := func(r resp) map[string]any { return r.Body["notifications"].(map[string]any) }
	me := a.expect(a.do("GET", "/client/me", tok, nil), 200, "me")
	if n := notif(me); n["promos"] != false || n["orders"] != true || n["promos_consent_at"] != nil {
		t.Fatalf("new client = %v", n)
	}
	on := notif(a.expect(a.do("PATCH", "/client/me", tok, map[string]any{"notifications": map[string]any{"promos": true}}), 200, "consent"))
	if on["promos"] != true || on["promos_consent_at"] == nil {
		t.Fatalf("consent = %v", on)
	}
	same := notif(a.expect(a.do("PATCH", "/client/me", tok, map[string]any{"notifications": map[string]any{"orders": false}}), 200, "orders off"))
	if same["promos"] != true || same["promos_consent_at"] != on["promos_consent_at"] || same["orders"] != false {
		t.Fatalf("orders off = %v", same)
	}
	again := notif(a.expect(a.do("PATCH", "/client/me", tok, map[string]any{"notifications": map[string]any{"promos": true}}), 200, "consent again"))
	if again["promos_consent_at"] != on["promos_consent_at"] {
		t.Fatalf("повторное согласие сдвинуло время: %v", again)
	}
	off := notif(a.expect(a.do("PATCH", "/client/me", tok, map[string]any{"notifications": map[string]any{"promos": false}}), 200, "opt out"))
	if off["promos"] != false || off["promos_consent_at"] != nil {
		t.Fatalf("opt out = %v", off)
	}
}
