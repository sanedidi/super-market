package family

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/delivery"
	"github.com/sanedidi/super-market/backend/internal/orders"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
	"github.com/sanedidi/super-market/backend/internal/push"
)

type Item struct {
	ID          string  `json:"id"`
	Line        int     `json:"line"`
	ProductID   *string `json:"product_id"`
	ProductName *string `json:"product_name"`
	UnitShort   *string `json:"unit_short"`
	Image       *string `json:"image"`
	Text        string  `json:"text"`
	Qty         string  `json:"qty"`
	Bought      bool    `json:"bought"`
	BoughtBy    *string `json:"bought_by_name"`
}

type Request struct {
	ID             string     `json:"id"`
	Title          string     `json:"title"`
	Comment        string     `json:"comment"`
	Status         string     `json:"status"`
	AuthorID       *string    `json:"author_id"`
	AuthorName     string     `json:"author_name"`
	AssigneeID     *string    `json:"assignee_id"`
	AssigneeName   string     `json:"assignee_name"`
	RemindAt       *time.Time `json:"remind_at"`
	RemindAtStore  bool       `json:"remind_at_store"`
	DeliverOfferAt *time.Time `json:"deliver_offer_at"`
	OrderID        *string    `json:"order_id"`
	ItemsTotal     int        `json:"items_total"`
	ItemsBought    int        `json:"items_bought"`
	Summary        string     `json:"summary"`
	CreatedAt      time.Time  `json:"created_at"`
	// Мне ли эта просьба (назначена мне или «любому», и не я её автор).
	ForMe bool   `json:"for_me"`
	Items []Item `json:"items,omitempty"`
}

const requestSelect = `
	SELECT r.id, r.title, r.comment, r.status, r.author_id,
	       COALESCE((SELECT COALESCE(NULLIF(u.full_name, ''), NULLIF(fm.label, ''), loc('Номер …', 'Raqam …') || right(u.phone, 4))
	                 FROM users u LEFT JOIN family_members fm ON fm.user_id = u.id WHERE u.id = r.author_id), loc('Бывший участник', 'Sobiq aʼzo')),
	       r.assignee_id,
	       COALESCE((SELECT COALESCE(NULLIF(u.full_name, ''), NULLIF(fm.label, ''), loc('Номер …', 'Raqam …') || right(u.phone, 4))
	                 FROM users u LEFT JOIN family_members fm ON fm.user_id = u.id WHERE u.id = r.assignee_id), loc('Любой из семьи', 'Oiladan istalgan kishi')),
	       r.remind_at, r.remind_at_store, r.deliver_offer_at, r.order_id,
	       (SELECT count(*) FROM shopping_request_items i WHERE i.request_id = r.id)::int,
	       (SELECT count(*) FROM shopping_request_items i WHERE i.request_id = r.id AND i.bought)::int,
	       COALESCE((SELECT string_agg(COALESCE(loc(p.name, p.name_uz), i.text) || CASE WHEN i.qty <> 1 THEN ' ×' || trim_scale(i.qty)::text ELSE '' END, ', ' ORDER BY i.line)
	                 FROM shopping_request_items i LEFT JOIN products p ON p.id = i.product_id WHERE i.request_id = r.id), ''),
	       r.created_at,
	       r.status IN ('pending', 'partial') AND (r.assignee_id IS NOT DISTINCT FROM $2 OR (r.assignee_id IS NULL AND r.author_id IS DISTINCT FROM $2))
	FROM shopping_requests r`

func scanRequest(row pgx.CollectableRow) (Request, error) {
	var r Request
	err := row.Scan(&r.ID, &r.Title, &r.Comment, &r.Status, &r.AuthorID, &r.AuthorName, &r.AssigneeID, &r.AssigneeName,
		&r.RemindAt, &r.RemindAtStore, &r.DeliverOfferAt, &r.OrderID, &r.ItemsTotal, &r.ItemsBought, &r.Summary, &r.CreatedAt, &r.ForMe)
	return r, err
}

// Requests — просьбы семьи: active — ждут покупки, иначе история.
func (s *Service) Requests(ctx context.Context, userID string, active bool, page httpx.Page) ([]Request, error) {
	familyID, _, err := s.mustFamily(ctx, userID)
	if err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, requestSelect+`
		WHERE r.family_id = $1 AND (r.status IN ('pending', 'partial')) = $3
		ORDER BY CASE WHEN $3 THEN COALESCE(r.remind_at, r.created_at) END, r.created_at DESC
		LIMIT $4 OFFSET $5`, familyID, userID, active, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanRequest)
}

