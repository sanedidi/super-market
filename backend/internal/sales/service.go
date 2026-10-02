// Package sales — продажи на кассе (POS), возврат от клиента и контроль
// фискальных чеков.
package sales

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/finance"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

type Service struct {
	pool *pgxpool.Pool
	now  func() time.Time
}

func NewService(pool *pgxpool.Pool) *Service { return &Service{pool: pool, now: time.Now} }

// ------------------------------------------------------------------ модели

type SaleItem struct {
	Line        int    `json:"line"`
	ProductID   string `json:"product_id"`
	ProductName string `json:"product_name"`
	Qty         string `json:"qty"`
	Price       string `json:"price"`
	Discount    string `json:"discount"`
	Total       string `json:"total"`
	ReturnedQty string `json:"returned_qty"`
	// Для чека возврата на фискальном модуле.
	IKPU         string   `json:"ikpu"`
	PackageCode  string   `json:"package_code"`
	VatRate      string   `json:"vat_rate"`
	MarkingCodes []string `json:"marking_codes"`
}

type SalePayment struct {
	PaymentMethodID string `json:"payment_method_id"`
	Name            string `json:"name"`
	Amount          string `json:"amount"`
}

type Sale struct {
	ID            string        `json:"id"`
	Number        int64         `json:"number"`
	StoreID       string        `json:"store_id"`
	StoreName     string        `json:"store_name"`
	WarehouseID   string        `json:"warehouse_id"`
	ClientUID     string        `json:"client_uid"`
	Subtotal      string        `json:"subtotal"`
	Discount      string        `json:"discount"`
	Total         string        `json:"total"`
	CustomerPhone string        `json:"customer_phone"`
	Note          string        `json:"note"`
	Cashier       string        `json:"cashier"`
	SoldAt        time.Time     `json:"sold_at"`
	FiscalStatus  string        `json:"fiscal_status"`
	FiscalNumber  string        `json:"fiscal_number"`
	FiscalSign    string        `json:"fiscal_sign"`
	FiscalQR      string        `json:"fiscal_qr"`
	FiscalModule  string        `json:"fiscal_module"`
	ShiftID       *string       `json:"shift_id"`
	CreatedAt     time.Time     `json:"created_at"`
	Items         []SaleItem    `json:"items,omitempty"`
	Payments      []SalePayment `json:"payments,omitempty"`
}

const saleSelect = `
	SELECT s.id, s.number, s.store_id, st.name, s.warehouse_id, s.client_uid, s.subtotal::text, s.discount::text,
	       s.total::text, s.customer_phone, s.note, e.full_name, s.sold_at, s.fiscal_status, s.fiscal_number,
	       s.fiscal_sign, s.fiscal_qr, s.fiscal_module, s.shift_id, s.created_at
	FROM sales s JOIN stores st ON st.id = s.store_id JOIN employees e ON e.id = s.cashier_id`

func scanSale(row pgx.CollectableRow) (Sale, error) {
	var s Sale
	err := row.Scan(&s.ID, &s.Number, &s.StoreID, &s.StoreName, &s.WarehouseID, &s.ClientUID, &s.Subtotal,
		&s.Discount, &s.Total, &s.CustomerPhone, &s.Note, &s.Cashier, &s.SoldAt, &s.FiscalStatus,
		&s.FiscalNumber, &s.FiscalSign, &s.FiscalQR, &s.FiscalModule, &s.ShiftID, &s.CreatedAt)
	return s, err
}

