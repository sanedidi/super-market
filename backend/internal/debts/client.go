package debts

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
	"github.com/sanedidi/super-market/backend/internal/push"
)

// Приложение покупателя: «Мои долги». Долги находятся по номеру телефона
// аккаунта во всех сетях. Признак «магазин даёт в долг» сюда не попадает.

type ClientStore struct {
	StoreID     string     `json:"store_id"`
	Name        string     `json:"name"`
	Address     string     `json:"address"`
	Phone       string     `json:"phone"`
	LogoURL     string     `json:"logo_url"`
	Lat         *float64   `json:"lat"`
	Lng         *float64   `json:"lng"`
	Amount      string     `json:"amount"`
	Since       *time.Time `json:"since"`
	DueDate     *string    `json:"due_date"`
	OverdueDays int        `json:"overdue_days"`
}

type ClientDebts struct {
	Total   string        `json:"total"`
	Stores  []ClientStore `json:"stores"`
	NextDue *string       `json:"next_due"`
}

func (s *Service) clientPhone(ctx context.Context, p *identity.Principal) (string, error) {
	var ph string
	err := s.pool.QueryRow(ctx, `SELECT phone FROM users WHERE id = $1`, p.UserID).Scan(&ph)
	return ph, err
}

// clientBalances — долги покупателя во всех сетях (по его номеру).
func (s *Service) clientBalances(ctx context.Context, ph string, storeID *string) ([]ClientStore, error) {
	rows, err := s.pool.Query(ctx, `SELECT id, network_id FROM debtors WHERE phone = $1`, ph)
	if err != nil {
		return nil, err
	}
	type dn struct{ id, network string }
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (dn, error) {
		var x dn
		err := r.Scan(&x.id, &x.network)
		return x, err
	})
	if err != nil {
		return nil, err
	}
	out := []ClientStore{}
	for _, d := range list {
		var stores []string
		if storeID != nil {
			stores = []string{*storeID}
		}
		id := d.id
		bs, err := s.balances(ctx, s.pool, d.network, stores, &id, "b.amount > 0 ORDER BY b.since")
		if err != nil {
			return nil, err
		}
		for _, b := range bs {
			c := ClientStore{StoreID: b.StoreID, Name: b.StoreName, Amount: b.Amount, Since: b.Since, DueDate: b.DueDate, OverdueDays: b.OverdueDays}
			if err := s.pool.QueryRow(ctx, `
				SELECT COALESCE(address, ''), phone, logo_url, ST_Y(location::geometry), ST_X(location::geometry) FROM stores WHERE id = $1`,
				b.StoreID).Scan(&c.Address, &c.Phone, &c.LogoURL, &c.Lat, &c.Lng); err != nil {
				return nil, err
			}
			out = append(out, c)
		}
	}
	return out, nil
}

func (s *Service) ClientDebts(ctx context.Context, p *identity.Principal) (ClientDebts, error) {
	out := ClientDebts{Total: "0.00", Stores: []ClientStore{}}
	ph, err := s.clientPhone(ctx, p)
	if err != nil {
		return out, err
	}
	if out.Stores, err = s.clientBalances(ctx, ph, nil); err != nil {
		return out, err
	}
	total := money.D("0")
	for i, c := range out.Stores {
		total = total.Add(money.D(c.Amount))
		if c.DueDate != nil && (out.NextDue == nil || *c.DueDate < *out.NextDue) {
			out.NextDue = out.Stores[i].DueDate
		}
	}
	out.Total = total.Money()
	return out, nil
}

type ClientEntry struct {
	ID        int64       `json:"id"`
	DocType   string      `json:"doc_type"`
	Number    *int64      `json:"number"`
	Amount    string      `json:"amount"`
	Balance   string      `json:"balance"`
	Detail    string      `json:"detail"`
	Dispute   string      `json:"dispute_status"`
	CreatedAt time.Time   `json:"created_at"`
	Sale      *ClientSale `json:"sale,omitempty"`
}

type ClientSale struct {
	Total string           `json:"total"`
	Paid  string           `json:"paid"`
	Debt  string           `json:"debt"`
	Items []ClientSaleItem `json:"items"`
}

type ClientSaleItem struct {
	Name  string `json:"name"`
	Qty   string `json:"qty"`
	Unit  string `json:"unit"`
	Total string `json:"total"`
}

type ClientStoreDebt struct {
	ClientStore
	Entries []ClientEntry `json:"entries"`
}

