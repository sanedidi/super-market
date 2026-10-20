package tenant

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/purge"
)

// Удаление сети или магазина супер-админом (Figma «Супер-админ · удаление
// сетей и магазинов», УС1–УС4). Сначала превью: что удалится и можно ли
// удалять; потом само удаление с подтверждением названием. Всё — одной
// транзакцией. Одобренные товары сети остаются в центральной базе, чужие
// данные (другие сети, курьеры «по пути») не трогаются.

// DeleteCount — строка «что удалится» в окне подтверждения.
type DeleteCount struct {
	Key   string `json:"key"`
	Label string `json:"label"`
	Count int64  `json:"count"`
}

// DeleteBlock — почему удалить нельзя.
type DeleteBlock struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type DeletePreview struct {
	Kind        string        `json:"kind"` // network | store
	ID          string        `json:"id"`
	Name        string        `json:"name"`
	NetworkID   string        `json:"network_id"`
	NetworkName string        `json:"network_name"`
	Counts      []DeleteCount `json:"counts"`
	Total       int64         `json:"total"`
	// Одобренные товары, которые предложила сеть: остаются в центральной базе.
	KeptProducts int64 `json:"kept_products"`
	// Незавершённые онлайн-заказы — пока они есть, удалить нельзя.
	ActiveOrders int64 `json:"active_orders"`
	// Деньги сети на балансе платформы (только для сети): без money_ack
	// удалить нельзя, если они не нулевые.
	BalanceAvailable string       `json:"balance_available"`
	BalancePending   string       `json:"balance_pending"`
	MoneyAckRequired bool         `json:"money_ack_required"`
	Blocked          *DeleteBlock `json:"blocked"`
}

type DeleteInput struct {
	ConfirmName string `json:"confirm_name"`
	MoneyAck    bool   `json:"money_ack"`
}

type DeleteResult struct {
	Name   string        `json:"name"`
	Counts []DeleteCount `json:"counts"`
	Total  int64         `json:"total"`
}

// deleteGroups — что показываем в окне (по таблицам); остальное входит в «Всего записей».
var deleteGroups = []struct {
	key, label string
	tables     []string
}{
	{"stores", "Магазины", []string{"stores"}},
	{"warehouses", "Склады", []string{"warehouses"}},
	{"employees", "Сотрудники и их логины", []string{"employees"}},
	{"products", "Свои товары сети (не прошли модерацию)", []string{"products"}},
	{"store_products", "Товары в магазинах", []string{"store_products"}},
	{"prices", "Цены", []string{"prices"}},
	{"stock", "Движения товара и остатки", []string{"stock_movements"}},
	{"documents", "Документы: приходы, перемещения, цены, касса", []string{"stock_documents", "price_documents", "cash_operations", "cash_transfers", "invoice_scans"}},
	{"pos_devices", "Кассы POS", []string{"pos_devices"}},
	{"shifts", "Смены касс", []string{"pos_shifts"}},
	{"sales", "Чеки продаж", []string{"sales"}},
	{"returns", "Возвраты", []string{"customer_returns"}},
	{"orders", "Онлайн-заказы", []string{"orders"}},
	{"debts", "Долги покупателей", []string{"debt_entries"}},
	{"promotions", "Акции", []string{"promotions"}},
	{"banners", "Баннеры витрины", []string{"banners"}},
	{"invoices", "Счета за подписку", []string{"subscription_invoices"}},
	{"supply", "Связи и заказы с агентами", []string{"supply_links", "supply_orders"}},
}

func groupCounts(d *purge.Deleter) []DeleteCount {
	out := []DeleteCount{}
	for _, g := range deleteGroups {
		var n int64
		for _, t := range g.tables {
			n += d.Deleted[t]
		}
		if n > 0 {
			out = append(out, DeleteCount{Key: g.key, Label: g.label, Count: n})
		}
	}
	return out
}