func (s *Service) getRequest(ctx context.Context, q db.Querier, userID, id string) (Request, string, error) {
	if err := validUUID(id); err != nil {
		return Request{}, "", apperr.NotFound("просьба не найдена").Uz("soʻrov topilmadi")
	}
	familyID, _, err := membership(ctx, q, userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return Request{}, "", errNoFamily
	}
	if err != nil {
		return Request{}, "", err
	}
	rows, err := q.Query(ctx, requestSelect+` WHERE r.family_id = $1 AND r.id = $3`, familyID, userID, id)
	if err != nil {
		return Request{}, "", err
	}
	r, err := pgx.CollectExactlyOneRow(rows, scanRequest)
	if errors.Is(err, pgx.ErrNoRows) {
		return r, "", apperr.NotFound("просьба не найдена").Uz("soʻrov topilmadi")
	}
	if err != nil {
		return r, "", err
	}
	rows, err = q.Query(ctx, `
		SELECT i.id, i.line, i.product_id, loc(p.name, p.name_uz), loc(un.short_name, un.short_name_uz), p.images[1], i.text, trim_scale(i.qty)::text, i.bought,
		       (SELECT COALESCE(NULLIF(u.full_name, ''), loc('кто-то из семьи', 'oiladan kimdir')) FROM users u WHERE u.id = i.bought_by)
		FROM shopping_request_items i
		LEFT JOIN products p ON p.id = i.product_id
		LEFT JOIN units un ON un.id = p.unit_id
		WHERE i.request_id = $1 ORDER BY i.line`, id)
	if err != nil {
		return r, "", err
	}
	r.Items, err = pgx.CollectRows(rows, pgx.RowToStructByPos[Item])
	return r, familyID, err
}

func (s *Service) Request(ctx context.Context, userID, id string) (Request, error) {
	r, _, err := s.getRequest(ctx, s.pool, userID, id)
	return r, err
}

type ItemInput struct {
	ProductID *string   `json:"product_id"`
	Text      string    `json:"text"`
	Qty       money.Qty `json:"qty"`
}

type RequestInput struct {
	Title          string      `json:"title"`
	AssigneeID     *string     `json:"assignee_id"`
	Comment        string      `json:"comment"`
	RemindAt       *time.Time  `json:"remind_at"`
	RemindAtStore  bool        `json:"remind_at_store"`
	DeliverOfferAt *time.Time  `json:"deliver_offer_at"`
	Items          []ItemInput `json:"items"`
}