func (s *Service) getSale(ctx context.Context, q db.Querier, p *identity.Principal, id string) (Sale, error) {
	rows, err := q.Query(ctx, saleSelect+` WHERE s.network_id = $1 AND s.id = $2`, p.NetworkID, id)
	if err != nil {
		return Sale{}, err
	}
	sale, err := pgx.CollectExactlyOneRow(rows, scanSale)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !p.CanAccessStore(sale.StoreID)) {
		return Sale{}, apperr.NotFound("продажа не найдена")
	}
	if err != nil {
		return Sale{}, err
	}
	rows, err = q.Query(ctx, `
		SELECT i.line, i.product_id, p.name, i.qty::text, i.price::text, i.discount::text, i.total::text,
		       COALESCE((SELECT sum(ri.qty) FROM customer_return_items ri JOIN customer_returns r ON r.id = ri.return_id
		                 WHERE r.sale_id = i.sale_id AND ri.sale_line = i.line), 0)::text,
		       p.ikpu, p.package_code, p.vat_rate::text, i.marking_codes
		FROM sale_items i JOIN products p ON p.id = i.product_id
		WHERE i.sale_id = $1 ORDER BY i.line`, id)
	if err != nil {
		return Sale{}, err
	}
	if sale.Items, err = pgx.CollectRows(rows, pgx.RowToStructByPos[SaleItem]); err != nil {
		return Sale{}, err
	}
	rows, err = q.Query(ctx, `
		SELECT sp.payment_method_id, m.name, sp.amount::text
		FROM sale_payments sp JOIN payment_methods m ON m.id = sp.payment_method_id
		WHERE sp.sale_id = $1`, id)
	if err != nil {
		return Sale{}, err
	}
	sale.Payments, err = pgx.CollectRows(rows, pgx.RowToStructByPos[SalePayment])
	return sale, err
}

func (s *Service) GetSale(ctx context.Context, p *identity.Principal, id string) (Sale, error) {
	return s.getSale(ctx, s.pool, p, id)
}

type SaleFilter struct {
	StoreID       string
	SaleID        string // только для возвратов: возвраты по чеку
	FiscalPending bool
	// Query — номер чека или client_uid (точно) или часть телефона покупателя.
	Query    string
	From, To *time.Time
	Page     httpx.Page
}

func (s *Service) ListSales(ctx context.Context, p *identity.Principal, f SaleFilter) ([]Sale, error) {
	rows, err := s.pool.Query(ctx, saleSelect+`
		WHERE s.network_id = $1 AND ($2 OR s.store_id = ANY($3::uuid[]))
		  AND ($4 = '' OR s.store_id::text = $4) AND (NOT $5 OR s.fiscal_status = 'pending')
		  AND ($6::timestamptz IS NULL OR s.sold_at >= $6) AND ($7::timestamptz IS NULL OR s.sold_at < $7)
		  AND ($10 = '' OR s.number::text = $10 OR s.client_uid = $10 OR ($11 <> '' AND regexp_replace(s.customer_phone, '\D', '', 'g') LIKE '%' || $11 || '%'))
		ORDER BY s.sold_at DESC LIMIT $8 OFFSET $9`,
		p.NetworkID, p.SeesAllStores(), p.StoreIDs, f.StoreID, f.FiscalPending, f.From, f.To, f.Page.Limit, f.Page.Offset,
		f.Query, phoneDigits(f.Query))
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanSale)
}

// phoneDigits — цифры из поиска для сравнения с телефоном (от 3 цифр).
func phoneDigits(q string) string {
	d := strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, q)
	if len(d) < 3 {
		return ""
	}
	return d
}

// ---------------------------------------------------------------- продажа

type SaleInput struct {
	ClientUID     string     `json:"client_uid"`
	StoreID       string     `json:"store_id"`
	WarehouseID   *string    `json:"warehouse_id"`
	PriceTypeID   *string    `json:"price_type_id"`
	CustomerPhone string     `json:"customer_phone"`
	Note          string     `json:"note"`
	SoldAt        *time.Time `json:"sold_at"`
	Items         []struct {
		ProductID string        `json:"product_id"`
		Qty       money.Qty     `json:"qty"`
		Discount  *money.Amount `json:"discount"`
		// Цена с кассы (только касса): по ней пробит чек. Офлайн касса могла
		// продать по старой цене — чек уже у покупателя, сервер её принимает.
		Price *money.Amount `json:"price"`
		// Коды маркировки DataMatrix, по одному на каждую штуку (только касса).
		MarkingCodes []string `json:"marking_codes"`
	} `json:"items"`
	Payments []struct {
		PaymentMethodID string       `json:"payment_method_id"`
		Amount          money.Amount `json:"amount"`
	} `json:"payments"`

	// Только для продаж с кассы (токен устройства): смена и чек, уже
	// подписанный фискальным модулем на кассе.
	ShiftID *string     `json:"shift_id"`
	Fiscal  *FiscalData `json:"fiscal"`
}

// FiscalData — что вернул фискальный модуль кассы.
type FiscalData struct {
	Number string `json:"number"`
	Sign   string `json:"sign"`
	QR     string `json:"qr"`
	Module string `json:"module"`
}