// Названия таблиц для сообщения «почему нельзя» — понятными словами.
var tableTitles = map[string]string{
	"stock_documents":      "складские документы",
	"stock_movements":      "движения товара",
	"stock_document_items": "строки складских документов",
	"batches":              "партии товара",
	"cash_operations":      "кассовые операции",
	"cash_entries":         "движения по кассе",
	"cash_transfers":       "перемещения денег между кассами",
	"sale_items":           "строки чеков",
	"sale_item_batches":    "строки чеков",
	"order_items":          "строки заказов",
	"supply_order_items":   "заказы магазинов у агента",
	"stock_reservations":   "резервы товара под заказы",
	"products":             "товары",
	"counterparties":       "контрагенты",
}

func foreignBlock(fe *purge.ForeignError, kind string) *DeleteBlock {
	what := tableTitles[fe.Table]
	if what == "" {
		what = fe.Table
	}
	msg := fmt.Sprintf("На данные %s ссылаются записи, которые нужно сохранить: %s (%s → %s). ",
		map[string]string{"network": "сети", "store": "магазина"}[kind], what, fe.Table, fe.Parent)
	if kind == "store" {
		msg += "Удалить можно сеть целиком, либо выключите магазин."
	} else {
		msg += "Проверьте, с кем связана сеть (агенты, магазины других сетей), или напишите разработчику — таблица указана в скобках."
	}
	return &DeleteBlock{Code: "linked", Message: msg}
}

const activeOrderStatuses = `('awaiting_payment', 'paid', 'accepted', 'picking', 'picked', 'delivering')`

// purgeNetwork удаляет сеть в tx; превью — то же самое с откатом.
func purgeNetwork(ctx context.Context, tx pgx.Tx, id string) (*purge.Deleter, error) {
	rows, err := tx.Query(ctx, `SELECT id::text FROM stores WHERE network_id = $1`, id)
	if err != nil {
		return nil, err
	}
	stores, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, err
	}
	d, err := purge.New(ctx, tx, purge.NetworkScope(id, stores))
	if err != nil {
		return nil, err
	}
	if err := limits(ctx, tx); err != nil {
		return nil, err
	}
	return d, d.Remove("networks", []string{"id"}, []string{id})
}

// networkFacts — имя, деньги, заказы и одобренные товары сети.
func networkFacts(ctx context.Context, q db.Querier, id string, lock bool) (DeletePreview, error) {
	p := DeletePreview{Kind: "network", ID: id, NetworkID: id, Counts: []DeleteCount{}}
	sql := `SELECT name FROM networks WHERE id = $1`
	if lock {
		sql += ` FOR UPDATE`
	}
	if err := q.QueryRow(ctx, sql, id).Scan(&p.Name); errors.Is(err, pgx.ErrNoRows) {
		return p, apperr.NotFound("сеть не найдена").Uz("tarmoq topilmadi")
	} else if err != nil {
		return p, err
	}
	p.NetworkName = p.Name
	var money bool
	err := q.QueryRow(ctx, `
		SELECT COALESCE(sum(amount) FILTER (WHERE status = 'available'), 0)::numeric(18,2)::text,
		       COALESCE(sum(amount) FILTER (WHERE status = 'pending'), 0)::numeric(18,2)::text,
		       COALESCE(sum(amount) FILTER (WHERE status = 'available'), 0) <> 0 OR COALESCE(sum(amount) FILTER (WHERE status = 'pending'), 0) <> 0
		FROM balance_entries WHERE network_id = $1`, id).Scan(&p.BalanceAvailable, &p.BalancePending, &money)
	if err != nil {
		return p, err
	}
	p.MoneyAckRequired = money
	if err := q.QueryRow(ctx, `SELECT count(*) FROM orders WHERE network_id = $1 AND status IN `+activeOrderStatuses, id).Scan(&p.ActiveOrders); err != nil {
		return p, err
	}
	err = q.QueryRow(ctx, `SELECT count(*) FROM products WHERE proposed_by = $1 AND network_id IS NULL`, id).Scan(&p.KeptProducts)
	return p, err
}

