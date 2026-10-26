package cafe

// Залы, столы и открытый счёт (план «Кафе», этап 5; Figma С1–С9, П9, П10).
//
// Счёт стола дописывают кассы (позже — телефоны официантов). Каждое
// изменение — операция с uid (bill_events.id): повтор не применяется второй
// раз, поэтому касса держит операции в очереди и досылает их после пропажи
// интернета. Операции — намерения («добавить блюдо», «отправить новые на
// кухню»), а не «вот весь счёт», поэтому два устройства не затирают друг
// друга; версия счёта растёт с каждой операцией.
//
// Оплата — обычная продажа с bill_id (одна или несколько при разделении);
// продукты списываются по техкарте при оплате, как у прилавка. Отмена уже
// приготовленного блюда списывает продукты как порчу.

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/events"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// DocSpoilage — списание продуктов отменённого приготовленного блюда.
const DocSpoilage = "spoilage"

// ================================================================ панель

type LayoutTable struct {
	ID         string  `json:"id"`
	HallID     string  `json:"hall_id"`
	Number     string  `json:"number"`
	Seats      int     `json:"seats"`
	Shape      string  `json:"shape"`
	X          int     `json:"x"`
	Y          int     `json:"y"`
	W          int     `json:"w"`
	H          int     `json:"h"`
	WaiterID   *string `json:"waiter_id"`
	WaiterName *string `json:"waiter_name"`
	Bookable   bool    `json:"bookable"`
	Service    bool    `json:"service"`
	// Открытый счёт сейчас — стол нельзя удалить.
	Busy bool `json:"busy"`
}

type LayoutHall struct {
	ID     string        `json:"id"`
	Name   string        `json:"name"`
	NameRu string        `json:"name_ru"`
	NameUz string        `json:"name_uz"`
	Sort   int           `json:"sort"`
	Tables []LayoutTable `json:"tables"`
}

func loadLayout(ctx context.Context, q db.Querier, storeID string) ([]LayoutHall, error) {
	rows, err := q.Query(ctx, `SELECT id, loc(name, name_uz), name, name_uz, sort FROM halls
		WHERE store_id = $1 AND is_active ORDER BY sort, created_at`, storeID)
	if err != nil {
		return nil, err
	}
	halls, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (LayoutHall, error) {
		var h LayoutHall
		err := r.Scan(&h.ID, &h.Name, &h.NameRu, &h.NameUz, &h.Sort)
		h.Tables = []LayoutTable{}
		return h, err
	})
	if err != nil {
		return nil, err
	}
	idx := map[string]int{}
	for i, h := range halls {
		idx[h.ID] = i
	}
	rows, err = q.Query(ctx, `
		SELECT t.id, t.hall_id, t.number, t.seats, t.shape, t.x, t.y, t.w, t.h, COALESCE(sw.waiter_id, t.waiter_id), e.full_name,
		       t.bookable, t.service,
		       EXISTS (SELECT 1 FROM bills b WHERE b.table_id = t.id AND b.status = 'open')
		FROM cafe_tables t
		LEFT JOIN cafe_shift_waiters sw ON sw.table_id = t.id AND sw.day = `+todaySQL+`
		LEFT JOIN employees e ON e.id = COALESCE(sw.waiter_id, t.waiter_id)
		WHERE t.store_id = $1 AND t.is_active
		ORDER BY t.y, t.x, t.number`, storeID)
	if err != nil {
		return nil, err
	}
	tables, err := pgx.CollectRows(rows, pgx.RowToStructByPos[LayoutTable])
	if err != nil {
		return nil, err
	}
	for _, t := range tables {
		if i, ok := idx[t.HallID]; ok {
			halls[i].Tables = append(halls[i].Tables, t)
		}
	}
	return halls, nil
}

func (s *Service) checkStore(ctx context.Context, p *identity.Principal, storeID string) error {
	if !httpx.IsUUID(storeID) || !p.CanAccessStore(storeID) {
		return apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	var ok bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM stores WHERE id = $1 AND network_id = $2)`, storeID, p.NetworkID).Scan(&ok); err != nil {
		return err
	}
	if !ok {
		return apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	return nil
}

// Layout — залы и столы точки (П9 «Касса → Залы и столы»).
func (s *Service) Layout(ctx context.Context, p *identity.Principal, storeID string) ([]LayoutHall, error) {
	if err := s.read(ctx, p); err != nil {
		return nil, err
	}
	if err := s.checkStore(ctx, p, storeID); err != nil {
		return nil, err
	}
	return loadLayout(ctx, s.pool, storeID)
}

type TableInput struct {
	ID       *string `json:"id"`
	Number   string  `json:"number"`
	Seats    int     `json:"seats"`
	Shape    string  `json:"shape"`
	X        int     `json:"x"`
	Y        int     `json:"y"`
	W        int     `json:"w"`
	H        int     `json:"h"`
	WaiterID *string `json:"waiter_id"`
	Bookable *bool   `json:"bookable"`
	Service  *bool   `json:"service"`
}

type HallInput struct {
	ID     *string      `json:"id"`
	Name   string       `json:"name"`
	NameUz string       `json:"name_uz"`
	Tables []TableInput `json:"tables"`
}

type LayoutInput struct {
	StoreID string      `json:"store_id"`
	Halls   []HallInput `json:"halls"`
}

// SaveLayout сохраняет схему целиком: залы и столы, которых нет во входе,
// удаляются (стол с открытым счётом удалить нельзя).
func (s *Service) SaveLayout(ctx context.Context, p *identity.Principal, in LayoutInput) ([]LayoutHall, error) {
	if err := p.Require(identity.PermStoresManage); err != nil {
		return nil, err
	}
	if err := s.read(ctx, p); err != nil {
		return nil, err
	}
	if err := s.checkStore(ctx, p, in.StoreID); err != nil {
		return nil, err
	}
	if len(in.Halls) > 20 {
		return nil, apperr.Validation("halls: не больше 20 залов").Uz("halls: 20 tadan koʻp zal boʻlmasin")
	}
	numbers := map[string]bool{}
	total := 0
	for hi := range in.Halls {
		h := &in.Halls[hi]
		h.Name, h.NameUz = strings.TrimSpace(h.Name), strings.TrimSpace(h.NameUz)
		if h.Name == "" {
			h.Name = h.NameUz
		}
		if h.Name == "" || len([]rune(h.Name)) > 40 || len([]rune(h.NameUz)) > 40 {
			return nil, apperr.Validation("halls: название зала, до 40 символов").Uz("halls: zal nomi, 40 belgigacha")
		}
		if h.ID != nil && !httpx.IsUUID(*h.ID) {
			h.ID = nil
		}
		for ti := range h.Tables {
			t := &h.Tables[ti]
			t.Number = strings.TrimSpace(t.Number)
			if t.Number == "" || len([]rune(t.Number)) > 8 {
				return nil, apperr.Validation("tables: номер стола, до 8 символов").Uz("tables: stol raqami, 8 belgigacha")
			}
			key := strings.ToLower(t.Number)
			if numbers[key] {
				return nil, apperr.Validation("tables: номер стола «" + t.Number + "» повторяется").Uz("tables: «" + t.Number + "» stol raqami takrorlanadi")
			}
			numbers[key] = true
			if t.Seats < 1 || t.Seats > 50 {
				return nil, apperr.Validation("tables: мест у стола — от 1 до 50").Uz("tables: stol oʻrinlari — 1 dan 50 gacha")
			}
			if t.Shape == "" {
				t.Shape = "rect"
			}
			if t.Shape != "rect" && t.Shape != "round" && t.Shape != "topchan" {
				return nil, apperr.Validation("tables: форма — rect, round или topchan").Uz("tables: shakl — rect, round yoki topchan")
			}
			if t.X < 0 || t.Y < 0 || t.X > 200 || t.Y > 200 || t.W < 1 || t.H < 1 || t.W > 20 || t.H > 20 {
				return nil, apperr.Validation("tables: стол за пределами схемы").Uz("tables: stol sxemadan tashqarida")
			}
			if t.ID != nil && !httpx.IsUUID(*t.ID) {
				t.ID = nil
			}
			if t.WaiterID != nil && *t.WaiterID == "" {
				t.WaiterID = nil
			}
			if t.WaiterID != nil && !httpx.IsUUID(*t.WaiterID) {
				return nil, apperr.Validation("tables: официант не найден").Uz("tables: ofitsiant topilmadi")
			}
			total++
		}
	}
	if total > 500 {
		return nil, apperr.Validation("tables: не больше 500 столов").Uz("tables: 500 tadan koʻp stol boʻlmasin")
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT 1 FROM stores WHERE id = $1 FOR UPDATE`, in.StoreID); err != nil {
			return err
		}
		keepHalls, keepTables := []string{}, []string{}
		for _, h := range in.Halls {
			if h.ID != nil {
				keepHalls = append(keepHalls, *h.ID)
			}
			for _, t := range h.Tables {
				if t.ID != nil {
					keepTables = append(keepTables, *t.ID)
				}
			}
		}
		// Удаляемые столы — без открытых счетов.
		var busy *string
		if err := tx.QueryRow(ctx, `
			SELECT min(t.number) FROM cafe_tables t
			WHERE t.store_id = $1 AND t.is_active AND NOT (t.id = ANY($2::uuid[]))
			  AND EXISTS (SELECT 1 FROM bills b WHERE b.table_id = t.id AND b.status = 'open')`, in.StoreID, keepTables).Scan(&busy); err != nil {
			return err
		}
		if busy != nil {
			return apperr.Conflict("table_busy", "стол "+*busy+": открыт счёт — удалить нельзя").Uz(*busy + "-stol: hisob ochiq — oʻchirib boʻlmaydi")
		}
		if _, err := tx.Exec(ctx, `UPDATE cafe_tables SET is_active = false WHERE store_id = $1 AND is_active AND NOT (id = ANY($2::uuid[]))`,
			in.StoreID, keepTables); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE halls SET is_active = false WHERE store_id = $1 AND is_active AND NOT (id = ANY($2::uuid[]))`,
			in.StoreID, keepHalls); err != nil {
			return err
		}
		// Номера переставляют (7 ↔ 8) — сначала временные, потом настоящие.
		if _, err := tx.Exec(ctx, `UPDATE cafe_tables SET number = '~' || left(id::text, 7) WHERE store_id = $1 AND is_active`, in.StoreID); err != nil {
			return err
		}
		for hi, h := range in.Halls {
			var hallID string
			if h.ID != nil {
				err := tx.QueryRow(ctx, `UPDATE halls SET name = $3, name_uz = $4, sort = $5 WHERE id = $1 AND store_id = $2 AND is_active RETURNING id`,
					*h.ID, in.StoreID, h.Name, h.NameUz, hi).Scan(&hallID)
				if errors.Is(err, pgx.ErrNoRows) {
					h.ID = nil
				} else if err != nil {
					return err
				}
			}
			if h.ID == nil {
				if err := tx.QueryRow(ctx, `INSERT INTO halls (network_id, store_id, name, name_uz, sort) VALUES ($1, $2, $3, $4, $5) RETURNING id`,
					p.NetworkID, in.StoreID, h.Name, h.NameUz, hi).Scan(&hallID); err != nil {
					return err
				}
			}
			for _, t := range h.Tables {
				if t.WaiterID != nil {
					var ok bool
					if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM employees WHERE id = $1 AND network_id = $2 AND status = 'active')`,
						*t.WaiterID, p.NetworkID).Scan(&ok); err != nil {
						return err
					}
					if !ok {
						return apperr.Validation("tables: официант не найден").Uz("tables: ofitsiant topilmadi")
					}
				}
				bookable, service := true, true
				if t.Bookable != nil {
					bookable = *t.Bookable
				}
				if t.Service != nil {
					service = *t.Service
				}
				updated := false
				if t.ID != nil {
					tag, err := tx.Exec(ctx, `UPDATE cafe_tables SET hall_id = $3, number = $4, seats = $5, shape = $6, x = $7, y = $8, w = $9, h = $10,
						waiter_id = $11, bookable = $12, service = $13 WHERE id = $1 AND store_id = $2 AND is_active`,
						*t.ID, in.StoreID, hallID, t.Number, t.Seats, t.Shape, t.X, t.Y, t.W, t.H, t.WaiterID, bookable, service)
					if err != nil {
						return err
					}
					updated = tag.RowsAffected() > 0
				}
				if !updated {
					if _, err := tx.Exec(ctx, `INSERT INTO cafe_tables (network_id, store_id, hall_id, number, seats, shape, x, y, w, h, waiter_id, bookable, service)
						VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)`,
						p.NetworkID, in.StoreID, hallID, t.Number, t.Seats, t.Shape, t.X, t.Y, t.W, t.H, t.WaiterID, bookable, service); err != nil {
						return err
					}
				}
			}
		}
		_, err := events.Bump(ctx, tx, in.StoreID)
		return err
	})
	if err != nil {
		return nil, err
	}
	return loadLayout(ctx, s.pool, in.StoreID)
}