// CreateSale проводит продажу: цены из каталога, товар по FIFO, деньги в
// кассы способов оплаты. Повтор с тем же client_uid возвращает первую продажу.
func (s *Service) CreateSale(ctx context.Context, p *identity.Principal, in SaleInput) (Sale, bool, error) {
	if err := p.Require(identity.PermSalesPOS); err != nil {
		return Sale{}, false, err
	}
	in.ClientUID = strings.TrimSpace(in.ClientUID)
	pos := p.DeviceID != ""
	if pos {
		// Касса продаёт только в своём магазине и только в смене.
		in.StoreID = p.StoreIDs[0]
		if in.ShiftID == nil || !httpx.IsUUID(*in.ShiftID) {
			return Sale{}, false, apperr.Validation("shift_id: продажа с кассы — только в смене")
		}
		if in.Fiscal != nil {
			f := in.Fiscal
			f.Number, f.Sign, f.QR, f.Module = strings.TrimSpace(f.Number), strings.TrimSpace(f.Sign), strings.TrimSpace(f.QR), strings.TrimSpace(f.Module)
			if f.Number == "" || f.Sign == "" || len(f.Number) > 64 || len(f.Sign) > 128 || len(f.QR) > 500 || len(f.Module) > 64 {
				return Sale{}, false, apperr.Validation("fiscal: номер и признак чека обязательны")
			}
		}
	} else if in.ShiftID != nil || in.Fiscal != nil {
		return Sale{}, false, apperr.Validation("shift_id и fiscal передаёт только касса")
	} else {
		for _, it := range in.Items {
			if it.Price != nil {
				return Sale{}, false, apperr.Validation("items: цену строки передаёт только касса")
			}
		}
	}
	if len(in.ClientUID) < 8 || len(in.ClientUID) > 64 {
		return Sale{}, false, apperr.Validation("client_uid: 8–64 символа, генерируется кассой (например, UUID)")
	}
	if !httpx.IsUUID(in.StoreID) || !p.CanAccessStore(in.StoreID) {
		return Sale{}, false, apperr.Validation("store_id: магазин не найден")
	}
	if len(in.Items) == 0 || len(in.Items) > 500 {
		return Sale{}, false, apperr.Validation("items: от 1 до 500 строк")
	}
	if len(in.Payments) == 0 {
		return Sale{}, false, apperr.Validation("payments: укажите оплату")
	}

	// Повторная отправка — отдаём уже проведённую продажу.
	var existing string
	err := s.pool.QueryRow(ctx, `SELECT id FROM sales WHERE network_id = $1 AND client_uid = $2`, p.NetworkID, in.ClientUID).Scan(&existing)
	if err == nil {
		sale, err := s.getSale(ctx, s.pool, p, existing)
		return sale, false, err
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return Sale{}, false, err
	}

	soldAt := s.now()
	if in.SoldAt != nil {
		// Офлайн-продажа: время кассы, но не из будущего и не старше 7 дней.
		if in.SoldAt.After(soldAt.Add(5*time.Minute)) || in.SoldAt.Before(soldAt.Add(-7*24*time.Hour)) {
			return Sale{}, false, apperr.Validation("sold_at: время продажи вне допустимого окна")
		}
		soldAt = *in.SoldAt
	}

	var id string
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		// Склад: указанный (из этого магазина) или склад магазина по умолчанию.
		var warehouseID string
		if in.WarehouseID != nil {
			if !httpx.IsUUID(*in.WarehouseID) {
				return apperr.Validation("warehouse_id: склад не найден")
			}
			err := tx.QueryRow(ctx, `SELECT id FROM warehouses WHERE id = $1 AND store_id = $2 AND is_active`,
				*in.WarehouseID, in.StoreID).Scan(&warehouseID)
			if errors.Is(err, pgx.ErrNoRows) {
				return apperr.Validation("warehouse_id: склад не найден в этом магазине")
			}
			if err != nil {
				return err
			}
		} else {
			var status string
			err := tx.QueryRow(ctx, `SELECT default_warehouse_id, status FROM stores WHERE id = $1 AND network_id = $2`,
				in.StoreID, p.NetworkID).Scan(&warehouseID, &status)
			if errors.Is(err, pgx.ErrNoRows) {
				return apperr.Validation("store_id: магазин не найден")
			}
			if err != nil {
				return err
			}
			if status != "active" {
				return apperr.Validation("store_id: магазин не работает")
			}
		}

		if pos {
			if err := CheckShiftTime(ctx, tx, *in.ShiftID, p.DeviceID, soldAt); err != nil {
				return err
			}
		}

		priceTypeID := ""
		if in.PriceTypeID != nil {
			if !httpx.IsUUID(*in.PriceTypeID) {
				return apperr.Validation("price_type_id: тип цены не найден")
			}
			if err := catalog.CheckPriceType(ctx, tx, p.NetworkID, *in.PriceTypeID); err != nil {
				return err
			}
			priceTypeID = *in.PriceTypeID
		} else {
			var err error
			if priceTypeID, err = catalog.DefaultPriceType(ctx, tx, p.NetworkID); err != nil {
				return err
			}
		}

		n, err := db.NextNumber(ctx, tx, "sales", p.NetworkID, "")
		if err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `
			INSERT INTO sales (network_id, store_id, warehouse_id, number, client_uid, price_type_id,
			                   subtotal, discount, total, cost, customer_phone, note, cashier_id, sold_at, device_id, shift_id)
			VALUES ($1, $2, $3, $4, $5, $6, 0, 0, 0, 0, $7, $8, $9, $10, NULLIF($11, '')::uuid, $12) RETURNING id`,
			p.NetworkID, in.StoreID, warehouseID, n, in.ClientUID, priceTypeID,
			strings.TrimSpace(in.CustomerPhone), strings.TrimSpace(in.Note), p.EmployeeID, soldAt, p.DeviceID, in.ShiftID).Scan(&id); err != nil {
			if db.IsUniqueViolation(err, "sales_network_id_client_uid_key") {
				return errDuplicate
			}
			return err
		}

		subtotal, discount, cost := money.D("0"), money.D("0"), money.D("0")
		seen := map[string]bool{}
		seenCodes := map[string]bool{}
		for i, it := range in.Items {
			line := i + 1
			ls := strconv.Itoa(line)
			if !httpx.IsUUID(it.ProductID) {
				return apperr.Validation("items: неверный product_id в строке " + ls)
			}
			if seen[it.ProductID] {
				return apperr.Validation("items: товар повторяется в строке " + ls + " — объедините количество")
			}
			seen[it.ProductID] = true
			if !it.Qty.Valid() || money.D(string(it.Qty)).Sign() <= 0 {
				return apperr.Validation("items: количество должно быть больше нуля в строке " + ls)
			}
			prod, err := catalog.EffectivePrice(ctx, tx, p.NetworkID, in.StoreID, priceTypeID, it.ProductID)
			if err != nil {
				return apperr.Validation("items: товар не найден в строке " + ls)
			}
			// Касса могла продать офлайн товар, который тем временем сняли с продажи.
			if !prod.IsActive && !pos {
				return apperr.Validation("items: товар «" + prod.Name + "» снят с продажи")
			}
			price := prod.Price
			if it.Price != nil {
				if !it.Price.Valid() || money.D(string(*it.Price)).Sign() < 0 {
					return apperr.Validation("items: неверная цена в строке " + ls)
				}
				price = money.D(string(*it.Price)).Money()
			}
			qty := money.D(string(it.Qty))
			if !prod.IsFractional && qty.Cmp(money.D(qty.Fixed(0))) != 0 {
				return apperr.Validation("items: «" + prod.Name + "» продаётся только целым количеством")
			}
			lineSum := money.D(price).Mul(qty).Round2()
			lineDiscount := money.D("0")
			if it.Discount != nil {
				lineDiscount = money.D(string(*it.Discount))
				if lineDiscount.Sign() > 0 {
					if err := p.Require(identity.PermSalesDiscount); err != nil {
						return err
					}
				}
				if lineDiscount.Cmp(lineSum) > 0 {
					return apperr.Validation("items: скидка больше суммы строки " + ls)
				}
			}
			codes, err := markingCodes(it.MarkingCodes, qty, prod.Name, seenCodes)
			if err != nil {
				return err
			}
			var taken []inventory.Taken
			short := "0"
			if pos {
				// С кассы — продажа уже случилась: недостачу фиксируем, а не отклоняем.
				taken, short, err = inventory.TakeUpTo(ctx, tx, p.NetworkID, warehouseID, it.ProductID, qty.Fixed(3), inventory.DocSale, id)
			} else {
				taken, err = inventory.TakeFIFO(ctx, tx, p.NetworkID, warehouseID, it.ProductID, qty.Fixed(3), inventory.DocSale, id)
			}
			if err != nil {
				return err
			}
			lineCost := money.D("0")
			for _, t := range taken {
				lineCost = lineCost.Add(money.D(t.Qty).Mul(money.D(t.UnitCost)))
			}
			if _, err := tx.Exec(ctx, `
				INSERT INTO sale_items (sale_id, line, product_id, qty, price, discount, total, cost, marking_codes, short_qty)
				VALUES ($1, $2, $3, $4::numeric, $5::numeric, $6::numeric, $7::numeric, $8::numeric, $9, $10::numeric)`,
				id, line, it.ProductID, qty.Fixed(3), price, lineDiscount.Money(),
				lineSum.Sub(lineDiscount).Money(), lineCost.Money(), codes, short); err != nil {
				return err
			}
			for _, t := range taken {
				if _, err := tx.Exec(ctx, `
					INSERT INTO sale_item_batches (sale_id, line, batch_id, qty, unit_cost, unit_cost_usd)
					VALUES ($1, $2, $3, $4::numeric, $5::numeric, $6::numeric)`,
					id, line, t.BatchID, t.Qty, t.UnitCost, t.UnitCostUSD); err != nil {
					return err
				}
			}
			subtotal = subtotal.Add(lineSum)
			discount = discount.Add(lineDiscount)
			cost = cost.Add(lineCost)
		}
		total := subtotal.Sub(discount)

		// Оплата: сумма способов оплаты = итог; деньги в кассы магазина.
		paid := money.D("0")
		methods := map[string]bool{}
		for _, pay := range in.Payments {
			if !httpx.IsUUID(pay.PaymentMethodID) || methods[pay.PaymentMethodID] {
				return apperr.Validation("payments: неверный или повторяющийся способ оплаты")
			}
			methods[pay.PaymentMethodID] = true
			if !pay.Amount.Valid() || money.D(string(pay.Amount)).Sign() <= 0 {
				return apperr.Validation("payments: сумма оплаты должна быть больше нуля")
			}
			cashboxID, currency, storeID, err := finance.PaymentMethodCashbox(ctx, tx, p.NetworkID, pay.PaymentMethodID)
			if err != nil {
				return err
			}
			if storeID == nil || *storeID != in.StoreID || currency != "UZS" {
				return apperr.Validation("payments: способ оплаты не относится к кассе этого магазина")
			}
			if _, err := tx.Exec(ctx, `INSERT INTO sale_payments (sale_id, payment_method_id, cashbox_id, amount)
				VALUES ($1, $2, $3, $4::numeric)`, id, pay.PaymentMethodID, cashboxID, string(pay.Amount)); err != nil {
				return err
			}
			if err := finance.AddCash(ctx, tx, p.NetworkID, cashboxID, string(pay.Amount), finance.DocSale, id); err != nil {
				return err
			}
			paid = paid.Add(money.D(string(pay.Amount)))
		}
		if paid.Cmp(total.Round2()) != 0 {
			return apperr.Validation("payments: сумма оплат " + paid.Money() + " не равна итогу " + total.Money()).
				WithDetails(map[string]any{"total": total.Money(), "paid": paid.Money()})
		}

		if _, err = tx.Exec(ctx, `UPDATE sales SET subtotal = $2::numeric, discount = $3::numeric, total = $4::numeric, cost = $5::numeric
			WHERE id = $1`, id, subtotal.Money(), discount.Money(), total.Money(), cost.Money()); err != nil {
			return err
		}
		if pos && in.Fiscal != nil {
			_, err = tx.Exec(ctx, `UPDATE sales SET fiscal_status = 'registered', fiscal_number = $2, fiscal_sign = $3,
				fiscal_qr = $4, fiscal_module = $5, fiscal_at = now() WHERE id = $1`,
				id, in.Fiscal.Number, in.Fiscal.Sign, in.Fiscal.QR, in.Fiscal.Module)
		}
		return err
	})
	if errors.Is(err, errDuplicate) {
		// Параллельная повторная отправка успела раньше.
		return s.CreateSale(ctx, p, in)
	}
	if err != nil {
		return Sale{}, false, err
	}
	sale, err := s.getSale(ctx, s.pool, p, id)
	return sale, true, err
}

