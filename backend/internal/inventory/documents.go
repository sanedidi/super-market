package inventory

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/finance"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Виды складских документов.
const (
	TypeIncome         = "income"
	TypeSupplierReturn = "supplier_return"
	TypeTransfer       = "transfer"
	TypeWriteOff       = "write_off"
	TypePosting        = "posting"
	TypeInventory      = "inventory"
)

var typeTitles = map[string]string{
	TypeIncome:         "Приход товара",
	TypeSupplierReturn: "Возврат поставщику",
	TypeTransfer:       "Перемещение",
	TypeWriteOff:       "Списание",
	TypePosting:        "Оприходование",
	TypeInventory:      "Инвентаризация",
}

// У каких документов в строках есть цена.
func hasPrice(t string) bool {
	return t == TypeIncome || t == TypeSupplierReturn || t == TypePosting
}

type Service struct {
	pool *pgxpool.Pool
}

func NewService(pool *pgxpool.Pool) *Service { return &Service{pool: pool} }

type Item struct {
	Line        int     `json:"line"`
	ProductID   string  `json:"product_id"`
	ProductName string  `json:"product_name"`
	UnitShort   string  `json:"unit_short"`
	Qty         string  `json:"qty"`
	Price       *string `json:"price"`
	ExpectedQty *string `json:"expected_qty"`
}

type Document struct {
	ID               string     `json:"id"`
	Type             string     `json:"type"`
	TypeTitle        string     `json:"type_title"`
	Number           int64      `json:"number"`
	Status           string     `json:"status"`
	WarehouseID      string     `json:"warehouse_id"`
	WarehouseName    string     `json:"warehouse_name"`
	StoreID          string     `json:"store_id"`
	ToWarehouseID    *string    `json:"to_warehouse_id"`
	ToWarehouseName  *string    `json:"to_warehouse_name"`
	CounterpartyID   *string    `json:"counterparty_id"`
	CounterpartyName *string    `json:"counterparty_name"`
	Currency         string     `json:"currency"`
	Rate             *string    `json:"rate"`
	Reason           string     `json:"reason"`
	Note             string     `json:"note"`
	Total            string     `json:"total"`
	CreatedBy        string     `json:"created_by"`
	PostedAt         *time.Time `json:"posted_at"`
	CreatedAt        time.Time  `json:"created_at"`
	ItemsCount       int        `json:"items_count"`
	Items            []Item     `json:"items,omitempty"`
}

const docSelect = `
	SELECT d.id, d.type, d.number, d.status, d.warehouse_id, w.name, w.store_id, d.to_warehouse_id, tw.name,
	       d.counterparty_id, c.name, d.currency, d.rate::text, d.reason, d.note, CASE WHEN d.status = 'draft' THEN COALESCE((SELECT sum(i.qty * i.price) FROM stock_document_items i WHERE i.document_id = d.id), 0)::numeric(18,2) ELSE d.total END::text,
	       e.full_name, d.posted_at, d.created_at,
	       (SELECT count(*) FROM stock_document_items i WHERE i.document_id = d.id)::int
	FROM stock_documents d
	JOIN warehouses w       ON w.id = d.warehouse_id
	LEFT JOIN warehouses tw ON tw.id = d.to_warehouse_id
	LEFT JOIN counterparties c ON c.id = d.counterparty_id
	JOIN employees e        ON e.id = d.created_by`

func scanDoc(row pgx.CollectableRow) (Document, error) {
	var d Document
	err := row.Scan(&d.ID, &d.Type, &d.Number, &d.Status, &d.WarehouseID, &d.WarehouseName, &d.StoreID,
		&d.ToWarehouseID, &d.ToWarehouseName, &d.CounterpartyID, &d.CounterpartyName, &d.Currency, &d.Rate,
		&d.Reason, &d.Note, &d.Total, &d.CreatedBy, &d.PostedAt, &d.CreatedAt, &d.ItemsCount)
	d.TypeTitle = typeTitles[d.Type]
	return d, err
}