// ================================================================ касса

type BillMod struct {
	OptionID string `json:"option_id"`
	Name     string `json:"name"`
	Qty      int    `json:"qty"`
	Price    string `json:"price"`
	Action   string `json:"action"`
}

type BillItem struct {
	ID        string    `json:"id"`
	Seq       int       `json:"seq"`
	ProductID string    `json:"product_id"`
	Name      string    `json:"name"`
	Qty       string    `json:"qty"`
	Price     string    `json:"price"`
	Mods      []BillMod `json:"mods"`
	Note      string    `json:"note"`
	Guest     *int      `json:"guest"`
	Course    string    `json:"course"`
	// new — ещё не на кухне, sent — ушла на кухню.
	Status       string     `json:"status"`
	SentAt       *time.Time `json:"sent_at"`
	CancelledQty string     `json:"cancelled_qty"`
	PaidQty      string     `json:"paid_qty"`
	// Состояние на кухне: waiting, new, cooking, ready, served, cancelled; "" — не на кухне.
	Kitchen string `json:"kitchen"`
	// «Несу» — официант отнёс блюдо гостям (этап 6).
	ServedAt *time.Time `json:"served_at"`
}

type Bill struct {
	ID             string     `json:"id"`
	TableID        *string    `json:"table_id"`
	TableNumber    string     `json:"table_number"`
	HallName       string     `json:"hall_name"`
	WaiterID       *string    `json:"waiter_id"`
	WaiterName     string     `json:"waiter_name"`
	Guests         int        `json:"guests"`
	Comment        string     `json:"comment"`
	Status         string     `json:"status"`
	ServicePercent string     `json:"service_percent"`
	PrecheckAt     *time.Time `json:"precheck_at"`
	Version        int        `json:"version"`
	OpenedAt       time.Time  `json:"opened_at"`
	Items          []BillItem `json:"items"`
	// Суммы: позиции (без отменённых), обслуживание, к оплате, уже оплачено.
	Subtotal string `json:"subtotal"`
	Service  string `json:"service"`
	Total    string `json:"total"`
	Paid     string `json:"paid"`
	// Сколько позиций готово на кухне — зелёная рамка стола.
	Ready int `json:"ready"`
	// Передача стола (О6 → О7): кому предложено, кто передаёт, почему, когда;
	// пусто — передачи нет или она просрочена (3 минуты).
	TransferTo       *string    `json:"transfer_to"`
	TransferToName   string     `json:"transfer_to_name"`
	TransferFrom     *string    `json:"transfer_from"`
	TransferFromName string     `json:"transfer_from_name"`
	TransferReason   string     `json:"transfer_reason"`
	TransferAt       *time.Time `json:"transfer_at"`
	// Для телефона официанта: мой стол (кассе — всегда true).
	Mine bool `json:"mine"`
}

// transferTTL — сколько ждём ответа на передачу стола.
const transferTTL = 3 * time.Minute

const billSelect = `
	SELECT b.id, b.table_id, COALESCE(t.number, ''), COALESCE(loc(h.name, h.name_uz), ''), b.waiter_id, COALESCE(e.full_name, ''),
	       b.guests, b.comment, b.status, trim_scale(b.service_percent)::text, b.precheck_at, b.version, b.opened_at,
	       COALESCE((SELECT sum(sa.total) FROM sales sa WHERE sa.bill_id = b.id), 0)::numeric(14,2)::text,
	       CASE WHEN b.transfer_at > now() - interval '3 minutes' THEN b.transfer_to END,
	       CASE WHEN b.transfer_at > now() - interval '3 minutes' THEN COALESCE(tt.full_name, '') ELSE '' END,
	       CASE WHEN b.transfer_at > now() - interval '3 minutes' THEN b.transfer_from END,
	       CASE WHEN b.transfer_at > now() - interval '3 minutes' THEN COALESCE(tf.full_name, '') ELSE '' END,
	       CASE WHEN b.transfer_at > now() - interval '3 minutes' THEN b.transfer_reason ELSE '' END,
	       CASE WHEN b.transfer_at > now() - interval '3 minutes' THEN b.transfer_at END
	FROM bills b
	LEFT JOIN cafe_tables t ON t.id = b.table_id
	LEFT JOIN halls h ON h.id = t.hall_id
	LEFT JOIN employees e ON e.id = b.waiter_id
	LEFT JOIN employees tt ON tt.id = b.transfer_to
	LEFT JOIN employees tf ON tf.id = b.transfer_from`