var errDuplicate = errors.New("duplicate client_uid")

// markingCodes проверяет коды маркировки строки: по одному на штуку, без
// повторов в чеке. Пустой список — товар без маркировки.
func markingCodes(raw []string, qty money.Dec, name string, seen map[string]bool) ([]string, error) {
	if len(raw) == 0 {
		return []string{}, nil
	}
	if qty.Cmp(money.D(strconv.Itoa(len(raw)))) != 0 {
		return nil, apperr.Validation("marking_codes: «" + name + "» — нужен код на каждую штуку")
	}
	out := make([]string, 0, len(raw))
	for _, c := range raw {
		c = strings.TrimSpace(c)
		if len(c) < 10 || len(c) > 200 {
			return nil, apperr.Validation("marking_codes: неверный код маркировки у «" + name + "»")
		}
		if seen[c] {
			return nil, apperr.Validation("marking_codes: код маркировки повторяется в чеке")
		}
		seen[c] = true
		out = append(out, c)
	}
	return out, nil
}

// ------------------------------------------------------ фискальные чеки

type FiscalInput struct {
	FiscalNumber string `json:"fiscal_number"`
	FiscalSign   string `json:"fiscal_sign"`
	// С кассы: QR чека и номер фискального модуля.
	FiscalQR     string `json:"fiscal_qr"`
	FiscalModule string `json:"fiscal_module"`
}