// Документ виден, если есть доступ к магазину склада-источника
// (или склада-получателя для перемещения).
const docVisible = `($2 OR w.store_id = ANY($3::uuid[]) OR tw.store_id = ANY($3::uuid[]))`

type Filter struct {
	Type        string
	Status      string
	WarehouseID string
	// StoreID — документы складов магазина; перемещения — и входящие на них.
	StoreID  string
	From, To *time.Time
	Page     httpx.Page
}

func (s *Service) List(ctx context.Context, p *identity.Principal, f Filter) ([]Document, error) {
	if f.Type != "" && typeTitles[f.Type] == "" {
		return nil, apperr.Validation("type: неизвестный вид документа")
	}
	if f.StoreID != "" && !httpx.IsUUID(f.StoreID) {
		return nil, apperr.Validation("store_id: неверный id")
	}
	rows, err := s.pool.Query(ctx, docSelect+`
		WHERE d.network_id = $1 AND `+docVisible+`
		  AND ($4 = '' OR d.type = $4) AND ($5 = '' OR d.status = $5)
		  AND ($6 = '' OR d.warehouse_id::text = $6 OR d.to_warehouse_id::text = $6)
		  AND ($7::timestamptz IS NULL OR d.created_at >= $7) AND ($8::timestamptz IS NULL OR d.created_at < $8)
		  AND ($11 = '' OR w.store_id::text = $11 OR tw.store_id::text = $11)
		ORDER BY d.created_at DESC, d.number DESC LIMIT $9 OFFSET $10`,
		p.NetworkID, p.SeesAllStores(), p.StoreIDs, f.Type, f.Status, f.WarehouseID, f.From, f.To, f.Page.Limit, f.Page.Offset, f.StoreID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanDoc)
}

func (s *Service) Get(ctx context.Context, p *identity.Principal, id string) (Document, error) {
	return s.get(ctx, s.pool, p, id)
}

func (s *Service) get(ctx context.Context, q db.Querier, p *identity.Principal, id string) (Document, error) {
	rows, err := q.Query(ctx, docSelect+` WHERE d.network_id = $1 AND `+docVisible+` AND d.id = $4`,
		p.NetworkID, p.SeesAllStores(), p.StoreIDs, id)
	if err != nil {
		return Document{}, err
	}
	d, err := pgx.CollectExactlyOneRow(rows, scanDoc)
	if errors.Is(err, pgx.ErrNoRows) {
		return Document{}, apperr.NotFound("документ не найден")
	}
	if err != nil {
		return Document{}, err
	}
	rows, err = q.Query(ctx, `
		SELECT i.line, i.product_id, p.name, u.short_name, i.qty::text, i.price::text, i.expected_qty::text
		FROM stock_document_items i
		JOIN products p ON p.id = i.product_id
		JOIN units u    ON u.id = p.unit_id
		WHERE i.document_id = $1 ORDER BY i.line`, id)
	if err != nil {
		return Document{}, err
	}
	d.Items, err = pgx.CollectRows(rows, pgx.RowToStructByPos[Item])
	return d, err
}

type ItemInput struct {
	ProductID string       `json:"product_id"`
	Qty       money.Qty    `json:"qty"`
	Price     *money.Price `json:"price"` // до 4 знаков: себестоимость и цены в USD
}

type Input struct {
	Type           string       `json:"type"`
	WarehouseID    *string      `json:"warehouse_id"`
	ToWarehouseID  *string      `json:"to_warehouse_id"`
	CounterpartyID *string      `json:"counterparty_id"`
	Currency       *string      `json:"currency"`
	Reason         *string      `json:"reason"`
	Note           *string      `json:"note"`
	Items          *[]ItemInput `json:"items"`
}