func loadBills(ctx context.Context, q db.Querier, where string, args ...any) ([]Bill, error) {
	rows, err := q.Query(ctx, billSelect+` WHERE `+where+` ORDER BY b.opened_at`, args...)
	if err != nil {
		return nil, err
	}
	bills, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Bill, error) {
		var b Bill
		err := r.Scan(&b.ID, &b.TableID, &b.TableNumber, &b.HallName, &b.WaiterID, &b.WaiterName, &b.Guests, &b.Comment, &b.Status,
			&b.ServicePercent, &b.PrecheckAt, &b.Version, &b.OpenedAt, &b.Paid,
			&b.TransferTo, &b.TransferToName, &b.TransferFrom, &b.TransferFromName, &b.TransferReason, &b.TransferAt)
		b.Items = []BillItem{}
		b.Mine = true
		return b, err
	})
	if err != nil || len(bills) == 0 {
		return bills, err
	}
	ids := make([]string, len(bills))
	idx := map[string]int{}
	for i, b := range bills {
		ids[i] = b.ID
		idx[b.ID] = i
	}
	rows, err = q.Query(ctx, `
		SELECT i.bill_id, i.id, i.seq, i.product_id, loc(i.name, i.name_uz), trim_scale(i.qty)::text, i.price::text, i.mods, i.note, i.guest,
		       i.course, i.status, i.sent_at, trim_scale(i.cancelled_qty)::text, trim_scale(i.paid_qty)::text,
		       COALESCE((SELECT t.status FROM kitchen_ticket_items ki JOIN kitchen_tickets t ON t.id = ki.ticket_id
		                 WHERE ki.bill_item_id = i.id ORDER BY t.created_at DESC LIMIT 1), ''), i.served_at
		FROM bill_items i WHERE i.bill_id = ANY($1::uuid[]) ORDER BY i.bill_id, i.seq`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var billID string
		var it BillItem
		var mods []byte
		if err := rows.Scan(&billID, &it.ID, &it.Seq, &it.ProductID, &it.Name, &it.Qty, &it.Price, &mods, &it.Note, &it.Guest,
			&it.Course, &it.Status, &it.SentAt, &it.CancelledQty, &it.PaidQty, &it.Kitchen, &it.ServedAt); err != nil {
			return nil, err
		}
		if it.ServedAt != nil && (it.Kitchen == "ready" || it.Kitchen == "new" || it.Kitchen == "cooking") {
			it.Kitchen = "served"
		}
		it.Mods = []BillMod{}
		_ = json.Unmarshal(mods, &it.Mods)
		b := &bills[idx[billID]]
		b.Items = append(b.Items, it)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i := range bills {
		sumUp(&bills[i])
	}
	return bills, nil
}

// sumUp — суммы счёта: позиции без отменённых, обслуживание по проценту.
func sumUp(b *Bill) {
	sub := money.D("0")
	for _, it := range b.Items {
		left := money.D(it.Qty).Sub(money.D(it.CancelledQty))
		sub = sub.Add(left.Mul(money.D(it.Price)))
		if it.Kitchen == "ready" && left.Sign() > 0 {
			b.Ready++
		}
	}
	service := sub.Mul(money.D(b.ServicePercent)).Div(money.D("100")).Round2()
	b.Subtotal, b.Service, b.Total = sub.Money(), service.Money(), sub.Round2().Add(service).Money()
}

func loadBill(ctx context.Context, q db.Querier, storeID, id string) (Bill, error) {
	list, err := loadBills(ctx, q, `b.id = $1 AND b.store_id = $2`, id, storeID)
	if err != nil {
		return Bill{}, err
	}
	if len(list) == 0 {
		return Bill{}, apperr.NotFound("счёт не найден").Uz("hisob topilmadi")
	}
	return list[0], nil
}

type PosHall struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Sort int    `json:"sort"`
}

// HallState — всё для кассы со столами: настройки, залы, столы, открытые счета.
type HallState struct {
	Version          int64         `json:"version"`
	Mode             string        `json:"mode"`
	ServicePercent   string        `json:"service_percent"`
	WaiterOwnTables  bool          `json:"waiter_own_tables"`
	PrecheckRequired bool          `json:"precheck_required"`
	VoidSeniorOnly   bool          `json:"void_senior_only"`
	ServiceIKPU      string        `json:"service_ikpu"`
	Halls            []PosHall     `json:"halls"`
	Tables           []LayoutTable `json:"tables"`
	Bills            []Bill        `json:"bills"`
}

func (s *Service) Hall(ctx context.Context, p *identity.Principal) (HallState, error) {
	storeID, err := deviceStore(p)
	if err != nil {
		return HallState{}, err
	}
	return s.hallState(ctx, p.NetworkID, storeID)
}

func (s *Service) hallState(ctx context.Context, networkID, storeID string) (HallState, error) {
	out := HallState{Halls: []PosHall{}, Tables: []LayoutTable{}, Bills: []Bill{}}
	var bt string
	var err error
	if err := s.pool.QueryRow(ctx, `SELECT business_type, cafe_mode, trim_scale(service_percent)::text, waiter_own_tables,
		precheck_required, void_senior_only, service_ikpu FROM networks WHERE id = $1`, networkID).
		Scan(&bt, &out.Mode, &out.ServicePercent, &out.WaiterOwnTables, &out.PrecheckRequired, &out.VoidSeniorOnly, &out.ServiceIKPU); err != nil {
		return out, err
	}
	if bt != BusinessCafe {
		return out, errNotCafe
	}
	if out.Version, err = events.Version(ctx, s.pool, storeID); err != nil {
		return out, err
	}
	halls, err := loadLayout(ctx, s.pool, storeID)
	if err != nil {
		return out, err
	}
	for _, h := range halls {
		out.Halls = append(out.Halls, PosHall{ID: h.ID, Name: h.Name, Sort: h.Sort})
		out.Tables = append(out.Tables, h.Tables...)
	}
	if out.Bills, err = loadBills(ctx, s.pool, `b.store_id = $1 AND b.status = 'open'`, storeID); err != nil {
		return out, err
	}
	if out.Bills == nil {
		out.Bills = []Bill{}
	}
	return out, nil
}

// ------------------------------------------------------------- операции

type BillItemInput struct {
	ID        string           `json:"id"`
	ProductID string           `json:"product_id"`
	Qty       money.Qty        `json:"qty"`
	Price     money.Amount     `json:"price"`
	Modifiers []ChosenModifier `json:"modifiers"`
	Note      string           `json:"note"`
	Guest     *int             `json:"guest"`
	Course    string           `json:"course"`
}

type MoveItem struct {
	ID  string    `json:"id"`
	Qty money.Qty `json:"qty"`
}

// BillOp — операция со счётом. Поля — по виду операции.
type BillOp struct {
	ID     string     `json:"id"`
	BillID string     `json:"bill_id"`
	Kind   string     `json:"kind"`
	At     *time.Time `json:"at"`
	// open
	TableID  *string `json:"table_id"`
	Guests   *int    `json:"guests"`
	WaiterID *string `json:"waiter_id"`
	Comment  string  `json:"comment"`
	// add
	Item *BillItemInput `json:"item"`
	// update, remove, cancel
	ItemID string     `json:"item_id"`
	Qty    *money.Qty `json:"qty"`
	Guest  *int       `json:"guest"`
	Note   *string    `json:"note"`
	Course *string    `json:"course"`
	// cancel, void
	Reason     string `json:"reason"`
	Spoil      bool   `json:"spoil"`
	ApproverID string `json:"approver_id"`
	// move, merge, move_items
	ToTableID *string    `json:"to_table_id"`
	ToBillID  *string    `json:"to_bill_id"`
	NewBillID *string    `json:"new_bill_id"`
	Items     []MoveItem `json:"items"`
	// transfer (официант): кому передать стол; причина — в Reason.
	ToWaiterID string `json:"to_waiter_id"`
	// Если задано и счёт с тех пор изменился (другая касса или телефон) —
	// 409 bill_changed с текущим счётом; клиент показывает и повторяет.
	ExpectedVersion *int `json:"expected_version"`
}

// actor — от чьего имени операция: касса (по умолчанию) или официант с
// телефона (ограниченный набор операций, свои столы).
type actor struct {
	waiter bool
	me     string // employee_id официанта
	senior bool   // старший: видит и ведёт все столы, назначает зоны
	own    bool   // настройка «официант видит только свои столы»
}

