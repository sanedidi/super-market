package cafe

// Кухня (Figma «Кухня» КХ1–КХ4, план «Кафе», этап 4): бегунки по цехам,
// экран кухни, экран выдачи для гостей, стоп-лист с кухни, состояние
// принтеров цехов. Устройства — кассы другого вида (pos_devices.kind), о
// переменах узнают ожиданием версии событий магазина (platform/events).

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/events"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Продажа, дошедшая до сервера позже (касса была без интернета), старше
// этого — уже не заказ для кухни: бегунок напечатала касса.
const ticketMaxAge = 3 * time.Hour

// Виды устройств (pos_devices.kind).
const (
	devicePOS     = "pos"
	deviceKitchen = "kitchen"
	deviceDisplay = "display"
)

type KitchenMod struct {
	Name   string `json:"name"`
	Action string `json:"action"`
	Qty    int    `json:"qty"`
}

// --------------------------------------------------- бегунки при продаже

// CreateTickets делит заказ кафе по цехам. Вызывается в транзакции продажи;
// продажа без номера заказа (магазин, старая касса) бегунков не получает.
// Цех без экрана кухни получает бегунок сразу «выдан» — его печатает касса.
func CreateTickets(ctx context.Context, tx pgx.Tx, saleID string) error {
	var networkID, storeID, orderType, cashier string
	var orderNo *int
	var soldAt time.Time
	err := tx.QueryRow(ctx, `
		SELECT s.network_id, s.store_id, s.order_no, COALESCE(s.order_type, 'here'), s.sold_at, COALESCE(e.full_name, '')
		FROM sales s LEFT JOIN employees e ON e.id = s.cashier_id WHERE s.id = $1`, saleID).
		Scan(&networkID, &storeID, &orderNo, &orderType, &soldAt, &cashier)
	if err != nil {
		return err
	}
	if orderNo == nil || time.Since(soldAt) > ticketMaxAge {
		return nil
	}
	type line struct {
		line                         int
		productID, name, nameUz, qty string
		note                         string
		workshopID                   *string
		cook                         int
		mods                         []KitchenMod
	}
	rows, err := tx.Query(ctx, `
		SELECT x.line, x.product_id, x.name, x.name_uz, x.qty, x.note, x.wid, COALESCE(x.cook, w.cook_minutes, 15)
		FROM (SELECT si.line, si.product_id, p.name, p.name_uz, trim_scale(si.qty)::text AS qty, si.note, p.cook_minutes AS cook,
		             COALESCE(p.workshop_id, g.workshop_id,
		                      (SELECT d.id FROM workshops d WHERE d.network_id = p.network_id AND d.is_default)) AS wid
		      FROM sale_items si JOIN products p ON p.id = si.product_id
		      LEFT JOIN menu_groups g ON g.id = p.menu_group_id
		      WHERE si.sale_id = $1 AND p.kind = 'dish') x
		LEFT JOIN workshops w ON w.id = x.wid
		ORDER BY x.line`, saleID)
	if err != nil {
		return err
	}
	lines, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (line, error) {
		var l line
		err := r.Scan(&l.line, &l.productID, &l.name, &l.nameUz, &l.qty, &l.note, &l.workshopID, &l.cook)
		l.mods = []KitchenMod{}
		return l, err
	})
	if err != nil || len(lines) == 0 {
		return err
	}
	byLine := map[int]int{}
	for i, l := range lines {
		byLine[l.line] = i
	}
	mrows, err := tx.Query(ctx, `
		SELECT m.line, m.name, m.qty, COALESCE(o.action, 'none')
		FROM sale_item_modifiers m LEFT JOIN modifier_options o ON o.id = m.option_id
		WHERE m.sale_id = $1 ORDER BY m.line, m.name`, saleID)
	if err != nil {
		return err
	}
	for mrows.Next() {
		var ln int
		var m KitchenMod
		if err := mrows.Scan(&ln, &m.Name, &m.Qty, &m.Action); err != nil {
			mrows.Close()
			return err
		}
		if i, ok := byLine[ln]; ok {
			lines[i].mods = append(lines[i].mods, m)
		}
	}
	mrows.Close()
	if err := mrows.Err(); err != nil {
		return err
	}

	// Какие цеха смотрят на экран: экран без цеха — все цеха.
	srows, err := tx.Query(ctx, `
		SELECT workshop_id::text FROM pos_devices
		WHERE store_id = $1 AND kind = 'kitchen' AND revoked_at IS NULL AND token_hash IS NOT NULL`, storeID)
	if err != nil {
		return err
	}
	screens, err := pgx.CollectRows(srows, pgx.RowTo[*string])
	if err != nil {
		return err
	}
	allScreen := false
	screenOf := map[string]bool{}
	for _, w := range screens {
		if w == nil {
			allScreen = true
		} else {
			screenOf[*w] = true
		}
	}

	type group struct {
		workshopID *string
		cook       int
		lines      []line
	}
	var groups []*group
	idx := map[string]*group{}
	for _, l := range lines {
		key := ""
		if l.workshopID != nil {
			key = *l.workshopID
		}
		g := idx[key]
		if g == nil {
			g = &group{workshopID: l.workshopID}
			idx[key] = g
			groups = append(groups, g)
		}
		g.lines = append(g.lines, l)
		if l.cook > g.cook {
			g.cook = l.cook
		}
	}
	tracked := false
	for _, g := range groups {
		status := "served"
		if allScreen || (g.workshopID != nil && screenOf[*g.workshopID]) {
			status, tracked = "new", true
		}
		var ticketID string
		err := tx.QueryRow(ctx, `
			INSERT INTO kitchen_tickets (network_id, store_id, sale_id, workshop_id, order_no, order_type, status,
			                             cook_minutes, cashier_name, paid_at, served_at, order_key)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, CASE WHEN $7 = 'served' THEN now() END, $11)
			ON CONFLICT (sale_id, workshop_id) DO NOTHING
			RETURNING id`,
			networkID, storeID, saleID, g.workshopID, orderNo, orderType, status, g.cook, cashier, soldAt, saleID).Scan(&ticketID)
		if errors.Is(err, pgx.ErrNoRows) {
			continue
		}
		if err != nil {
			return err
		}
		for _, l := range g.lines {
			mods, _ := json.Marshal(l.mods)
			if _, err := tx.Exec(ctx, `
				INSERT INTO kitchen_ticket_items (ticket_id, line, product_id, name, name_uz, qty, mods, note)
				VALUES ($1, $2, $3, $4, $5, $6::numeric, $7, $8)`,
				ticketID, l.line, l.productID, l.name, l.nameUz, l.qty, mods, l.note); err != nil {
				return err
			}
		}
	}
	if tracked {
		_, err = events.Bump(ctx, tx, storeID)
	}
	return err
}