// RegisterFiscal отмечает, что касса магазина пробила чек по продаже или возврату.
func (s *Service) RegisterFiscal(ctx context.Context, p *identity.Principal, table, id string, in FiscalInput) error {
	if err := p.Require(identity.PermSalesPOS); err != nil {
		return err
	}
	in.FiscalNumber, in.FiscalSign = strings.TrimSpace(in.FiscalNumber), strings.TrimSpace(in.FiscalSign)
	if in.FiscalNumber == "" || in.FiscalSign == "" || len(in.FiscalNumber) > 64 || len(in.FiscalSign) > 128 {
		return apperr.Validation("укажите fiscal_number и fiscal_sign из чека")
	}
	if table != "sales" && table != "customer_returns" {
		return apperr.NotFound("документ не найден")
	}
	in.FiscalQR, in.FiscalModule = strings.TrimSpace(in.FiscalQR), strings.TrimSpace(in.FiscalModule)
	if len(in.FiscalQR) > 500 || len(in.FiscalModule) > 64 {
		return apperr.Validation("fiscal_qr, fiscal_module: слишком длинные")
	}
	var storeID, status string
	var deviceID *string
	err := s.pool.QueryRow(ctx, `SELECT store_id, fiscal_status, device_id::text FROM `+table+` WHERE id = $1 AND network_id = $2`,
		id, p.NetworkID).Scan(&storeID, &status, &deviceID)
	// Касса отмечает только свои чеки.
	if err == nil && p.DeviceID != "" && (deviceID == nil || *deviceID != p.DeviceID) {
		err = pgx.ErrNoRows
	}
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !p.CanAccessStore(storeID)) {
		return apperr.NotFound("документ не найден")
	}
	if err != nil {
		return err
	}
	if status == "registered" {
		return apperr.Conflict("already_registered", "чек уже зарегистрирован")
	}
	_, err = s.pool.Exec(ctx, `UPDATE `+table+` SET fiscal_status = 'registered', fiscal_number = $2, fiscal_sign = $3, fiscal_at = now(),
		fiscal_qr = CASE WHEN $4 = '' THEN fiscal_qr ELSE $4 END, fiscal_module = CASE WHEN $5 = '' THEN fiscal_module ELSE $5 END
		WHERE id = $1`, id, in.FiscalNumber, in.FiscalSign, in.FiscalQR, in.FiscalModule)
	return err
}

