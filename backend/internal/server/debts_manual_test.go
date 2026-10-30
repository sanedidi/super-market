package server_test

import (
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// TestDebtsManual — «Добавить должника» в «SM Магазин»: старый долг по
// номеру, имени и сумме; номер уже есть — сумма прибавляется; лимит и
// стоп-лист не останавливают; запись видна в истории и в приложении
// покупателя, её можно оспорить.
func TestDebtsManual(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	const buyer = "+998934102207"

	// Новый номер: не найден; без имени не записать.
	look := a.expect(a.do("GET", "/store/debtors/lookup?store_id="+store+"&phone=93%20410%2022%2007", tok, nil), 200, "lookup new")
	if look.Body["found"] != false || look.Body["unverified_limit"] != "100000.00" {
		t.Fatalf("lookup new = %v", look.Body)
	}
	a.expect(a.do("POST", "/store/debtors", tok, map[string]any{"store_id": store, "phone": buyer, "amount": 50000}), 400, "no name")
	a.expect(a.do("POST", "/store/debtors", tok, map[string]any{"store_id": store, "phone": buyer, "full_name": "Бахром", "amount": 0}), 400, "zero")
	a.expect(a.do("POST", "/store/debtors", tok, map[string]any{"store_id": store, "phone": "123", "full_name": "Бахром", "amount": 1000}), 400, "bad phone")

	// «Даёт в долг» выключен — старый долг всё равно вносится.
	m1 := a.expect(a.do("POST", "/store/debtors", tok, map[string]any{
		"store_id": store, "phone": "93 410 22 07", "full_name": "Бахром ака, сосед", "amount": 80000, "note": "из тетради",
	}), 201, "manual new")
	if m1.Body["created"] != true || m1.str("balance") != "80000.00" || m1.Body["over_limit"] != false ||
		m1.str("full_name") != "Бахром ака, сосед" || m1.Body["number"].(float64) != 1 || m1.Body["due_date"] == nil {
		t.Fatalf("manual new = %v", m1.Body)
	}
	debtor := m1.str("debtor_id")

	// Номер уже есть: без имени, сумма прибавляется, имя прежнее; сверх лимита
	// неподтверждённого номера (100 000) — записывается с over_limit.
	m2 := a.expect(a.do("POST", "/store/debtors", tok, map[string]any{
		"store_id": store, "phone": buyer, "full_name": "Другое имя", "amount": 40000,
	}), 201, "manual existing")
	if m2.Body["created"] != false || m2.str("debtor_id") != debtor || m2.str("balance") != "120000.00" ||
		m2.Body["over_limit"] != true || m2.str("full_name") != "Бахром ака, сосед" {
		t.Fatalf("manual existing = %v", m2.Body)
	}
	look = a.expect(a.do("GET", "/store/debtors/lookup?store_id="+store+"&phone="+buyer, tok, nil), 200, "lookup found")
	if d, _ := look.Body["debtor"].(map[string]any); look.Body["found"] != true || d["amount"] != "120000.00" || d["full_name"] != "Бахром ака, сосед" {
		t.Fatalf("lookup found = %v", look.Body)
	}

	// Стоп-лист не останавливает — только помечает.
	a.expect(a.do("PATCH", "/store/debtors/"+debtor, tok, map[string]any{"blocked": true, "credit_limit": 1000000}), 200, "block")
	m3 := a.expect(a.do("POST", "/store/debtors", tok, map[string]any{"store_id": store, "phone": buyer, "amount": 5000}), 201, "manual blocked")
	if m3.Body["over_limit"] != true || m3.Body["blocked"] != true || m3.str("balance") != "125000.00" {
		t.Fatalf("manual blocked = %v", m3.Body)
	}

	// Список, итоги и история: «Внесён вручную» с комментарием, номером и кем внесён.
	list := a.expect(a.do("GET", "/store/debtors?store_id="+store, tok, nil), 200, "list").items()
	if len(list) != 1 || list[0]["amount"] != "125000.00" {
		t.Fatalf("list = %v", list)
	}
	if sum := a.expect(a.do("GET", "/store/debtors/summary?store_id="+store, tok, nil), 200, "summary"); sum.str("total") != "125000.00" {
		t.Fatalf("summary = %v", sum.Body)
	}
	card := a.expect(a.do("GET", "/store/debtors/"+debtor+"?store_id="+store, tok, nil), 200, "card")
	es := card.Body["entries"].([]any)
	last := es[len(es)-1].(map[string]any)
	if len(es) != 3 || last["doc_type"] != "manual" || last["detail"] != "из тетради" || last["number"].(float64) != 1 ||
		last["employee"] == "" || last["balance"] != "80000.00" {
		t.Fatalf("entries = %v", es)
	}

	// Покупатель видит запись в приложении и может её оспорить.
	clientTok, _ := a.login(buyer, identity.AppClient)
	hist := a.expect(a.do("GET", "/client/debts/"+store, clientTok, nil), 200, "client history")
	ce := hist.Body["entries"].([]any)
	if len(ce) != 3 || ce[0].(map[string]any)["doc_type"] != "manual" {
		t.Fatalf("client entries = %v", ce)
	}
	entry := jsonStr(ce[0].(map[string]any)["id"])
	a.expect(a.do("POST", "/client/debts/entries/"+entry+"/dispute", clientTok, map[string]any{"comment": "Я столько не брал"}), 201, "dispute manual")
	ds := a.expect(a.do("GET", "/store/debt-disputes?store_id="+store, tok, nil), 200, "disputes").items()
	if len(ds) != 1 || ds[0]["doc_type"] != "manual" || ds[0]["number"].(float64) != 3 || ds[0]["cashier"] == "" {
		t.Fatalf("disputes = %v", ds)
	}

	// Чужой магазин — отказ.
	a.expect(a.do("POST", "/store/debtors", tok, map[string]any{
		"store_id": "00000000-0000-0000-0000-000000000001", "phone": buyer, "amount": 1000,
	}), 400, "foreign store")
}
