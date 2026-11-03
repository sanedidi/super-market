package server_test

import (
	"testing"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/pos"
)

// Весы магазина и отправка товаров в весы (Figma «Панель магазина · Весы:
// отправка товаров в весы (любой бренд)», Н1–Н5).
func TestScaleDevices(t *testing.T) {
	pool := freshDB(t)
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	a := newAPI(t, cfg, pool, nil)
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	_, sugar := catalogBasics(t, a, adminTok)
	tok, store := setupNetwork(t, a, adminTok, "+998900000002")
	sugarP := a.expect(a.do("GET", "/admin/products/"+sugar, adminTok, nil), 200, "sugar")
	kg, cat := sugarP.str("unit_id"), sugarP.str("category_id")
	persimmon := a.expect(a.do("POST", "/store/products", tok, map[string]any{
		"name": "Хурма «Шарон»", "category_id": cat, "unit_id": kg, "base_price": 22000,
	}), 201, "own persimmon").str("id")
	a.expect(a.do("PUT", "/store/scales/settings", tok, map[string]any{
		"enabled": true, "prefix": "27", "item_digits": 5, "value": "weight", "weight_step": 1, "name_lang": "ru",
	}), 200, "scale settings")
	a.expect(a.do("PUT", "/store/products/"+sugar+"/sell-mode", tok, map[string]any{"mode": "weight", "plu": 1}), 200, "sugar plu")
	a.expect(a.do("PUT", "/store/products/"+persimmon+"/sell-mode", tok, map[string]any{"mode": "weight", "plu": 99}), 200, "persimmon plu")

	dev := a.expect(a.do("POST", "/store/pos/devices", tok, map[string]any{"store_id": store, "name": "Касса 1"}), 201, "device")
	posTok := a.expect(a.do("POST", "/pos/activate", "", map[string]any{"code": dev.str("activation_code")}), 200, "activate").str("token")

	// Н2: весы с драйвером — нужен IP; касса — этого магазина.
	a.expect(a.do("POST", "/store/scales/devices", tok, map[string]any{
		"store_id": store, "name": "Весы у фруктов", "brand": "rongta", "host": "весы",
	}), 400, "direct scale needs IP")
	a.expect(a.do("POST", "/store/scales/devices", tok, map[string]any{
		"store_id": store, "name": "Весы", "brand": "acme", "host": "192.168.1.80",
	}), 400, "unknown brand")
	rongta := a.expect(a.do("POST", "/store/scales/devices", tok, map[string]any{
		"store_id": store, "name": "Весы у фруктов", "brand": "rongta", "model": "RLS1000C", "host": "192.168.1.80", "device_id": dev.str("id"),
	}), 201, "rongta scale")
	if rongta.Body["port"].(float64) != 4001 || rongta.Body["direct"] != true || rongta.Body["to_send"].(float64) != 2 {
		t.Fatalf("rongta scale = %v", rongta.Body)
	}
	rid := rongta.str("id")

	// Весы в списке — «На весах» считает по ним: пока ни в одних — «новый».
	list := a.expect(a.do("GET", "/store/scales/products?store_id="+store, tok, nil), 200, "scale products")
	for _, it := range list.items() {
		if it["status"] != "new" {
			t.Fatalf("before send %v = %v", it["name"], it["status"])
		}
	}

	// Н3: отправить изменённые — задание кассе на 2 товара.
	jobs := a.expect(a.do("POST", "/store/scales/send", tok, map[string]any{"store_id": store, "scale_ids": []string{rid}}), 200, "send").items()
	if len(jobs) != 1 || jobs[0]["status"] != "pending" || jobs[0]["total"].(float64) != 2 {
		t.Fatalf("send jobs = %v", jobs)
	}
	jobID := jobs[0]["id"].(string)

	// Касса забирает задание: весы, адрес, товары латиницей и целыми сумами.
	taken := a.expect(posDo(a, "GET", "/pos/scales/jobs", posTok, "", nil), 200, "take jobs").items()
	if len(taken) != 1 || taken[0]["id"] != jobID {
		t.Fatalf("taken = %v", taken)
	}
	sc := taken[0]["scale"].(map[string]any)
	if sc["host"] != "192.168.1.80" || sc["port"].(float64) != 4001 || sc["brand"] != "rongta" {
		t.Fatalf("job scale = %v", sc)
	}
	items := taken[0]["items"].([]any)
	if len(items) != 2 {
		t.Fatalf("job items = %v", items)
	}
	p99 := items[1].(map[string]any)
	if p99["plu"].(float64) != 99 || p99["name"] != `Xurma "Sharon"` || p99["price"].(float64) != 22000 || p99["unit"] != "kg" {
		t.Fatalf("persimmon in job = %v", p99)
	}
	// Взятое задание вторая касса (и повтор) не получает, пока первая работает.
	if again := a.expect(posDo(a, "GET", "/pos/scales/jobs", posTok, "", nil), 200, "take again").items(); len(again) != 1 {
		t.Fatalf("same device retakes its running job, got %v", again)
	}

	// Итог: сахар принят, хурму весы не приняли.
	a.expect(posDo(a, "POST", "/pos/scales/jobs/"+jobID, posTok, "", map[string]any{
		"done_ids": []string{sugar},
		"failures": []map[string]any{{"product_id": persimmon, "plu": 99, "name": "Xurma", "error": "весы не ответили"}},
	}), 200, "job result")
	done := a.expect(a.do("GET", "/store/scales/jobs?store_id="+store+"&ids="+jobID, tok, nil), 200, "job status").items()[0]
	if done["status"] != "done" || done["sent"].(float64) != 1 || len(done["failures"].([]any)) != 1 {
		t.Fatalf("job done = %v", done)
	}
	list = a.expect(a.do("GET", "/store/scales/products?store_id="+store, tok, nil), 200, "after send")
	st := map[string]string{}
	for _, it := range list.items() {
		st[it["product_id"].(string)] = it["status"].(string)
	}
	if st[sugar] != "entered" || st[persimmon] != "new" {
		t.Fatalf("statuses after send = %v", st)
	}
	scales := a.expect(a.do("GET", "/store/scales/devices?store_id="+store, tok, nil), 200, "scales").items()
	if scales[0]["to_send"].(float64) != 1 || scales[0]["items"].(float64) != 1 || scales[0]["check_ok"] != true {
		t.Fatalf("scale after send = %v", scales[0])
	}

	// Цена сахара поменялась — «изменён», в следующей отправке только он и хурма.
	a.expect(a.do("POST", "/store/scales/send", tok, map[string]any{"store_id": store, "scale_ids": []string{rid}, "mode": "all"}), 200, "send all")
	all := a.expect(posDo(a, "GET", "/pos/scales/jobs", posTok, "", nil), 200, "take all").items()
	if len(all) != 1 || len(all[0]["items"].([]any)) != 2 {
		t.Fatalf("all mode = %v", all)
	}

	// Весы через файл: отправлять нельзя — файл и «Загружено в весы».
	cas := a.expect(a.do("POST", "/store/scales/devices", tok, map[string]any{
		"store_id": store, "name": "Весы на мясном", "brand": "cas", "model": "CL5000",
	}), 201, "cas scale")
	a.expect(a.do("POST", "/store/scales/send", tok, map[string]any{"store_id": store, "scale_ids": []string{cas.str("id")}}), 409, "file scale is not sent")
	file := a.expect(a.do("GET", "/store/scales/devices/"+cas.str("id")+"/file?mode=all", tok, nil), 200, "file").items()
	if len(file) != 2 || file[0]["code"] != "00001" || file[1]["name"] != "Хурма «Шарон»" {
		t.Fatalf("file rows = %v", file)
	}
	a.expect(a.do("POST", "/store/scales/devices/"+cas.str("id")+"/loaded", tok, map[string]any{"product_ids": []string{sugar}}), 200, "loaded")
	list = a.expect(a.do("GET", "/store/scales/products?store_id="+store, tok, nil), 200, "after file")
	for _, it := range list.items() {
		if it["product_id"] == sugar && it["status"] != "entered" {
			t.Fatalf("sugar in both scales = %v", it)
		}
	}

	// Проверка связи: касса не достучалась — весы «нет связи».
	chk := a.expect(a.do("POST", "/store/scales/devices/"+rid+"/check", tok, nil), 200, "check")
	a.expect(posDo(a, "POST", "/pos/scales/jobs/"+all[0]["id"].(string), posTok, "", map[string]any{"done_ids": []string{}, "error": "нет связи"}), 200, "all failed")
	took := a.expect(posDo(a, "GET", "/pos/scales/jobs", posTok, "", nil), 200, "take check").items()
	if len(took) != 1 || took[0]["kind"] != "check" || took[0]["id"] != chk.str("id") {
		t.Fatalf("check job = %v", took)
	}
	a.expect(posDo(a, "POST", "/pos/scales/jobs/"+chk.str("id"), posTok, "", map[string]any{"error": "весы не отвечают"}), 200, "check failed")
	scales = a.expect(a.do("GET", "/store/scales/devices?store_id="+store, tok, nil), 200, "scales after check").items()
	if scales[0]["check_ok"] != false || scales[0]["check_error"] != "весы не отвечают" {
		t.Fatalf("scale after check = %v", scales[0])
	}

	a.expect(a.do("DELETE", "/store/scales/devices/"+cas.str("id"), tok, nil), 200, "delete scale")
	if n := len(a.expect(a.do("GET", "/store/scales/devices?store_id="+store, tok, nil), 200, "after delete").items()); n != 1 {
		t.Fatalf("scales after delete = %d", n)
	}
}

func TestScaleName(t *testing.T) {
	for in, want := range map[string]string{
		"Хурма «Шарон» 1 кг": `Xurma "Sharon" 1 kg`,
		"Oʻrik  quritilgan":  "O'rik quritilgan",
		"Қовун Ғаллаорол":    "Qovun G'allaorol",
		"Колбаса варёная «Докторская» высший сорт ГОСТ": `Kolbasa varyonaya "Doktorskaya"`,
	} {
		if got := pos.ScaleName(in); got != want {
			t.Errorf("ScaleName(%q) = %q, want %q", in, got, want)
		}
	}
}