// CreateRequest — попросить купить. Исполнителю сразу приходит push;
// если задано время — ещё и напоминание в это время.
func (s *Service) CreateRequest(ctx context.Context, userID string, in RequestInput) (Request, error) {
	familyID, _, err := s.mustFamily(ctx, userID)
	if err != nil {
		return Request{}, err
	}
	in.Title = strings.TrimSpace(in.Title)
	if in.Title == "" {
		in.Title = i18n.T(ctx, "Купить по дороге домой", "Uyga qaytishda sotib olish")
	}
	in.Comment = strings.TrimSpace(in.Comment)
	switch {
	case len([]rune(in.Title)) > 80:
		return Request{}, apperr.Validation("title: не длиннее 80 символов").Uz("title: 80 belgidan oshmasin")
	case len([]rune(in.Comment)) > 500:
		return Request{}, apperr.Validation("comment: не длиннее 500 символов").Uz("comment: 500 belgidan oshmasin")
	case len(in.Items) == 0 || len(in.Items) > 50:
		return Request{}, apperr.Validation("items: от 1 до 50 товаров").Uz("items: 1 dan 50 tagacha mahsulot")
	case in.DeliverOfferAt != nil && !in.DeliverOfferAt.After(s.now()):
		return Request{}, apperr.Validation("deliver_offer_at: время уже прошло").Uz("deliver_offer_at: vaqt allaqachon oʻtgan")
	case in.RemindAt != nil && in.RemindAt.After(s.now().Add(7*24*time.Hour)):
		return Request{}, apperr.Validation("remind_at: не дальше недели").Uz("remind_at: bir haftadan uzoq boʻlmasin")
	}
	if in.AssigneeID != nil {
		fid, _, err := membership(ctx, s.pool, *in.AssigneeID)
		if !httpx.IsUUID(*in.AssigneeID) || errors.Is(err, pgx.ErrNoRows) || (err == nil && fid != familyID) {
			return Request{}, apperr.Validation("assignee_id: такого человека нет в семье").Uz("assignee_id: oilada bunday odam yoʻq")
		}
		if err != nil {
			return Request{}, err
		}
	}
	for i, it := range in.Items {
		it.Text = strings.TrimSpace(it.Text)
		in.Items[i].Text = it.Text
		if it.Qty == "" {
			in.Items[i].Qty = "1"
		} else if !it.Qty.Valid() || money.D(string(it.Qty)).Sign() <= 0 {
			return Request{}, apperr.Validation(fmt.Sprintf("items[%d].qty: больше нуля", i)).Uz(fmt.Sprintf("items[%d].qty: noldan katta boʻlsin", i))
		}
		if it.ProductID == nil && it.Text == "" {
			return Request{}, apperr.Validation(fmt.Sprintf("items[%d]: товар или текст", i)).Uz(fmt.Sprintf("items[%d]: mahsulot yoki matn", i))
		}
		if len([]rune(it.Text)) > 100 {
			return Request{}, apperr.Validation(fmt.Sprintf("items[%d].text: не длиннее 100 символов", i)).Uz(fmt.Sprintf("items[%d].text: 100 belgidan oshmasin", i))
		}
		if it.ProductID != nil && !httpx.IsUUID(*it.ProductID) {
			return Request{}, apperr.Validation(fmt.Sprintf("items[%d].product_id: товар не найден", i)).Uz(fmt.Sprintf("items[%d].product_id: mahsulot topilmadi", i))
		}
	}
	now := s.now()
	remindNow := in.RemindAt == nil || !in.RemindAt.After(now.Add(5*time.Minute))
	var id string
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var remindedAt *time.Time
		if remindNow {
			remindedAt = &now
		}
		if err := tx.QueryRow(ctx, `
			INSERT INTO shopping_requests (family_id, author_id, assignee_id, title, comment, remind_at, remind_at_store, deliver_offer_at, reminded_at)
			VALUES ($1, $2, $3, $4, $5, COALESCE($6, now()), $7, $8, $9) RETURNING id`,
			familyID, userID, in.AssigneeID, in.Title, in.Comment, in.RemindAt, in.RemindAtStore, in.DeliverOfferAt, remindedAt).Scan(&id); err != nil {
			return err
		}
		for i, it := range in.Items {
			if _, err := tx.Exec(ctx, `INSERT INTO shopping_request_items (request_id, line, product_id, text, qty)
				VALUES ($1, $2, $3, $4, $5::numeric)`, id, i+1, it.ProductID, it.Text, string(it.Qty)); err != nil {
				if db.IsForeignKeyViolation(err) {
					return apperr.Validation(fmt.Sprintf("items[%d].product_id: товар не найден", i)).Uz(fmt.Sprintf("items[%d].product_id: mahsulot topilmadi", i))
				}
				return err
			}
		}
		r, _, err := s.getRequest(ctx, tx, userID, id)
		if err != nil {
			return err
		}
		title := i18n.Text{RU: r.AuthorName + " просит купить", UZ: r.AuthorName + " xarid qilishni soʻramoqda"}
		body := i18n.Text{RU: r.Summary, UZ: r.Summary}
		if !remindNow {
			at := in.RemindAt.In(delivery.Tashkent).Format("15:04")
			body.RU += " · напомним в " + at
			body.UZ += " · soat " + at + " da eslatamiz"
		}
		return s.notifyAssignees(ctx, tx, r, familyID, "family_request", title, body)
	})
	if err != nil {
		return Request{}, err
	}
	return s.Request(ctx, userID, id)
}

// notifyAssignees — исполнителю или всем, кроме автора.
func (s *Service) notifyAssignees(ctx context.Context, q db.Querier, r Request, familyID, kind string, title, body i18n.Text) error {
	data := map[string]string{"type": "family_request", "request_id": r.ID}
	if r.AssigneeID != nil {
		return push.Enqueue(ctx, q, *r.AssigneeID, kind, title, body, data)
	}
	author := ""
	if r.AuthorID != nil {
		author = *r.AuthorID
	}
	return notifyFamily(ctx, q, familyID, author, kind, title, body, data)
}

