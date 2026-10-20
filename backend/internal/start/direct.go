package start

// Добавление после «Начала работы»: черновик уже записан и закрыт, а магазин
// добавляет новый товар из «Моих товаров» теми же способами — поиск, штрихкод,
// фото полки, «Новый товар», каталог ИКПУ. Товар сразу попадает в ассортимент
// магазина (store_products); цена и количество, если их указали, проводятся
// так же, как в «Записать и закрыть»: документ цен и оприходование.

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// target — куда добавлять товар: в черновик «Начала работы» или, если оно уже
// записано и закрыто, сразу в магазин (direct).
func (s *Service) target(ctx context.Context, tx pgx.Tx, p *identity.Principal, st store) (string, bool, error) {
	id, err := s.ensureDraft(ctx, tx, p, st)
	if err == nil {
		return id, false, nil
	}
	if ae, ok := apperr.As(err); ok && ae.Code == "start_closed" {
		return "", true, nil
	}
	return "", false, err
}

// similarStoreSQL — как similarSQL, только похожие ищутся среди товаров
// магазина ($1 — магазин), а не в черновике.
var similarStoreSQL = strings.Replace(similarSQL,
	"FROM start_lines l JOIN products p ON p.id = l.product_id, n\n\t           WHERE l.draft_id = $1 AND",
	"FROM store_products l JOIN products p ON p.id = l.product_id, n\n\t           WHERE l.store_id = $1::uuid AND", 1)

func init() {
	if similarStoreSQL == similarSQL {
		panic("start: similarStoreSQL не собрался из similarSQL")
	}
}