// Create создаёт черновик документа.
func (s *Service) Create(ctx context.Context, p *identity.Principal, in Input) (Document, error) {
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return Document{}, err
	}
	if typeTitles[in.Type] == "" {
		return Document{}, apperr.Validation("type: ожидается income, supplier_return, transfer, write_off, posting или inventory")
	}
	if in.WarehouseID == nil || !httpx.IsUUID(*in.WarehouseID) {
		return Document{}, apperr.Validation("warehouse_id: обязательное поле")
	}
	currency := "UZS"
	if in.Currency != nil {
		currency = *in.Currency
	}
	if currency != "UZS" && currency != "USD" {
		return Document{}, apperr.Validation("currency: ожидается UZS или USD")
	}

	var id string
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if err := s.checkWarehouse(ctx, tx, p, *in.WarehouseID, true); err != nil {
			return err
		}
		if err := s.checkHeader(ctx, tx, p, in); err != nil {
			return err
		}
		n, err := db.NextNumber(ctx, tx, "stock_documents", p.NetworkID, "type = $2", in.Type)
		if err != nil {
			return err
		}
		reason, note := "", ""
		if in.Reason != nil {
			reason = strings.TrimSpace(*in.Reason)
		}
		if in.Note != nil {
			note = strings.TrimSpace(*in.Note)
		}
		if err := tx.QueryRow(ctx, `
			INSERT INTO stock_documents (network_id, type, number, warehouse_id, to_warehouse_id, counterparty_id,
			                             currency, reason, note, created_by)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING id`,
			p.NetworkID, in.Type, n, *in.WarehouseID, in.ToWarehouseID, in.CounterpartyID,
			currency, reason, note, p.EmployeeID).Scan(&id); err != nil {
			return err
		}
		if in.Items != nil {
			return s.replaceItems(ctx, tx, p, id, in.Type, *in.Items)
		}
		return nil
	})
	if err != nil {
		return Document{}, err
	}
	return s.Get(ctx, p, id)
}

// checkHeader — поля, обязательные для вида документа.
func (s *Service) checkHeader(ctx context.Context, tx pgx.Tx, p *identity.Principal, in Input) error {
	switch in.Type {
	case TypeIncome, TypeSupplierReturn:
		if in.CounterpartyID == nil || !httpx.IsUUID(*in.CounterpartyID) {
			return apperr.Validation("counterparty_id: укажите поставщика")
		}
		if err := finance.CheckCounterparty(ctx, tx, p.NetworkID, *in.CounterpartyID); err != nil {
			return err
		}
	case TypeTransfer:
		if in.ToWarehouseID == nil || !httpx.IsUUID(*in.ToWarehouseID) {
			return apperr.Validation("to_warehouse_id: укажите склад-получатель")
		}
		if *in.ToWarehouseID == *in.WarehouseID {
			return apperr.Validation("to_warehouse_id: склады должны быть разными")
		}
		// Получатель — любой склад сети, даже в магазине без доступа (перемещение между магазинами).
		if err := s.checkWarehouse(ctx, tx, p, *in.ToWarehouseID, false); err != nil {
			return apperr.Validation("to_warehouse_id: склад не найден")
		}
	case TypeWriteOff:
		if in.Reason == nil || strings.TrimSpace(*in.Reason) == "" {
			return apperr.Validation("reason: укажите причину списания")
		}
	}
	if in.Type != TypeTransfer && in.ToWarehouseID != nil {
		return apperr.Validation("to_warehouse_id: только для перемещения")
	}
	if in.Type != TypeIncome && in.Type != TypeSupplierReturn && in.CounterpartyID != nil {
		return apperr.Validation("counterparty_id: только для прихода и возврата поставщику")
	}
	if in.Currency != nil && *in.Currency != "UZS" && !hasPrice(in.Type) {
		return apperr.Validation("currency: только для документов с ценами")
	}
	return nil
}

func (s *Service) checkWarehouse(ctx context.Context, q db.Querier, p *identity.Principal, id string, needAccess bool) error {
	var storeID string
	var active bool
	err := q.QueryRow(ctx, `SELECT store_id, is_active FROM warehouses WHERE id = $1 AND network_id = $2`, id, p.NetworkID).
		Scan(&storeID, &active)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && (!active || (needAccess && !p.CanAccessStore(storeID)))) {
		return apperr.Validation("warehouse_id: склад не найден или отключён")
	}
	return err
}