// CancelTicketLines — возврат по заказу кафе: возвращённое количество строки
// уходит на кухню как «ОТМЕНА», заказ без строк — отменён. Вызывается в
// транзакции возврата; returned — строка продажи → сколько вернули сейчас.
func CancelTicketLines(ctx context.Context, tx pgx.Tx, saleID string, returned map[int]string) error {
	if len(returned) == 0 {
		return nil
	}
	var storeID string
	err := tx.QueryRow(ctx, `SELECT store_id FROM kitchen_tickets WHERE sale_id = $1 AND status IN ('new', 'cooking', 'ready') LIMIT 1`,
		saleID).Scan(&storeID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil // на кухне заказа уже нет (выдан) или не было
	}
	if err != nil {
		return err
	}
	for line, qty := range returned {
		if _, err := tx.Exec(ctx, `
			UPDATE kitchen_ticket_items i SET cancelled_qty = LEAST(i.qty, i.cancelled_qty + $3::numeric)
			FROM kitchen_tickets t
			WHERE t.id = i.ticket_id AND t.sale_id = $1 AND i.line = $2 AND t.status IN ('new', 'cooking', 'ready')`,
			saleID, line, qty); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(ctx, `
		UPDATE kitchen_tickets t SET status = 'cancelled', cancelled_at = now()
		WHERE t.sale_id = $1 AND t.status IN ('new', 'cooking', 'ready')
		  AND NOT EXISTS (SELECT 1 FROM kitchen_ticket_items i WHERE i.ticket_id = t.id AND i.cancelled_qty < i.qty)`, saleID); err != nil {
		return err
	}
	_, err = events.Bump(ctx, tx, storeID)
	return err
}

// ------------------------------------------------------- экран кухни

type KitchenItem struct {
	ID           string       `json:"id"`
	Line         int          `json:"line"`
	ProductID    string       `json:"product_id"`
	Name         string       `json:"name"`
	Qty          string       `json:"qty"`
	Mods         []KitchenMod `json:"mods"`
	Note         string       `json:"note"`
	Done         bool         `json:"done"`
	CancelledQty string       `json:"cancelled_qty"`
}

type KitchenTicket struct {
	ID          string        `json:"id"`
	WorkshopID  *string       `json:"workshop_id"`
	Status      string        `json:"status"`
	CookMinutes int           `json:"cook_minutes"`
	StartedAt   *time.Time    `json:"started_at"`
	ReadyAt     *time.Time    `json:"ready_at"`
	CancelledAt *time.Time    `json:"cancelled_at"`
	Items       []KitchenItem `json:"items"`
	// Ждёт печати на кассе (отправка с телефона, цех без экрана).
	PrintPending bool `json:"print_pending"`
}

// KitchenOrder — заказ на экране кухни: бегунки всех цехов (экран цеха
// показывает свои позиции и «+ N позиций в баре»).
type KitchenOrder struct {
	// Карточка: продажа у прилавка или отправка счёта стола «На кухню».
	ID      string  `json:"id"`
	SaleID  string  `json:"sale_id"`
	BillID  *string `json:"bill_id"`
	OrderNo *int    `json:"order_no"`
	// Стол: «Стол 7», официант.
	TableLabel string    `json:"table_label"`
	Waiter     string    `json:"waiter"`
	OrderType  string    `json:"order_type"`
	PaidAt     time.Time `json:"paid_at"`
	Cashier    string    `json:"cashier"`
	// waiting («по команде») · new · cooking · ready · served · cancelled.
	Status  string          `json:"status"`
	ReadyAt *time.Time      `json:"ready_at"`
	Tickets []KitchenTicket `json:"tickets"`
}

type KitchenBoard struct {
	Version int64     `json:"version"`
	Now     time.Time `json:"now"`
	// Цех экрана (nil — все цеха, вкладки выбирает повар).
	WorkshopID *string        `json:"workshop_id"`
	Orders     []KitchenOrder `json:"orders"`
}

func deviceStore(p *identity.Principal) (string, error) {
	if p.DeviceID == "" || len(p.StoreIDs) != 1 {
		return "", apperr.Forbidden("только для устройств кафе").Uz("faqat kafe qurilmalari uchun")
	}
	return p.StoreIDs[0], nil
}

// orderStatus — состояние заказа по бегункам с экраном: готовится, пока
// хоть один цех не готов; готов — когда все готовы.
func orderStatus(ts []KitchenTicket) (string, *time.Time) {
	var anyNew, anyCooking, anyReady, anyServed, anyWaiting bool
	var readyAt *time.Time
	for _, t := range ts {
		switch t.Status {
		case "waiting":
			anyWaiting = true
		case "new":
			anyNew = true
		case "cooking":
			anyCooking = true
		case "ready":
			anyReady = true
			if t.ReadyAt != nil && (readyAt == nil || t.ReadyAt.After(*readyAt)) {
				readyAt = t.ReadyAt
			}
		case "served":
			// Бегунок без экрана (сразу «выдан») на состояние не влияет.
			if t.ReadyAt != nil {
				anyServed = true
			}
		}
	}
	switch {
	case anyNew && !anyCooking && !anyReady && !anyServed:
		return "new", nil
	case anyNew || anyCooking:
		return "cooking", nil
	case anyReady:
		return "ready", readyAt
	case anyServed:
		return "served", nil
	case anyWaiting:
		return "waiting", nil
	}
	return "cancelled", nil
}

// loadOrders — заказы магазина по условию на бегунки (where — про t).
func loadOrders(ctx context.Context, q db.Querier, storeID, where string, args ...any) ([]KitchenOrder, error) {
	all := append([]any{storeID}, args...)
	rows, err := q.Query(ctx, `
		SELECT t.id, t.order_key, COALESCE(t.sale_id::text, ''), t.bill_id, t.table_label, t.waiter_name, t.workshop_id,
		       t.order_no, t.order_type, t.status, t.cook_minutes, t.cashier_name,
		       t.paid_at, t.started_at, t.ready_at, t.cancelled_at, t.print_pending
		FROM kitchen_tickets t
		WHERE t.store_id = $1 AND t.order_key IN (SELECT t.order_key FROM kitchen_tickets t WHERE t.store_id = $1 AND (`+where+`))
		ORDER BY t.paid_at, t.order_key, t.workshop_id NULLS FIRST`, all...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var orders []KitchenOrder
	at := map[string]int{}
	ticketAt := map[string][2]int{}
	var ids []string
	for rows.Next() {
		var t KitchenTicket
		var o KitchenOrder
		if err := rows.Scan(&t.ID, &o.ID, &o.SaleID, &o.BillID, &o.TableLabel, &o.Waiter, &t.WorkshopID, &o.OrderNo, &o.OrderType,
			&t.Status, &t.CookMinutes, &o.Cashier, &o.PaidAt, &t.StartedAt, &t.ReadyAt, &t.CancelledAt, &t.PrintPending); err != nil {
			return nil, err
		}
		t.Items = []KitchenItem{}
		i, ok := at[o.ID]
		if !ok {
			i = len(orders)
			at[o.ID] = i
			orders = append(orders, o)
		}
		ticketAt[t.ID] = [2]int{i, len(orders[i].Tickets)}
		orders[i].Tickets = append(orders[i].Tickets, t)
		ids = append(ids, t.ID)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()
	if len(ids) == 0 {
		return []KitchenOrder{}, nil
	}
	irows, err := q.Query(ctx, `
		SELECT i.ticket_id, i.id, i.line, i.product_id, loc(i.name, i.name_uz), trim_scale(i.qty)::text, i.mods, i.note, i.done,
		       trim_scale(i.cancelled_qty)::text
		FROM kitchen_ticket_items i WHERE i.ticket_id = ANY($1::uuid[]) ORDER BY i.line`, ids)
	if err != nil {
		return nil, err
	}
	defer irows.Close()
	for irows.Next() {
		var tid string
		var it KitchenItem
		var mods []byte
		if err := irows.Scan(&tid, &it.ID, &it.Line, &it.ProductID, &it.Name, &it.Qty, &mods, &it.Note, &it.Done, &it.CancelledQty); err != nil {
			return nil, err
		}
		it.Mods = []KitchenMod{}
		_ = json.Unmarshal(mods, &it.Mods)
		pos := ticketAt[tid]
		t := &orders[pos[0]].Tickets[pos[1]]
		t.Items = append(t.Items, it)
	}
	if err := irows.Err(); err != nil {
		return nil, err
	}
	for i := range orders {
		orders[i].Status, orders[i].ReadyAt = orderStatus(orders[i].Tickets)
	}
	return orders, nil
}

// Board — заказы на экране кухни: не выданные и недавно отменённые.
func (s *Service) Board(ctx context.Context, p *identity.Principal) (KitchenBoard, error) {
	storeID, err := deviceStore(p)
	if err != nil {
		return KitchenBoard{}, err
	}
	out := KitchenBoard{Now: s.now().UTC()}
	if p.DeviceWorkshopID != "" {
		w := p.DeviceWorkshopID
		out.WorkshopID = &w
	}
	// Версия — до чтения: изменение во время чтения придёт следующим ожиданием.
	if out.Version, err = events.Version(ctx, s.pool, storeID); err != nil {
		return out, err
	}
	// Отменённый заказ виден ещё 10 минут — «ОТМЕНА».
	out.Orders, err = loadOrders(ctx, s.pool, storeID,
		`t.status IN ('waiting', 'new', 'cooking', 'ready') OR (t.status = 'cancelled' AND t.cancelled_at > now() - $2::interval)`,
		"10 minutes")
	return out, err
}

type KitchenActionInput struct {
	// start — «Начать готовить», ready — «Готово», served — «Выдано» /
	// «Отдано курьеру», back — вернуть «готово» в «готовится».
	Action string `json:"action"`
	// Цех вкладки на экране «Все цеха» (пусто — все цеха заказа).
	WorkshopID string `json:"workshop_id"`
}

// Act — кнопка на карточке заказа. Повтор безопасен: уже сделанное не меняется.
func (s *Service) Act(ctx context.Context, p *identity.Principal, orderKey string, in KitchenActionInput) (KitchenBoard, error) {
	storeID, err := deviceStore(p)
	if err != nil {
		return KitchenBoard{}, err
	}
	if p.DeviceKind == deviceDisplay {
		return KitchenBoard{}, apperr.Forbidden("экран выдачи только показывает номера").Uz("berish ekrani faqat raqamlarni koʻrsatadi")
	}
	if !validOrderKey(orderKey) {
		return KitchenBoard{}, apperr.NotFound("заказ не найден").Uz("buyurtma topilmadi")
	}
	ws := in.WorkshopID
	if p.DeviceWorkshopID != "" {
		ws = p.DeviceWorkshopID
	}
	if ws != "" && !httpx.IsUUID(ws) {
		return KitchenBoard{}, apperr.Validation("workshop_id: цех не найден").Uz("workshop_id: sex topilmadi")
	}
	var sql string
	switch in.Action {
	case "start":
		sql = `UPDATE kitchen_tickets SET status = 'cooking', started_at = now()
			WHERE order_key = $1 AND store_id = $2 AND status = 'new' AND ($3 = '' OR workshop_id::text = $3)`
	case "ready":
		sql = `UPDATE kitchen_tickets SET status = 'ready', started_at = COALESCE(started_at, now()), ready_at = now()
			WHERE order_key = $1 AND store_id = $2 AND status IN ('new', 'cooking') AND ($3 = '' OR workshop_id::text = $3)`
	case "back":
		sql = `UPDATE kitchen_tickets SET status = 'cooking', ready_at = NULL
			WHERE order_key = $1 AND store_id = $2 AND status = 'ready' AND ($3 = '' OR workshop_id::text = $3)`
	case "served":
		// Выдают заказ целиком — все цеха.
		sql = `UPDATE kitchen_tickets SET status = 'served', served_at = now(),
			       started_at = COALESCE(started_at, now()), ready_at = COALESCE(ready_at, now())
			WHERE order_key = $1 AND store_id = $2 AND status IN ('new', 'cooking', 'ready') AND ($3 = '' OR $3 <> '')`
	default:
		return KitchenBoard{}, apperr.Validation("action: ожидается start, ready, back или served").Uz("action: start, ready, back yoki served boʻlishi kerak")
	}
	var pushes []waiterPush
	if err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		pushes = nil
		tag, err := tx.Exec(ctx, sql, orderKey, storeID, ws)
		if err != nil || tag.RowsAffected() == 0 {
			return err
		}
		if in.Action == "ready" {
			if pushes, err = readyPushes(ctx, tx, storeID, orderKey); err != nil {
				return err
			}
		}
		_, err = events.Bump(ctx, tx, storeID)
		return err
	}); err != nil {
		return KitchenBoard{}, err
	}
	s.sendPushes(ctx, pushes)
	return s.Board(ctx, p)
}

type ItemDoneInput struct {
	Done bool `json:"done"`
}

// ItemDone — галочка у позиции на карточке.
func (s *Service) ItemDone(ctx context.Context, p *identity.Principal, itemID string, in ItemDoneInput) (KitchenBoard, error) {
	storeID, err := deviceStore(p)
	if err != nil {
		return KitchenBoard{}, err
	}
	if p.DeviceKind == deviceDisplay || !httpx.IsUUID(itemID) {
		return KitchenBoard{}, apperr.NotFound("позиция не найдена").Uz("pozitsiya topilmadi")
	}
	if err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
			UPDATE kitchen_ticket_items i SET done = $3 FROM kitchen_tickets t
			WHERE i.id = $1 AND t.id = i.ticket_id AND t.store_id = $2 AND i.done <> $3`, itemID, storeID, in.Done)
		if err != nil || tag.RowsAffected() == 0 {
			return err
		}
		_, err = events.Bump(ctx, tx, storeID)
		return err
	}); err != nil {
		return KitchenBoard{}, err
	}
	return s.Board(ctx, p)
}

// validOrderKey — карточка кухни: id продажи или «id счёта-номер отправки».
func validOrderKey(k string) bool {
	if httpx.IsUUID(k) {
		return true
	}
	if len(k) < 38 || len(k) > 46 || k[36] != '-' || !httpx.IsUUID(k[:36]) {
		return false
	}
	for _, c := range k[37:] {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// ------------------------------------------------------ экран выдачи

type DisplayBoard struct {
	Version     int64  `json:"version"`
	StoreName   string `json:"store_name"`
	ShowCooking bool   `json:"show_cooking"`
	// Номера заказов: «Готовим» и «Готово — заберите».
	Cooking []int `json:"cooking"`
	Ready   []int `json:"ready"`
}

// Display — номера для гостей. Готовый номер убирается после «Выдано» или
// через display_hide_minutes после «Готово».
func (s *Service) Display(ctx context.Context, p *identity.Principal) (DisplayBoard, error) {
	storeID, err := deviceStore(p)
	if err != nil {
		return DisplayBoard{}, err
	}
	out := DisplayBoard{Cooking: []int{}, Ready: []int{}}
	var hide int
	if err := s.pool.QueryRow(ctx, `
		SELECT st.name, n.display_show_cooking, n.display_hide_minutes
		FROM stores st JOIN networks n ON n.id = st.network_id WHERE st.id = $1`, storeID).
		Scan(&out.StoreName, &out.ShowCooking, &hide); err != nil {
		return out, err
	}
	if out.Version, err = events.Version(ctx, s.pool, storeID); err != nil {
		return out, err
	}
	orders, err := loadOrders(ctx, s.pool, storeID, `t.status IN ('new', 'cooking', 'ready') AND t.order_no IS NOT NULL`)
	if err != nil {
		return out, err
	}
	now := s.now()
	for _, o := range orders {
		if o.OrderNo == nil {
			continue
		}
		switch o.Status {
		case "new", "cooking":
			out.Cooking = append(out.Cooking, *o.OrderNo)
		case "ready":
			if o.ReadyAt == nil || now.Sub(*o.ReadyAt) < time.Duration(hide)*time.Minute {
				out.Ready = append(out.Ready, *o.OrderNo)
			}
		}
	}
	return out, nil
}

// ---------------------------------------------------- стоп-лист с кухни

type KitchenStopInput struct {
	ProductID string `json:"product_id"`
	Stopped   bool   `json:"stopped"`
}

// KitchenStop — повар ставит блюдо на стоп (или снимает): касса увидит
// плитку «стоп-лист», приложение покупателя скроет блюдо.
func (s *Service) KitchenStop(ctx context.Context, p *identity.Principal, in KitchenStopInput) ([]string, error) {
	storeID, err := deviceStore(p)
	if err != nil {
		return nil, err
	}
	if p.DeviceKind == deviceDisplay {
		return nil, apperr.Forbidden("экран выдачи только показывает номера").Uz("berish ekrani faqat raqamlarni koʻrsatadi")
	}
	if !httpx.IsUUID(in.ProductID) {
		return nil, apperr.Validation("product_id: блюдо не найдено").Uz("product_id: taom topilmadi")
	}
	if err := setStop(ctx, s.pool, p.NetworkID, storeID, in.ProductID, in.Stopped, ""); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `SELECT product_id::text FROM stop_list WHERE store_id = $1 ORDER BY created_at`, storeID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

// setStop — поставить на стоп или снять; версия событий растёт, если что-то
// поменялось. employeeID — кто поставил (пусто — экран кухни).
func setStop(ctx context.Context, pool *pgxpool.Pool, networkID, storeID, productID string, stopped bool, employeeID string) error {
	return db.InTx(ctx, pool, func(tx pgx.Tx) error {
		var n int64
		if stopped {
			tag, err := tx.Exec(ctx, `
				INSERT INTO stop_list (store_id, product_id, created_by)
				SELECT $1, id, NULLIF($3, '')::uuid FROM products WHERE id = $2 AND (network_id IS NULL OR network_id = $4)
				ON CONFLICT DO NOTHING`, storeID, productID, employeeID, networkID)
			if err != nil {
				return err
			}
			n = tag.RowsAffected()
		} else {
			tag, err := tx.Exec(ctx, `DELETE FROM stop_list WHERE store_id = $1 AND product_id = $2`, storeID, productID)
			if err != nil {
				return err
			}
			n = tag.RowsAffected()
		}
		if n == 0 {
			return nil
		}
		_, err := events.Bump(ctx, tx, storeID)
		return err
	})
}

// ------------------------------------------------- ожидание изменений

// Wait — версия событий магазина устройства, как только она больше after.
func (s *Service) Wait(ctx context.Context, p *identity.Principal, hub *events.Hub, after int64) (int64, error) {
	storeID, err := deviceStore(p)
	if err != nil {
		return 0, err
	}
	return hub.Wait(ctx, storeID, after, 25*time.Second)
}

// ------------------------------------------------ касса кафе и принтеры

type PrintTest struct {
	WorkshopID string    `json:"workshop_id"`
	At         time.Time `json:"at"`
}

// KitchenStatus — для кассы кафе: какие цеха сейчас видят экран кухни (иначе
// бегунок печатает касса), запросы «Тест печати» из панели, стоп-лист.
type KitchenStatus struct {
	Version int64 `json:"version"`
	// id цеха → экран в сети; "*" — экран всех цехов.
	Screens    map[string]bool `json:"screens"`
	PrintTests []PrintTest     `json:"print_tests"`
	Stop       []string        `json:"stop"`
	// Бегунки цехов без экрана, отправленные с телефона официанта: касса
	// печатает и отмечает POST /pos/kitchen/printed.
	Print []KitchenOrder `json:"print"`
}

func (s *Service) Status(ctx context.Context, p *identity.Principal) (KitchenStatus, error) {
	storeID, err := deviceStore(p)
	if err != nil {
		return KitchenStatus{}, err
	}
	out := KitchenStatus{Screens: map[string]bool{}, PrintTests: []PrintTest{}}
	if out.Version, err = events.Version(ctx, s.pool, storeID); err != nil {
		return out, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT COALESCE(workshop_id::text, '*'), bool_or(last_seen_at > now() - interval '2 minutes')
		FROM pos_devices WHERE store_id = $1 AND kind = 'kitchen' AND revoked_at IS NULL AND token_hash IS NOT NULL
		GROUP BY 1`, storeID)
	if err != nil {
		return out, err
	}
	for rows.Next() {
		var id string
		var on *bool
		if err := rows.Scan(&id, &on); err != nil {
			rows.Close()
			return out, err
		}
		out.Screens[id] = on != nil && *on
	}
	rows.Close()
	rows, err = s.pool.Query(ctx, `SELECT id::text, printer_test_at FROM workshops
		WHERE network_id = $1 AND printer_test_at > now() - interval '10 minutes'`, p.NetworkID)
	if err != nil {
		return out, err
	}
	if out.PrintTests, err = pgx.CollectRows(rows, pgx.RowToStructByPos[PrintTest]); err != nil {
		return out, err
	}
	rows, err = s.pool.Query(ctx, `SELECT product_id::text FROM stop_list WHERE store_id = $1 ORDER BY created_at`, storeID)
	if err != nil {
		return out, err
	}
	out.Stop, err = pgx.CollectRows(rows, pgx.RowTo[string])
	if out.Stop == nil {
		out.Stop = []string{}
	}
	if err != nil {
		return out, err
	}
	if p.DeviceKind == devicePOS || p.DeviceKind == "" {
		if out.Print, err = loadOrders(ctx, s.pool, storeID, `t.print_pending AND t.created_at > now() - interval '3 hours'`); err != nil {
			return out, err
		}
		// Карточка — вся отправка; печатать нужно только бегунки с флагом.
		for i := range out.Print {
			kept := out.Print[i].Tickets[:0]
			for _, t := range out.Print[i].Tickets {
				if t.PrintPending {
					kept = append(kept, t)
				}
			}
			out.Print[i].Tickets = kept
		}
	}
	if out.Print == nil {
		out.Print = []KitchenOrder{}
	}
	return out, nil
}

