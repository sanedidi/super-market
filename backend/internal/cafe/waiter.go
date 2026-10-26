package cafe

// Официант в телефоне (план «Кафе», этап 6; Figma О1–О13). Режим в
// «SM Магазин»: входит сотрудник с правом cafe.waiter, работает с теми же
// счетами, что и касса, через те же операции (bill_events — повтор не
// применяется, версия счёта растёт). Свои маршруты /store/cafe/waiter/*,
// потому что токен сотрудника — не токен кассы: нет device_id, точка
// выбирается параметром store_id, а набор операций уже, чем у кассы
// (отмена с ПИНом, перенос и объединение — только касса).
//
// Чей стол: кто открыл — того и стол (О5); на смену старший назначает
// зоны (О8); передать стол — предложение, которое получатель принимает за
// 3 минуты (О6 → О7). При настройке «официант видит только свои столы»
// чужой стол приходит серым: без позиций и сумм, добавить нельзя — только
// «Попросить стол».

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/events"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// Notifier — push сотруднику в приложение магазина (пакет notify).
type Notifier interface {
	Employee(ctx context.Context, employeeID string, text i18n.Text) int
}

// WithNotifier включает push официантам: стол открыт, готово — заберите,
// передача стола.
func (s *Service) WithNotifier(n Notifier) *Service {
	s.notifier = n
	return s
}

type waiterPush struct {
	employeeID string
	text       i18n.Text
}

func (s *Service) sendPushes(ctx context.Context, ps []waiterPush) {
	if s.notifier == nil {
		return
	}
	for _, p := range ps {
		if p.employeeID != "" {
			s.notifier.Employee(ctx, p.employeeID, p.text)
		}
	}
}

func tableOpenedPush(waiterID, number string, guests int) waiterPush {
	g := strconv.Itoa(guests)
	return waiterPush{employeeID: waiterID, text: i18n.Text{
		RU: "Стол " + number + " открыт\n" + g + " " + plural(guests, "гость", "гостя", "гостей"),
		UZ: number + "-stol ochildi\n" + g + " mehmon",
	}}
}

// readyPushes — «Готово — заберите» официанту стола, когда кухня отметила
// бегунок отправки готовым.
func readyPushes(ctx context.Context, q db.Querier, storeID, orderKey string) ([]waiterPush, error) {
	var waiter *string
	var number string
	var names []string
	err := q.QueryRow(ctx, `
		SELECT b.waiter_id, COALESCE(ct.number, ''),
		       COALESCE((SELECT array_agg(loc(i.name, i.name_uz) || ' × ' || trim_scale(i.qty)::text ORDER BY i.line)
		                 FROM kitchen_ticket_items i JOIN kitchen_tickets t2 ON t2.id = i.ticket_id
		                 WHERE t2.order_key = t.order_key AND t2.store_id = t.store_id AND t2.status = 'ready'), '{}')
		FROM kitchen_tickets t JOIN bills b ON b.id = t.bill_id LEFT JOIN cafe_tables ct ON ct.id = b.table_id
		WHERE t.store_id = $1 AND t.order_key = $2 AND t.status = 'ready' LIMIT 1`, storeID, orderKey).Scan(&waiter, &number, &names)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && waiter == nil) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	list := strings.Join(names, ", ")
	return []waiterPush{{employeeID: *waiter, text: i18n.Text{
		RU: "Стол " + number + ": готово — заберите\n" + list,
		UZ: number + "-stol: tayyor — olib keting\n" + list,
	}}}, nil
}

// ------------------------------------------------------------ операции

var waiterKinds = map[string]bool{
	"open": true, "add": true, "update": true, "remove": true, "send": true, "fire": true, "guests": true,
	"precheck": true, "void": true, "serve": true, "transfer": true, "accept": true, "decline": true,
	"request": true, "take": true,
}

// Операции только официанта (касса их не шлёт).
var waiterOnlyKinds = map[string]bool{
	"serve": true, "transfer": true, "accept": true, "decline": true, "request": true, "take": true,
}

func isWaiterOp(kind string) bool { return waiterOnlyKinds[kind] }