// lockRequest — просьба семьи пользователя под блокировкой, в активном статусе.
func (s *Service) lockRequest(ctx context.Context, tx pgx.Tx, userID, id string) (Request, string, error) {
	r, familyID, err := s.getRequest(ctx, tx, userID, id)
	if err != nil {
		return r, familyID, err
	}
	if _, err := tx.Exec(ctx, `SELECT 1 FROM shopping_requests WHERE id = $1 FOR UPDATE`, id); err != nil {
		return r, familyID, err
	}
	if r.Status != "pending" && r.Status != "partial" {
		return r, familyID, apperr.Conflict("request_closed", "просьба уже выполнена или отменена").Uz("soʻrov allaqachon bajarilgan yoki bekor qilingan")
	}
	return r, familyID, nil
}

type BoughtInput struct {
	Bought bool `json:"bought"`
}

// MarkItem — отметить товар купленным. Когда куплено всё, автору уходит push.
func (s *Service) MarkItem(ctx context.Context, userID, id, itemID string, in BoughtInput) (Request, error) {
	if err := validUUID(itemID); err != nil {
		return Request{}, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		r, _, err := s.lockRequest(ctx, tx, userID, id)
		if err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `UPDATE shopping_request_items SET bought = $3,
			bought_by = CASE WHEN $3 THEN $4::uuid END, bought_at = CASE WHEN $3 THEN now() END
			WHERE request_id = $1 AND id = $2`, id, itemID, in.Bought, userID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
		}
		var total, bought int
		if err := tx.QueryRow(ctx, `SELECT count(*), count(*) FILTER (WHERE bought) FROM shopping_request_items WHERE request_id = $1`, id).Scan(&total, &bought); err != nil {
			return err
		}
		status := "pending"
		switch {
		case bought == total:
			status = "bought"
		case bought > 0:
			status = "partial"
		}
		if _, err := tx.Exec(ctx, `UPDATE shopping_requests SET status = $2, updated_at = now() WHERE id = $1`, id, status); err != nil {
			return err
		}
		if status == "bought" && r.AuthorID != nil && *r.AuthorID != userID {
			var name string
			if err := tx.QueryRow(ctx, `SELECT COALESCE(NULLIF(u.full_name, ''), NULLIF(fm.label, ''), loc('Кто-то из семьи', 'Oiladan kimdir'))
				FROM users u LEFT JOIN family_members fm ON fm.user_id = u.id WHERE u.id = $1`, userID).Scan(&name); err != nil {
				return err
			}
			return push.Enqueue(ctx, tx, *r.AuthorID, "family_done",
				i18n.Text{RU: name + " всё купил(а)", UZ: name + " hammasini sotib oldi"},
				i18n.Text{RU: r.Title + ": " + r.Summary, UZ: r.Title + ": " + r.Summary},
				map[string]string{"type": "family_request", "request_id": id})
		}
		return nil
	})
	if err != nil {
		return Request{}, err
	}
	return s.Request(ctx, userID, id)
}

type SnoozeInput struct {
	Minutes int `json:"minutes"`
}

// Snooze — «напомнить позже» (по умолчанию через час).
func (s *Service) Snooze(ctx context.Context, userID, id string, in SnoozeInput) (Request, error) {
	if in.Minutes == 0 {
		in.Minutes = 60
	}
	if in.Minutes < 5 || in.Minutes > 24*60 {
		return Request{}, apperr.Validation("minutes: от 5 минут до суток").Uz("minutes: 5 daqiqadan bir sutkagacha")
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, _, err := s.lockRequest(ctx, tx, userID, id); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `UPDATE shopping_requests SET remind_at = now() + make_interval(mins => $2),
			reminded_at = NULL, updated_at = now() WHERE id = $1`, id, in.Minutes)
		return err
	})
	if err != nil {
		return Request{}, err
	}
	return s.Request(ctx, userID, id)
}

