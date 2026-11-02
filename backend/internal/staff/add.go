package staff

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// «Проверка» (Figma «SM Сотрудник · «Проверка»», П3 / П4в): товара нет в
// магазине — сотрудник со «Складом» ставит цену продажи, считает, сколько
// есть, выбирает поставщика и цену закупки. Одна кнопка: товар в «Мои
// товары», документ цен, приход от поставщика — проведены сразу.

type AddInput struct {
	StoreID        string       `json:"store_id"`
	ProductID      string       `json:"product_id"`
	Price          money.Amount `json:"price"`
	Qty            money.Qty    `json:"qty"`
	CounterpartyID string       `json:"counterparty_id"`
	Cost           money.Price  `json:"cost"`
}

type AddResult struct {
	PriceDocument DocRef `json:"price_document"`
	Document      DocRef `json:"document"`
	// Сумма прихода (qty × cost).
	Total   string `json:"total"`
	Glance  Glance `json:"product"`
	Created bool   `json:"created"`
}

// AddToStore — товар в магазин с ценой и приходом. Повтор (остаток уже есть)
// — 409 already_in_store: второй приход не создаётся.
func (s *Service) AddToStore(ctx context.Context, p *identity.Principal, in AddInput) (AddResult, error) {
	var res AddResult
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return res, err
	}
	st, err := s.store(ctx, p, in.StoreID)
	if err != nil {
		return res, err
	}
	if !httpx.IsUUID(in.ProductID) {
		return res, apperr.Validation("product_id: товар не найден").Uz("product_id: mahsulot topilmadi")
	}
	if !in.Price.Valid() || money.D(string(in.Price)).Sign() <= 0 {
		return res, apperr.Validation("price: цена продажи больше нуля").Uz("price: sotish narxi noldan katta boʻlsin")
	}
	if !in.Qty.Valid() || money.D(string(in.Qty)).Sign() <= 0 {
		return res, apperr.Validation("qty: сколько есть — больше нуля").Uz("qty: qancha bor — noldan katta boʻlsin")
	}
	if !httpx.IsUUID(in.CounterpartyID) {
		return res, apperr.Validation("counterparty_id: укажите поставщика").Uz("counterparty_id: yetkazib beruvchini tanlang")
	}
	if !in.Cost.Valid() || money.D(string(in.Cost)).Sign() <= 0 {
		return res, apperr.Validation("cost: цена закупки больше нуля").Uz("cost: xarid narxi noldan katta boʻlsin")
	}

	// Товар доступен сети; уже в магазине с остатком — это не новый товар.
	var fractional, active, inStore bool
	var stock string
	err = s.pool.QueryRow(ctx, `
		SELECT u.is_fractional, p.is_active,
		       EXISTS (SELECT 1 FROM store_products sp WHERE sp.store_id = $3 AND sp.product_id = p.id),
		       COALESCE((SELECT sum(b.qty_remaining) FROM batches b WHERE b.warehouse_id = $4 AND b.product_id = p.id AND b.qty_remaining > 0), 0)::text
		FROM products p JOIN units u ON u.id = p.unit_id
		WHERE p.id = $1 AND (p.network_id = $2 OR (p.network_id IS NULL AND p.moderation_status = 'approved'))`,
		in.ProductID, p.NetworkID, st.ID, st.WarehouseID).Scan(&fractional, &active, &inStore, &stock)
	if errors.Is(err, pgx.ErrNoRows) {
		return res, apperr.Validation("product_id: товар не найден").Uz("product_id: mahsulot topilmadi")
	}
	if err != nil {
		return res, err
	}
	if !active {
		return res, apperr.Validation("product_id: товар отключён").Uz("product_id: mahsulot oʻchirilgan")
	}
	if inStore && money.D(stock).Sign() > 0 {
		return res, apperr.Conflict("already_in_store", "товар уже в магазине — откройте его карточку").Uz("mahsulot allaqachon doʻkonda — kartochkasini oching")
	}
	if q := money.D(string(in.Qty)); !fractional && q.Cmp(money.D(q.Fixed(0))) != 0 {
		return res, apperr.Validation("qty: штучный товар — целое число").Uz("qty: donali mahsulot — butun son")
	}

	// 1. В «Мои товары» (посчитан — сколько есть, столько и пришло).
	if _, err := s.pool.Exec(ctx, `
		INSERT INTO store_products AS sp (network_id, store_id, product_id, counted_at)
		VALUES ($1, $2, $3, now())
		ON CONFLICT (store_id, product_id) DO UPDATE SET uncounted_since = NULL, counted_at = now()`,
		p.NetworkID, st.ID, in.ProductID); err != nil {
		return res, err
	}
	res.Created = !inStore

	// 2. Цена продажи. Добавлять товар может «Склад»: цену нового товара он
	// ставит вместе с ним (менять цену товара магазина — по-прежнему «Цены»).
	pp := *p
	pp.Permissions = append(append([]string{}, p.Permissions...), identity.PermPricesManage)
	note := "SM Сотрудник · Проверка"
	items := []struct {
		ProductID string       `json:"product_id"`
		NewPrice  money.Amount `json:"new_price"`
	}{{ProductID: in.ProductID, NewPrice: in.Price}}
	pdoc, err := s.cat.CreatePriceDoc(ctx, &pp, catalog.PriceDocInput{PriceTypeID: &st.PriceType, StoreID: &st.ID, Note: &note, Items: &items})
	if err != nil {
		return res, err
	}
	if _, err := s.cat.PostPriceDoc(ctx, &pp, pdoc.ID); err != nil {
		return res, err
	}
	res.PriceDocument = DocRef{ID: pdoc.ID, Number: pdoc.Number}

	// 3. Приход от поставщика — проведён сразу.
	wh, cp, cost := st.WarehouseID, in.CounterpartyID, in.Cost
	lines := []inventory.ItemInput{{ProductID: in.ProductID, Qty: in.Qty, Price: &cost}}
	doc, err := s.inv.Create(ctx, p, inventory.Input{Type: inventory.TypeIncome, WarehouseID: &wh, CounterpartyID: &cp, Note: &note, Items: &lines})
	if err != nil {
		return res, err
	}
	posted, err := s.inv.Post(ctx, p, doc.ID)
	if err != nil {
		_ = s.inv.Delete(context.WithoutCancel(ctx), p, doc.ID)
		return res, err
	}
	res.Document = DocRef{ID: posted.ID, Number: posted.Number}
	res.Total = money.D(string(in.Qty)).Mul(money.D(string(in.Cost))).Money()
	res.Glance, err = s.Glance(ctx, p, GlanceInput{StoreID: st.ID, ProductID: in.ProductID})
	return res, err
}
