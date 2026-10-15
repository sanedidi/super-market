package server_test

import (
	"context"
	"encoding/hex"
	"testing"
	"time"

	"github.com/sanedidi/super-market/backend/internal/debts"
	"github.com/sanedidi/super-market/backend/internal/identity"
)

// TestDebtsQR — продажа в долг по QR покупателя: приложение получает секрет,
// касса находит покупателя по QR (без номера и кода), устаревший или чужой QR —
// ошибка, номер QR есть в каталоге кассы, экран QR видит «Записано в долг».
func TestDebtsQR(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	ctx := context.Background()
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	cola, _ := catalogBasics(t, a, adminTok)
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	wh := a.expect(a.do("GET", "/store/warehouses?store_id="+store, tok, nil), 200, "wh").items()[0]["id"].(string)
	doc := a.expect(a.do("POST", "/store/inventory/documents", tok, map[string]any{
		"type": "posting", "warehouse_id": wh, "items": []map[string]any{{"product_id": cola, "qty": 20, "price": 10000}},
	}), 201, "posting")
	a.expect(a.do("POST", "/store/inventory/documents/"+doc.str("id")+"/post", tok, nil), 200, "post")
	a.expect(a.do("PUT", "/store/debt-settings/stores/"+store, tok, map[string]any{"debt_enabled": true}), 200, "enable")

	dev := a.expect(a.do("POST", "/store/pos/devices", tok, map[string]any{"store_id": store, "name": "Касса 1"}), 201, "device")
	dt := a.expect(a.do("POST", "/pos/activate", "", map[string]any{"code": dev.str("activation_code")}), 200, "activate").str("token")
	role := a.expect(a.do("POST", "/store/roles", tok, map[string]any{
		"name": "Кассир", "permissions": []string{identity.PermSalesPOS, identity.PermDebtsGive},
	}), 201, "role").str("id")
	cashier := a.expect(a.do("POST", "/store/employees", tok, map[string]any{
		"phone": "+998900000006", "full_name": "Дилноза", "role_id": role, "store_ids": []string{store},
	}), 201, "cashier").str("id")
	a.expect(a.do("PUT", "/store/pos/pins/"+cashier, tok, map[string]any{"pin": "1234"}), 200, "pin")
	// Кассир без права «в долг» QR не проверяет.
	role2 := a.expect(a.do("POST", "/store/roles", tok, map[string]any{
		"name": "Стажёр", "permissions": []string{identity.PermSalesPOS},
	}), 201, "role2").str("id")
	intern := a.expect(a.do("POST", "/store/employees", tok, map[string]any{
		"phone": "+998900000007", "full_name": "Стажёр", "role_id": role2, "store_ids": []string{store},
	}), 201, "intern").str("id")
	a.expect(a.do("PUT", "/store/pos/pins/"+intern, tok, map[string]any{"pin": "4321"}), 200, "pin2")

	var cash string
	for _, x := range a.expect(posDo(a, "GET", "/pos/catalog", dt, "", nil), 200, "catalog").Body["payment_methods"].([]any) {
		if m := x.(map[string]any); m["kind"] == "cash" {
			cash = m["id"].(string)
		}
	}
	shift := a.expect(posDo(a, "POST", "/pos/shifts", dt, cashier, map[string]any{"client_uid": "shift-qr-01", "opening_cash": 0}), 201, "shift").str("id")

	// Покупатель: «Мой QR-код». Повторный запрос — тот же секрет.
	const buyer = "+998905764723"
	clientTok, _ := a.login(buyer, identity.AppClient)
	a.expect(a.do("PATCH", "/client/me", clientTok, map[string]any{"first_name": "Шахзод", "last_name": "Анваров"}), 200, "name")
	q := a.expect(a.do("GET", "/client/qr", clientTok, nil), 200, "my qr")
	if len(q.str("qr_id")) != 10 || len(q.str("secret")) != 64 || q.str("prefix") != "99" || q.Body["step"].(float64) != 30 || q.Body["digits"].(float64) != 8 {
		t.Fatalf("qr = %v", q.Body)
	}
	if again := a.expect(a.do("GET", "/client/qr", clientTok, nil), 200, "my qr again"); again.str("secret") != q.str("secret") || again.str("qr_id") != q.str("qr_id") {
		t.Fatal("qr secret changed")
	}
	a.expect(a.do("GET", "/client/qr", "", nil), 401, "qr guest")
	secret, err := hex.DecodeString(q.str("secret"))
	if err != nil {
		t.Fatal(err)
	}
	qrID := q.str("qr_id")
	payload := debts.QRPayload(qrID, secret, time.Now())

	// Не QR покупателя, чужой номер QR, устаревший код, нет права.
	a.expect(posDo(a, "GET", "/pos/debtors/qr?code=4601234567893", dt, cashier, nil), 400, "barcode")
	a.expect(posDo(a, "GET", "/pos/debtors/qr?code=99"+"1000000000"+payload[12:], dt, cashier, nil), 400, "unknown qr id")
	old := a.expect(posDo(a, "GET", "/pos/debtors/qr?code="+debts.QRPayload(qrID, secret, time.Now().Add(-5*time.Minute)), dt, cashier, nil), 400, "old qr")
	if old.Body["error"].(map[string]any)["code"] != "qr_expired" {
		t.Fatalf("old qr = %v", old.Body)
	}
	a.expect(posDo(a, "GET", "/pos/debtors/qr?code="+payload, dt, intern, nil), 403, "no debts.give")

	// Скан QR: покупатель сразу подтверждён, лимит по умолчанию, имя из профиля.
	look := a.expect(posDo(a, "GET", "/pos/debtors/qr?code="+payload, dt, cashier, nil), 200, "qr lookup")
	d := look.Body["debtor"].(map[string]any)
	if look.Body["found"] != true || look.str("phone") != buyer || look.str("qr_id") != qrID ||
		d["verified"] != true || d["limit"] != "500000.00" || d["full_name"] != "Шахзод Анваров" {
		t.Fatalf("qr lookup = %v", look.Body)
	}
	// Тот же QR ещё раз в течение шага — касса могла пересканировать.
	a.expect(posDo(a, "GET", "/pos/debtors/qr?code="+payload, dt, cashier, nil), 200, "qr rescan")

	// Касса без связи найдёт покупателя по номеру QR в каталоге.
	found := false
	for _, x := range a.expect(posDo(a, "GET", "/pos/catalog", dt, "", nil), 200, "catalog 2").Body["debtors"].([]any) {
		if m := x.(map[string]any); m["phone"] == buyer && m["qr_id"] == qrID {
			found = true
		}
	}
	if !found {
		t.Fatal("qr_id not in pos catalog")
	}

	// Экран QR: до продажи — ничего, после — «Записано в долг».
	since := time.Now().Add(-time.Minute).UTC().Format(time.RFC3339)
	if r := a.expect(a.do("GET", "/client/qr/recent?since="+since, clientTok, nil), 200, "recent empty"); r.Body["entry"] != nil {
		t.Fatalf("recent before sale = %v", r.Body)
	}
	a.expect(a.do("GET", "/client/qr/recent?since=yesterday", clientTok, nil), 400, "recent bad since")
	a.expect(posDo(a, "POST", "/pos/sales", dt, cashier, map[string]any{
		"client_uid": "sale-qr-0001", "shift_id": shift, "items": []map[string]any{{"product_id": cola, "qty": 2}},
		"payments": []map[string]any{{"payment_method_id": cash, "amount": 5000}},
		"debt":     map[string]any{"phone": look.str("phone"), "amount": 25000},
	}), 201, "debt sale")
	rec := a.expect(a.do("GET", "/client/qr/recent?since="+since, clientTok, nil), 200, "recent")
	e, _ := rec.Body["entry"].(map[string]any)
	if e == nil || e["amount"] != "25000.00" || e["balance"] != "25000.00" || e["store_name"] != "Магазин 1" || e["due_date"] == nil || e["number"] == nil {
		t.Fatalf("recent = %v", rec.Body)
	}
	// «Это не я» прямо с экрана QR — по id записи.
	a.expect(a.do("POST", "/client/debts/entries/"+jsonStr(e["id"])+"/dispute", clientTok, map[string]any{"comment": "не я"}), 201, "dispute from qr")

	// Удалил аккаунт — старый QR больше не подходит.
	var userID string
	if err := pool.QueryRow(ctx, `SELECT id FROM users WHERE phone = $1`, buyer).Scan(&userID); err != nil {
		t.Fatal(err)
	}
	a.expect(a.do("DELETE", "/client/me", clientTok, nil), 204, "delete account")
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM client_qr WHERE user_id = $1`, userID).Scan(&n); err != nil || n != 0 {
		t.Fatalf("client_qr after delete: %d %v", n, err)
	}
	a.expect(posDo(a, "GET", "/pos/debtors/qr?code="+debts.QRPayload(qrID, secret, time.Now()), dt, cashier, nil), 400, "deleted account qr")
}

// TestQRCode — код QR совпадает с независимым расчётом (тот же вектор — в
// тестах приложения покупателя, чтобы касса и телефон считали одинаково).
func TestQRCode(t *testing.T) {
	secret, _ := hex.DecodeString("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
	// Посчитано независимо (Python: hmac/hashlib).
	for step, want := range map[int64]string{0: "94464393", 1: "04309558", 56_666_666: "62793923", 59_999_999: "86033075"} {
		if got := debts.QRCode(secret, step); got != want {
			t.Fatalf("step %d: %s, want %s", step, got, want)
		}
	}
	if got := debts.QRPayload("1234567890", secret, time.Unix(1_700_000_000, 0)); got != "99123456789062793923" {
		t.Fatalf("payload = %s", got)
	}
	for _, bad := range []string{"", "4601234567893", "98123456789012345678", "991234567890123456789", "99123456789O12345678"} {
		if _, _, ok := debts.ParseQR(bad); ok {
			t.Fatalf("ParseQR(%q) = ok", bad)
		}
	}
	if id, code, ok := debts.ParseQR(" 99123456789012345678\n"); !ok || id != "1234567890" || code != "12345678" {
		t.Fatalf("ParseQR = %s %s %v", id, code, ok)
	}
}