var errBillChanged = apperr.Conflict("bill_changed", "счёт изменился на другом устройстве — обновите").Uz("hisob boshqa qurilmada oʻzgardi — yangilang")

// todaySQL — рабочий день кафе (по Ташкенту).
const todaySQL = `(now() AT TIME ZONE 'Asia/Tashkent')::date`

var errBillClosed = apperr.Conflict("bill_closed", "счёт уже закрыт").Uz("hisob allaqachon yopilgan")

// ApplyOp применяет операцию к счёту и возвращает счёт. Повтор (тот же id)
// ничего не меняет.
func (s *Service) ApplyOp(ctx context.Context, p *identity.Principal, op BillOp) (Bill, error) {
	storeID, err := deviceStore(p)
	if err != nil {
		return Bill{}, err
	}
	if p.DeviceKind != "" && p.DeviceKind != devicePOS {
		return Bill{}, apperr.Forbidden("счёт ведёт касса").Uz("hisobni kassa yuritadi")
	}
	if err := p.Require(identity.PermSalesPOS); err != nil {
		return Bill{}, err
	}
	return s.applyBillOp(ctx, p, storeID, op, actor{})
}

func (s *Service) applyBillOp(ctx context.Context, p *identity.Principal, storeID string, op BillOp, who actor) (Bill, error) {
	if who.waiter {
		if err := waiterAllowed(op.Kind); err != nil {
			return Bill{}, err
		}
	}
	if !httpx.IsUUID(op.ID) || !httpx.IsUUID(op.BillID) {
		return Bill{}, apperr.Validation("id, bill_id: uuid операции и счёта").Uz("id, bill_id: amal va hisob uuid")
	}
	at := time.Now()
	if op.At != nil && op.At.Before(at.Add(time.Minute)) && op.At.After(at.Add(-72*time.Hour)) {
		at = *op.At
	}
	resultBill := op.BillID
	var pushes []waiterPush
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		pushes = pushes[:0]
		var done bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM bill_events WHERE id = $1)`, op.ID).Scan(&done); err != nil {
			return err
		}
		if done {
			return nil
		}
		if op.Kind == "open" {
			ps, err := openBill(ctx, tx, p, storeID, op, at, who)
			if err != nil {
				return err
			}
			pushes = append(pushes, ps...)
		} else {
			var status string
			var version int
			var waiter *string
			err := tx.QueryRow(ctx, `SELECT status, version, waiter_id FROM bills WHERE id = $1 AND store_id = $2 FOR UPDATE`, op.BillID, storeID).
				Scan(&status, &version, &waiter)
			if errors.Is(err, pgx.ErrNoRows) {
				return apperr.NotFound("счёт не найден").Uz("hisob topilmadi")
			}
			if err != nil {
				return err
			}
			if status != "open" {
				return errBillClosed
			}
			if op.ExpectedVersion != nil && *op.ExpectedVersion != version {
				return errBillChanged
			}
			if who.waiter {
				if err := waiterOwns(op.Kind, waiter, who); err != nil {
					return err
				}
				// Старший с телефона подтверждает сам (ПИН не нужен — он вошёл).
				if who.senior && op.ApproverID == "" {
					op.ApproverID = who.me
				}
			}
			var next string
			if isWaiterOp(op.Kind) {
				ps, err := waiterOp(ctx, tx, p, storeID, op, who, waiter)
				if err != nil {
					return err
				}
				pushes = append(pushes, ps...)
			} else if next, err = applyOp(ctx, tx, p, storeID, op); err != nil {
				return err
			}
			if next != "" {
				resultBill = next
			}
		}
		payload, _ := json.Marshal(op)
		if _, err := tx.Exec(ctx, `INSERT INTO bill_events (id, bill_id, kind, payload, employee_id, device_id, at)
			VALUES ($1, $2, $3, $4, NULLIF($5, '')::uuid, NULLIF($6, '')::uuid, $7)`,
			op.ID, op.BillID, op.Kind, payload, p.EmployeeID, p.DeviceID, at); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE bills SET version = version + 1 WHERE id = $1`, op.BillID); err != nil {
			return err
		}
		_, err := events.Bump(ctx, tx, storeID)
		return err
	})
	if err != nil {
		return Bill{}, err
	}
	s.sendPushes(ctx, pushes)
	bill, err := loadBill(ctx, s.pool, storeID, resultBill)
	if err == nil && who.waiter {
		bill.Mine = bill.WaiterID != nil && *bill.WaiterID == who.me
	}
	return bill, err
}

func openBill(ctx context.Context, tx pgx.Tx, p *identity.Principal, storeID string, op BillOp, at time.Time, who actor) ([]waiterPush, error) {
	var exists bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM bills WHERE id = $1)`, op.BillID).Scan(&exists); err != nil {
		return nil, err
	}
	if exists {
		return nil, nil
	}
	if op.TableID == nil || !httpx.IsUUID(*op.TableID) {
		return nil, apperr.Validation("table_id: стол не найден").Uz("table_id: stol topilmadi")
	}
	var number string
	var service bool
	var waiter *string
	// Официант стола: назначенный на смену (О8), иначе постоянный из панели.
	err := tx.QueryRow(ctx, `
		SELECT t.number, t.service, COALESCE(sw.waiter_id, t.waiter_id)
		FROM cafe_tables t LEFT JOIN cafe_shift_waiters sw ON sw.table_id = t.id AND sw.day = `+todaySQL+`
		WHERE t.id = $1 AND t.store_id = $2 AND t.is_active FOR UPDATE OF t`,
		*op.TableID, storeID).Scan(&number, &service, &waiter)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.Validation("table_id: стол не найден").Uz("table_id: stol topilmadi")
	}
	if err != nil {
		return nil, err
	}
	guests := 1
	if op.Guests != nil {
		guests = *op.Guests
	}
	if guests < 1 || guests > 99 {
		return nil, apperr.Validation("guests: гостей — от 1 до 99").Uz("guests: mehmonlar — 1 dan 99 gacha")
	}
	if who.waiter {
		// Кто открыл стол — того и стол (О5). Старший может открыть на другого.
		if op.WaiterID != nil && *op.WaiterID != "" && who.senior {
			if err := checkEmployee(ctx, tx, p.NetworkID, *op.WaiterID); err != nil {
				return nil, err
			}
			waiter = op.WaiterID
		} else {
			me := who.me
			waiter = &me
		}
	} else if op.WaiterID != nil {
		if *op.WaiterID == "" {
			waiter = nil
		} else if err := checkEmployee(ctx, tx, p.NetworkID, *op.WaiterID); err != nil {
			return nil, err
		} else {
			waiter = op.WaiterID
		}
	}
	comment := strings.TrimSpace(op.Comment)
	if len([]rune(comment)) > 200 {
		return nil, apperr.Validation("comment: до 200 символов").Uz("comment: 200 belgigacha")
	}
	pct := "0"
	if service {
		if err := tx.QueryRow(ctx, `SELECT service_percent::text FROM networks WHERE id = $1`, p.NetworkID).Scan(&pct); err != nil {
			return nil, err
		}
	}
	_, err = tx.Exec(ctx, `INSERT INTO bills (id, network_id, store_id, table_id, waiter_id, guests, service_percent, opened_at, opened_by, device_id, comment)
		VALUES ($1, $2, $3, $4, $5, $6, $7::numeric, $8, NULLIF($9, '')::uuid, NULLIF($10, '')::uuid, $11)`,
		op.BillID, p.NetworkID, storeID, *op.TableID, waiter, guests, pct, at, p.EmployeeID, p.DeviceID, comment)
	if db.IsUniqueViolation(err, "bills_table_open_key") {
		return nil, apperr.Conflict("table_busy", "стол "+number+" уже открыт на другой кассе").Uz(number + "-stol boshqa kassada ochilgan")
	}
	if err != nil {
		return nil, err
	}
	// Стол открыли с кассы (или старший) на официанта — ему push.
	if waiter != nil && *waiter != p.EmployeeID {
		return []waiterPush{tableOpenedPush(*waiter, number, guests)}, nil
	}
	return nil, nil
}

func checkEmployee(ctx context.Context, q db.Querier, networkID, id string) error {
	if !httpx.IsUUID(id) {
		return apperr.Validation("официант не найден").Uz("ofitsiant topilmadi")
	}
	var ok bool
	if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM employees WHERE id = $1 AND network_id = $2 AND status = 'active')`, id, networkID).Scan(&ok); err != nil {
		return err
	}
	if !ok {
		return apperr.Validation("официант не найден").Uz("ofitsiant topilmadi")
	}
	return nil
}

