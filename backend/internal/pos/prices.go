package pos

import (
	"context"
	"errors"
	"net/http"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// WithCatalog подключает цены: касса ставит цену товару без цены прямо в чеке.
func (s *Service) WithCatalog(c *catalog.Service) *Service {
	s.cat = c
	return s
}

type PriceInput struct {
	Price money.Amount `json:"price"`
	// IfUnpriced — цену поставили на кассе без связи (очередь): если у товара
	// цена уже появилась (поставили в панели или на другой кассе) — не менять.
	IfUnpriced bool `json:"if_unpriced"`
}

type ProductPrice struct {
	ProductID string `json:"product_id"`
	Price     string `json:"price"`
}

// SetPrice — цена продажи товара в магазине кассы: документ цен по типу цен
// по умолчанию создаётся и сразу проводится. Нужен кассир с правом
// «Установка цен». Касса пробивает товар без цены — сначала спрашивает её.
func (s *Service) SetPrice(ctx context.Context, p *identity.Principal, productID string, in PriceInput) (ProductPrice, error) {
	if p.EmployeeID == "" {
		return ProductPrice{}, apperr.New(http.StatusUnauthorized, "cashier_required", "войдите кассиром по ПИНу").Uz("PIN-kod bilan kassir sifatida kiring")
	}
	if err := p.Require(identity.PermPricesManage); err != nil {
		return ProductPrice{}, err
	}
	if !httpx.IsUUID(productID) {
		return ProductPrice{}, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
	}
	if !in.Price.Valid() || money.D(string(in.Price)).Sign() <= 0 {
		return ProductPrice{}, apperr.Validation("price: цена больше нуля").Uz("price: narx noldan katta boʻlsin")
	}
	var ok bool
	err := s.pool.QueryRow(ctx, `SELECT true FROM products WHERE id = $1 AND (network_id IS NULL OR network_id = $2)`, productID, p.NetworkID).Scan(&ok)
	if errors.Is(err, pgx.ErrNoRows) {
		return ProductPrice{}, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
	}
	if err != nil {
		return ProductPrice{}, err
	}
	priceType, err := catalog.DefaultPriceType(ctx, s.pool, p.NetworkID)
	if errors.Is(err, pgx.ErrNoRows) {
		return ProductPrice{}, apperr.Conflict("no_price_type", "в сети нет типа цен").Uz("tarmoqda narx turi yoʻq")
	}
	if err != nil {
		return ProductPrice{}, err
	}
	storeID := p.StoreIDs[0]
	if in.IfUnpriced {
		cur, err := catalog.EffectivePrice(ctx, s.pool, p.NetworkID, storeID, priceType, productID)
		if err != nil {
			return ProductPrice{}, err
		}
		if money.D(cur.Price).Sign() > 0 {
			return ProductPrice{ProductID: productID, Price: money.D(cur.Price).Money()}, nil
		}
	}
	note := "Касса"
	items := []struct {
		ProductID string       `json:"product_id"`
		NewPrice  money.Amount `json:"new_price"`
	}{{ProductID: productID, NewPrice: in.Price}}
	doc, err := s.cat.CreatePriceDoc(ctx, p, catalog.PriceDocInput{PriceTypeID: &priceType, StoreID: &storeID, Note: &note, Items: &items})
	if err != nil {
		return ProductPrice{}, err
	}
	if _, err := s.cat.PostPriceDoc(ctx, p, doc.ID); err != nil {
		return ProductPrice{}, err
	}
	return ProductPrice{ProductID: productID, Price: money.D(string(in.Price)).Money()}, nil
}
