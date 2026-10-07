package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/config"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// Демо-доступ для проверки приложений в App Store / Google Play.
//
// Номер из REVIEW_LOGIN становится сотрудником «Baraka Market» со всеми
// правами (в «SM Магазин» он входит по логину review.store), курьером
// «по пути» с подтверждённой личностью и покупателем с адресом рядом с
// магазинами сети. Для приложения курьера магазина заводится штатный курьер
// с логином review.
//
// Пароли не случайные: они выводятся из JWT_SECRET, поэтому при каждом
// запуске одни и те же — повторный запуск не ломает данные, уже
// отправленные на проверку. Если пароль сменили в панели, review вернёт его.

const (
	reviewCourierPhone = "+998900000110" // служебный номер штатного курьера
	reviewCourierLogin = "review"
	reviewStoreLogin   = "review.store"
	reviewCourierName  = "Курьер для проверки"
	reviewEmployeeName = "Проверка приложений"
	reviewRoleName     = "Проверка приложений"
	courierRoleName    = "Курьер"
)

// reviewCreds — что вставить в заметки для проверяющего.
type reviewCreds struct {
	phone, code              string
	network                  string
	courierLogin, courierPwd string
	storeLogin, storePwd     string // пусто — номер проверки сам владелец сети
	crowdCode                string
}

// reviewPassword — пароль курьера магазина, постоянный для данного JWT_SECRET.
func reviewPassword(secret string) string {
	return derivedPassword(secret, "demo-review-courier-password")
}

// reviewStorePassword — пароль сотрудника для «SM Магазин», постоянный для данного JWT_SECRET.
func reviewStorePassword(secret string) string {
	return derivedPassword(secret, "demo-review-store-password")
}

// derivedPassword — запоминающийся пароль из секрета и назначения.
func derivedPassword(secret, purpose string) string {
	words := []string{"olma", "anor", "uzum", "qovun", "non", "choy", "asal", "limon", "sabzi", "shaftoli", "gilos", "behi"}
	m := hmac.New(sha256.New, []byte(secret))
	m.Write([]byte(purpose))
	sum := m.Sum(nil)
	a := words[int(sum[0])%len(words)]
	b := words[int(sum[1])%len(words)]
	if a == b {
		b = words[(int(sum[1])+1)%len(words)]
	}
	return fmt.Sprintf("%s-%s-%04d", a, b, binary.BigEndian.Uint16(sum[2:4])%10000)
}