func activeOrdersBlock(n int64, kind string) *DeleteBlock {
	return &DeleteBlock{Code: "active_orders", Message: fmt.Sprintf(
		"У %s %d незавершённых онлайн-заказа(ов). Дождитесь доставки или отмените их — потом удаление станет доступно.",
		map[string]string{"network": "сети", "store": "магазина"}[kind], n)}
}

// PreviewNetworkDelete — что удалится вместе с сетью и можно ли удалять.
func (s *Service) PreviewNetworkDelete(ctx context.Context, id string) (DeletePreview, error) {
	var out DeletePreview
	err := rollbackTx(ctx, s, func(tx pgx.Tx) error {
		p, err := networkFacts(ctx, tx, id, false)
		if err != nil {
			return err
		}
		if p.ActiveOrders > 0 {
			p.Blocked = activeOrdersBlock(p.ActiveOrders, "network")
		}
		d, err := purgeNetwork(ctx, tx, id)
		var fe *purge.ForeignError
		switch {
		case errors.As(err, &fe):
			if p.Blocked == nil {
				p.Blocked = foreignBlock(fe, "network")
			}
		case err != nil:
			return err
		default:
			p.Counts, p.Total = groupCounts(d), d.Total()
		}
		out = p
		return nil
	})
	return out, err
}

// DeleteNetwork удаляет сеть целиком. confirm_name — название сети;
// money_ack — обязателен, если на балансе есть деньги.
func (s *Service) DeleteNetwork(ctx context.Context, admin *identity.Principal, id string, in DeleteInput) (DeleteResult, error) {
	var out DeleteResult
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		p, err := networkFacts(ctx, tx, id, true)
		if err != nil {
			return err
		}
		if err := checkConfirm(p.Name, in.ConfirmName); err != nil {
			return err
		}
		if p.ActiveOrders > 0 {
			return apperr.Conflict("active_orders", activeOrdersBlock(p.ActiveOrders, "network").Message)
		}
		if p.MoneyAckRequired && !in.MoneyAck {
			return apperr.Conflict("money_ack_required", fmt.Sprintf(
				"На балансе сети %s сум (и %s в пути). Подтвердите, что деньги выплачены или магазин от них отказался.",
				p.BalanceAvailable, p.BalancePending))
		}
		money, err := archive(ctx, tx, archiveNetworkSQL, id)
		if err != nil {
			return err
		}
		d, err := purgeNetwork(ctx, tx, id)
		var fe *purge.ForeignError
		if errors.As(err, &fe) {
			return apperr.Conflict("linked", foreignBlock(fe, "network").Message)
		}
		if err != nil {
			return err
		}
		if err := logDeletion(ctx, tx, admin, "network", id, p.Name, id, p.Name, p.BalanceAvailable, money, d); err != nil {
			return err
		}
		out = DeleteResult{Name: p.Name, Counts: groupCounts(d), Total: d.Total()}
		return nil
	})
	return out, err
}

// ------------------------------------------------------------- магазин

type storeFacts struct {
	DeletePreview
	stores                int
	warehouses, cashboxes []string
}

func loadStoreFacts(ctx context.Context, q db.Querier, id string, lock bool) (storeFacts, error) {
	f := storeFacts{DeletePreview: DeletePreview{Kind: "store", ID: id, Counts: []DeleteCount{}, BalanceAvailable: "0.00", BalancePending: "0.00"}}
	sql := `SELECT s.name, s.network_id, n.name,
	               (SELECT count(*) FROM stores x WHERE x.network_id = s.network_id)::int
	        FROM stores s JOIN networks n ON n.id = s.network_id WHERE s.id = $1`
	if lock {
		sql += ` FOR UPDATE OF s, n`
	}
	if err := q.QueryRow(ctx, sql, id).Scan(&f.Name, &f.NetworkID, &f.NetworkName, &f.stores); errors.Is(err, pgx.ErrNoRows) {
		return f, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	} else if err != nil {
		return f, err
	}
	if err := q.QueryRow(ctx, `SELECT count(*) FROM orders WHERE store_id = $1 AND status IN `+activeOrderStatuses, id).Scan(&f.ActiveOrders); err != nil {
		return f, err
	}
	for _, x := range []struct {
		sql string
		dst *[]string
	}{
		{`SELECT id::text FROM warehouses WHERE store_id = $1`, &f.warehouses},
		{`SELECT id::text FROM cashboxes WHERE store_id = $1`, &f.cashboxes},
	} {
		rows, err := q.Query(ctx, x.sql, id)
		if err != nil {
			return f, err
		}
		if *x.dst, err = pgx.CollectRows(rows, pgx.RowTo[string]); err != nil {
			return f, err
		}
	}
	return f, nil
}