func (s *Service) replaceItems(ctx context.Context, tx pgx.Tx, p *identity.Principal, docID, docType string, items []ItemInput) error {
	if _, err := tx.Exec(ctx, `DELETE FROM stock_document_items WHERE document_id = $1`, docID); err != nil {
		return err
	}
	if len(items) > 1000 {
		return apperr.Validation("items: не больше 1000 строк")
	}
	seen := map[string]bool{}
	for i, it := range items {
		line := strconv.Itoa(i + 1)
		if !httpx.IsUUID(it.ProductID) {
			return apperr.Validation("items: неверный product_id в строке " + line)
		}
		if seen[it.ProductID] {
			return apperr.Validation("items: товар повторяется в строке " + line)
		}
		seen[it.ProductID] = true
		if !it.Qty.Valid() {
			return apperr.Validation("items: не указано количество в строке " + line)
		}
		if docType != TypeInventory && strings.Trim(string(it.Qty), "0.") == "" {
			return apperr.Validation("items: количество должно быть больше нуля в строке " + line)
		}
		var price *string
		if hasPrice(docType) {
			if docType != TypeSupplierReturn && (it.Price == nil || !it.Price.Valid()) {
				return apperr.Validation("items: не указана цена в строке " + line)
			}
			if it.Price != nil {
				v := string(*it.Price)
				price = &v
			}
		} else if it.Price != nil {
			return apperr.Validation("items: у этого документа нет цен (строка " + line + ")")
		}
		tag, err := tx.Exec(ctx, `
			INSERT INTO stock_document_items (document_id, line, product_id, qty, price)
			SELECT $1, $2, p.id, $3::numeric, $4::numeric FROM products p
			JOIN units u ON u.id = p.unit_id
			WHERE p.id = $5 AND (p.network_id IS NULL OR p.network_id = $6)
			  AND (u.is_fractional OR $3::numeric = trunc($3::numeric))`,
			docID, i+1, string(it.Qty), price, it.ProductID, p.NetworkID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.Validation("items: товар не найден или количество дробное для штучного товара (строка " + line + ")")
		}
	}
	return nil
}