func review(ctx context.Context, cfg config.Config, pool *pgxpool.Pool) (reviewCreds, error) {
	rph, rcode, err := cfg.Review()
	if err != nil {
		return reviewCreds{}, err
	}
	if rph == "" {
		return reviewCreds{}, errors.New("REVIEW_LOGIN не задан — укажите в .env «+998XXXXXXXXX:123456» и запустите снова")
	}
	nw := demoNetworks[0]
	var networkID string
	err = pool.QueryRow(ctx, `
		SELECT n.id::text FROM networks n JOIN demo_seed d ON d.kind = 'network' AND d.id = n.id::text
		WHERE n.name = $1 AND n.status = 'active' ORDER BY d.created_at LIMIT 1`, nw.name).Scan(&networkID)
	if errors.Is(err, pgx.ErrNoRows) {
		return reviewCreds{}, fmt.Errorf("демо-данные не загружены (нет сети «%s») — сначала выполните demo seed", nw.name)
	}
	if err != nil {
		return reviewCreds{}, err
	}

	// Номера, которые уже работают в настоящей (не демо) сети, не трогаем.
	for _, ph := range []string{rph, reviewCourierPhone} {
		var other string
		err := pool.QueryRow(ctx, `
			SELECT n.name FROM employees e JOIN users u ON u.id = e.user_id JOIN networks n ON n.id = e.network_id
			WHERE u.phone = $1 AND e.network_id::text <> $2`, ph, networkID).Scan(&other)
		if err == nil {
			return reviewCreds{}, fmt.Errorf("%s уже сотрудник сети «%s» — это не демо-сеть, review её не меняет; "+
				"укажите в REVIEW_LOGIN другой номер или удалите сотрудника в той сети", ph, other)
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return reviewCreds{}, err
		}
	}
	var ownerPhone string
	if err := pool.QueryRow(ctx, `
		SELECT u.phone FROM employees e JOIN roles r ON r.id = e.role_id AND r.is_owner JOIN users u ON u.id = e.user_id
		WHERE e.network_id::text = $1 ORDER BY e.created_at LIMIT 1`, networkID).Scan(&ownerPhone); err != nil {
		return reviewCreds{}, fmt.Errorf("владелец сети %s: %w", nw.name, err)
	}

	s := &seeder{ctx: ctx, pool: pool, start: time.Now(), existed: map[string]bool{}}
	s.phones = []string{demoAdminPhone, ownerPhone}
	for _, ph := range []string{rph, reviewCourierPhone} {
		if !slices.Contains(s.phones, ph) {
			s.phones = append(s.phones, ph)
		}
	}
	for _, ph := range s.phones {
		var ok bool
		if err := pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM users WHERE phone = $1)`, ph).Scan(&ok); err != nil {
			return reviewCreds{}, err
		}
		s.existed[ph] = ok
	}

	code, err := randomCode()
	if err != nil {
		return reviewCreds{}, err
	}
	local := cfg
	local.DevOTPCode = code
	local.SuperAdminPhones = []string{demoAdminPhone}
	local.TelegramBotToken = ""
	local.EskizEmail = ""
	app, err := server.Build(ctx, local, pool, nil, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		return reviewCreds{}, err
	}
	s.c = client{h: app.Handler, code: code, reviewPhone: rph, reviewCode: rcode, pool: pool, secret: cfg.JWTSecret}
	defer s.finish()

	r := &reviewer{seeder: s, networkID: networkID, phone: rph, ownerPhone: ownerPhone}
	creds := reviewCreds{phone: rph, code: rcode, network: nw.name, courierLogin: reviewCourierLogin, courierPwd: reviewPassword(cfg.JWTSecret),
		storeLogin: reviewStoreLogin, storePwd: reviewStorePassword(cfg.JWTSecret)}
	if err := r.run(&creds); err != nil {
		return creds, fmt.Errorf("%w\nисправьте причину и запустите demo review снова (повторный запуск безопасен)", err)
	}
	printReview(creds)
	return creds, nil
}

type reviewer struct {
	*seeder
	networkID, phone, ownerPhone string
	owner                        string // токен владельца в приложении магазина
	stores                       []demoPoint
}

type demoPoint struct {
	id       string
	lat, lng float64
}

// loginAs — вход в приложение. Для номера проверки сначала удаляется
// неиспользованный код (он всё равно постоянный), иначе сработает
// «код уже отправлен, попробуйте позже».
func (r *reviewer) loginAs(ph, app string, terms bool) (string, error) {
	if ph == r.phone {
		if _, err := r.pool.Exec(r.ctx, `DELETE FROM auth_codes WHERE phone = $1`, ph); err != nil {
			return "", err
		}
	}
	tok, err := r.c.loginTerms(ph, app, terms)
	if err != nil {
		return "", fmt.Errorf("вход %s в приложение %s: %w", ph, app, err)
	}
	return tok, nil
}

func (r *reviewer) run(creds *reviewCreds) error {
	rows, err := r.pool.Query(r.ctx, `
		SELECT id::text, ST_Y(location::geometry), ST_X(location::geometry) FROM stores
		WHERE network_id::text = $1 ORDER BY created_at`, r.networkID)
	if err != nil {
		return err
	}
	r.stores, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (demoPoint, error) {
		var p demoPoint
		return p, row.Scan(&p.id, &p.lat, &p.lng)
	})
	if err != nil {
		return err
	}
	if len(r.stores) == 0 {
		return errors.New("в демо-сети нет магазинов — выполните demo clean и demo seed")
	}

	if r.owner, err = r.loginAs(r.ownerPhone, identity.AppStore, false); err != nil {
		return err
	}
	if err := r.staff(creds); err != nil {
		return fmt.Errorf("сотрудник: %w", err)
	}
	if err := r.courier(creds); err != nil {
		return fmt.Errorf("курьер магазина: %w", err)
	}
	if err := r.crowd(creds); err != nil {
		return fmt.Errorf("курьер «по пути»: %w", err)
	}
	if err := r.customer(); err != nil {
		return fmt.Errorf("покупатель: %w", err)
	}
	// Итоговая проверка: проверяющий входит в приложение магазина.
	if creds.storeLogin != "" {
		out, err := r.c.call("POST", "/auth/store/login", "", obj{"login": creds.storeLogin, "password": creds.storePwd}, http.StatusOK)
		if err != nil {
			return fmt.Errorf("вход в «SM Магазин» по логину %s: %w", creds.storeLogin, err)
		}
		if out["password_change_required"] == true {
			return fmt.Errorf("логин %s с временным паролем — так проверяющий застрянет на смене пароля", creds.storeLogin)
		}
	}
	return nil
}

// ensureRole находит роль сети по названию или создаёт её; права perms
// добавляются к уже имеющимся.
func (r *reviewer) ensureRole(name string, perms []string) (string, error) {
	var (
		id  string
		cur []string
	)
	err := r.pool.QueryRow(r.ctx, `SELECT id::text, permissions FROM roles WHERE network_id::text = $1 AND name = $2 AND NOT is_owner`,
		r.networkID, name).Scan(&id, &cur)
	if errors.Is(err, pgx.ErrNoRows) {
		out, err := r.c.call("POST", "/store/roles", r.owner, obj{"name": name, "permissions": perms}, http.StatusCreated)
		if err != nil {
			return "", err
		}
		return str(out, "id"), r.record("review_role", str(out, "id"))
	}
	if err != nil {
		return "", err
	}
	missing := false
	for _, p := range perms {
		if !slices.Contains(cur, p) {
			cur, missing = append(cur, p), true
		}
	}
	if missing {
		if _, err := r.c.call("PATCH", "/store/roles/"+id, r.owner, obj{"permissions": cur}, http.StatusOK); err != nil {
			return "", err
		}
	}
	return id, nil
}

type employeeRow struct {
	id, status string
	owner      bool
}

func (r *reviewer) employee(ph string) (*employeeRow, error) {
	var e employeeRow
	err := r.pool.QueryRow(r.ctx, `
		SELECT e.id::text, e.status, ro.is_owner FROM employees e
		JOIN users u ON u.id = e.user_id JOIN roles ro ON ro.id = e.role_id
		WHERE u.phone = $1 AND e.network_id::text = $2`, ph, r.networkID).Scan(&e.id, &e.status, &e.owner)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return &e, err
}

// staff — номер проверки становится сотрудником сети со всеми правами и
// получает логин для «SM Магазин».
func (r *reviewer) staff(creds *reviewCreds) error {
	e, err := r.employee(r.phone)
	if err != nil {
		return err
	}
	switch {
	case e != nil && e.owner:
		// Логин владельца выдаёт супер-админ — review его пароль не трогает.
		creds.storeLogin, creds.storePwd = "", ""
		fmt.Printf("магазин: %s — владелец сети, оставлен как есть (в «SM Магазин» — его логин и пароль)\n", r.phone)
		return nil
	case e != nil:
		if e.status != "active" {
			if _, err := r.c.call("PATCH", "/store/employees/"+e.id, r.owner, obj{"status": "active"}, http.StatusOK); err != nil {
				return err
			}
		}
		fmt.Printf("магазин: %s уже сотрудник сети, оставлен как есть\n", r.phone)
		return r.storeLogin(e.id, creds)
	}
	all := make([]string, 0, len(identity.Permissions))
	for _, p := range identity.Permissions {
		all = append(all, p.Code)
	}
	roleID, err := r.ensureRole(reviewRoleName, all)
	if err != nil {
		return err
	}
	out, err := r.c.call("POST", "/store/employees", r.owner, obj{
		"phone": r.phone, "full_name": reviewEmployeeName, "role_id": roleID, "all_stores": true,
	}, http.StatusCreated)
	if err != nil {
		return err
	}
	fmt.Printf("магазин: %s — сотрудник сети с ролью «%s»\n", r.phone, reviewRoleName)
	if err := r.record("review_employee", str(out, "id")); err != nil {
		return err
	}
	return r.storeLogin(str(out, "id"), creds)
}

// storeLogin — логин сотрудника для проверки в «SM Магазин». Пароль
// постоянный, не временный: иначе каждый проверяющий застрял бы на смене
// пароля. Поэтому он пишется в базу напрямую — через панель магазина
// выдаётся только временный.
func (r *reviewer) storeLogin(empID string, creds *reviewCreds) error {
	var (
		login, hash  string
		locked, temp bool
	)
	err := r.pool.QueryRow(r.ctx, `
		SELECT login, password_hash, COALESCE(locked_until > now(), false), must_change_password
		FROM employee_logins WHERE employee_id::text = $1`, empID).Scan(&login, &hash, &locked, &temp)
	existed := err == nil
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	if existed && login == creds.storeLogin && !locked && !temp && identity.CheckPassword(hash, creds.storePwd) {
		fmt.Printf("«SM Магазин»: логин %s уже есть, пароль прежний\n", creds.storeLogin)
		return nil
	}
	newHash, err := identity.HashPassword(creds.storePwd)
	if err != nil {
		return err
	}
	_, err = r.pool.Exec(r.ctx, `
		INSERT INTO employee_logins (employee_id, network_id, login, password_hash, must_change_password)
		VALUES ($1::uuid, $2::uuid, $3, $4, false)
		ON CONFLICT (employee_id) DO UPDATE SET
			login = EXCLUDED.login, password_hash = EXCLUDED.password_hash, must_change_password = false,
			password_changed_at = now(), failed_attempts = 0, locked_until = NULL`,
		empID, r.networkID, creds.storeLogin, newHash)
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return fmt.Errorf("логин %q уже занят сотрудником другой сети — освободите его и запустите снова", creds.storeLogin)
	}
	if err != nil {
		return err
	}
	if !existed {
		if err := r.record("review_store_login", empID); err != nil {
			return err
		}
	}
	fmt.Printf("«SM Магазин»: логин %s, пароль задан\n", creds.storeLogin)
	return nil
}

// courier — штатный курьер сети с логином и паролем для приложения курьера.
func (r *reviewer) courier(creds *reviewCreds) error {
	roleID, err := r.ensureRole(courierRoleName, []string{identity.PermOrdersDeliver})
	if err != nil {
		return err
	}
	e, err := r.employee(reviewCourierPhone)
	if err != nil {
		return err
	}
	var empID string
	switch {
	case e == nil:
		out, err := r.c.call("POST", "/store/employees", r.owner, obj{
			"phone": reviewCourierPhone, "full_name": reviewCourierName, "role_id": roleID, "all_stores": true,
		}, http.StatusCreated)
		if err != nil {
			return err
		}
		empID = str(out, "id")
		if err := r.record("review_courier", empID); err != nil {
			return err
		}
	case e.owner:
		empID = e.id
	default:
		empID = e.id
		if _, err := r.c.call("PATCH", "/store/employees/"+empID, r.owner, obj{"status": "active", "role_id": roleID}, http.StatusOK); err != nil {
			return err
		}
	}

	var (
		login, hash string
		locked      bool
	)
	err = r.pool.QueryRow(r.ctx, `SELECT login, password_hash, COALESCE(locked_until > now(), false) FROM employee_logins WHERE employee_id::text = $1`,
		empID).Scan(&login, &hash, &locked)
	existed := err == nil
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	if !existed || login != creds.courierLogin || locked || !identity.CheckPassword(hash, creds.courierPwd) {
		code, out, err := r.c.do("PUT", "/store/couriers/"+empID+"/login", r.owner, obj{"login": creds.courierLogin, "password": creds.courierPwd})
		if err != nil {
			return err
		}
		if code == http.StatusConflict {
			return fmt.Errorf("логин %q уже занят курьером другой сети — освободите его и запустите снова", creds.courierLogin)
		}
		if code != http.StatusOK {
			return fmt.Errorf("PUT /store/couriers/%s/login: статус %d: %v", empID, code, out)
		}
		if !existed {
			if err := r.record("review_courier_login", empID); err != nil {
				return err
			}
		}
		fmt.Printf("курьер магазина: логин %s, пароль задан\n", creds.courierLogin)
	} else {
		fmt.Printf("курьер магазина: логин %s уже есть, пароль прежний\n", creds.courierLogin)
	}
	if _, err := r.c.call("POST", "/auth/courier/login", "", obj{"login": creds.courierLogin, "password": creds.courierPwd}, http.StatusOK); err != nil {
		return fmt.Errorf("проверка входа: %w", err)
	}
	return nil
}

// crowd — регистрация курьера «по пути» и проверка личности в магазине сети.
func (r *reviewer) crowd(creds *reviewCreds) error {
	var existed, deleted bool
	var status string
	err := r.pool.QueryRow(r.ctx, `
		SELECT cc.status, cc.deleted_at IS NOT NULL FROM crowd_couriers cc JOIN users u ON u.id = cc.user_id
		WHERE u.phone = $1`, r.phone).Scan(&status, &deleted)
	switch {
	case err == nil:
		existed = !deleted
	case !errors.Is(err, pgx.ErrNoRows):
		return err
	}
	if status == "blocked" {
		return fmt.Errorf("%s заблокирован как курьер — разблокируйте в панели супер-админа (Курьеры «по пути»)", r.phone)
	}

	// Доставка «по пути» включена во всех магазинах демо-сети: там проходит
	// проверка личности, и туда приходят заказы в ленту.
	admin, err := r.c.login(demoAdminPhone, identity.AppAdmin)
	if err != nil {
		return err
	}
	for _, st := range r.stores {
		if _, err := r.c.call("PUT", "/admin/crowd/stores/"+st.id, admin, obj{"crowd_enabled": true}, http.StatusOK); err != nil {
			return err
		}
	}

	tok, err := r.loginAs(r.phone, identity.AppCrowd, true)
	if err != nil {
		return err
	}
	me, err := r.c.call("GET", "/crowd/me", tok, nil, http.StatusOK)
	if err != nil {
		return err
	}
	if !existed {
		if err := r.record("review_crowd", str(me, "user_id")); err != nil {
			return err
		}
		if _, err := r.c.call("PUT", "/crowd/me", tok, obj{"vehicle": "bike"}, http.StatusOK); err != nil {
			return err
		}
	}
	creds.crowdCode = str(me, "code")
	if str(me, "status") != "active" {
		code, out, err := r.c.do("POST", "/store/crowd/verify", r.owner, obj{
			"code": creds.crowdCode, "store_id": r.stores[0].id, "decision": "approve", "doc_type": "id_card",
			"full_name": "Демо Курьер", "birth_date": "1995-01-01", "doc_last4": "0000", "photo_match": true, "doc_valid": true,
		})
		if err != nil {
			return err
		}
		if code == http.StatusConflict && out["code"] == "doc_used" {
			return errors.New("документ «Демо Курьер, 1995-01-01, …0000» уже подтверждён у другого курьера — удалите того курьера и запустите снова")
		}
		if code != http.StatusOK {
			return fmt.Errorf("POST /store/crowd/verify: статус %d: %v", code, out)
		}
		fmt.Printf("курьер «по пути»: %s, личность подтверждена\n", creds.crowdCode)
	} else {
		fmt.Printf("курьер «по пути»: %s, личность уже подтверждена\n", creds.crowdCode)
	}
	if _, err := r.c.call("PUT", "/crowd/route", tok, obj{"online": true}, http.StatusOK); err != nil {
		return err
	}
	st := r.stores[0]
	feed, err := r.c.call("GET", fmt.Sprintf("/crowd/offers?lat=%f&lng=%f", st.lat, st.lng), tok, nil, http.StatusOK)
	if err != nil {
		return err
	}
	if s := str(feed, "state"); s != "ok" {
		return fmt.Errorf("лента заказов: состояние %q, ожидалось ok", s)
	}
	return nil
}

// customer — вход в приложение покупателя и адрес рядом с магазинами сети.
func (r *reviewer) customer() error {
	var existed bool
	if err := r.pool.QueryRow(r.ctx, `
		SELECT EXISTS (SELECT 1 FROM customers c JOIN users u ON u.id = c.user_id WHERE u.phone = $1)`, r.phone).Scan(&existed); err != nil {
		return err
	}
	tok, err := r.loginAs(r.phone, identity.AppClient, false)
	if err != nil {
		return err
	}
	if !existed {
		var userID string
		if err := r.pool.QueryRow(r.ctx, `SELECT id::text FROM users WHERE phone = $1`, r.phone).Scan(&userID); err != nil {
			return err
		}
		if err := r.record("review_customer", userID); err != nil {
			return err
		}
	}
	list, err := r.c.call("GET", "/client/addresses", tok, nil, http.StatusOK)
	if err != nil {
		return err
	}
	if len(items(list)) > 0 {
		fmt.Println("покупатель: адрес уже есть")
		return nil
	}
	st := r.stores[0]
	out, err := r.c.call("POST", "/client/addresses", tok, obj{
		"label": "Дом", "address": "Чиланзар, 9-й квартал, 20", "lat": st.lat + 0.0015, "lng": st.lng + 0.0015,
	}, http.StatusCreated)
	if err != nil {
		return err
	}
	fmt.Println("покупатель: добавлен адрес рядом с магазином", demoNetworks[0].stores[0].name)
	return r.record("review_address", str(out, "id"))
}

func printReview(c reviewCreds) {
	fmt.Printf(`
================ Демо-доступ для проверки приложений ================
Вставьте в App Store Connect (App Review Information → Notes)
и Google Play Console (App access → инструкции для проверки):

Super Market (покупатель)
  Телефон: %[1]s
  Код из SMS/Telegram: %[2]s (код не приходит — всегда вводите этот)

SM Магазин (сотрудник сети «%[3]s», все права)
  %[7]s

SM Курьер — «Курьер по пути» (личность подтверждена, код курьера %[6]s)
  Телефон: %[1]s
  Код: %[2]s

SM Курьер — «Курьер магазина» (вход по логину)
  Логин: %[4]s
  Пароль: %[5]s
=====================================================================
`, c.phone, c.code, c.network, c.courierLogin, c.courierPwd, c.crowdCode, storeNote(c))
}

func storeNote(c reviewCreds) string {
	if c.storeLogin == "" {
		return "Логин и пароль владельца сети (номер проверки — владелец)"
	}
	return fmt.Sprintf("Логин: %s\n  Пароль: %s", c.storeLogin, c.storePwd)
}