// checkSenior — подтверждение старшего (отмена позиции, закрыть без оплаты):
// сотрудник с правом возврата. ПИН касса проверила сама.
func checkSenior(ctx context.Context, q db.Querier, networkID, id string) error {
	if !httpx.IsUUID(id) {
		return apperr.Forbidden("нужно подтверждение старшего кассира").Uz("katta kassir tasdigʻi kerak")
	}
	var ok bool
	if err := q.QueryRow(ctx, `
		SELECT r.is_owner OR $3 = ANY(r.permissions) FROM employees e JOIN roles r ON r.id = e.role_id
		WHERE e.id = $1 AND e.network_id = $2 AND e.status = 'active'`, id, networkID, identity.PermSalesReturn).Scan(&ok); err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	if !ok {
		return apperr.Forbidden("подтвердить может только старший кассир").Uz("faqat katta kassir tasdiqlay oladi")
	}
	return nil
}

// left — сколько позиции осталось (не отменено и не оплачено).
const itemLeft = `(qty - cancelled_qty - paid_qty)`

func applyOp(ctx context.Context, tx pgx.Tx, p *identity.Principal, storeID string, op BillOp) (string, error) {
	switch op.Kind {
	case "add":
		return "", addItem(ctx, tx, p, op)
	case "update":
		if !httpx.IsUUID(op.ItemID) {
			return "", errItem
		}
		if op.Course != nil && *op.Course != "now" && *op.Course != "later" {
			return "", apperr.Validation("course: now или later").Uz("course: now yoki later")
		}
		if op.Guest != nil && (*op.Guest < 0 || *op.Guest > 99) {
			return "", apperr.Validation("guest: от 1 до 99").Uz("guest: 1 dan 99 gacha")
		}
		var qty *string
		if op.Qty != nil {
			if !op.Qty.Valid() || money.D(string(*op.Qty)).Sign() <= 0 {
				return "", apperr.Validation("qty: больше нуля").Uz("qty: noldan katta")
			}
			q := string(*op.Qty)
			qty = &q
		}
		if op.Note != nil && len([]rune(*op.Note)) > 200 {
			return "", apperr.Validation("note: до 200 символов").Uz("note: 200 belgigacha")
		}
		tag, err := tx.Exec(ctx, `UPDATE bill_items SET qty = COALESCE($3::numeric, qty), note = COALESCE($4, note),
			course = COALESCE($5, course), guest = CASE WHEN $6::int IS NULL THEN guest WHEN $6 = 0 THEN NULL ELSE $6 END
			WHERE id = $1 AND bill_id = $2 AND status = 'new'`, op.ItemID, op.BillID, qty, op.Note, op.Course, op.Guest)
		if err != nil {
			return "", err
		}
		if tag.RowsAffected() == 0 {
			return "", errSent
		}
		return "", nil
	case "remove":
		tag, err := tx.Exec(ctx, `DELETE FROM bill_items WHERE id = $1 AND bill_id = $2 AND status = 'new'`, op.ItemID, op.BillID)
		if err != nil {
			return "", err
		}
		if tag.RowsAffected() == 0 {
			return "", errSent
		}
		return "", nil
	case "send":
		return "", sendToKitchen(ctx, tx, p, storeID, op.BillID)
	case "fire":
		// «Подать горячее»: блюда «по команде» — в работу, таймер с этой минуты.
		// Цех без экрана: бегунок «ПОДАВАТЬ» печатает касса (с телефона — по
		// очереди печати), бегунок считается выданным.
		screens, all, err := kitchenScreens(ctx, tx, storeID)
		if err != nil {
			return "", err
		}
		rows, err := tx.Query(ctx, `SELECT id, workshop_id FROM kitchen_tickets WHERE bill_id = $1 AND status = 'waiting' FOR UPDATE`, op.BillID)
		if err != nil {
			return "", err
		}
		type waitingTicket struct {
			id       string
			workshop *string
		}
		list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (waitingTicket, error) {
			var t waitingTicket
			err := r.Scan(&t.id, &t.workshop)
			return t, err
		})
		if err != nil || len(list) == 0 {
			return "", err
		}
		for _, t := range list {
			screen := all || (t.workshop != nil && screens[*t.workshop])
			if screen {
				_, err = tx.Exec(ctx, `UPDATE kitchen_tickets SET status = 'new', paid_at = now() WHERE id = $1`, t.id)
			} else {
				_, err = tx.Exec(ctx, `UPDATE kitchen_tickets SET status = 'served', paid_at = now(), served_at = now(),
					print_pending = $2, print_kind = 'fire' WHERE id = $1`, t.id, p.DeviceID == "")
			}
			if err != nil {
				return "", err
			}
		}
		_, err = tx.Exec(ctx, `UPDATE bill_items SET course = 'now' WHERE bill_id = $1 AND course = 'later' AND status = 'sent'`, op.BillID)
		return "", err
	case "cancel":
		return "", cancelItem(ctx, tx, p, storeID, op)
	case "guests":
		if op.Guests == nil || *op.Guests < 1 || *op.Guests > 99 {
			return "", apperr.Validation("guests: от 1 до 99").Uz("guests: 1 dan 99 gacha")
		}
		_, err := tx.Exec(ctx, `UPDATE bills SET guests = $2 WHERE id = $1`, op.BillID, *op.Guests)
		return "", err
	case "waiter":
		var w *string
		if op.WaiterID != nil && *op.WaiterID != "" {
			if err := checkEmployee(ctx, tx, p.NetworkID, *op.WaiterID); err != nil {
				return "", err
			}
			w = op.WaiterID
		}
		_, err := tx.Exec(ctx, `UPDATE bills SET waiter_id = $2 WHERE id = $1`, op.BillID, w)
		return "", err
	case "precheck":
		_, err := tx.Exec(ctx, `UPDATE bills SET precheck_at = now() WHERE id = $1`, op.BillID)
		return "", err
	case "move":
		return "", moveBill(ctx, tx, storeID, op)
	case "merge":
		return mergeBill(ctx, tx, storeID, op)
	case "move_items":
		return moveItems(ctx, tx, p, storeID, op)
	case "void":
		return "", voidBill(ctx, tx, p, op)
	}
	return "", apperr.Validation("kind: неизвестная операция").Uz("kind: nomaʼlum amal")
}

var (
	errItem = apperr.NotFound("позиция не найдена").Uz("pozitsiya topilmadi")
	errSent = apperr.Conflict("item_sent", "позиция уже на кухне — отмена через «Отменить позицию»").Uz("pozitsiya oshxonada — «Pozitsiyani bekor qilish» orqali")
)

func addItem(ctx context.Context, tx pgx.Tx, p *identity.Principal, op BillOp) error {
	in := op.Item
	if in == nil || !httpx.IsUUID(in.ID) || !httpx.IsUUID(in.ProductID) {
		return apperr.Validation("item: id и product_id").Uz("item: id va product_id")
	}
	if !in.Qty.Valid() || money.D(string(in.Qty)).Sign() <= 0 {
		return apperr.Validation("item.qty: больше нуля").Uz("item.qty: noldan katta")
	}
	if !in.Price.Valid() {
		return apperr.Validation("item.price: цена").Uz("item.price: narx")
	}
	if in.Course == "" {
		in.Course = "now"
	}
	if in.Course != "now" && in.Course != "later" {
		return apperr.Validation("item.course: now или later").Uz("item.course: now yoki later")
	}
	if in.Guest != nil && (*in.Guest < 1 || *in.Guest > 99) {
		return apperr.Validation("item.guest: от 1 до 99").Uz("item.guest: 1 dan 99 gacha")
	}
	in.Note = strings.TrimSpace(in.Note)
	if len([]rune(in.Note)) > 200 {
		return apperr.Validation("item.note: до 200 символов").Uz("item.note: 200 belgigacha")
	}
	var name, nameUz string
	err := tx.QueryRow(ctx, `SELECT name, name_uz FROM products WHERE id = $1 AND (network_id IS NULL OR network_id = $2)`,
		in.ProductID, p.NetworkID).Scan(&name, &nameUz)
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.Validation("item.product_id: блюдо не найдено").Uz("item.product_id: taom topilmadi")
	}
	if err != nil {
		return err
	}
	mods := []BillMod{}
	if len(in.Modifiers) > 0 {
		res, err := ResolveModifiers(ctx, tx, p.NetworkID, in.ProductID, name, in.Modifiers, false)
		if err != nil {
			return err
		}
		for _, m := range res {
			mods = append(mods, BillMod{OptionID: m.OptionID, Name: m.Name, Qty: m.Qty, Price: m.Price.Money(), Action: m.Action})
		}
	}
	modsJSON, _ := json.Marshal(mods)
	_, err = tx.Exec(ctx, `
		INSERT INTO bill_items (id, bill_id, seq, product_id, name, name_uz, qty, price, mods, note, guest, course, created_by)
		VALUES ($1, $2, (SELECT COALESCE(max(seq), 0) + 1 FROM bill_items WHERE bill_id = $2), $3, $4, $5, $6::numeric, $7::numeric,
		        $8, $9, $10, $11, NULLIF($12, '')::uuid)
		ON CONFLICT (id) DO NOTHING`,
		in.ID, op.BillID, in.ProductID, name, nameUz, string(in.Qty), string(in.Price), modsJSON, in.Note, in.Guest, in.Course, p.EmployeeID)
	return err
}