func onlyStoreBlock(name string) *DeleteBlock {
	return &DeleteBlock{Code: "only_store", Message: fmt.Sprintf(
		"«%s» — единственный магазин сети. Отдельно его удалить нельзя: удалите сеть целиком.", name)}
}

func purgeStore(ctx context.Context, tx pgx.Tx, f storeFacts) (*purge.Deleter, error) {
	d, err := purge.New(ctx, tx, purge.StoreScope(f.ID, f.warehouses, f.cashboxes))
	if err != nil {
		return nil, err
	}
	if err := limits(ctx, tx); err != nil {
		return nil, err
	}
	return d, d.Remove("stores", []string{"id"}, []string{f.ID})
}

// PreviewStoreDelete — что удалится вместе с магазином.
func (s *Service) PreviewStoreDelete(ctx context.Context, id string) (DeletePreview, error) {
	var out DeletePreview
	err := rollbackTx(ctx, s, func(tx pgx.Tx) error {
		f, err := loadStoreFacts(ctx, tx, id, false)
		if err != nil {
			return err
		}
		switch {
		case f.stores <= 1:
			f.Blocked = onlyStoreBlock(f.Name)
		case f.ActiveOrders > 0:
			f.Blocked = activeOrdersBlock(f.ActiveOrders, "store")
		}
		if f.stores > 1 {
			d, err := purgeStore(ctx, tx, f)
			var fe *purge.ForeignError
			switch {
			case errors.As(err, &fe):
				if f.Blocked == nil {
					f.Blocked = foreignBlock(fe, "store")
				}
			case err != nil:
				return err
			default:
				f.Counts, f.Total = groupCounts(d), d.Total()
			}
		}
		out = f.DeletePreview
		return nil
	})
	return out, err
}

// DeleteStore удаляет магазин; сеть и другие её магазины остаются.
func (s *Service) DeleteStore(ctx context.Context, admin *identity.Principal, id string, in DeleteInput) (DeleteResult, error) {
	var out DeleteResult
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		f, err := loadStoreFacts(ctx, tx, id, true)
		if err != nil {
			return err
		}
		if err := checkConfirm(f.Name, in.ConfirmName); err != nil {
			return err
		}
		if f.stores <= 1 {
			return apperr.Conflict("only_store", onlyStoreBlock(f.Name).Message)
		}
		if f.ActiveOrders > 0 {
			return apperr.Conflict("active_orders", activeOrdersBlock(f.ActiveOrders, "store").Message)
		}
		money, err := archive(ctx, tx, archiveStoreSQL, id)
		if err != nil {
			return err
		}
		d, err := purgeStore(ctx, tx, f)
		var fe *purge.ForeignError
		if errors.As(err, &fe) {
			return apperr.Conflict("linked", foreignBlock(fe, "store").Message)
		}
		if err != nil {
			return err
		}
		if err := logDeletion(ctx, tx, admin, "store", id, f.Name, f.NetworkID, f.NetworkName, "0", money, d); err != nil {
			return err
		}
		out = DeleteResult{Name: f.Name, Counts: groupCounts(d), Total: d.Total()}
		return nil
	})
	return out, err
}

// ------------------------------------------------------------- общее

func checkConfirm(name, typed string) error {
	if !strings.EqualFold(strings.Join(strings.Fields(name), " "), strings.Join(strings.Fields(typed), " ")) {
		return apperr.Validation("введите название точно, чтобы подтвердить удаление").Uz("oʻchirishni tasdiqlash uchun nomini aniq kiriting")
	}
	return nil
}