func waiterAllowed(kind string) error {
	if waiterKinds[kind] {
		return nil
	}
	switch kind {
	case "cancel", "move", "merge", "move_items", "waiter":
		return apperr.Forbidden("с телефона нельзя — попросите кассира").Uz("telefondan mumkin emas — kassirdan soʻrang")
	}
	return apperr.Validation("kind: неизвестная операция").Uz("kind: nomaʼlum amal")
}

var errForeignTable = apperr.Forbidden("чужой стол — можно только попросить его").Uz("boshqaning stoli — faqat soʻrash mumkin")

// waiterOwns — можно ли официанту менять этот счёт.
func waiterOwns(kind string, waiter *string, who actor) error {
	switch kind {
	case "accept", "decline", "request", "take":
		return nil
	}
	if who.senior || waiter == nil || *waiter == who.me {
		return nil
	}
	if who.own {
		return errForeignTable
	}
	return nil
}

func waiterOp(ctx context.Context, tx pgx.Tx, p *identity.Principal, storeID string, op BillOp, who actor, waiter *string) ([]waiterPush, error) {
	var number string
	if err := tx.QueryRow(ctx, `SELECT COALESCE(t.number, '') FROM bills b LEFT JOIN cafe_tables t ON t.id = b.table_id WHERE b.id = $1`,
		op.BillID).Scan(&number); err != nil {
		return nil, err
	}
	meName := func() string {
		var n string
		_ = tx.QueryRow(ctx, `SELECT full_name FROM employees WHERE id = $1`, who.me).Scan(&n)
		return n
	}
	switch op.Kind {
	case "serve":
		if !httpx.IsUUID(op.ItemID) {
			return nil, errItem
		}
		tag, err := tx.Exec(ctx, `UPDATE bill_items SET served_at = COALESCE(served_at, now()) WHERE id = $1 AND bill_id = $2 AND status = 'sent'`,
			op.ItemID, op.BillID)
		if err != nil {
			return nil, err
		}
		if tag.RowsAffected() == 0 {
			return nil, apperr.Conflict("item_not_sent", "позиция ещё не на кухне").Uz("pozitsiya hali oshxonada emas")
		}
		return nil, nil

	case "take":
		// Стол без официанта — беру себе.
		if waiter != nil && *waiter != who.me {
			return nil, apperr.Conflict("table_taken", "у стола уже есть официант").Uz("stolda allaqachon ofitsiant bor")
		}
		_, err := tx.Exec(ctx, `UPDATE bills SET waiter_id = $2 WHERE id = $1`, op.BillID, who.me)
		return nil, err

	case "request":
		if waiter == nil || *waiter == who.me {
			return nil, apperr.Conflict("no_owner", "у стола нет официанта — возьмите его").Uz("stolda ofitsiant yoʻq — oʻzingiz oling")
		}
		return []waiterPush{{employeeID: *waiter, text: i18n.Text{
			RU: meName() + " просит стол " + number + "\nПередайте стол в «Мои столы», если согласны",
			UZ: meName() + " " + number + "-stolni soʻrayapti\nRozi boʻlsangiz, «Mening stollarim»da stolni bering",
		}}}, nil

	case "transfer":
		if !httpx.IsUUID(op.ToWaiterID) || op.ToWaiterID == who.me || (waiter != nil && op.ToWaiterID == *waiter) {
			return nil, apperr.Validation("to_waiter_id: кому передать стол").Uz("to_waiter_id: stolni kimga berish")
		}
		if err := checkWaiter(ctx, tx, p.NetworkID, storeID, op.ToWaiterID); err != nil {
			return nil, err
		}
		reason := strings.TrimSpace(op.Reason)
		if len([]rune(reason)) > 200 {
			return nil, apperr.Validation("reason: до 200 символов").Uz("reason: 200 belgigacha")
		}
		if _, err := tx.Exec(ctx, `UPDATE bills SET transfer_to = $2, transfer_from = $3, transfer_reason = $4, transfer_at = now() WHERE id = $1`,
			op.BillID, op.ToWaiterID, who.me, reason); err != nil {
			return nil, err
		}
		body := "Примите в «Мои столы» за 3 минуты"
		bodyUz := "3 daqiqa ichida «Mening stollarim»da qabul qiling"
		if reason != "" {
			body += "\n" + reason
			bodyUz += "\n" + reason
		}
		return []waiterPush{{employeeID: op.ToWaiterID, text: i18n.Text{
			RU: meName() + " передаёт вам стол " + number + "\n" + body,
			UZ: meName() + " sizga " + number + "-stolni beryapti\n" + bodyUz,
		}}}, nil

	case "accept", "decline":
		var to, from *string
		var at *time.Time
		if err := tx.QueryRow(ctx, `SELECT transfer_to, transfer_from, transfer_at FROM bills WHERE id = $1`, op.BillID).Scan(&to, &from, &at); err != nil {
			return nil, err
		}
		if to == nil || *to != who.me || at == nil || at.Before(time.Now().Add(-transferTTL)) {
			return nil, apperr.Conflict("transfer_expired", "предложение снято — стол остался у прежнего официанта").
				Uz("taklif bekor qilindi — stol avvalgi ofitsiantda qoldi")
		}
		sql := `UPDATE bills SET transfer_to = NULL, transfer_from = NULL, transfer_reason = '', transfer_at = NULL WHERE id = $1`
		if op.Kind == "accept" {
			sql = `UPDATE bills SET waiter_id = transfer_to, transfer_to = NULL, transfer_from = NULL, transfer_reason = '', transfer_at = NULL WHERE id = $1`
		}
		if _, err := tx.Exec(ctx, sql, op.BillID); err != nil {
			return nil, err
		}
		if from == nil {
			return nil, nil
		}
		if op.Kind == "accept" {
			return []waiterPush{{employeeID: *from, text: i18n.Text{
				RU: "Стол " + number + " передан\nПринял(а): " + meName(),
				UZ: number + "-stol berildi\nQabul qildi: " + meName(),
			}}}, nil
		}
		return []waiterPush{{employeeID: *from, text: i18n.Text{
			RU: "Стол " + number + " остался у вас\n" + meName() + ": отказ от передачи",
			UZ: number + "-stol sizda qoldi\n" + meName() + ": rad etdi",
		}}}, nil
	}
	return nil, apperr.Validation("kind: неизвестная операция").Uz("kind: nomaʼlum amal")
}