// Summary — итоги продаж за период по всем чекам (не по странице списка).
type Summary struct {
	SalesCount   int    `json:"sales_count"`
	Subtotal     string `json:"subtotal"` // до скидок
	Discount     string `json:"discount"` // скидки
	Revenue      string `json:"revenue"`  // выручка по чекам (со скидками)
	ReturnsCount int    `json:"returns_count"`
	Returns      string `json:"returns"` // возвращено покупателям
	Net          string `json:"net"`     // выручка минус возвраты
}

// Summary считает итоги продаж и возвратов с теми же фильтрами, что и
// списки (магазин, период, только непробитые). Возвраты — по дате возврата.
func (s *Service) Summary(ctx context.Context, p *identity.Principal, f SaleFilter) (Summary, error) {
	if f.StoreID != "" && !httpx.IsUUID(f.StoreID) {
		return Summary{}, apperr.Validation("store_id: неверный id")
	}
	var out Summary
	err := s.pool.QueryRow(ctx, `
		WITH sl AS (
			SELECT count(*)::int AS n, COALESCE(sum(subtotal), 0) AS subtotal, COALESCE(sum(discount), 0) AS discount,
			       COALESCE(sum(total), 0) AS total
			FROM sales
			WHERE network_id = $1 AND ($2 OR store_id = ANY($3::uuid[])) AND ($4 = '' OR store_id::text = $4)
			  AND (NOT $5 OR fiscal_status = 'pending')
			  AND ($6::timestamptz IS NULL OR sold_at >= $6) AND ($7::timestamptz IS NULL OR sold_at < $7)
		), rt AS (
			SELECT count(*)::int AS n, COALESCE(sum(total), 0) AS total
			FROM customer_returns
			WHERE network_id = $1 AND ($2 OR store_id = ANY($3::uuid[])) AND ($4 = '' OR store_id::text = $4)
			  AND (NOT $5 OR fiscal_status = 'pending')
			  AND ($6::timestamptz IS NULL OR created_at >= $6) AND ($7::timestamptz IS NULL OR created_at < $7)
		)
		SELECT sl.n, sl.subtotal::numeric(18,2)::text, sl.discount::numeric(18,2)::text, sl.total::numeric(18,2)::text,
		       rt.n, rt.total::numeric(18,2)::text, (sl.total - rt.total)::numeric(18,2)::text
		FROM sl, rt`,
		p.NetworkID, p.SeesAllStores(), p.StoreIDs, f.StoreID, f.FiscalPending, f.From, f.To).Scan(
		&out.SalesCount, &out.Subtotal, &out.Discount, &out.Revenue, &out.ReturnsCount, &out.Returns, &out.Net)
	return out, err
}