// sendToKitchen — новые позиции уходят на кухню одной отправкой: бегунок по
// цеху; «по команде» — бегунок ждёт («Подать горячее»). Товары (не блюда)
// на кухню не идут, просто отмечаются отправленными.
func sendToKitchen(ctx context.Context, tx pgx.Tx, p *identity.Principal, storeID, billID string) error {
	type line struct {
		id, productID, name, nameUz, qty, note, course string
		seq                                            int
		workshopID                                     *string
		cook                                           int
		dish                                           bool
		mods                                           []byte
	}
	rows, err := tx.Query(ctx, `
		SELECT x.id, x.seq, x.product_id, x.name, x.name_uz, x.qty, x.note, x.course, x.mods, x.kind = 'dish', x.wid,
		       COALESCE(x.cook, w.cook_minutes, 15)
		FROM (SELECT i.id, i.seq, i.product_id, i.name, i.name_uz, trim_scale(i.qty)::text AS qty, i.note, i.course, i.mods, pr.kind,
		             pr.cook_minutes AS cook,
		             COALESCE(pr.workshop_id, g.workshop_id,
		                      (SELECT d.id FROM workshops d WHERE d.network_id = pr.network_id AND d.is_default)) AS wid
		      FROM bill_items i JOIN products pr ON pr.id = i.product_id
		      LEFT JOIN menu_groups g ON g.id = pr.menu_group_id
		      WHERE i.bill_id = $1 AND i.status = 'new') x
		LEFT JOIN workshops w ON w.id = x.wid
		ORDER BY x.seq`, billID)
	if err != nil {
		return err
	}
	lines, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (line, error) {
		var l line
		err := r.Scan(&l.id, &l.seq, &l.productID, &l.name, &l.nameUz, &l.qty, &l.note, &l.course, &l.mods, &l.dish, &l.workshopID, &l.cook)
		return l, err
	})
	if err != nil || len(lines) == 0 {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE bill_items SET status = 'sent', sent_at = now() WHERE bill_id = $1 AND status = 'new'`, billID); err != nil {
		return err
	}
	var batch int
	var number, waiter, cashier string
	if err := tx.QueryRow(ctx, `
		SELECT COALESCE((SELECT max(batch) FROM kitchen_tickets WHERE bill_id = b.id), 0) + 1, COALESCE(t.number, ''),
		       COALESCE((SELECT full_name FROM employees WHERE id = b.waiter_id), ''),
		       COALESCE((SELECT full_name FROM employees WHERE id = NULLIF($2, '')::uuid), '')
		FROM bills b LEFT JOIN cafe_tables t ON t.id = b.table_id WHERE b.id = $1`, billID, p.EmployeeID).
		Scan(&batch, &number, &waiter, &cashier); err != nil {
		return err
	}
	screens, all, err := kitchenScreens(ctx, tx, storeID)
	if err != nil {
		return err
	}
	type group struct {
		workshopID *string
		course     string
		cook       int
		lines      []line
	}
	var groups []*group
	idx := map[string]*group{}
	for _, l := range lines {
		if !l.dish {
			continue
		}
		key := l.course + ":"
		if l.workshopID != nil {
			key += *l.workshopID
		}
		g := idx[key]
		if g == nil {
			g = &group{workshopID: l.workshopID, course: l.course}
			idx[key] = g
			groups = append(groups, g)
		}
		g.lines = append(g.lines, l)
		if l.cook > g.cook {
			g.cook = l.cook
		}
	}
	// Одна отправка — один номер; «по команде» — отдельная отправка, чтобы
	// бегунок «сразу» и бегунок «по команде» одного цеха не совпали.
	batches := map[string]int{"now": batch, "later": batch + 1}
	usedLater := false
	for _, g := range groups {
		if g.course == "later" {
			usedLater = true
		}
	}
	if !usedLater {
		delete(batches, "later")
	}
	for _, g := range groups {
		// Цех без экрана: бегунок печатает касса и сразу считает его выданным.
		// «По команде» ждёт команды и без экрана — «Подать горячее» печатает
		// «ПОДАВАТЬ». Отправка с кассы печатает сама; с телефона официанта —
		// касса узнаёт из /pos/kitchen/status.
		screen := all || (g.workshopID != nil && screens[*g.workshopID])
		status := "served"
		if g.course == "later" {
			status = "waiting"
		} else if screen {
			status = "new"
		}
		printPending := !screen && p.DeviceID == ""
		b := batches[g.course]
		var ticketID string
		err := tx.QueryRow(ctx, `
			INSERT INTO kitchen_tickets (network_id, store_id, bill_id, batch, workshop_id, order_type, status, cook_minutes, cashier_name,
			                             paid_at, served_at, order_key, table_label, waiter_name, print_pending)
			VALUES ($1, $2, $3, $4, $5, 'here', $6, $7, $8, now(), CASE WHEN $6 = 'served' THEN now() END, $11, $9, $10, $12)
			RETURNING id`,
			p.NetworkID, storeID, billID, b, g.workshopID, status, g.cook, cashier, number, waiter, billID+"-"+strconv.Itoa(b), printPending).Scan(&ticketID)
		if err != nil {
			return err
		}
		for _, l := range g.lines {
			if _, err := tx.Exec(ctx, `
				INSERT INTO kitchen_ticket_items (ticket_id, line, product_id, name, name_uz, qty, mods, note, bill_item_id)
				VALUES ($1, $2, $3, $4, $5, $6::numeric, $7, $8, $9)`,
				ticketID, l.seq, l.productID, l.name, l.nameUz, l.qty, kitchenMods(l.mods), l.note, l.id); err != nil {
				return err
			}
		}
	}
	return nil
}

// kitchenMods — модификаторы счёта в вид бегунка: название, действие, сколько.
func kitchenMods(raw []byte) []byte {
	var mods []BillMod
	_ = json.Unmarshal(raw, &mods)
	out := make([]KitchenMod, 0, len(mods))
	for _, m := range mods {
		out = append(out, KitchenMod{Name: m.Name, Action: m.Action, Qty: m.Qty})
	}
	b, _ := json.Marshal(out)
	return b
}

// kitchenScreens — цеха с подключённым экраном кухни; all — есть экран всех цехов.
func kitchenScreens(ctx context.Context, q db.Querier, storeID string) (map[string]bool, bool, error) {
	rows, err := q.Query(ctx, `SELECT workshop_id::text FROM pos_devices
		WHERE store_id = $1 AND kind = 'kitchen' AND revoked_at IS NULL AND token_hash IS NOT NULL`, storeID)
	if err != nil {
		return nil, false, err
	}
	list, err := pgx.CollectRows(rows, pgx.RowTo[*string])
	if err != nil {
		return nil, false, err
	}
	out, all := map[string]bool{}, false
	for _, w := range list {
		if w == nil {
			all = true
		} else {
			out[*w] = true
		}
	}
	return out, all, nil
}

// cancelItem — отмена позиции, уже ушедшей на кухню: причина, ПИН старшего;
// кухня получает «ОТМЕНА»; если кухня начала (или просят) — продукты
// списываются как порча.
func cancelItem(ctx context.Context, tx pgx.Tx, p *identity.Principal, storeID string, op BillOp) error {
	if !httpx.IsUUID(op.ItemID) {
		return errItem
	}
	op.Reason = strings.TrimSpace(op.Reason)
	if op.Reason == "" || len([]rune(op.Reason)) > 200 {
		return apperr.Validation("reason: укажите причину отмены").Uz("reason: bekor qilish sababini kiriting")
	}
	if err := checkSenior(ctx, tx, p.NetworkID, op.ApproverID); err != nil {
		return err
	}
	if op.Qty == nil || !op.Qty.Valid() || money.D(string(*op.Qty)).Sign() <= 0 {
		return apperr.Validation("qty: сколько отменить").Uz("qty: qanchasini bekor qilish")
	}
	qty := money.D(string(*op.Qty))
	var productID, status, left, kind string
	var modsRaw []byte
	err := tx.QueryRow(ctx, `SELECT i.product_id, i.status, `+itemLeft+`::text, i.mods, pr.kind FROM bill_items i
		JOIN products pr ON pr.id = i.product_id WHERE i.id = $1 AND i.bill_id = $2 FOR UPDATE OF i`, op.ItemID, op.BillID).
		Scan(&productID, &status, &left, &modsRaw, &kind)
	if errors.Is(err, pgx.ErrNoRows) {
		return errItem
	}
	if err != nil {
		return err
	}
	if status == "new" {
		return apperr.Conflict("item_new", "позиция ещё не на кухне — её можно просто удалить").Uz("pozitsiya hali oshxonada emas — uni shunchaki oʻchirish mumkin")
	}
	if qty.Cmp(money.D(left)) > 0 {
		return apperr.Conflict("cancel_exceeds", "нельзя отменить больше, чем осталось в счёте").Uz("hisobda qolganidan koʻp bekor qilib boʻlmaydi").
			WithDetails(map[string]any{"available": left})
	}
	if _, err := tx.Exec(ctx, `UPDATE bill_items SET cancelled_qty = cancelled_qty + $2::numeric WHERE id = $1`, op.ItemID, qty.Fixed(3)); err != nil {
		return err
	}
	// Кухня: «ОТМЕНА» в строке; бегунок без строк — отменён.
	var started bool
	if err := tx.QueryRow(ctx, `
		SELECT COALESCE(bool_or(t.status IN ('cooking', 'ready', 'served') AND t.started_at IS NOT NULL), false)
		FROM kitchen_ticket_items ki JOIN kitchen_tickets t ON t.id = ki.ticket_id WHERE ki.bill_item_id = $1`, op.ItemID).Scan(&started); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		UPDATE kitchen_ticket_items ki SET cancelled_qty = LEAST(ki.qty, ki.cancelled_qty + $2::numeric)
		FROM kitchen_tickets t
		WHERE t.id = ki.ticket_id AND ki.bill_item_id = $1 AND t.status IN ('waiting', 'new', 'cooking', 'ready')`, op.ItemID, qty.Fixed(3)); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		UPDATE kitchen_tickets t SET status = 'cancelled', cancelled_at = now()
		WHERE t.bill_id = $1 AND t.status IN ('waiting', 'new', 'cooking', 'ready')
		  AND NOT EXISTS (SELECT 1 FROM kitchen_ticket_items i WHERE i.ticket_id = t.id AND i.cancelled_qty < i.qty)`, op.BillID); err != nil {
		return err
	}
	if !(started || op.Spoil) {
		return nil
	}
	// Порча: продукты по техкарте (блюдо) или сам товар.
	warehouseID, err := storeWarehouse(ctx, tx, p.NetworkID, storeID, nil)
	if err != nil {
		return err
	}
	if kind == KindDish {
		var mods []BillMod
		_ = json.Unmarshal(modsRaw, &mods)
		chosen := make([]ChosenModifier, 0, len(mods))
		for _, m := range mods {
			chosen = append(chosen, ChosenModifier{OptionID: m.OptionID, Qty: m.Qty})
		}
		resolved, err := ResolveModifiers(ctx, tx, p.NetworkID, productID, "", chosen, false)
		if err != nil {
			return err
		}
		needs, err := Explode(ctx, tx, productID, qty, resolved)
		if err != nil {
			return err
		}
		_, err = TakeIngredients(ctx, tx, p.NetworkID, warehouseID, needs, DocSpoilage, op.ID)
		return err
	}
	_, _, err = inventory.TakeUpTo(ctx, tx, p.NetworkID, warehouseID, productID, qty.Fixed(3), DocSpoilage, op.ID)
	return err
}

func tableLabel(ctx context.Context, q db.Querier, tableID string) (string, error) {
	var n string
	err := q.QueryRow(ctx, `SELECT number FROM cafe_tables WHERE id = $1`, tableID).Scan(&n)
	return n, err
}

// freeTable — стол этой точки без открытого счёта.
func freeTable(ctx context.Context, tx pgx.Tx, storeID string, tableID *string) error {
	if tableID == nil || !httpx.IsUUID(*tableID) {
		return apperr.Validation("to_table_id: стол не найден").Uz("to_table_id: stol topilmadi")
	}
	var number string
	var busy bool
	err := tx.QueryRow(ctx, `SELECT t.number, EXISTS (SELECT 1 FROM bills b WHERE b.table_id = t.id AND b.status = 'open')
		FROM cafe_tables t WHERE t.id = $1 AND t.store_id = $2 AND t.is_active FOR UPDATE`, *tableID, storeID).Scan(&number, &busy)
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.Validation("to_table_id: стол не найден").Uz("to_table_id: stol topilmadi")
	}
	if err != nil {
		return err
	}
	if busy {
		return apperr.Conflict("table_busy", "стол "+number+" занят — объедините счета").Uz(number + "-stol band — hisoblarni birlashtiring")
	}
	return nil
}

// moveBill — счёт, заказы на кухне и официант переезжают на свободный стол.
func moveBill(ctx context.Context, tx pgx.Tx, storeID string, op BillOp) error {
	if err := freeTable(ctx, tx, storeID, op.ToTableID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE bills SET table_id = $2 WHERE id = $1`, op.BillID, *op.ToTableID); err != nil {
		return err
	}
	n, err := tableLabel(ctx, tx, *op.ToTableID)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `UPDATE kitchen_tickets SET table_label = $2 WHERE bill_id = $1`, op.BillID, n)
	return err
}