// Update меняет черновик: примечание, причину, поставщика, валюту и/или строки.
func (s *Service) Update(ctx context.Context, p *identity.Principal, id string, in Input) (Document, error) {
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return Document{}, err
	}
	if in.Type != "" || in.WarehouseID != nil || in.ToWarehouseID != nil {
		return Document{}, apperr.Validation("вид документа и склады не меняются — создайте новый документ")
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		d, err := s.lockDraft(ctx, tx, p, id)
		if err != nil {
			return err
		}
		merged := Input{Type: d.Type, WarehouseID: &d.WarehouseID, ToWarehouseID: d.ToWarehouseID,
			CounterpartyID: d.CounterpartyID, Currency: &d.Currency, Reason: &d.Reason}
		if in.CounterpartyID != nil {
			merged.CounterpartyID = in.CounterpartyID
		}
		if in.Currency != nil {
			merged.Currency = in.Currency
			if *in.Currency != "UZS" && *in.Currency != "USD" {
				return apperr.Validation("currency: ожидается UZS или USD")
			}
		}
		if in.Reason != nil {
			merged.Reason = in.Reason
		}
		if err := s.checkHeader(ctx, tx, p, merged); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			UPDATE stock_documents SET counterparty_id = $2, currency = $3, reason = $4, note = COALESCE($5, note)
			WHERE id = $1`, id, merged.CounterpartyID, *merged.Currency, strings.TrimSpace(*merged.Reason), trimPtr(in.Note)); err != nil {
			return err
		}
		if in.Items != nil {
			return s.replaceItems(ctx, tx, p, id, d.Type, *in.Items)
		}
		return nil
	})
	if err != nil {
		return Document{}, err
	}
	return s.Get(ctx, p, id)
}

// Delete удаляет черновик.
func (s *Service) Delete(ctx context.Context, p *identity.Principal, id string) error {
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return err
	}
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := s.lockDraft(ctx, tx, p, id); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `DELETE FROM stock_documents WHERE id = $1`, id)
		return err
	})
}

func (s *Service) lockDraft(ctx context.Context, tx pgx.Tx, p *identity.Principal, id string) (Document, error) {
	if _, err := tx.Exec(ctx, `SELECT 1 FROM stock_documents WHERE id = $1 AND network_id = $2 FOR UPDATE`, id, p.NetworkID); err != nil {
		return Document{}, err
	}
	d, err := s.get(ctx, tx, p, id)
	if err != nil {
		return Document{}, err
	}
	if !p.CanAccessStore(d.StoreID) {
		return Document{}, apperr.NotFound("документ не найден")
	}
	if d.Status != "draft" {
		return Document{}, apperr.Conflict("document_posted", "документ уже проведён")
	}
	return d, nil
}

// Post проводит документ: двигает товар, считает сумму, пишет взаиморасчёты.
func (s *Service) Post(ctx context.Context, p *identity.Principal, id string) (Document, error) {
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return Document{}, err
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		d, err := s.lockDraft(ctx, tx, p, id)
		if err != nil {
			return err
		}
		if len(d.Items) == 0 {
			return apperr.Validation("в документе нет строк")
		}
		// Повторная проверка шапки: контрагент или склад могли отключить.
		if err := s.checkHeader(ctx, tx, p, Input{Type: d.Type, WarehouseID: &d.WarehouseID,
			ToWarehouseID: d.ToWarehouseID, CounterpartyID: d.CounterpartyID, Currency: &d.Currency, Reason: &d.Reason}); err != nil {
			return err
		}

		// Курс фиксируется в документе. Для UZS-документа он нужен только
		// для себестоимости в USD; если курс не задан — USD-себестоимость 0.
		rate, err := finance.CurrentRate(ctx, tx, p.NetworkID)
		if err != nil {
			if d.Currency == "USD" {
				return err
			}
			rate = ""
		}
		var rateArg *string
		if rate != "" {
			rateArg = &rate
		}

		total := "0"
		for _, it := range d.Items {
			var lineTotal string
			switch d.Type {
			case TypeIncome, TypePosting:
				cost, costUSD, err := costs(ctx, tx, *it.Price, d.Currency, rate)
				if err != nil {
					return err
				}
				if err := AddBatch(ctx, tx, p.NetworkID, d.WarehouseID, it.ProductID, it.Qty, cost, costUSD, DocStock, d.ID); err != nil {
					return err
				}
				lineTotal = mul(ctx, tx, it.Qty, *it.Price)

			case TypeSupplierReturn:
				taken, err := TakeFIFO(ctx, tx, p.NetworkID, d.WarehouseID, it.ProductID, it.Qty, DocStock, d.ID)
				if err != nil {
					return err
				}
				if it.Price != nil {
					lineTotal = mul(ctx, tx, it.Qty, *it.Price)
				} else {
					// Цена возврата не указана — по себестоимости в валюте документа.
					lineTotal = takenCost(ctx, tx, taken, d.Currency)
					price := divide(ctx, tx, lineTotal, it.Qty)
					if _, err := tx.Exec(ctx, `UPDATE stock_document_items SET price = $3::numeric WHERE document_id = $1 AND line = $2`,
						d.ID, it.Line, price); err != nil {
						return err
					}
				}

			case TypeTransfer:
				taken, err := TakeFIFO(ctx, tx, p.NetworkID, d.WarehouseID, it.ProductID, it.Qty, DocStock, d.ID)
				if err != nil {
					return err
				}
				for _, t := range taken {
					if err := AddBatch(ctx, tx, p.NetworkID, *d.ToWarehouseID, it.ProductID, t.Qty, t.UnitCost, t.UnitCostUSD, DocStock, d.ID); err != nil {
						return err
					}
				}
				lineTotal = takenCost(ctx, tx, taken, "UZS")

			case TypeWriteOff:
				taken, err := TakeFIFO(ctx, tx, p.NetworkID, d.WarehouseID, it.ProductID, it.Qty, DocStock, d.ID)
				if err != nil {
					return err
				}
				lineTotal = takenCost(ctx, tx, taken, "UZS")

			case TypeInventory:
				expected, err := StockQty(ctx, tx, d.WarehouseID, it.ProductID)
				if err != nil {
					return err
				}
				if _, err := tx.Exec(ctx, `UPDATE stock_document_items SET expected_qty = $3::numeric WHERE document_id = $1 AND line = $2`,
					d.ID, it.Line, expected); err != nil {
					return err
				}
				var diff string
				var sign int
				if err := tx.QueryRow(ctx, `SELECT abs($1::numeric - $2::numeric)::text, sign($1::numeric - $2::numeric)::int`,
					it.Qty, expected).Scan(&diff, &sign); err != nil {
					return err
				}
				switch sign {
				case 1: // излишек — приходуем по последней себестоимости
					cost, costUSD, err := LastCost(ctx, tx, p.NetworkID, d.WarehouseID, it.ProductID)
					if err != nil {
						return err
					}
					if err := AddBatch(ctx, tx, p.NetworkID, d.WarehouseID, it.ProductID, diff, cost, costUSD, DocStock, d.ID); err != nil {
						return err
					}
					lineTotal = mul(ctx, tx, diff, cost)
				case -1: // недостача — списываем по FIFO
					taken, err := TakeFIFOPhysical(ctx, tx, p.NetworkID, d.WarehouseID, it.ProductID, diff, DocStock, d.ID)
					if err != nil {
						return err
					}
					lineTotal = "-" + takenCost(ctx, tx, taken, "UZS")
				default:
					lineTotal = "0"
				}
			}
			if err := tx.QueryRow(ctx, `SELECT ($1::numeric + $2::numeric)::text`, total, lineTotal).Scan(&total); err != nil {
				return err
			}
		}

		if _, err := tx.Exec(ctx, `
			UPDATE stock_documents SET status = 'posted', posted_by = $2, posted_at = now(),
			       rate = $3::numeric, total = round($4::numeric, 2)
			WHERE id = $1`, d.ID, p.EmployeeID, rateArg, total); err != nil {
			return err
		}

		// Взаиморасчёты с поставщиком — в UZS.
		if d.Type == TypeIncome || d.Type == TypeSupplierReturn {
			totalUZS := total
			if d.Currency == "USD" {
				totalUZS = mul(ctx, tx, total, rate)
			}
			if d.Type == TypeSupplierReturn {
				totalUZS = "-" + totalUZS
			}
			if err := finance.AddCounterparty(ctx, tx, p.NetworkID, *d.CounterpartyID, totalUZS, finance.DocStockDocument, d.ID); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return Document{}, err
	}
	return s.Get(ctx, p, id)
}

// costs — себестоимость единицы в UZS и USD по цене в валюте документа.
func costs(ctx context.Context, tx pgx.Tx, price, currency, rate string) (string, string, error) {
	var cost, costUSD string
	var err error
	switch {
	case currency == "USD":
		err = tx.QueryRow(ctx, `SELECT round($1::numeric * $2::numeric, 4)::text, $1::numeric::text`, price, rate).Scan(&cost, &costUSD)
	case rate != "":
		err = tx.QueryRow(ctx, `SELECT $1::numeric::text, round($1::numeric / $2::numeric, 6)::text`, price, rate).Scan(&cost, &costUSD)
	default:
		cost, costUSD = price, "0"
	}
	return cost, costUSD, err
}

func mul(ctx context.Context, tx pgx.Tx, a, b string) string {
	var out string
	_ = tx.QueryRow(ctx, `SELECT round($1::numeric * $2::numeric, 2)::text`, a, b).Scan(&out)
	return out
}

func divide(ctx context.Context, tx pgx.Tx, a, b string) string {
	var out string
	_ = tx.QueryRow(ctx, `SELECT round($1::numeric / NULLIF($2::numeric, 0), 4)::text`, a, b).Scan(&out)
	if out == "" {
		return "0"
	}
	return out
}

// takenCost — себестоимость списанного в UZS или USD.
func takenCost(ctx context.Context, tx pgx.Tx, taken []Taken, currency string) string {
	total := "0"
	for _, t := range taken {
		cost := t.UnitCost
		if currency == "USD" {
			cost = t.UnitCostUSD
		}
		_ = tx.QueryRow(ctx, `SELECT round($1::numeric + $2::numeric * $3::numeric, 2)::text`, total, t.Qty, cost).Scan(&total)
	}
	return total
}

func trimPtr(p *string) *string {
	if p == nil {
		return nil
	}
	t := strings.TrimSpace(*p)
	return &t
}

// ------------------------------------------------------------------ остатки

type StockRow struct {
	WarehouseID   string `json:"warehouse_id"`
	WarehouseName string `json:"warehouse_name"`
	StoreID       string `json:"store_id"`
	ProductID     string `json:"product_id"`
	ProductName   string `json:"product_name"`
	UnitShort     string `json:"unit_short"`
	Qty           string `json:"qty"`
	// Средняя себестоимость единицы по оставшимся партиям (UZS). Без прав
	// inventory.manage или reports.view себестоимость не отдаётся.
	AvgCost    string `json:"avg_cost,omitempty"`
	TotalCost  string `json:"total_cost,omitempty"`
	AvgCostUSD string `json:"avg_cost_usd,omitempty"`
}

// SeesCost — видит ли сотрудник себестоимость остатков и движений.
func SeesCost(p *identity.Principal) bool {
	return p.CanAny(identity.PermInventoryManage, identity.PermReportsView)
}

type StockFilter struct {
	WarehouseID string
	StoreID     string
	ProductID   string
	Query       string
	Page        httpx.Page
}

func (s *Service) Stock(ctx context.Context, p *identity.Principal, f StockFilter) ([]StockRow, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT w.id, w.name, w.store_id, pr.id, pr.name, u.short_name,
		       sum(b.qty_remaining)::text,
		       round(sum(b.qty_remaining * b.unit_cost) / sum(b.qty_remaining), 2)::text,
		       round(sum(b.qty_remaining * b.unit_cost), 2)::text,
		       round(sum(b.qty_remaining * b.unit_cost_usd) / sum(b.qty_remaining), 4)::text
		FROM batches b
		JOIN warehouses w ON w.id = b.warehouse_id
		JOIN products pr  ON pr.id = b.product_id
		JOIN units u      ON u.id = pr.unit_id
		WHERE b.network_id = $1 AND b.qty_remaining > 0
		  AND ($2 OR w.store_id = ANY($3::uuid[]))
		  AND ($4 = '' OR w.id::text = $4) AND ($5 = '' OR w.store_id::text = $5) AND ($6 = '' OR pr.id::text = $6)
		  AND ($7 = '' OR lower(pr.name) LIKE '%' || lower($7) || '%')
		GROUP BY w.id, w.name, w.store_id, pr.id, pr.name, u.short_name
		ORDER BY w.name, pr.name LIMIT $8 OFFSET $9`,
		p.NetworkID, p.SeesAllStores(), p.StoreIDs, f.WarehouseID, f.StoreID, f.ProductID, strings.TrimSpace(f.Query),
		f.Page.Limit, f.Page.Offset)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, pgx.RowToStructByPos[StockRow])
	if err == nil && !SeesCost(p) {
		for i := range out {
			out[i].AvgCost, out[i].TotalCost, out[i].AvgCostUSD = "", "", ""
		}
	}
	return out, err
}