type PrintedInput struct {
	TicketIDs []string `json:"ticket_ids"`
}

// Printed — касса напечатала бегунки, отправленные с телефона официанта.
func (s *Service) Printed(ctx context.Context, p *identity.Principal, in PrintedInput) error {
	storeID, err := deviceStore(p)
	if err != nil {
		return err
	}
	ids := make([]string, 0, len(in.TicketIDs))
	for _, id := range in.TicketIDs {
		if httpx.IsUUID(id) {
			ids = append(ids, id)
		}
	}
	if len(ids) == 0 {
		return nil
	}
	_, err = s.pool.Exec(ctx, `UPDATE kitchen_tickets SET print_pending = false WHERE store_id = $1 AND id = ANY($2::uuid[])`, storeID, ids)
	return err
}

type PrinterReport struct {
	WorkshopID string `json:"workshop_id"`
	OK         bool   `json:"ok"`
	// Бегунков ждут печати (принтер не отвечает).
	Pending int `json:"pending"`
}

// ReportPrinters — касса сообщает, печатает ли принтер цеха (панель П7:
// «в сети», «нет связи с принтером», «2 бегунка не напечатаны»).
func (s *Service) ReportPrinters(ctx context.Context, p *identity.Principal, in []PrinterReport) error {
	if _, err := deviceStore(p); err != nil {
		return err
	}
	if len(in) > 50 {
		return apperr.Validation("слишком много цехов").Uz("sexlar juda koʻp")
	}
	for _, r := range in {
		if !httpx.IsUUID(r.WorkshopID) || r.Pending < 0 || r.Pending > 10000 {
			return apperr.Validation("workshop_id: цех не найден").Uz("workshop_id: sex topilmadi")
		}
		if _, err := s.pool.Exec(ctx, `UPDATE workshops SET printer_ok = $3, printer_pending = $4, printer_seen_at = now()
			WHERE id = $1 AND network_id = $2`, r.WorkshopID, p.NetworkID, r.OK, r.Pending); err != nil {
			return err
		}
	}
	return nil
}