// Cancel — отменить просьбу может автор или владелец семьи.
func (s *Service) Cancel(ctx context.Context, userID, id string) (Request, error) {
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		r, _, err := s.lockRequest(ctx, tx, userID, id)
		if err != nil {
			return err
		}
		_, role, err := membership(ctx, tx, userID)
		if err != nil {
			return err
		}
		if (r.AuthorID == nil || *r.AuthorID != userID) && role != "owner" {
			return apperr.Forbidden("отменить просьбу может её автор или владелец семьи").Uz("soʻrovni uning muallifi yoki oila egasi bekor qilishi mumkin")
		}
		_, err = tx.Exec(ctx, `UPDATE shopping_requests SET status = 'cancelled', updated_at = now() WHERE id = $1`, id)
		return err
	})
	if err != nil {
		return Request{}, err
	}
	return s.Request(ctx, userID, id)
}

type OrderedInput struct {
	OrderID string `json:"order_id"`
}

// Ordered — «заказал домой»: просьба закрыта заказом покупателя.
func (s *Service) Ordered(ctx context.Context, userID, id string, in OrderedInput) (Request, error) {
	if !httpx.IsUUID(in.OrderID) {
		return Request{}, apperr.Validation("order_id: заказ не найден").Uz("order_id: buyurtma topilmadi")
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		r, _, err := s.lockRequest(ctx, tx, userID, id)
		if err != nil {
			return err
		}
		var number int64
		err = tx.QueryRow(ctx, `SELECT number FROM orders WHERE id = $1 AND customer_id = $2`, in.OrderID, userID).Scan(&number)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Validation("order_id: заказ не найден").Uz("order_id: buyurtma topilmadi")
		}
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE shopping_requests SET status = 'ordered', order_id = $2, updated_at = now() WHERE id = $1`, id, in.OrderID); err != nil {
			return err
		}
		if r.AuthorID != nil && *r.AuthorID != userID {
			return push.Enqueue(ctx, tx, *r.AuthorID, "family_ordered",
				i18n.Text{RU: "Заказали домой", UZ: "Uyga buyurtma berildi"},
				i18n.Text{RU: fmt.Sprintf("%s: заказ №%d привезут курьером", r.Title, number), UZ: fmt.Sprintf("%s: №%d buyurtmani kuryer olib keladi", r.Title, number)},
				map[string]string{"type": "family_request", "request_id": id})
		}
		return nil
	})
	if err != nil {
		return Request{}, err
	}
	return s.Request(ctx, userID, id)
}

// ---------------------------------------------------------- заказать домой

type QuoteLine struct {
	ItemID  string                 `json:"item_id"`
	Qty     string                 `json:"qty"`
	Product *orders.CatalogProduct `json:"product"` // null — в магазине не нашли
}

type Quote struct {
	Store   *delivery.NearbyStore `json:"store"`
	Lines   []QuoteLine           `json:"lines"`
	Found   int                   `json:"found"`
	Total   string                `json:"total"`
	Message string                `json:"message,omitempty"`
}

// ToCart — товары просьбы в ближайшем магазине, который доставляет по
// адресу: из каталога — по id, свой текст — поиском по названию. Из 5
// ближайших берётся тот, где нашлось больше всего.
func (s *Service) ToCart(ctx context.Context, userID, id string, lat, lng float64) (Quote, error) {
	r, _, err := s.getRequest(ctx, s.pool, userID, id)
	if err != nil {
		return Quote{}, err
	}
	var todo []Item
	for _, it := range r.Items {
		if !it.Bought {
			todo = append(todo, it)
		}
	}
	stores, err := s.delivery.Nearby(ctx, lat, lng)
	if err != nil {
		return Quote{}, err
	}
	if len(stores) == 0 {
		return Quote{Lines: []QuoteLine{}, Total: "0.00", Message: i18n.T(ctx, "По этому адресу пока никто не доставляет", "Bu manzilga hozircha hech kim yetkazib bermaydi")}, nil
	}
	var best Quote
	for i, st := range stores {
		if i == 5 {
			break
		}
		q := Quote{Store: &stores[i], Lines: []QuoteLine{}}
		total := money.D("0")
		for _, it := range todo {
			f := orders.CatalogFilter{Query: it.Text}
			if it.ProductID != nil {
				f = orders.CatalogFilter{IDs: []string{*it.ProductID}}
			}
			found, err := s.orders.StoreCatalog(ctx, st.ID, f, httpx.Page{Limit: 1})
			if err != nil {
				return Quote{}, err
			}
			line := QuoteLine{ItemID: it.ID, Qty: it.Qty}
			if len(found) > 0 && money.D(found[0].Available).Sign() > 0 {
				p := found[0]
				line.Product = &p
				q.Found++
				total = total.Add(money.D(p.Price).Mul(money.D(it.Qty)).Round2())
			}
			q.Lines = append(q.Lines, line)
		}
		q.Total = total.Money()
		if best.Store == nil || q.Found > best.Found {
			best = q
		}
		if q.Found == len(todo) {
			break
		}
	}
	return best, nil
}

// ------------------------------------------------------------- подсказки

type Suggestion struct {
	ProductID string `json:"product_id"`
	Name      string `json:"name"`
	Times     int    `json:"times"`
}

// Suggestions — «часто покупаете»: товары из заказов семьи за 90 дней.
func (s *Service) Suggestions(ctx context.Context, userID string) ([]Suggestion, error) {
	familyID, _, err := s.mustFamily(ctx, userID)
	if err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT oi.product_id, loc(p.name, p.name_uz), count(DISTINCT o.id)::int
		FROM orders o
		JOIN order_items oi ON oi.order_id = o.id
		JOIN products p ON p.id = oi.product_id
		WHERE o.customer_id IN (SELECT user_id FROM family_members WHERE family_id = $1)
		  AND o.status = 'delivered' AND o.created_at > now() - interval '90 days' AND p.is_active
		GROUP BY oi.product_id, p.name, p.name_uz
		ORDER BY 3 DESC, 2 LIMIT 12`, familyID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Suggestion])
}