// checkWaiter — активный сотрудник сети с правом официанта (или владелец),
// которому доступна точка.
func checkWaiter(ctx context.Context, q db.Querier, networkID, storeID, id string) error {
	if !httpx.IsUUID(id) {
		return apperr.Validation("официант не найден").Uz("ofitsiant topilmadi")
	}
	var ok bool
	if err := q.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM employees e JOIN roles r ON r.id = e.role_id
			WHERE e.id = $1 AND e.network_id = $2 AND e.status = 'active'
			  AND (r.is_owner OR $3 = ANY(r.permissions))
			  AND (e.all_stores OR EXISTS (SELECT 1 FROM employee_stores es WHERE es.employee_id = e.id AND es.store_id = $4)))`,
		id, networkID, identity.PermCafeWaiter, storeID).Scan(&ok); err != nil {
		return err
	}
	if !ok {
		return apperr.Validation("официант не найден").Uz("ofitsiant topilmadi")
	}
	return nil
}

// ------------------------------------------------------------ API телефона

// waiterStore — точка официанта: право cafe.waiter, сеть-кафе, store_id из
// запроса (или единственная точка сотрудника).
func (s *Service) waiterStore(ctx context.Context, p *identity.Principal, storeID string) (string, actor, error) {
	who := actor{waiter: true, me: p.EmployeeID}
	if err := p.Require(identity.PermCafeWaiter); err != nil {
		return "", who, err
	}
	if p.EmployeeID == "" {
		return "", who, apperr.Forbidden("только для сотрудников").Uz("faqat xodimlar uchun")
	}
	if err := requireCafe(ctx, s.pool, p.NetworkID); err != nil {
		return "", who, err
	}
	if storeID == "" {
		if !p.SeesAllStores() && len(p.StoreIDs) == 1 {
			storeID = p.StoreIDs[0]
		} else {
			// Одна точка в сети — она и есть.
			rows, err := s.pool.Query(ctx, `SELECT id FROM stores WHERE network_id = $1 AND status = 'active' ORDER BY created_at LIMIT 2`, p.NetworkID)
			if err != nil {
				return "", who, err
			}
			ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
			if err != nil {
				return "", who, err
			}
			if len(ids) == 1 {
				storeID = ids[0]
			}
		}
	}
	if err := s.checkStore(ctx, p, storeID); err != nil {
		return "", who, err
	}
	var own bool
	if err := s.pool.QueryRow(ctx, `SELECT waiter_own_tables FROM networks WHERE id = $1`, p.NetworkID).Scan(&own); err != nil {
		return "", who, err
	}
	who.own = own
	who.senior = p.IsOwner || p.Can(identity.PermSalesReturn)
	return storeID, who, nil
}

// WaiterHall — всё для экрана «Мои столы» (О1): зал, столы с официантом на
// смену, открытые счета (чужие — серыми при «только свои столы»).
type WaiterHall struct {
	HallState
	StoreID string `json:"store_id"`
	Me      string `json:"me"`
	// Старший: видит и ведёт все столы, назначает зоны на смену.
	Senior bool `json:"senior"`
}

func (s *Service) WaiterHall(ctx context.Context, p *identity.Principal, storeID string) (WaiterHall, error) {
	storeID, who, err := s.waiterStore(ctx, p, storeID)
	if err != nil {
		return WaiterHall{}, err
	}
	out := WaiterHall{StoreID: storeID, Me: who.me, Senior: who.senior}
	if out.HallState, err = s.hallState(ctx, p.NetworkID, storeID); err != nil {
		return out, err
	}
	for i := range out.Bills {
		b := &out.Bills[i]
		b.Mine = b.WaiterID != nil && *b.WaiterID == who.me
		involved := (b.TransferTo != nil && *b.TransferTo == who.me) || (b.TransferFrom != nil && *b.TransferFrom == who.me)
		if who.own && !who.senior && !b.Mine && b.WaiterID != nil && !involved {
			// Чужой стол — серый: без позиций и сумм.
			b.Items = []BillItem{}
			b.Subtotal, b.Service, b.Total, b.Paid, b.Ready = "", "", "", "", 0
			b.TransferTo, b.TransferFrom, b.TransferToName, b.TransferFromName, b.TransferReason, b.TransferAt = nil, nil, "", "", "", nil
		}
	}
	return out, nil
}

// WaiterOp — операция со счётом с телефона официанта.
func (s *Service) WaiterOp(ctx context.Context, p *identity.Principal, storeID string, op BillOp) (Bill, error) {
	storeID, who, err := s.waiterStore(ctx, p, storeID)
	if err != nil {
		return Bill{}, err
	}
	return s.applyBillOp(ctx, p, storeID, op, who)
}

// WaiterDish — блюдо для телефона: касса берёт название и цену из своего
// каталога, телефону они приходят вместе с меню.
type WaiterDish struct {
	ProductID string `json:"product_id"`
	Name      string `json:"name"`
	NameRu    string `json:"name_ru"`
	NameUz    string `json:"name_uz"`
	Price     string `json:"price"`
	Image     string `json:"image"`
}

// WaiterMenu — меню точки для телефона: группы, блюда, модификаторы,
// стоп-лист (как блок cafe в /pos/catalog) плюс названия, цены и фото.
type WaiterMenu struct {
	*PosMenu
	Items []WaiterDish `json:"items"`
}

func (s *Service) WaiterMenu(ctx context.Context, p *identity.Principal, storeID string) (WaiterMenu, error) {
	storeID, _, err := s.waiterStore(ctx, p, storeID)
	if err != nil {
		return WaiterMenu{}, err
	}
	menu, err := MenuForPOS(ctx, s.pool, p.NetworkID, storeID)
	if err != nil || menu == nil {
		if err == nil {
			err = errNotCafe
		}
		return WaiterMenu{}, err
	}
	out := WaiterMenu{PosMenu: menu, Items: []WaiterDish{}}
	ids := make([]string, 0, len(menu.Dishes))
	for _, d := range menu.Dishes {
		ids = append(ids, d.ProductID)
	}
	if len(ids) == 0 {
		return out, nil
	}
	// Цена — как на кассе: цена магазина, цена сети, базовая.
	rows, err := s.pool.Query(ctx, `
		SELECT p.id, loc(p.name, p.name_uz), p.name, p.name_uz,
		       COALESCE(sp.price, np.price, p.base_price, 0)::numeric(14,2)::text, COALESCE(p.images[1], '')
		FROM products p
		LEFT JOIN price_types pt ON pt.network_id = $1 AND pt.is_default
		LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = pt.id AND sp.store_id = $2
		LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = pt.id AND np.store_id IS NULL AND np.network_id = $1
		WHERE p.id = ANY($3::uuid[])`, p.NetworkID, storeID, ids)
	if err != nil {
		return out, err
	}
	out.Items, err = pgx.CollectRows(rows, pgx.RowToStructByPos[WaiterDish])
	if out.Items == nil {
		out.Items = []WaiterDish{}
	}
	return out, err
}

// WaiterWait — ждать изменения в точке (как касса и экран кухни).
func (s *Service) WaiterWait(ctx context.Context, p *identity.Principal, hub *events.Hub, storeID string, after int64) (int64, error) {
	storeID, _, err := s.waiterStore(ctx, p, storeID)
	if err != nil {
		return 0, err
	}
	return hub.Wait(ctx, storeID, after, 25*time.Second)
}

// WaiterInfo — официант точки для списков «кому передать» и зон на смену.
type WaiterInfo struct {
	ID       string `json:"id"`
	FullName string `json:"full_name"`
	Me       bool   `json:"me"`
	// Сколько столов за ним сегодня (зоны на смену или постоянные).
	Tables int `json:"tables"`
}

func (s *Service) WaiterList(ctx context.Context, p *identity.Principal, storeID string) ([]WaiterInfo, error) {
	storeID, who, err := s.waiterStore(ctx, p, storeID)
	if err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT e.id, e.full_name,
		       (SELECT count(*) FROM cafe_tables t LEFT JOIN cafe_shift_waiters sw ON sw.table_id = t.id AND sw.day = `+todaySQL+`
		        WHERE t.store_id = $2 AND t.is_active AND COALESCE(sw.waiter_id, t.waiter_id) = e.id)
		FROM employees e JOIN roles r ON r.id = e.role_id
		WHERE e.network_id = $1 AND e.status = 'active' AND (r.is_owner OR $3 = ANY(r.permissions))
		  AND (e.all_stores OR EXISTS (SELECT 1 FROM employee_stores es WHERE es.employee_id = e.id AND es.store_id = $2))
		ORDER BY e.full_name`, p.NetworkID, storeID, identity.PermCafeWaiter)
	if err != nil {
		return nil, err
	}
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (WaiterInfo, error) {
		var w WaiterInfo
		err := r.Scan(&w.ID, &w.FullName, &w.Tables)
		w.Me = w.ID == who.me
		return w, err
	})
	if list == nil {
		list = []WaiterInfo{}
	}
	return list, err
}