// lockOther — второй счёт той же точки, открытый.
func lockOther(ctx context.Context, tx pgx.Tx, storeID, id string) error {
	var status string
	err := tx.QueryRow(ctx, `SELECT status FROM bills WHERE id = $1 AND store_id = $2 FOR UPDATE`, id, storeID).Scan(&status)
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.NotFound("счёт не найден").Uz("hisob topilmadi")
	}
	if err != nil {
		return err
	}
	if status != "open" {
		return errBillClosed
	}
	return nil
}

func hasPayments(ctx context.Context, q db.Querier, billID string) (bool, error) {
	var paid bool
	err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM sales WHERE bill_id = $1)`, billID).Scan(&paid)
	return paid, err
}

// mergeBill — объединить с занятым столом: позиции переходят в его счёт, этот закрывается.
func mergeBill(ctx context.Context, tx pgx.Tx, storeID string, op BillOp) (string, error) {
	if op.ToBillID == nil || !httpx.IsUUID(*op.ToBillID) || *op.ToBillID == op.BillID {
		return "", apperr.Validation("to_bill_id: счёт, с которым объединить").Uz("to_bill_id: qaysi hisob bilan birlashtirish")
	}
	if err := lockOther(ctx, tx, storeID, *op.ToBillID); err != nil {
		return "", err
	}
	if paid, err := hasPayments(ctx, tx, op.BillID); err != nil || paid {
		if err != nil {
			return "", err
		}
		return "", apperr.Conflict("bill_partly_paid", "часть счёта уже оплачена — объединить нельзя").Uz("hisobning bir qismi toʻlangan — birlashtirib boʻlmaydi")
	}
	if _, err := tx.Exec(ctx, `
		UPDATE bill_items i SET bill_id = $2, seq = (SELECT COALESCE(max(seq), 0) FROM bill_items WHERE bill_id = $2) + i.seq
		WHERE i.bill_id = $1`, op.BillID, *op.ToBillID); err != nil {
		return "", err
	}
	var n string
	if err := tx.QueryRow(ctx, `SELECT COALESCE(t.number, '') FROM bills b LEFT JOIN cafe_tables t ON t.id = b.table_id WHERE b.id = $1`,
		*op.ToBillID).Scan(&n); err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx, `UPDATE kitchen_tickets SET table_label = $2 WHERE bill_id = $1`, op.BillID, n); err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx, `UPDATE bills SET status = 'void', merged_into = $2, closed_at = now(), void_reason = 'merged' WHERE id = $1`,
		op.BillID, *op.ToBillID); err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx, `UPDATE bills SET version = version + 1,
		guests = LEAST(99, guests + (SELECT guests FROM bills WHERE id = $2)) WHERE id = $1`, *op.ToBillID, op.BillID); err != nil {
		return "", err
	}
	return *op.ToBillID, nil
}

// moveItems — часть блюд за другой стол (свободный — новый счёт, занятый — в его счёт).
func moveItems(ctx context.Context, tx pgx.Tx, p *identity.Principal, storeID string, op BillOp) (string, error) {
	if len(op.Items) == 0 || len(op.Items) > 200 {
		return "", apperr.Validation("items: какие блюда перенести").Uz("items: qaysi taomlarni koʻchirish")
	}
	var target string
	switch {
	case op.ToBillID != nil:
		if !httpx.IsUUID(*op.ToBillID) || *op.ToBillID == op.BillID {
			return "", apperr.Validation("to_bill_id: другой счёт").Uz("to_bill_id: boshqa hisob")
		}
		if err := lockOther(ctx, tx, storeID, *op.ToBillID); err != nil {
			return "", err
		}
		target = *op.ToBillID
	case op.NewBillID != nil && httpx.IsUUID(*op.NewBillID):
		var exists bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM bills WHERE id = $1)`, *op.NewBillID).Scan(&exists); err != nil {
			return "", err
		}
		if exists {
			return "", apperr.Conflict("bill_exists", "такой счёт уже есть").Uz("bunday hisob bor")
		}
		var guests int
		var waiter *string
		if err := tx.QueryRow(ctx, `SELECT guests, waiter_id FROM bills WHERE id = $1`, op.BillID).Scan(&guests, &waiter); err != nil {
			return "", err
		}
		g := 1
		if _, err := openBill(ctx, tx, p, storeID, BillOp{BillID: *op.NewBillID, TableID: op.ToTableID, Guests: &g, WaiterID: waiter}, time.Now(), actor{}); err != nil {
			return "", err
		}
		target = *op.NewBillID
	default:
		return "", apperr.Validation("to_bill_id или new_bill_id + to_table_id").Uz("to_bill_id yoki new_bill_id + to_table_id")
	}
	sort.Slice(op.Items, func(i, j int) bool { return op.Items[i].ID < op.Items[j].ID })
	for _, m := range op.Items {
		if !httpx.IsUUID(m.ID) || !m.Qty.Valid() || money.D(string(m.Qty)).Sign() <= 0 {
			return "", apperr.Validation("items: позиция и количество").Uz("items: pozitsiya va miqdor")
		}
		var qty, left string
		var paidOrCancelled bool
		err := tx.QueryRow(ctx, `SELECT qty::text, `+itemLeft+`::text, paid_qty > 0 OR cancelled_qty > 0 FROM bill_items
			WHERE id = $1 AND bill_id = $2 FOR UPDATE`, m.ID, op.BillID).Scan(&qty, &left, &paidOrCancelled)
		if errors.Is(err, pgx.ErrNoRows) {
			return "", errItem
		}
		if err != nil {
			return "", err
		}
		mq := money.D(string(m.Qty))
		if mq.Cmp(money.D(left)) > 0 {
			return "", apperr.Conflict("move_exceeds", "нельзя перенести больше, чем осталось").Uz("qolganidan koʻp koʻchirib boʻlmaydi")
		}
		if mq.Cmp(money.D(qty)) == 0 && !paidOrCancelled {
			if _, err := tx.Exec(ctx, `UPDATE bill_items SET bill_id = $2, seq = (SELECT COALESCE(max(seq), 0) + 1 FROM bill_items WHERE bill_id = $2)
				WHERE id = $1`, m.ID, target); err != nil {
				return "", err
			}
			continue
		}
		// Часть строки: остаток остаётся, перенесённое — новая строка.
		if _, err := tx.Exec(ctx, `UPDATE bill_items SET qty = qty - $2::numeric WHERE id = $1`, m.ID, mq.Fixed(3)); err != nil {
			return "", err
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO bill_items (id, bill_id, seq, product_id, name, name_uz, qty, price, mods, note, guest, course, status, sent_at, created_by)
			SELECT gen_random_uuid(), $2, (SELECT COALESCE(max(seq), 0) + 1 FROM bill_items WHERE bill_id = $2), product_id, name, name_uz,
			       $3::numeric, price, mods, note, NULL, course, status, sent_at, created_by
			FROM bill_items WHERE id = $1`, m.ID, target, mq.Fixed(3)); err != nil {
			return "", err
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE bills SET version = version + 1 WHERE id = $1`, target); err != nil {
		return "", err
	}
	return op.BillID, nil
}