// directLine — товар сразу в магазин. ask — как в setLine: спросить про повтор
// и похожий товар (иначе повтор — пропуск).
func (s *Service) directLine(ctx context.Context, tx pgx.Tx, p *identity.Principal, st store, in LineInput, ask bool) (bool, error) {
	if !in.Add {
		return false, errClosed()
	}
	if !httpx.IsUUID(in.ProductID) {
		return false, apperr.Validation("product_id: товар не найден").Uz("product_id: mahsulot topilmadi")
	}
	var fractional, active, inStore bool
	err := tx.QueryRow(ctx, `
		SELECT u.is_fractional, p.is_active, EXISTS (SELECT 1 FROM store_products a WHERE a.store_id = $3 AND a.product_id = p.id)
		FROM products p JOIN units u ON u.id = p.unit_id
		WHERE p.id = $1 AND (p.network_id IS NULL OR p.network_id = $2)`, in.ProductID, p.NetworkID, st.ID).Scan(&fractional, &active, &inStore)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, apperr.Validation("product_id: товар не найден").Uz("product_id: mahsulot topilmadi")
	}
	if err != nil {
		return false, err
	}
	if !active {
		return false, apperr.Validation("product_id: товар отключён").Uz("product_id: mahsulot oʻchirilgan")
	}
	if in.Source != nil && !sources[*in.Source] {
		return false, apperr.Validation("source: photo, barcode, catalog, search, new, tasnif или manual").Uz("source: photo, barcode, catalog, search, new, tasnif yoki manual")
	}
	if inStore {
		if !ask {
			return true, nil
		}
		return false, apperr.Conflict("already_added", "товар уже добавлен").Uz("mahsulot allaqachon qoʻshilgan").
			WithDetails(map[string]any{"product_id": in.ProductID, "in_store": true})
	}
	if ask {
		rows, err := tx.Query(ctx, similarStoreSQL, st.ID, in.ProductID, st.ID, SimilarMin)
		if err != nil {
			return false, err
		}
		sim, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Similar, error) {
			var x Similar
			err := r.Scan(&x.ProductID, &x.Name, &x.Image, &x.Barcode)
			return x, err
		})
		if err != nil {
			return false, err
		}
		if len(sim) > 0 {
			if !in.ConfirmSimilar {
				return false, apperr.Conflict("similar_exists", "похожий товар уже есть в магазине").Uz("oʻxshash mahsulot doʻkonda allaqachon bor").
					WithDetails(map[string]any{"product_id": in.ProductID, "similar": sim[0]})
			}
			for _, x := range sim {
				if _, err := tx.Exec(ctx, `
					INSERT INTO start_similar_ok (store_id, product_id, similar_id) VALUES ($1, least($2::uuid, $3::uuid), greatest($2::uuid, $3::uuid))
					ON CONFLICT DO NOTHING`, st.ID, in.ProductID, x.ProductID); err != nil {
					return false, err
				}
			}
		}
	}

	qty := in.Qty.Or()
	if qty != nil {
		q := money.D(string(*qty))
		if !qty.Valid() || q.Sign() < 0 {
			return false, apperr.Validation("qty: неверное количество").Uz("qty: miqdor notoʻgʻri")
		}
		if !fractional && q.Cmp(money.D(q.Fixed(0))) != 0 {
			return false, apperr.Validation("qty: товар штучный — количество целое").Uz("qty: mahsulot donali — miqdor butun son boʻlsin")
		}
		if q.Cmp(money.D("99999999")) > 0 {
			return false, apperr.Validation("qty: слишком большое количество").Uz("qty: miqdor juda katta")
		}
	}
	if v := in.Price.Or(); v != nil {
		if !v.Valid() || money.D(string(*v)).Sign() < 0 {
			return false, apperr.Validation("price: неверная цена продажи").Uz("price: sotish narxi notoʻgʻri")
		}
		if money.D(string(*v)).Sign() > 0 {
			if err := p.Require(identity.PermPricesManage); err != nil {
				return false, apperr.Forbidden("нет права «Установка цен» — добавьте товар без цены или попросите владельца").Uz("«Narxlarni belgilash» huquqi yoʻq — mahsulotni narxsiz qoʻshing yoki egasidan soʻrang")
			}
		}
	}
	if v := in.Cost.Or(); v != nil && !v.Valid() {
		return false, apperr.Validation("cost: неверная себестоимость").Uz("cost: tannarx notoʻgʻri")
	}
	if in.Barcode != nil && strings.TrimSpace(*in.Barcode) != "" {
		if err := bindBarcode(ctx, tx, p, in.ProductID, strings.TrimSpace(*in.Barcode)); err != nil {
			return false, err
		}
	}
	// Без количества — «Остаток не посчитан», как строки «Начала работы» без него.
	if _, err := tx.Exec(ctx, `
		INSERT INTO store_products (network_id, store_id, product_id, uncounted_since, counted_at)
		VALUES ($1, $2, $3, CASE WHEN $4 THEN NULL ELSE now() END, CASE WHEN $4 THEN now() END)
		ON CONFLICT (store_id, product_id) DO NOTHING`, p.NetworkID, st.ID, in.ProductID, qty != nil); err != nil {
		return false, err
	}
	// Свой новый товар — на модерацию в общую базу, как после «Записать и закрыть».
	_, err = tx.Exec(ctx, `
		UPDATE products SET moderation_status = 'pending'
		WHERE id = $1 AND network_id = $2 AND moderation_status = 'draft'`, in.ProductID, p.NetworkID)
	return false, err
}

// applyDirect — цены и количество товаров, добавленных сразу в магазин:
// документ цен магазина и оприходование по себестоимости (как «Записать и
// закрыть»). Зовётся после транзакции добавления.
func (s *Service) applyDirect(ctx context.Context, p *identity.Principal, st store, items []LineInput) error {
	type priceItem = struct {
		ProductID string       `json:"product_id"`
		NewPrice  money.Amount `json:"new_price"`
	}
	var prices []priceItem
	var posting []inventory.ItemInput
	for _, it := range items {
		if v := it.Price.Or(); v != nil && money.D(string(*v)).Sign() > 0 {
			prices = append(prices, priceItem{ProductID: it.ProductID, NewPrice: *v})
		}
		if v := it.Qty.Or(); v != nil && money.D(string(*v)).Sign() > 0 {
			cost := money.Price("0")
			if c := it.Cost.Or(); c != nil {
				cost = *c
			}
			posting = append(posting, inventory.ItemInput{ProductID: it.ProductID, Qty: *v, Price: &cost})
		}
	}
	note := "Мои товары"
	if len(prices) > 0 {
		doc, err := s.cat.CreatePriceDoc(ctx, p, catalog.PriceDocInput{PriceTypeID: &st.PriceTypeID, StoreID: &st.ID, Note: &note, Items: &prices})
		if err != nil {
			return err
		}
		if _, err := s.cat.PostPriceDoc(ctx, p, doc.ID); err != nil {
			return err
		}
	}
	if len(posting) > 0 {
		wh := st.WarehouseID
		doc, err := s.inv.Create(ctx, p, inventory.Input{Type: inventory.TypePosting, WarehouseID: &wh, Note: &note, Items: &posting})
		if err != nil {
			return err
		}
		if _, err := s.inv.Post(ctx, p, doc.ID); err != nil {
			_ = s.inv.Delete(context.WithoutCancel(ctx), p, doc.ID)
			return err
		}
	}
	return nil
}