// ZoneInput — зоны на смену (О8): стол → официант на сегодня.
type ZoneInput struct {
	StoreID string `json:"store_id"`
	// Полный список на сегодня: стол без записи — постоянный официант стола.
	Assignments []ZoneAssignment `json:"assignments"`
	// «Как вчера» — повторить последнее назначение (assignments не нужны).
	LikeYesterday bool `json:"like_yesterday"`
}

type ZoneAssignment struct {
	TableID  string `json:"table_id"`
	WaiterID string `json:"waiter_id"`
}

// SetZones — старший сохраняет зоны на смену. Уже открытые столы не
// переезжают — только новые.
func (s *Service) SetZones(ctx context.Context, p *identity.Principal, in ZoneInput) (WaiterHall, error) {
	storeID, who, err := s.waiterStore(ctx, p, in.StoreID)
	if err != nil {
		return WaiterHall{}, err
	}
	if !who.senior {
		return WaiterHall{}, apperr.Forbidden("зоны на смену назначает старший").Uz("smena zonalarini katta xodim belgilaydi")
	}
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if in.LikeYesterday {
			_, err := tx.Exec(ctx, `
				WITH last AS (SELECT max(day) AS day FROM cafe_shift_waiters WHERE store_id = $1 AND day < `+todaySQL+`),
				del AS (DELETE FROM cafe_shift_waiters WHERE store_id = $1 AND day = `+todaySQL+`)
				INSERT INTO cafe_shift_waiters (store_id, day, table_id, waiter_id, set_by)
				SELECT sw.store_id, `+todaySQL+`, sw.table_id, sw.waiter_id, NULLIF($2, '')::uuid
				FROM cafe_shift_waiters sw, last WHERE sw.store_id = $1 AND sw.day = last.day
				  AND EXISTS (SELECT 1 FROM cafe_tables t WHERE t.id = sw.table_id AND t.is_active)
				  AND EXISTS (SELECT 1 FROM employees e WHERE e.id = sw.waiter_id AND e.status = 'active')`, storeID, p.EmployeeID)
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM cafe_shift_waiters WHERE store_id = $1 AND day = `+todaySQL, storeID); err != nil {
			return err
		}
		seen := map[string]bool{}
		for _, a := range in.Assignments {
			if !httpx.IsUUID(a.TableID) || seen[a.TableID] {
				return apperr.Validation("assignments: стол не найден или повторяется").Uz("assignments: stol topilmadi yoki takrorlanadi")
			}
			seen[a.TableID] = true
			if err := checkWaiter(ctx, tx, p.NetworkID, storeID, a.WaiterID); err != nil {
				return err
			}
			tag, err := tx.Exec(ctx, `
				INSERT INTO cafe_shift_waiters (store_id, day, table_id, waiter_id, set_by)
				SELECT $1, `+todaySQL+`, t.id, $3, NULLIF($4, '')::uuid FROM cafe_tables t WHERE t.id = $2 AND t.store_id = $1 AND t.is_active`,
				storeID, a.TableID, a.WaiterID, p.EmployeeID)
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 0 {
				return apperr.Validation("assignments: стол не найден").Uz("assignments: stol topilmadi")
			}
		}
		return nil
	})
	if err != nil {
		return WaiterHall{}, err
	}
	if _, err := events.Bump(ctx, s.pool, storeID); err != nil {
		return WaiterHall{}, err
	}
	return s.WaiterHall(ctx, p, storeID)
}

// MySales — «Мои продажи» за день: закрытые столы официанта, гости, выручка,
// обслуживание (выручка стола — на официанта счёта, О5).
type MySales struct {
	Date    string `json:"date"`
	Bills   int    `json:"bills"`
	Guests  int    `json:"guests"`
	Total   string `json:"total"`
	Service string `json:"service"`
	// Открытые сейчас столы официанта.
	Open int `json:"open"`
}

func (s *Service) MySales(ctx context.Context, p *identity.Principal, storeID, date string) (MySales, error) {
	storeID, who, err := s.waiterStore(ctx, p, storeID)
	if err != nil {
		return MySales{}, err
	}
	day := time.Now().In(tashkent).Format("2006-01-02")
	if date != "" {
		if _, err := time.Parse("2006-01-02", date); err != nil {
			return MySales{}, apperr.Validation("date: ГГГГ-ММ-ДД").Uz("date: YYYY-MM-DD")
		}
		day = date
	}
	out := MySales{Date: day}
	err = s.pool.QueryRow(ctx, `
		SELECT count(*), COALESCE(sum(b.guests), 0),
		       COALESCE(sum((SELECT sum(sa.total) FROM sales sa WHERE sa.bill_id = b.id)), 0)::numeric(14,2)::text,
		       COALESCE(sum((SELECT sum(sa.service_amount) FROM sales sa WHERE sa.bill_id = b.id)), 0)::numeric(14,2)::text,
		       (SELECT count(*) FROM bills o WHERE o.store_id = $1 AND o.waiter_id = $2 AND o.status = 'open')
		FROM bills b
		WHERE b.store_id = $1 AND b.waiter_id = $2 AND b.status = 'closed'
		  AND (b.closed_at AT TIME ZONE 'Asia/Tashkent')::date = $3::date`, storeID, who.me, day).
		Scan(&out.Bills, &out.Guests, &out.Total, &out.Service, &out.Open)
	return out, err
}

var tashkent = func() *time.Location {
	l, err := time.LoadLocation("Asia/Tashkent")
	if err != nil {
		return time.FixedZone("UZT", 5*3600)
	}
	return l
}()

func plural(n int, one, few, many string) string {
	n10, n100 := n%10, n%100
	switch {
	case n10 == 1 && n100 != 11:
		return one
	case n10 >= 2 && n10 <= 4 && (n100 < 10 || n100 >= 20):
		return few
	}
	return many
}