// --------------------------------------------- панель: «Тест печати»

// TestPrint — касса магазина распечатает тестовый бегунок цеха.
func (s *Service) TestPrint(ctx context.Context, p *identity.Principal, workshopID string) (Workshop, error) {
	if err := s.manage(ctx, p); err != nil {
		return Workshop{}, err
	}
	if !httpx.IsUUID(workshopID) {
		return Workshop{}, apperr.NotFound("цех не найден").Uz("sex topilmadi")
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE workshops SET printer_test_at = now(), printer_ok = NULL WHERE id = $1 AND network_id = $2`,
			workshopID, p.NetworkID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.NotFound("цех не найден").Uz("sex topilmadi")
		}
		return bumpNetwork(ctx, tx, p.NetworkID)
	})
	if err != nil {
		return Workshop{}, err
	}
	return getWorkshop(ctx, s.pool, p.NetworkID, workshopID)
}

// bumpNetwork — изменение для всех точек сети (цеха, принтеры, настройки кухни).
func bumpNetwork(ctx context.Context, tx pgx.Tx, networkID string) error {
	rows, err := tx.Query(ctx, `SELECT id::text FROM stores WHERE network_id = $1`, networkID)
	if err != nil {
		return err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	sort.Strings(ids)
	for _, id := range ids {
		if _, err := events.Bump(ctx, tx, id); err != nil {
			return err
		}
	}
	return nil
}