// StockSummary — итоги остатков по фильтру (по всем строкам, не по странице).
type StockSummary struct {
	Positions int `json:"positions"` // строк «склад × товар»
	Products  int `json:"products"`  // разных товаров
	// Себестоимость остатков, UZS; только с правом inventory.manage или reports.view.
	CostValue *string `json:"cost_value,omitempty"`
}

func (s *Service) StockSummary(ctx context.Context, p *identity.Principal, f StockFilter) (StockSummary, error) {
	var out StockSummary
	var cost string
	err := s.pool.QueryRow(ctx, `
		SELECT count(DISTINCT (b.warehouse_id, b.product_id))::int, count(DISTINCT b.product_id)::int,
		       round(COALESCE(sum(b.qty_remaining * b.unit_cost), 0), 2)::text
		FROM batches b
		JOIN warehouses w ON w.id = b.warehouse_id
		JOIN products pr  ON pr.id = b.product_id
		WHERE b.network_id = $1 AND b.qty_remaining > 0
		  AND ($2 OR w.store_id = ANY($3::uuid[]))
		  AND ($4 = '' OR w.id::text = $4) AND ($5 = '' OR w.store_id::text = $5) AND ($6 = '' OR pr.id::text = $6)
		  AND ($7 = '' OR lower(pr.name) LIKE '%' || lower($7) || '%')`,
		p.NetworkID, p.SeesAllStores(), p.StoreIDs, f.WarehouseID, f.StoreID, f.ProductID, strings.TrimSpace(f.Query)).
		Scan(&out.Positions, &out.Products, &cost)
	if err == nil && SeesCost(p) {
		out.CostValue = &cost
	}
	return out, err
}

