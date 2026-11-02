package server_test

import (
	"context"
	"testing"
	"time"

	"github.com/sanedidi/super-market/backend/internal/finance"
	"github.com/sanedidi/super-market/backend/internal/identity"
)

// TestCashHandover — касса не копит деньги (Figma «SM Магазин · Касса: норма
// размена, «К сдаче» → «Принято», разовый пересчёт ящика», М1–М6, и «Касса ·
// «Закрыть день» оставляет размен по норме…», ЗД6–ЗД7): норму размена и
// пересчёт магазин задаёт сам; без нормы в ящике остаётся всё, с нормой —
// остальное «К сдаче»; «Принял» и «Принял всё»; разовый пересчёт ящика.
func TestCashHandover(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")

	dev := a.expect(a.do("POST", "/store/pos/devices", tok, map[string]any{"store_id": store, "name": "Касса 1"}), 201, "device")
	dt := a.expect(a.do("POST", "/pos/activate", "", map[string]any{"code": dev.str("activation_code"), "app_version": "0.4.9"}), 200, "activate").str("token")
	role := a.expect(a.do("POST", "/store/roles", tok, map[string]any{"name": "Кассир", "permissions": []string{identity.PermSalesPOS}}), 201, "role").str("id")
	cashier := a.expect(a.do("POST", "/store/employees", tok, map[string]any{
		"phone": "+998900000006", "full_name": "Кассир", "role_id": role, "store_ids": []string{store},
	}), 201, "cashier").str("id")
	a.expect(a.do("PUT", "/store/pos/pins/"+cashier, tok, map[string]any{"pin": "1234"}), 200, "pin")

	shiftNo := 0
	// day — смена: размен opening, наличных за день cash (внесение), закрыть с body.
	day := func(opening, cash int, close map[string]any) map[string]any {
		t.Helper()
		shiftNo++
		uid := "handover-shift-" + string(rune('a'+shiftNo))
		id := a.expect(posDo(a, "POST", "/pos/shifts", dt, cashier, map[string]any{"client_uid": uid + "-000", "opening_cash": opening}), 201, "open").str("id")
		if cash > 0 {
			a.expect(posDo(a, "POST", "/pos/shifts/"+id+"/cash-moves", dt, cashier, map[string]any{
				"client_uid": uid + "-mov", "kind": "in", "amount": cash, "reason": "Выручка"}), 200, "cash in")
		}
		if close == nil {
			return map[string]any{"id": id}
		}
		return a.expect(posDo(a, "POST", "/pos/shifts/"+id+"/close", dt, cashier, close), 200, "close").Body
	}
	left := func() any {
		t.Helper()
		return a.expect(posDo(a, "GET", "/pos/shifts/current", dt, cashier, nil), 200, "current").Body["left_in_drawer"]
	}
	drawer := func() map[string]any {
		t.Helper()
		return a.expect(a.do("GET", "/store/pos/drawer?store_id="+store, tok, nil), 200, "drawer").Body
	}

	// Значений по умолчанию нет: норма и пересчёт не заданы, напоминание включено.
	cs := a.expect(a.do("GET", "/store/pos/cash-settings?store_id="+store, tok, nil), 200, "cash settings")
	if cs.Body["cash_float"] != nil || cs.Body["recount_every_days"] != nil || cs.Body["handover_remind"] != true {
		t.Fatalf("cash settings = %v", cs.Body)
	}
	// Без нормы — как раньше: «К сдаче» нет, в ящике остаётся всё.
	if c := day(100000, 400000, map[string]any{}); c["to_hand"] != nil {
		t.Fatalf("без нормы отложено: %v", c)
	}
	if d := drawer(); d["pending_count"].(float64) != 0 || d["cash_float"] != nil {
		t.Fatalf("drawer без нормы = %v", d)
	}

	// Магазин задал норму 50 000 и пересчёт раз в 7 дней — касса видит в каталоге.
	a.expect(a.do("PUT", "/store/pos/cash-settings", tok, map[string]any{"store_id": store, "cash_float": 50000, "recount_every_days": 7}), 200, "save cash settings")
	a.expect(a.do("PUT", "/store/pos/cash-settings", tok, map[string]any{"store_id": store, "cash_float": 50000, "recount_every_days": 3}), 400, "recount 3")
	set := a.expect(posDo(a, "GET", "/pos/catalog", dt, "", nil), 200, "catalog").Body["settings"].(map[string]any)
	if set["cash_float"] != "50000.00" || set["recount_every_days"].(float64) != 7 {
		t.Fatalf("catalog settings = %v", set)
	}

	// «Закрыть день» без пересчёта: 50 000 в ящике, остальное «К сдаче».
	c2 := day(500000, 300000, map[string]any{})
	if c2["to_hand"] != "750000.00" {
		t.Fatalf("to_hand = %v", c2)
	}
	if l := left(); l != "50000" {
		t.Fatalf("left_in_drawer = %v", l)
	}
	if d := drawer(); d["amount"] != "50000.00" || d["pending_total"] != "750000.00" || d["pending_count"].(float64) != 1 {
		t.Fatalf("drawer = %v", d)
	}
	// Кассир поменял размен на этот раз (F3) и пересчитал ящик.
	c3 := day(50000, 200000, map[string]any{"counted_cash": 240000, "leave": 20000})
	if c3["to_hand"] != "220000.00" || c3["diff"] != "-10000.00" {
		t.Fatalf("leave close = %v", c3)
	}
	if l := left(); l != "20000" {
		t.Fatalf("left after leave = %v", l)
	}

	// «Ожидает сдачи»: два конверта, старый первым.
	pend := a.expect(a.do("GET", "/store/finance/pending-handovers?store_id="+store+"&status=pending", tok, nil), 200, "pending").items()
	if len(pend) != 2 || pend[0]["amount"] != "750000.00" || pend[1]["amount"] != "220000.00" || pend[0]["left_amount"] != "50000.00" {
		t.Fatalf("pending = %v", pend)
	}
	// Получил меньше — недостача смены, сдача в главную кассу.
	acc := a.expect(a.do("POST", "/store/finance/pending-handovers/"+pend[0]["id"].(string)+"/accept", tok, map[string]any{"received": 740000}), 200, "accept")
	if acc.Body["received"] != "740000.00" || acc.Body["shortage"] != "10000.00" || acc.Body["accepted_at"] == nil || acc.Body["transfer_id"] == nil {
		t.Fatalf("accept = %v", acc.Body)
	}
	// Повтор безопасен.
	a.expect(a.do("POST", "/store/finance/pending-handovers/"+pend[0]["id"].(string)+"/accept", tok, map[string]any{"received": 1}), 200, "accept again")
	all := a.expect(a.do("POST", "/store/finance/pending-handovers/accept-all", tok, map[string]any{"store_id": store}), 200, "accept all").items()
	if len(all) != 1 || all[0]["received"] != "220000.00" || all[0]["shortage"] != "0.00" {
		t.Fatalf("accept all = %v", all)
	}
	if d := drawer(); d["pending_count"].(float64) != 0 || d["amount"] != "20000.00" {
		t.Fatalf("drawer after accept = %v", d)
	}
	accepted := a.expect(a.do("GET", "/store/finance/pending-handovers?store_id="+store+"&status=accepted", tok, nil), 200, "accepted").items()
	if len(accepted) != 2 {
		t.Fatalf("accepted = %v", accepted)
	}
	var main string
	for _, b := range a.expect(a.do("GET", "/store/finance/cashboxes", tok, nil), 200, "boxes").items() {
		if b["is_main"] == true {
			main = b["balance"].(string)
		}
	}
	if main != "960000.00" {
		t.Fatalf("главная касса = %v", main)
	}

	// Деньги накопились (размен 900 000 при норме 50 000) — предупреждение и
	// разовый пересчёт: «забирал я» — сдача в главную кассу, X-отчёт сходится.
	open := day(900000, 0, nil)
	if d := drawer(); d["float_warning"] != true {
		t.Fatalf("float warning = %v", d)
	}
	rc := a.expect(a.do("POST", "/store/finance/drawer/recount", tok, map[string]any{"store_id": store, "counted": 100000, "kind": "taken"}), 200, "recount")
	if rc.Body["before"] != "900000.00" || rc.Body["diff"] != "800000.00" || rc.Body["transfer_id"] == nil {
		t.Fatalf("recount = %v", rc.Body)
	}
	sh := a.expect(a.do("GET", "/store/pos/shifts/"+open["id"].(string), tok, nil), 200, "shift")
	if sh.Body["report"].(map[string]any)["expected_cash"] != "100000.00" {
		t.Fatalf("x-report = %v", sh.Body["report"])
	}
	if d := drawer(); d["amount"] != "100000.00" || d["float_warning"] != false {
		t.Fatalf("drawer after recount = %v", d)
	}
	a.expect(posDo(a, "POST", "/pos/shifts/"+open["id"].(string)+"/close", dt, cashier, map[string]any{}), 200, "close 4")
	// Без смены: посчитали меньше — недостача.
	rc2 := a.expect(a.do("POST", "/store/finance/drawer/recount", tok, map[string]any{"store_id": store, "counted": 40000, "kind": "shortage"}), 200, "recount 2")
	if rc2.Body["before"] != "50000.00" || rc2.Body["diff"] != "10000.00" || rc2.Body["transfer_id"] != nil {
		t.Fatalf("recount 2 = %v", rc2.Body)
	}
	if l := left(); l != "40000" {
		t.Fatalf("left after recount = %v", l)
	}
	a.expect(a.do("POST", "/store/finance/drawer/recount", tok, map[string]any{"store_id": store, "counted": 1, "kind": "lost"}), 400, "bad kind")

	// Напоминание: после 21:00 раз в день.
	ctx := context.Background()
	evening := time.Date(2026, 11, 2, 16, 30, 0, 0, time.UTC) // 21:30 в Ташкенте
	if n, err := finance.RemindHandovers(ctx, pool, evening.Add(-2*time.Hour)); err != nil || n != 0 {
		t.Fatalf("до 21:00: %d %v", n, err)
	}
	if n, err := finance.RemindHandovers(ctx, pool, evening); err != nil || n != 1 {
		t.Fatalf("remind: %d %v", n, err)
	}
	if n, err := finance.RemindHandovers(ctx, pool, evening.Add(time.Hour)); err != nil || n != 0 {
		t.Fatalf("remind again: %d %v", n, err)
	}
	// Магазин убрал норму — дальше в ящике остаётся всё.
	a.expect(a.do("PUT", "/store/pos/cash-settings", tok, map[string]any{"store_id": store, "cash_float": nil, "recount_every_days": nil, "handover_remind": false}), 200, "clear")
	if c := day(40000, 10000, map[string]any{}); c["to_hand"] != nil {
		t.Fatalf("норму убрали, а отложено: %v", c)
	}
}