type FiscalSummary struct {
	PendingSales   int `json:"pending_sales"`
	PendingReturns int `json:"pending_returns"`
	// Самая старая продажа без чека (для напоминания).
	OldestPendingAt *time.Time `json:"oldest_pending_at"`
}

// FiscalControl — сколько продаж и возвратов ещё без чека.
func (s *Service) FiscalControl(ctx context.Context, p *identity.Principal, storeID string) (FiscalSummary, error) {
	var out FiscalSummary
	err := s.pool.QueryRow(ctx, `
		SELECT
		  (SELECT count(*) FROM sales WHERE network_id = $1 AND fiscal_status = 'pending'
		     AND ($2 OR store_id = ANY($3::uuid[])) AND ($4 = '' OR store_id::text = $4))::int,
		  (SELECT count(*) FROM customer_returns WHERE network_id = $1 AND fiscal_status = 'pending'
		     AND ($2 OR store_id = ANY($3::uuid[])) AND ($4 = '' OR store_id::text = $4))::int,
		  (SELECT min(sold_at) FROM sales WHERE network_id = $1 AND fiscal_status = 'pending'
		     AND ($2 OR store_id = ANY($3::uuid[])) AND ($4 = '' OR store_id::text = $4))`,
		p.NetworkID, p.SeesAllStores(), p.StoreIDs, storeID).Scan(&out.PendingSales, &out.PendingReturns, &out.OldestPendingAt)
	return out, err
}

// ShiftMaxDuration — смена кассы по закону не длиннее 24 часов.
const ShiftMaxDuration = 24 * time.Hour

// CheckShiftTime — смена есть на этой кассе и на момент at длится не больше 24 часов.
func CheckShiftTime(ctx context.Context, q db.Querier, shiftID, deviceID string, at time.Time) error {
	var opened time.Time
	err := q.QueryRow(ctx, `SELECT opened_at FROM pos_shifts WHERE id = $1 AND device_id = $2`, shiftID, deviceID).Scan(&opened)
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.Validation("shift_id: смена не найдена на этой кассе")
	}
	if err != nil {
		return err
	}
	if at.Sub(opened) > ShiftMaxDuration {
		return apperr.Conflict("shift_expired", "смена идёт больше 24 часов — закройте её (Z-отчёт) и откройте новую")
	}
	return nil
}