// voidBill — закрыть стол без оплаты (гость ушёл): причина, старший кассир
// (если так настроено); кухня не готовит то, что ещё не начала.
func voidBill(ctx context.Context, tx pgx.Tx, p *identity.Principal, op BillOp) error {
	// Стол открыли по ошибке и на кухню ничего не ушло — закрыть может сам
	// официант, без причины и старшего.
	var sent bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM bill_items WHERE bill_id = $1 AND status = 'sent')`, op.BillID).Scan(&sent); err != nil {
		return err
	}
	op.Reason = strings.TrimSpace(op.Reason)
	if op.Reason == "" && !sent {
		op.Reason = "пустой счёт"
	}
	if op.Reason == "" || len([]rune(op.Reason)) > 200 {
		return apperr.Validation("reason: укажите причину").Uz("reason: sababini kiriting")
	}
	var seniorOnly bool
	if err := tx.QueryRow(ctx, `SELECT void_senior_only FROM networks WHERE id = $1`, p.NetworkID).Scan(&seniorOnly); err != nil {
		return err
	}
	if seniorOnly && sent {
		if err := checkSenior(ctx, tx, p.NetworkID, op.ApproverID); err != nil {
			return err
		}
	}
	if paid, err := hasPayments(ctx, tx, op.BillID); err != nil || paid {
		if err != nil {
			return err
		}
		return apperr.Conflict("bill_partly_paid", "часть счёта уже оплачена — закройте остаток оплатой").Uz("hisobning bir qismi toʻlangan — qolganini toʻlov bilan yoping")
	}
	if _, err := tx.Exec(ctx, `UPDATE kitchen_tickets SET status = 'cancelled', cancelled_at = now()
		WHERE bill_id = $1 AND status IN ('waiting', 'new')`, op.BillID); err != nil {
		return err
	}
	approver := op.ApproverID
	if approver == "" {
		approver = p.EmployeeID
	}
	_, err := tx.Exec(ctx, `UPDATE bills SET status = 'void', closed_at = now(), closed_by = NULLIF($2, '')::uuid, void_reason = $3 WHERE id = $1`,
		op.BillID, approver, op.Reason)
	return err
}

// =============================================================== оплата

type PaidLine struct {
	BillItemID string
	Qty        money.Dec
}

// PayBill — продажа оплачивает позиции счёта (вызывается в транзакции
// продажи). Всё оплачено (или отменено) — счёт закрыт.
func PayBill(ctx context.Context, tx pgx.Tx, networkID, storeID, billID, employeeID string, lines []PaidLine) error {
	if !httpx.IsUUID(billID) {
		return apperr.Validation("bill_id: счёт не найден").Uz("bill_id: hisob topilmadi")
	}
	var status string
	err := tx.QueryRow(ctx, `SELECT status FROM bills WHERE id = $1 AND store_id = $2 AND network_id = $3 FOR UPDATE`,
		billID, storeID, networkID).Scan(&status)
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.Validation("bill_id: счёт не найден").Uz("bill_id: hisob topilmadi")
	}
	if err != nil {
		return err
	}
	if status != "open" {
		return errBillClosed
	}
	for _, l := range lines {
		tag, err := tx.Exec(ctx, `UPDATE bill_items SET paid_qty = paid_qty + $3::numeric
			WHERE id = $1 AND bill_id = $2 AND `+itemLeft+` >= $3::numeric`, l.BillItemID, billID, l.Qty.Fixed(3))
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.Conflict("bill_item_paid", "позиция счёта уже оплачена или отменена").Uz("hisob pozitsiyasi allaqachon toʻlangan yoki bekor qilingan").
				WithDetails(map[string]any{"bill_item_id": l.BillItemID})
		}
	}
	if _, err := tx.Exec(ctx, `
		UPDATE bills b SET status = 'closed', closed_at = now(), closed_by = NULLIF($2, '')::uuid, version = version + 1
		WHERE b.id = $1 AND NOT EXISTS (SELECT 1 FROM bill_items i WHERE i.bill_id = b.id AND `+itemLeft+` > 0)`,
		billID, employeeID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE bills SET version = version + 1 WHERE id = $1 AND status = 'open'`, billID); err != nil {
		return err
	}
	_, err = events.Bump(ctx, tx, storeID)
	return err
}

// BillServicePercent — процент обслуживания счёта (проверка суммы продажи).
func BillServicePercent(ctx context.Context, q db.Querier, billID string) (money.Dec, error) {
	var pct string
	if err := q.QueryRow(ctx, `SELECT service_percent::text FROM bills WHERE id = $1`, billID).Scan(&pct); err != nil {
		return money.Dec{}, err
	}
	return money.D(pct), nil
}