func (s *Service) ClientStoreDebt(ctx context.Context, p *identity.Principal, storeID string) (ClientStoreDebt, error) {
	var out ClientStoreDebt
	if !httpx.IsUUID(storeID) {
		return out, apperr.NotFound("долга в этом магазине нет").Uz("bu doʻkonda qarz yoʻq")
	}
	ph, err := s.clientPhone(ctx, p)
	if err != nil {
		return out, err
	}
	var debtorID string
	err = s.pool.QueryRow(ctx, `
		SELECT d.id FROM debtors d JOIN stores st ON st.network_id = d.network_id AND st.id = $2 WHERE d.phone = $1`, ph, storeID).Scan(&debtorID)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, apperr.NotFound("долга в этом магазине нет").Uz("bu doʻkonda qarz yoʻq")
	}
	if err != nil {
		return out, err
	}
	list, err := s.clientBalances(ctx, ph, &storeID)
	if err != nil {
		return out, err
	}
	if len(list) > 0 {
		out.ClientStore = list[0]
	} else {
		out.ClientStore = ClientStore{StoreID: storeID, Amount: "0.00"}
		if err := s.pool.QueryRow(ctx, `SELECT name, COALESCE(address, ''), phone, logo_url, ST_Y(location::geometry), ST_X(location::geometry)
			FROM stores WHERE id = $1`, storeID).Scan(&out.Name, &out.Address, &out.Phone, &out.LogoURL, &out.Lat, &out.Lng); err != nil {
			return out, err
		}
	}
	es, err := entries(ctx, s.pool, debtorID, []string{storeID}, 100)
	if err != nil {
		return out, err
	}
	out.Entries = make([]ClientEntry, 0, len(es))
	for _, e := range es {
		ce := ClientEntry{ID: e.ID, DocType: e.DocType, Number: e.Number, Amount: e.Amount, Balance: e.Balance, Detail: e.Detail,
			Dispute: e.Disputed, CreatedAt: e.CreatedAt}
		if e.DocType == DocSale {
			sale := &ClientSale{Items: []ClientSaleItem{}}
			if err := s.pool.QueryRow(ctx, `SELECT total::text, (total - debt_amount)::numeric(18,2)::text, debt_amount::text FROM sales WHERE id = $1`,
				e.DocID).Scan(&sale.Total, &sale.Paid, &sale.Debt); err != nil {
				return out, err
			}
			rows, err := s.pool.Query(ctx, `
				SELECT loc(p.name, p.name_uz), si.qty::text, loc(u.short_name, u.short_name_uz), si.total::text FROM sale_items si
				JOIN products p ON p.id = si.product_id JOIN units u ON u.id = p.unit_id
				WHERE si.sale_id = $1 ORDER BY si.line`, e.DocID)
			if err != nil {
				return out, err
			}
			if sale.Items, err = pgx.CollectRows(rows, pgx.RowToStructByPos[ClientSaleItem]); err != nil {
				return out, err
			}
			ce.Sale = sale
		}
		out.Entries = append(out.Entries, ce)
	}
	return out, nil
}

type DisputeInput struct {
	Comment string `json:"comment"`
}

// ClientDispute — «Это не я»: жалоба владельцу на запись долга.
func (s *Service) ClientDispute(ctx context.Context, p *identity.Principal, entryID int64, in DisputeInput) (ClientEntry, error) {
	ph, err := s.clientPhone(ctx, p)
	if err != nil {
		return ClientEntry{}, err
	}
	in.Comment = strings.TrimSpace(in.Comment)
	if len([]rune(in.Comment)) > 500 {
		return ClientEntry{}, apperr.Validation("comment: не длиннее 500 символов").Uz("comment: 500 belgidan oshmasin")
	}
	var out ClientEntry
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var networkID, storeID, docType, amount string
		err := tx.QueryRow(ctx, `
			SELECT e.network_id, e.store_id, e.doc_type, e.amount::text FROM debt_entries e JOIN debtors d ON d.id = e.debtor_id
			WHERE e.id = $1 AND d.phone = $2`, entryID, ph).Scan(&networkID, &storeID, &docType, &amount)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.NotFound("запись не найдена").Uz("yozuv topilmadi")
		}
		if err != nil {
			return err
		}
		if docType != DocSale && docType != DocManual {
			return apperr.Validation("оспорить можно только запись долга").Uz("faqat qarz yozuvi ustidan eʼtiroz bildirish mumkin")
		}
		tag, err := tx.Exec(ctx, `
			INSERT INTO debt_disputes (network_id, entry_id, user_id, comment) VALUES ($1, $2, $3, $4)
			ON CONFLICT (entry_id, user_id) DO NOTHING`, networkID, entryID, p.UserID, in.Comment)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.Conflict("already_disputed", "жалоба по этой записи уже отправлена").Uz("bu yozuv boʻyicha shikoyat allaqachon yuborilgan")
		}
		out = ClientEntry{ID: entryID, DocType: docType, Amount: amount, Dispute: "open"}
		return push.EnqueueStaff(ctx, tx, storeID, identity.PermDebtsManage, "debt_dispute",
			i18n.Text{RU: "Покупатель оспаривает долг", UZ: "Xaridor qarzga eʼtiroz bildirdi"},
			i18n.Text{RU: push.Sum(amount) + " сум — «Это не я». Проверьте запись", UZ: push.Sum(amount) + " soʻm — «Bu men emasman». Yozuvni tekshiring"},
			map[string]string{"type": "debt_dispute", "entry_id": itoa(entryID)})
	})
	return out, err
}

func itoa(n int64) string {
	b := make([]byte, 0, 20)
	if n == 0 {
		return "0"
	}
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}
