package server_test

import (
	"context"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/sanedidi/super-market/backend/internal/field"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// TestFieldWalks — «SM Продажник» (Figma «SM Продажник · Обход с записью
// пути», П1–П7, и «Супер-админ · Продажники», С1–С3): вход по логину от
// супер-админа, обход с точками, обойдённые клетки навсегда, «Здесь уже
// прошёл …», белая зона, отметки магазинов с историей, заявка «Подключить»
// без начисления 50%, итог обхода, экран «Сейчас», маршрут за день,
// покрытие районов, блокировка, автопауза.
func TestFieldWalks(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	app, err := server.Build(ctx, cfg, pool, &fakeTelegram{}, quietLog())
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app.Handler)
	t.Cleanup(srv.Close)
	a := api{t: t, srv: srv, pool: pool}
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)

	// Район: квадрат ~1,1 × 0,85 км вокруг 41.360–41.370, 69.275–69.285.
	ds := a.expect(a.do("GET", "/admin/field/districts", adminTok, nil), 200, "districts")
	if len(ds.items()) != 12 {
		t.Fatalf("districts = %d", len(ds.items()))
	}
	var yunus string
	for _, d := range ds.items() {
		if d["name"] == "Юнусабад" {
			yunus = d["id"].(string)
		}
	}
	a.expect(a.do("PUT", "/admin/field/districts/"+yunus+"/boundary", adminTok, map[string]any{"boundary": [][2]float64{{41.36, 69.275}}}), 400, "too few points")
	a.expect(a.do("PUT", "/admin/field/districts/"+yunus+"/boundary", adminTok, map[string]any{"boundary": [][2]float64{{1, 1}, {1, 2}, {2, 2}}}), 400, "outside tashkent")
	d := a.expect(a.do("PUT", "/admin/field/districts/"+yunus+"/boundary", adminTok, map[string]any{
		"boundary": [][2]float64{{41.36, 69.275}, {41.37, 69.275}, {41.37, 69.285}, {41.36, 69.285}},
	}), 200, "boundary")
	total := d.Body["total_cells"].(float64)
	if total < 70 || total > 110 || d.Body["coverage_pct"].(float64) != 0 {
		t.Fatalf("district = %v", d.Body)
	}

	// Продажники.
	a.expect(a.do("POST", "/admin/field/reps", adminTok, map[string]any{"full_name": "Азиз", "phone": "901112233"}), 400, "no login")
	r1 := a.expect(a.do("POST", "/admin/field/reps", adminTok, map[string]any{
		"full_name": "Азиз Каримов", "phone": "+998901112233", "district_id": yunus, "login": "Aziz.K", "password": "secret-123",
	}), 201, "rep 1")
	if r1.str("login") != "aziz.k" || r1.str("district_name") != "Юнусабад" || r1.str("color") == "" {
		t.Fatalf("rep = %v", r1.Body)
	}
	a.expect(a.do("POST", "/admin/field/reps", adminTok, map[string]any{
		"full_name": "Другой", "phone": "+998901112299", "login": "aziz.k", "password": "secret-123",
	}), 409, "login taken")
	r2 := a.expect(a.do("POST", "/admin/field/reps", adminTok, map[string]any{
		"full_name": "Бахтиёр Юсупов", "phone": "+998901112244", "district_id": yunus, "login": "bahtiyor", "password": "secret-456",
	}), 201, "rep 2")

	// Вход.
	if r := a.expect(a.do("POST", "/auth/field/login", "", map[string]string{"login": "aziz.k", "password": "wrong-pass"}), 401, "bad password"); r.Body["error"].(map[string]any)["details"].(map[string]any)["attempts_left"].(float64) != 4 {
		t.Fatalf("attempts = %v", r.Body)
	}
	tok1 := a.expect(a.do("POST", "/auth/field/login", "", map[string]string{"login": " AZIZ.K ", "password": "secret-123"}), 200, "login 1").str("access_token")
	tok2 := a.expect(a.do("POST", "/auth/field/login", "", map[string]string{"login": "bahtiyor", "password": "secret-456"}), 200, "login 2").str("access_token")
	a.expect(a.do("GET", "/field/me", adminTok, nil), 403, "admin token in field app")
	a.expect(a.do("GET", "/admin/field/live", tok1, nil), 403, "field token in admin")

	me := a.expect(a.do("GET", "/field/me", tok1, nil), 200, "me")
	if me.Body["walk"] != nil || me.str("district", "name") != "Юнусабад" || me.Body["grid"].(map[string]any)["m"].(float64) != 100 {
		t.Fatalf("me = %v", me.Body)
	}

	// Обход 1: Азиз идёт на север по 69.280 (≈ 400 м).
	w1 := a.expect(a.do("POST", "/field/walks", tok1, map[string]any{"lat": 41.3605, "lng": 69.28}), 200, "start 1")
	w1ID := w1.str("id")
	if again := a.expect(a.do("POST", "/field/walks", tok1, nil), 200, "start again"); again.str("id") != w1ID {
		t.Fatalf("second start opened a new walk")
	}
	a.expect(a.do("POST", "/field/walks/"+w1ID+"/points", tok2, map[string]any{"points": []any{}}), 404, "someone else's walk")
	start := time.Now().Add(-50 * time.Second)
	var pts []map[string]any
	for i := 0; i < 40; i++ {
		pts = append(pts, map[string]any{"at": start.Add(time.Duration(i) * time.Second), "lat": 41.3605 + float64(i)*0.00009, "lng": 69.28, "accuracy": 8})
	}
	// Плохая точность, прыжок GPS и подделанная точка не считаются в путь.
	pts = append(pts,
		map[string]any{"at": start.Add(41 * time.Second), "lat": 41.3650, "lng": 69.28, "accuracy": 80},
		map[string]any{"at": start.Add(42 * time.Second), "lat": 41.40, "lng": 69.28, "accuracy": 5},
		map[string]any{"at": start.Add(43 * time.Second), "lat": 41.30, "lng": 69.20, "accuracy": 5, "mocked": true},
	)
	p1 := a.expect(a.do("POST", "/field/walks/"+w1ID+"/points", tok1, map[string]any{"points": pts}), 200, "points 1")
	walk := p1.Body["walk"].(map[string]any)
	if dist := walk["distance_m"].(float64); dist < 370 || dist > 420 {
		t.Fatalf("distance = %v", dist)
	}
	if p1.Body["accepted"].(float64) != 41 || walk["mock_points"].(float64) != 1 || walk["new_cells"].(float64) < 5 || walk["other_m"].(float64) != 0 {
		t.Fatalf("walk 1 = %v", p1.Body)
	}
	if p1.str("here", "state") != "new" {
		t.Fatalf("here = %v", p1.Body["here"])
	}
	// Повтор той же пачки — ничего не добавляется.
	if r := a.expect(a.do("POST", "/field/walks/"+w1ID+"/points", tok1, map[string]any{"points": pts[:5]}), 200, "repeat"); r.Body["accepted"].(float64) != 0 {
		t.Fatalf("repeat accepted = %v", r.Body["accepted"])
	}

	// Отказ: без фото витрины нельзя.
	visit := func(tok string, body map[string]any) resp { return a.do("POST", "/field/visits", tok, body) }
	a.expect(visit(tok1, map[string]any{"result": "refused", "lat": 41.3615, "lng": 69.2802, "reason": "expensive"}), 400, "refused without photo")
	a.expect(visit(tok1, map[string]any{"result": "refused", "lat": 41.3615, "lng": 69.2802, "photo_url": "https://x/p.jpg"}), 400, "refused without reason")
	pl := a.expect(visit(tok1, map[string]any{
		"result": "refused", "lat": 41.3615, "lng": 69.2802, "accuracy": 6, "name": "Baraka Market",
		"photo_url": "https://x/p.jpg", "reason": "has_program", "program": "billz", "comment": "до марта",
	}), 201, "refused")
	placeID := pl.str("id")
	if pl.str("result") != "refused" || pl.Body["mine"] != true || len(pl.Body["history"].([]any)) != 1 {
		t.Fatalf("place = %v", pl.Body)
	}
	a.expect(visit(tok1, map[string]any{"result": "later", "lat": 41.362, "lng": 69.2802, "remind_on": "2001-01-01"}), 400, "later in the past")
	a.expect(visit(tok1, map[string]any{"result": "ours", "lat": 41.362, "lng": 69.2802, "place_id": placeID + "x"}), 404, "bad place id")

	// Заявка «Подключить» от продажника — в «Заявки агентов», без начисления.
	leadPl := a.expect(visit(tok1, map[string]any{
		"result": "lead", "lat": 41.3630, "lng": 69.2805,
		"lead": map[string]any{"name": "Zamon Market", "owner_name": "Шерзод", "owner_phone": "90 777 66 55", "address": "Юнусабад-4"},
	}), 201, "lead")
	if leadPl.str("lead_status") != "pending" || leadPl.str("name") != "Zamon Market" {
		t.Fatalf("lead place = %v", leadPl.Body)
	}

	// Обход 2: Бахтиёр идёт по тому же пути — «Здесь уже прошёл Азиз».
	w2ID := a.expect(a.do("POST", "/field/walks", tok2, nil), 200, "start 2").str("id")
	start2 := time.Now().Add(-30 * time.Second)
	pts = nil
	for i := 0; i < 20; i++ {
		pts = append(pts, map[string]any{"at": start2.Add(time.Duration(i) * time.Second), "lat": 41.3605 + float64(i)*0.00009, "lng": 69.28, "accuracy": 8})
	}
	p2 := a.expect(a.do("POST", "/field/walks/"+w2ID+"/points", tok2, map[string]any{"points": pts}), 200, "points 2")
	if p2.str("here", "state") != "other" || p2.str("here", "rep_name") != "Азиз Каримов" || p2.Body["here"].(map[string]any)["places"].(float64) < 1 {
		t.Fatalf("here 2 = %v", p2.Body["here"])
	}
	w2 := p2.Body["walk"].(map[string]any)
	if w2["other_m"].(float64) < 100 || w2["new_cells"].(float64) != 0 {
		t.Fatalf("walk 2 = %v", w2)
	}
	// Ближайшая белая зона.
	hz := a.expect(a.do("GET", "/field/white-zone?lat=41.3622&lng=69.28", tok2, nil), 200, "white zone")
	h, _ := hz.Body["hint"].(map[string]any)
	if h == nil || h["distance_m"].(float64) <= 0 || h["direction"] == "" {
		t.Fatalf("hint = %v", hz.Body)
	}
	// Магазины Super Market на карте: активный — виден, склад дистрибьютора — нет.
	for _, q := range []string{
		`INSERT INTO networks (id, name, kind) VALUES ('11111111-0000-0000-0000-000000000001', 'Сеть на карте', 'single'), ('11111111-0000-0000-0000-000000000002', 'Дистрибьютор', 'distributor')`,
		`INSERT INTO stores (network_id, name, location) VALUES
		   ('11111111-0000-0000-0000-000000000001', 'Магазин SM', ST_SetSRID(ST_MakePoint(69.28, 41.36), 4326)::geography),
		   ('11111111-0000-0000-0000-000000000002', 'Склад', ST_SetSRID(ST_MakePoint(69.281, 41.361), 4326)::geography)`,
	} {
		if _, err := pool.Exec(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	// Карта: свои и чужие клетки, линии, магазины.
	mp := a.expect(a.do("GET", "/field/map?min_lat=41.355&min_lng=69.27&max_lat=41.37&max_lng=69.29", tok2, nil), 200, "map")
	cells := mp.Body["cells"].([]any)
	mine, other := 0, 0
	for _, c := range cells {
		if c.([]any)[2].(float64) == 1 {
			mine++
		} else {
			other++
		}
	}
	if mine == 0 || other == 0 || len(mp.Body["tracks"].([]any)) != 2 || len(mp.Body["places"].([]any)) != 2 {
		t.Fatalf("map: mine=%d other=%d tracks=%d places=%d", mine, other, len(mp.Body["tracks"].([]any)), len(mp.Body["places"].([]any)))
	}
	if st := mp.Body["stores"].([]any); len(st) != 1 || st[0].(map[string]any)["name"] != "Магазин SM" {
		t.Fatalf("map stores = %v", mp.Body["stores"])
	}
	// Вся область города (больше 8 км): магазины — во всей области, клетки — в середине.
	wide := a.expect(a.do("GET", "/admin/field/map?min_lat=41.1&min_lng=69.0&max_lat=41.5&max_lng=69.5", adminTok, nil), 200, "admin map wide")
	if len(wide.Body["stores"].([]any)) != 1 {
		t.Fatalf("admin wide stores = %v", wide.Body["stores"])
	}
	a.expect(a.do("GET", "/field/map?min_lat=41.355", tok2, nil), 400, "map without bbox")

	// «Это он?»: рядом уже отмечен магазин Азиза.
	near := a.expect(a.do("GET", "/field/places/near?lat=41.3616&lng=69.2802", tok2, nil), 200, "near")
	if len(near.items()) != 1 || near.items()[0]["id"] != placeID || near.items()[0]["mine"] != false {
		t.Fatalf("near = %v", near.Body)
	}
	tomorrow := time.Now().In(time.FixedZone("UZ", 5*3600)).AddDate(0, 0, 1).Format("2006-01-02")
	upd := a.expect(visit(tok2, map[string]any{"result": "later", "place_id": placeID, "lat": 41.3616, "lng": 69.2802, "remind_on": tomorrow}), 201, "later on same place")
	if upd.str("result") != "later" || upd.Body["visits"].(float64) != 2 || upd.str("name") != "Baraka Market" || upd.str("photo_url") != "https://x/p.jpg" ||
		upd.str("remind_on") != tomorrow || len(upd.Body["history"].([]any)) != 2 {
		t.Fatalf("updated place = %v", upd.Body)
	}
	a.expect(visit(tok2, map[string]any{"result": "ours", "place_id": placeID, "lat": 41.38, "lng": 69.2802}), 400, "place too far")
	// Дубль заявки: тот же номер у Бахтиёра — магазин закреплён за Азизом.
	if r := a.expect(visit(tok2, map[string]any{
		"result": "lead", "lat": 41.3680, "lng": 69.2805,
		"lead": map[string]any{"name": "Zamon", "owner_name": "Шерзод", "owner_phone": "+998907776655"},
	}), 409, "lead dup"); r.str("error", "code") != "store_exists" || r.Body["error"].(map[string]any)["details"].(map[string]any)["mine"] != false {
		t.Fatalf("dup = %v", r.Body)
	}
	// Напоминание «Прийти позже» — у Бахтиёра.
	if me2 := a.expect(a.do("GET", "/field/me", tok2, nil), 200, "me 2"); len(me2.Body["reminders"].([]any)) != 1 || me2.Body["walk"] == nil {
		t.Fatalf("me 2 = %v", me2.Body)
	}
	myPl := a.expect(a.do("GET", "/field/places?result=later", tok2, nil), 200, "my places")
	if len(myPl.items()) != 1 {
		t.Fatalf("my places = %v", myPl.Body)
	}

	// Супер-админ: заявка продажника — в общей очереди, без агента и 50%.
	leads := a.expect(a.do("GET", "/admin/store-leads?status=pending", adminTok, nil), 200, "admin leads")
	if len(leads.items()) != 1 || leads.items()[0]["source"] != "rep" || leads.items()[0]["agent_name"] != "Азиз Каримов" || leads.items()[0]["agent_network_id"] != "" {
		t.Fatalf("leads = %v", leads.Body)
	}
	leadID := leads.items()[0]["id"].(string)
	if c := a.expect(a.do("GET", "/admin/store-leads/"+leadID, adminTok, nil), 200, "admin lead"); c.Body["agent_connected"].(float64) != 0 {
		t.Fatalf("lead card = %v", c.Body)
	}
	a.expect(a.do("POST", "/admin/store-leads/"+leadID+"/connect", adminTok, map[string]any{"kind": "single"}), 200, "connect rep lead")
	if rw := a.expect(a.do("GET", "/admin/store-leads/rewards", adminTok, nil), 200, "rewards"); len(rw.items()) != 0 {
		t.Fatalf("rep lead in agent rewards: %v", rw.Body)
	}
	if pc := a.expect(a.do("GET", "/field/places/"+leadPl.str("id"), tok1, nil), 200, "lead place"); pc.str("lead_status") != "connected" {
		t.Fatalf("lead place = %v", pc.Body)
	}

	// Итог обхода Азиза: покрытие района до и после.
	sum := a.expect(a.do("POST", "/field/walks/"+w1ID+"/finish", tok1, nil), 200, "finish")
	after, before := sum.Body["coverage_after"].(float64), sum.Body["coverage_before"].(float64)
	if sum.str("status") != "ended" || sum.str("end_reason") != "manual" || after <= 0 || before != 0 ||
		sum.Body["results"].(map[string]any)["total"].(float64) != 2 || sum.str("district") != "Юнусабад" {
		t.Fatalf("summary = %v", sum.Body)
	}
	a.expect(a.do("POST", "/field/walks/"+w1ID+"/points", tok1, map[string]any{"points": pts[:1]}), 409, "points after finish")

	// С1 «Сейчас».
	live := a.expect(a.do("GET", "/admin/field/live", adminTok, nil), 200, "live")
	if live.Body["walking"].(float64) != 1 || live.Body["total"].(float64) != 2 || live.Body["today"].(map[string]any)["places"].(float64) != 3 {
		t.Fatalf("live = %v", live.Body)
	}
	// С2 «Маршрут за день»: путь, хронология с визитами и заходом в чужую зону.
	day := a.expect(a.do("GET", "/admin/field/reps/"+r2.str("id")+"/day", adminTok, nil), 200, "day")
	walks := day.Body["walks"].([]any)
	if len(walks) != 1 || len(walks[0].(map[string]any)["pts"].([]any)) < 10 {
		t.Fatalf("day walks = %v", day.Body)
	}
	kinds := map[string]int{}
	for _, e := range day.Body["events"].([]any) {
		kinds[e.(map[string]any)["kind"].(string)]++
	}
	if kinds["start"] != 1 || kinds["other"] != 1 || kinds["visit"] != 1 {
		t.Fatalf("events = %v", kinds)
	}
	a.expect(a.do("GET", "/admin/field/reps/"+r2.str("id")+"/day?date=07.11.2026", adminTok, nil), 400, "bad date")
	// С3: покрытие районов, сброс.
	ds = a.expect(a.do("GET", "/admin/field/districts", adminTok, nil), 200, "districts after")
	for _, x := range ds.items() {
		if x["id"] == yunus && (x["coverage_pct"].(float64) != after || x["places"].(float64) != 2 || x["connected"].(float64) != 1 || len(x["reps"].([]any)) != 2) {
			t.Fatalf("district = %v", x)
		}
	}
	if rs := a.expect(a.do("POST", "/admin/field/districts/"+yunus+"/reset", adminTok, nil), 200, "reset"); rs.Body["coverage_pct"].(float64) != 0 {
		t.Fatalf("reset = %v", rs.Body)
	}

	// Автопауза: стоит на месте больше 30 минут; снова пошёл — пауза снята.
	if _, err := pool.Exec(ctx, `UPDATE field_walks SET last_moved_at = now() - interval '40 minutes' WHERE id = $1`, w2ID); err != nil {
		t.Fatal(err)
	}
	if err := field.NewService(pool, nil, quietLog()).Tick(ctx); err != nil {
		t.Fatal(err)
	}
	if w := a.expect(a.do("GET", "/field/walks/"+w2ID, tok2, nil), 200, "auto paused"); w.str("status") != "paused" || w.Body["auto_paused"] != true {
		t.Fatalf("auto pause = %v", w.Body)
	}
	moved := a.expect(a.do("POST", "/field/walks/"+w2ID+"/points", tok2, map[string]any{"points": []any{
		map[string]any{"at": time.Now().Add(-2 * time.Second), "lat": 41.3650, "lng": 69.28, "accuracy": 5},
	}}), 200, "moved again")
	if moved.str("walk", "status") != "active" {
		t.Fatalf("auto resume = %v", moved.Body["walk"])
	}
	// Ручная пауза: точки не пишутся.
	a.expect(a.do("POST", "/field/walks/"+w2ID+"/pause", tok2, nil), 200, "pause")
	if r := a.expect(a.do("POST", "/field/walks/"+w2ID+"/points", tok2, map[string]any{"points": []any{
		map[string]any{"at": time.Now(), "lat": 41.3660, "lng": 69.28, "accuracy": 5},
	}}), 200, "points on pause"); r.Body["accepted"].(float64) != 0 {
		t.Fatalf("points on pause = %v", r.Body)
	}
	a.expect(a.do("POST", "/field/walks/"+w2ID+"/resume", tok2, nil), 200, "resume")

	// Блокировка: сессия закрыта, обход закончен.
	a.expect(a.do("PATCH", "/admin/field/reps/"+r2.str("id"), adminTok, map[string]any{"status": "blocked"}), 200, "block")
	a.expect(a.do("GET", "/field/me", tok2, nil), 401, "blocked session")
	a.expect(a.do("POST", "/auth/field/login", "", map[string]string{"login": "bahtiyor", "password": "secret-456"}), 403, "blocked login")
	var st string
	if err := pool.QueryRow(ctx, `SELECT status FROM field_walks WHERE id = $1`, w2ID).Scan(&st); err != nil || st != "ended" {
		t.Fatalf("walk after block = %q %v", st, err)
	}
	// Новый пароль — старые сессии закрыты.
	a.expect(a.do("PATCH", "/admin/field/reps/"+r1.str("id"), adminTok, map[string]any{"password": "new-secret-1", "district_id": nil}), 200, "new password")
	a.expect(a.do("GET", "/field/me", tok1, nil), 401, "old session after new password")
	tok1 = a.expect(a.do("POST", "/auth/field/login", "", map[string]string{"login": "aziz.k", "password": "new-secret-1"}), 200, "login new").str("access_token")
	if me := a.expect(a.do("GET", "/field/me", tok1, nil), 200, "me without district"); me.Body["district"] != nil {
		t.Fatalf("district after unset = %v", me.Body["district"])
	}
}

// TestFieldAutoEnd — открытый обход, начатый вчера, закрывается сам.
func TestFieldAutoEnd(t *testing.T) {
	pool := freshDB(t)
	ctx := context.Background()
	cfg := testConfig()
	cfg.DevOTPCode = "111111"
	app, err := server.Build(ctx, cfg, pool, &fakeTelegram{}, quietLog())
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app.Handler)
	t.Cleanup(srv.Close)
	a := api{t: t, srv: srv, pool: pool}
	adminTok, _ := a.login("+998900000001", identity.AppAdmin)
	a.expect(a.do("POST", "/admin/field/reps", adminTok, map[string]any{
		"full_name": "Азиз", "phone": "+998901112233", "login": "aziz", "password": "secret-123",
	}), 201, "rep")
	tok := a.expect(a.do("POST", "/auth/field/login", "", map[string]string{"login": "aziz", "password": "secret-123"}), 200, "login").str("access_token")
	id := a.expect(a.do("POST", "/field/walks", tok, nil), 200, "start").str("id")
	if _, err := pool.Exec(ctx, `UPDATE field_walks SET started_at = now() - interval '1 day' WHERE id = $1`, id); err != nil {
		t.Fatal(err)
	}
	if err := field.NewService(pool, nil, quietLog()).Tick(ctx); err != nil {
		t.Fatal(err)
	}
	if w := a.expect(a.do("GET", "/field/walks/"+id, tok, nil), 200, "walk"); w.str("status") != "ended" || w.str("end_reason") != "auto" {
		t.Fatalf("auto end = %v", w.Body)
	}
	// Новый обход можно начать.
	if id2 := a.expect(a.do("POST", "/field/walks", tok, nil), 200, "start 2").str("id"); id2 == id {
		t.Fatal("old walk reopened")
	}
}