// limits — не ждать долго чужих блокировок (касса, заказы идут вживую) и не
// висеть дольше двух минут на одном запросе.
func limits(ctx context.Context, tx pgx.Tx) error {
	_, err := tx.Exec(ctx, `SET LOCAL lock_timeout = '10s'; SET LOCAL statement_timeout = '120s'`)
	return err
}

// Денежная история — копией в журнал: платежи покупателей (сверка с
// Payme/Click), выплаты, счета за подписку, баланс, долги покупателей.
const archiveNetworkSQL = `
	SELECT json_build_object(
		'payments', (SELECT COALESCE(json_agg(p), '[]') FROM payments p JOIN orders o ON o.id = p.order_id WHERE o.network_id = $1),
		'payouts', (SELECT COALESCE(json_agg(x), '[]') FROM payouts x WHERE x.network_id = $1),
		'subscription_invoices', (SELECT COALESCE(json_agg(x), '[]') FROM subscription_invoices x WHERE x.network_id = $1),
		'balance_entries', (SELECT COALESCE(json_agg(x), '[]') FROM balance_entries x WHERE x.network_id = $1),
		'debt_entries', (SELECT COALESCE(json_agg(x), '[]') FROM debt_entries x WHERE x.network_id = $1))`

const archiveStoreSQL = `
	SELECT json_build_object(
		'payments', (SELECT COALESCE(json_agg(p), '[]') FROM payments p JOIN orders o ON o.id = p.order_id WHERE o.store_id = $1),
		'debt_entries', (SELECT COALESCE(json_agg(x), '[]') FROM debt_entries x WHERE x.store_id = $1))`

func archive(ctx context.Context, tx pgx.Tx, sql, id string) ([]byte, error) {
	var b []byte
	err := tx.QueryRow(ctx, sql, id).Scan(&b)
	return b, err
}

// rollbackTx выполняет fn в транзакции и всегда откатывает её (превью).
func rollbackTx(ctx context.Context, s *Service, fn func(tx pgx.Tx) error) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.WithoutCancel(ctx)) //nolint:errcheck
	return fn(tx)
}

func logDeletion(ctx context.Context, tx pgx.Tx, admin *identity.Principal, kind, id, name, networkID, networkName, balance string, money []byte, d *purge.Deleter) error {
	deleted, err := json.Marshal(d.Deleted)
	if err != nil {
		return err
	}
	detached, err := json.Marshal(d.Detached)
	if err != nil {
		return err
	}
	var by *string
	if admin != nil && admin.UserID != "" {
		by = &admin.UserID
	}
	_, err = tx.Exec(ctx, `
		INSERT INTO admin_deletions (kind, target_id, name, network_id, network_name, deleted, detached, balance, money, deleted_by)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8::numeric, $9, $10)`,
		kind, id, name, networkID, networkName, deleted, detached, balance, money, by)
	return err
}

// ------------------------------------------------------------- HTTP

func (m *Module) previewNetworkDelete(w http.ResponseWriter, r *http.Request) {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	handle(m, w, r, http.StatusOK, func() (DeletePreview, error) { return m.svc.PreviewNetworkDelete(r.Context(), id) })
}

func (m *Module) deleteNetwork(w http.ResponseWriter, r *http.Request) {
	withBody(m, w, r, http.StatusOK, "id", func(id string, in DeleteInput) (DeleteResult, error) {
		return m.svc.DeleteNetwork(r.Context(), identity.FromContext(r.Context()), id, in)
	})
}

func (m *Module) previewStoreDelete(w http.ResponseWriter, r *http.Request) {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	handle(m, w, r, http.StatusOK, func() (DeletePreview, error) { return m.svc.PreviewStoreDelete(r.Context(), id) })
}

func (m *Module) deleteStore(w http.ResponseWriter, r *http.Request) {
	withBody(m, w, r, http.StatusOK, "id", func(id string, in DeleteInput) (DeleteResult, error) {
		return m.svc.DeleteStore(r.Context(), identity.FromContext(r.Context()), id, in)
	})
}