// --------------------------------------------------------------- воркер

// Remind — напоминания в назначенное время и предложение доставки, если к
// сроку не куплено. Вызывается воркером раз в минуту.
func (s *Service) Remind(ctx context.Context) error {
	rows, err := s.pool.Query(ctx, `
		UPDATE shopping_requests SET reminded_at = now()
		WHERE status IN ('pending', 'partial') AND reminded_at IS NULL AND remind_at <= now()
		RETURNING id, family_id, author_id`)
	if err != nil {
		return err
	}
	type due struct{ id, family, author string }
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (due, error) {
		var d due
		var author *string
		err := r.Scan(&d.id, &d.family, &author)
		if author != nil {
			d.author = *author
		}
		return d, err
	})
	if err != nil {
		return err
	}
	for _, d := range list {
		if err := s.remindOne(ctx, d.id, d.family, d.author, false); err != nil {
			return err
		}
	}

	rows, err = s.pool.Query(ctx, `
		UPDATE shopping_requests SET offered_at = now()
		WHERE status IN ('pending', 'partial') AND offered_at IS NULL AND deliver_offer_at <= now()
		RETURNING id, family_id, author_id`)
	if err != nil {
		return err
	}
	list, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (due, error) {
		var d due
		var author *string
		err := r.Scan(&d.id, &d.family, &author)
		if author != nil {
			d.author = *author
		}
		return d, err
	})
	if err != nil {
		return err
	}
	for _, d := range list {
		if err := s.remindOne(ctx, d.id, d.family, d.author, true); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) remindOne(ctx context.Context, id, familyID, authorID string, offer bool) error {
	// Читаем от имени автора: for_me не нужен, нужны имена и состав.
	var viewer any // автор мог удалить аккаунт
	if authorID != "" {
		viewer = authorID
	}
	rows, err := s.pool.Query(ctx, requestSelect+` WHERE r.family_id = $1 AND r.id = $3`, familyID, viewer, id)
	if err != nil {
		return err
	}
	r, err := pgx.CollectExactlyOneRow(rows, scanRequest)
	if err != nil {
		return err
	}
	title := i18n.Text{RU: r.AuthorName + " просит купить по дороге 🛒", UZ: r.AuthorName + " yoʻl-yoʻlakay xarid qilishni soʻramoqda 🛒"}
	body := i18n.Text{RU: r.Summary, UZ: r.Summary}
	kind := "family_remind"
	if offer {
		title = i18n.Text{RU: "Не успеваете купить?", UZ: "Xarid qilishga ulgurmayapsizmi?"}
		body = i18n.Text{RU: "Закажите домой — привезёт курьер: " + r.Summary, UZ: "Uyga buyurtma bering — kuryer olib keladi: " + r.Summary}
		kind = "family_offer"
	}
	return s.notifyAssignees(ctx, s.pool, r, familyID, kind, title, body)
}