type FillInput struct {
	StoreID   string                       `json:"store_id"`
	ProductID string                       `json:"product_id"`
	Qty       httpx.Optional[money.Qty]    `json:"qty"`
	Cost      httpx.Optional[money.Price]  `json:"cost"`
	Price     httpx.Optional[money.Amount] `json:"price"`
}

type FillResult struct {
	ProductID string `json:"product_id"`
}

// Fill — цена и остаток товара, который только что добавили в магазин из
// «Моих товаров» («Добавить товар»): документ цен и оприходование, как в
// «Записать и закрыть». Количество — только пока остатка нет (иначе его
// считают «Посчитать»); без количества товар остаётся «не посчитан».
func (s *Service) Fill(ctx context.Context, p *identity.Principal, in FillInput) (FillResult, error) {
	out := FillResult{ProductID: in.ProductID}
	var st store
	li := LineInput{ProductID: in.ProductID, Qty: in.Qty, Cost: in.Cost, Price: in.Price}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var err error
		if st, err = s.store(ctx, tx, p, in.StoreID); err != nil {
			return err
		}
		if !httpx.IsUUID(in.ProductID) {
			return apperr.NotFound("товара нет в магазине").Uz("mahsulot doʻkonda yoʻq")
		}
		var fractional bool
		var stock string
		err = tx.QueryRow(ctx, `
			SELECT u.is_fractional, COALESCE((SELECT sum(b.qty_remaining) FROM batches b WHERE b.warehouse_id = $3 AND b.product_id = p.id AND b.qty_remaining > 0), 0)::text
			FROM store_products a JOIN products p ON p.id = a.product_id JOIN units u ON u.id = p.unit_id
			WHERE a.store_id = $1 AND a.product_id = $2 FOR UPDATE OF a`, st.ID, in.ProductID, st.WarehouseID).Scan(&fractional, &stock)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.NotFound("товара нет в магазине").Uz("mahsulot doʻkonda yoʻq")
		}
		if err != nil {
			return err
		}
		if v := in.Qty.Or(); v != nil {
			q := money.D(string(*v))
			if !v.Valid() || q.Sign() < 0 {
				return apperr.Validation("qty: неверное количество").Uz("qty: miqdor notoʻgʻri")
			}
			if !fractional && q.Cmp(money.D(q.Fixed(0))) != 0 {
				return apperr.Validation("qty: товар штучный — количество целое").Uz("qty: mahsulot donali — miqdor butun son boʻlsin")
			}
			if money.D(stock).Sign() > 0 {
				return apperr.Conflict("stock_exists", "у товара уже есть остаток — посчитайте его кнопкой «Посчитать»").Uz("mahsulotda qoldiq bor — uni «Sanash» tugmasi bilan sanang")
			}
			if _, err := tx.Exec(ctx, `UPDATE store_products SET uncounted_since = NULL, counted_at = now() WHERE store_id = $1 AND product_id = $2`, st.ID, in.ProductID); err != nil {
				return err
			}
		}
		if v := in.Price.Or(); v != nil {
			if !v.Valid() || money.D(string(*v)).Sign() < 0 {
				return apperr.Validation("price: неверная цена продажи").Uz("price: sotish narxi notoʻgʻri")
			}
			if money.D(string(*v)).Sign() > 0 {
				if err := p.Require(identity.PermPricesManage); err != nil {
					return err
				}
			}
		}
		if v := in.Cost.Or(); v != nil && !v.Valid() {
			return apperr.Validation("cost: неверная себестоимость").Uz("cost: tannarx notoʻgʻri")
		}
		return nil
	})
	if err != nil {
		return out, err
	}
	return out, s.applyDirect(ctx, p, st, []LineInput{li})
}
