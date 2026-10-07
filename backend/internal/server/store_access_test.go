package server_test

import (
	"slices"
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// employee создаёт роль с правами perms и сотрудника с доступом к магазинам
// storeIDs (nil — ко всем) и входит под ним.
func employee(t *testing.T, a api, ownerTok, phone, roleName string, perms, storeIDs []string) (tok, id string) {
	t.Helper()
	if perms == nil {
		perms = []string{}
	}
	role := a.expect(a.do("POST", "/store/roles", ownerTok, map[string]any{"name": roleName, "permissions": perms}),
		201, "role "+roleName)
	body := map[string]any{"phone": phone, "full_name": roleName + " " + phone, "role_id": role.str("id")}
	if storeIDs == nil {
		body["all_stores"] = true
	} else {
		body["store_ids"] = storeIDs
	}
	e := a.expect(a.do("POST", "/store/employees", ownerTok, body), 201, "employee "+phone)
	tok, _ = a.login(phone, identity.AppStore)
	return tok, e.str("id")
}

func storeIDsOf(r resp) []string {
	raw, _ := r.Body["store_ids"].([]any)
	out := make([]string, 0, len(raw))
	for _, x := range raw {
		out = append(out, x.(string))
	}
	slices.Sort(out)
	return out
}

// TestEmployeeStoresMerge — менеджер без доступа ко всем магазинам правит
// сотрудника: чужие магазины сотрудника сохраняются, назначить чужой
// магазин или «все магазины» нельзя; у владельца меняется только имя.
func TestEmployeeStoresMerge(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	owner, s1 := setupNetwork(t, a, adminTok, "+998900000002")
	s2 := a.expect(a.do("POST", "/store/stores", owner, map[string]any{"name": "Магазин 2"}), 201, "store 2").str("id")

	mgr, _ := employee(t, a, owner, "+998900000010", "Менеджер", []string{identity.PermStaffManage}, []string{s1})
	cashierRole := a.expect(a.do("POST", "/store/roles", owner, map[string]any{"name": "Кассир", "permissions": []string{}}), 201, "role").str("id")
	both := a.expect(a.do("POST", "/store/employees", owner, map[string]any{
		"phone": "+998900000011", "full_name": "Кассир двух магазинов", "role_id": cashierRole, "store_ids": []string{s1, s2},
	}), 201, "employee in both stores").str("id")

	want := []string{s1, s2}
	slices.Sort(want)

	// Менеджер видит только s1 и отправляет форму со своим магазином — s2 остаётся.
	r := a.expect(a.do("PATCH", "/store/employees/"+both, mgr, map[string]any{
		"full_name": "Кассир", "role_id": cashierRole, "all_stores": false, "store_ids": []string{s1},
	}), 200, "manager edits employee")
	if got := storeIDsOf(r); !slices.Equal(got, want) {
		t.Fatalf("store_ids after manager edit = %v, want %v", got, want)
	}
	// Снял свой магазин — чужой всё равно остаётся.
	r = a.expect(a.do("PATCH", "/store/employees/"+both, mgr, map[string]any{"store_ids": []string{}}), 200, "manager removes own store")
	if got := storeIDsOf(r); !slices.Equal(got, []string{s2}) {
		t.Fatalf("store_ids after removing own store = %v, want [%s]", got, s2)
	}
	// Повторная отправка уже назначенного чужого магазина не ошибка.
	a.expect(a.do("PATCH", "/store/employees/"+both, mgr, map[string]any{"store_ids": []string{s1, s2}}), 200, "resend foreign store")

	// Назначить магазин, к которому сам не имеешь доступа, или «все магазины» — нельзя.
	only1 := a.expect(a.do("POST", "/store/employees", mgr, map[string]any{
		"phone": "+998900000012", "full_name": "Новый кассир", "role_id": cashierRole, "store_ids": []string{s1},
	}), 201, "manager creates employee in own store").str("id")
	a.expect(a.do("PATCH", "/store/employees/"+only1, mgr, map[string]any{"store_ids": []string{s1, s2}}), 403, "grant foreign store")
	a.expect(a.do("PATCH", "/store/employees/"+only1, mgr, map[string]any{"all_stores": true}), 403, "grant all stores")
	a.expect(a.do("POST", "/store/employees", mgr, map[string]any{
		"phone": "+998900000013", "full_name": "Х", "role_id": cashierRole, "store_ids": []string{s2},
	}), 403, "create in foreign store")
	a.expect(a.do("POST", "/store/employees", mgr, map[string]any{
		"phone": "+998900000013", "full_name": "Х", "role_id": cashierRole, "all_stores": true,
	}), 403, "create with all stores")

	// Владелец сети: меняется только имя (так шлёт форма), остальное — 403.
	var ownerID string
	for _, e := range a.expect(a.do("GET", "/store/employees", owner, nil), 200, "employees").items() {
		if e["is_owner"] == true {
			ownerID = e["id"].(string)
		}
	}
	a.expect(a.do("PATCH", "/store/employees/"+ownerID, mgr, map[string]any{"full_name": "Владелец сети"}), 200, "rename owner")
	a.expect(a.do("PATCH", "/store/employees/"+ownerID, mgr, map[string]any{"full_name": "В", "all_stores": true}), 403, "owner stores")

	// Владелец видит всё и может переназначить магазины целиком.
	r = a.expect(a.do("PATCH", "/store/employees/"+both, owner, map[string]any{"store_ids": []string{s2}}), 200, "owner edit")
	if got := storeIDsOf(r); !slices.Equal(got, []string{s2}) {
		t.Fatalf("owner edit store_ids = %v", got)
	}
}

// TestStoreReadPermissions — разделы панели читаются только с правом на
// раздел; общие справочники и остатки (без себестоимости) видны всем.
func TestStoreReadPermissions(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	owner, s1 := setupNetwork(t, a, adminTok, "+998900000002")
	fake := "00000000-0000-0000-0000-000000000001"

	nobody, _ := employee(t, a, owner, "+998900000020", "Без прав", nil, []string{s1})

	open := []string{
		"/store/me", "/store/stores", "/store/warehouses?store_id=" + s1, "/store/products?store_id=" + s1,
		"/store/catalog/units", "/store/price-types", "/store/finance/payment-methods?store_id=" + s1,
		"/store/inventory/stock?store_id=" + s1,
	}
	for _, p := range open {
		a.expect(a.do("GET", p, nobody, nil), 200, "open "+p)
	}

	closed := map[string]string{
		"/store/permissions":                                 identity.PermStaffManage,
		"/store/roles":                                       identity.PermStaffManage,
		"/store/employees":                                   identity.PermStaffManage,
		"/store/price-documents":                             identity.PermPricesManage,
		"/store/price-documents/" + fake:                     identity.PermPricesManage,
		"/store/promotions":                                  identity.PermPricesManage,
		"/store/promotions/" + fake:                          identity.PermPricesManage,
		"/store/finance/rates":                               identity.PermFinanceManage,
		"/store/finance/counterparty-types":                  identity.PermCounterpartiesManage,
		"/store/finance/counterparties":                      identity.PermCounterpartiesManage,
		"/store/finance/counterparties/" + fake:              identity.PermCounterpartiesManage,
		"/store/finance/counterparties/" + fake + "/entries": identity.PermCounterpartiesManage,
		"/store/finance/reasons":                             identity.PermFinanceManage,
		"/store/finance/cashboxes":                           identity.PermFinanceManage,
		"/store/finance/cashboxes/" + fake + "/entries":      identity.PermFinanceManage,
		"/store/finance/operations":                          identity.PermFinanceManage,
		"/store/finance/transfers":                           identity.PermFinanceManage,
		"/store/finance/handovers":                           identity.PermFinanceManage,
		"/store/inventory/documents":                         identity.PermInventoryManage,
		"/store/inventory/documents/" + fake:                 identity.PermInventoryManage,
		"/store/sales":                                       identity.PermSalesPOS,
		"/store/sales/summary":                               identity.PermSalesPOS,
		"/store/sales/fiscal-control":                        identity.PermSalesPOS,
		"/store/sales/" + fake:                               identity.PermSalesPOS,
		"/store/sales/returns":                               identity.PermSalesPOS,
		"/store/sales/returns/" + fake:                       identity.PermSalesPOS,
		"/store/orders":                                      identity.PermOrdersManage,
		"/store/orders/" + fake:                              identity.PermOrdersManage,
		"/store/couriers":                                    identity.PermOrdersManage,
		"/store/stores/" + s1 + "/delivery":                  identity.PermStoresManage,
		"/store/stores/" + s1 + "/zones":                     identity.PermStoresManage,
		"/store/balance":                                     identity.PermPayoutsManage,
		"/store/balance/entries":                             identity.PermPayoutsManage,
		"/store/payouts":                                     identity.PermPayoutsManage,
		"/store/billing":                                     identity.PermPayoutsManage,
		"/store/billing/invoices":                            identity.PermPayoutsManage,
		"/store/reports/cash-flow":                           identity.PermReportsView,
		"/store/reports/profit-loss":                         identity.PermReportsView,
		"/store/reports/abc-xyz":                             identity.PermReportsView,
	}
	for p, perm := range closed {
		r := a.expect(a.do("GET", p, nobody, nil), 403, "closed "+p)
		if d, _ := r.Body["error"].(map[string]any)["details"].(map[string]any); d["permission"] != perm {
			t.Fatalf("%s: details = %v, want permission %s", p, d, perm)
		}
	}

	// Курьер работает через /courier/*, заказы магазина ему не видны.
	courier, _ := employee(t, a, owner, "+998900000021", "Курьер", []string{identity.PermOrdersDeliver}, []string{s1})
	a.expect(a.do("GET", "/store/orders?store_id="+s1, courier, nil), 403, "courier store orders")
	a.expect(a.do("GET", "/courier/me", courier, nil), 200, "courier me")

	// Кассир: продажи и возвраты — да, заказы и склад — нет.
	cashier, _ := employee(t, a, owner, "+998900000022", "Кассир", []string{identity.PermSalesPOS}, []string{s1})
	for _, p := range []string{"/store/sales?store_id=" + s1, "/store/sales/returns", "/store/sales/fiscal-control", "/store/sales/summary"} {
		a.expect(a.do("GET", p, cashier, nil), 200, "cashier "+p)
	}
	a.expect(a.do("GET", "/store/inventory/documents", cashier, nil), 403, "cashier docs")

	// Кладовщик видит контрагентов (поставщики в приходе) и курс, но не кассы.
	keeper, _ := employee(t, a, owner, "+998900000023", "Кладовщик", []string{identity.PermInventoryManage}, []string{s1})
	for _, p := range []string{"/store/finance/counterparties?q=x", "/store/finance/rates", "/store/inventory/documents", "/store/sales/summary"} {
		want := 200
		if p == "/store/sales/summary" {
			want = 403
		}
		a.expect(a.do("GET", p, keeper, nil), want, "keeper "+p)
	}
	a.expect(a.do("GET", "/store/finance/cashboxes", keeper, nil), 403, "keeper cashboxes")
}