type Movement struct {
	ProductID   string `json:"product_id"`
	ProductName string `json:"product_name"`
	Qty         string `json:"qty"`
	UnitCost    string `json:"unit_cost,omitempty"` // только с правом inventory.manage или reports.view
	DocType     string `json:"doc_type"`
	// Вид складского документа (income, write_off…), для продаж и заказов пусто.
	DocKind   string    `json:"doc_kind"`
	DocID     string    `json:"doc_id"`
	DocNumber *int64    `json:"doc_number"`
	CreatedAt time.Time `json:"created_at"`
	// Остаток на складе после операции; только когда задан product_id.
	BalanceAfter *string `json:"balance_after"`
}

// Movements — история движения товара по складу (product_id необязателен).
func (s *Service) Movements(ctx context.Context, p *identity.Principal, warehouseID, productID string, page httpx.Page) ([]Movement, error) {
	if !httpx.IsUUID(warehouseID) || (productID != "" && !httpx.IsUUID(productID)) {
		return nil, apperr.Validation("укажите warehouse_id (и при необходимости product_id)")
	}
	if err := s.checkWarehouse(ctx, s.pool, p, warehouseID, true); err != nil {
		return nil, err
	}
	// Остаток после операции считается по всей истории товара (оконной
	// суммой до LIMIT), поэтому он верен на любой странице.
	rows, err := s.pool.Query(ctx, `
		WITH mv AS (
			SELECT m.id, m.product_id, m.qty, m.unit_cost, m.doc_type, m.doc_id, m.created_at,
			       CASE WHEN $2 <> '' THEN sum(m.qty) OVER (ORDER BY m.created_at, m.id) END AS after
			FROM stock_movements m
			WHERE m.warehouse_id = $1 AND ($2 = '' OR m.product_id::text = $2)
			ORDER BY m.created_at DESC, m.id DESC LIMIT $3 OFFSET $4
		)
		SELECT m.product_id, pr.name, m.qty::text, m.unit_cost::text, m.doc_type, COALESCE(d.type, ''), m.doc_id,
		       COALESCE(d.number, sa.number, cr.number, o.number), m.created_at, m.after::text
		FROM mv m
		JOIN products pr ON pr.id = m.product_id
		LEFT JOIN stock_documents d ON m.doc_type = 'stock_document' AND d.id = m.doc_id
		LEFT JOIN sales sa ON m.doc_type = 'sale' AND sa.id = m.doc_id
		LEFT JOIN customer_returns cr ON m.doc_type = 'customer_return' AND cr.id = m.doc_id
		LEFT JOIN orders o ON m.doc_type = 'order' AND o.id = m.doc_id
		ORDER BY m.created_at DESC, m.id DESC`,
		warehouseID, productID, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, pgx.RowToStructByPos[Movement])
	if err == nil && !SeesCost(p) {
		for i := range out {
			out[i].UnitCost = ""
		}
	}
	return out, err
}
