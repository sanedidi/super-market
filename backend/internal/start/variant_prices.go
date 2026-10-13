package start

import (
	"context"
	"errors"
	"strconv"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
	"github.com/sanedidi/super-market/backend/internal/variants/naming"
)

// Цены группы вариаций на «Инвентаризации» (Figma «Панель магазина ·
// Вариации своих товаров», В3): цена продажи ставится один раз на вес — или
// на всю группу, если переключателя веса у неё нет, — и её получают все
// строки этого веса без «своей цены». «Своя цена» строки — та же отметка
// магазина (variant_own_prices), что в «Товарах».

// GroupPriceInput — POST /store/start/group-price.
type GroupPriceInput struct {
	StoreID string       `json:"store_id"`
	GroupID string       `json:"group_id"`
	Weight  string       `json:"weight"`
	Price   money.Amount `json:"price"`
}

// OwnPriceInput — POST /store/start/lines/{product_id}/own-price: включить
// «свою цену» (с ценой) или вернуть строке цену веса.
type OwnPriceInput struct {
	StoreID string        `json:"store_id"`
	Own     bool          `json:"own"`
	Price   *money.Amount `json:"price"`
}

func errNotInGroup() error {
	return apperr.Validation("товар не в группе вариаций").Uz("mahsulot variantlar guruhida emas")
}

// groupLine — строка черновика из группы вариаций.
type groupLine struct {
	productID, weight string
	price             *string
	posted, own       bool
}

// groupLines — строки черновика группы и название переключателя веса.
func groupLines(ctx context.Context, tx pgx.Tx, draftID, storeID, groupID string) ([]groupLine, string, error) {
	var label string
	err := tx.QueryRow(ctx, `SELECT weight_label FROM variant_groups WHERE id = $1 AND status = 'confirmed'`, groupID).Scan(&label)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, "", apperr.NotFound("группа не найдена").Uz("guruh topilmadi")
	}
	if err != nil {
		return nil, "", err
	}
	rows, err := tx.Query(ctx, `
		SELECT l.product_id, p.variant_weight, l.price::text, l.document_id IS NOT NULL,
		       EXISTS (SELECT 1 FROM variant_own_prices o WHERE o.store_id = $3 AND o.product_id = p.id)
		FROM start_lines l JOIN products p ON p.id = l.product_id
		WHERE l.draft_id = $1 AND p.variant_group_id = $2`, draftID, groupID, storeID)
	if err != nil {
		return nil, "", err
	}
	lines, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (groupLine, error) {
		var g groupLine
		err := r.Scan(&g.productID, &g.weight, &g.price, &g.posted, &g.own)
		return g, err
	})
	return lines, label, err
}

// sameWeight — строка того же веса (без переключателя веса — вся группа).
func sameWeight(label, a, b string) bool { return label == "" || naming.Fold(a) == naming.Fold(b) }

// SetGroupPrice — цена продажи на вес группы для всех его строк без своей цены.
func (s *Service) SetGroupPrice(ctx context.Context, p *identity.Principal, in GroupPriceInput) (LinesResult, error) {
	if !httpx.IsUUID(in.GroupID) {
		return LinesResult{}, apperr.Validation("group_id: группа не найдена").Uz("group_id: guruh topilmadi")
	}
	if !in.Price.Valid() {
		return LinesResult{}, apperr.Validation("price: укажите цену").Uz("price: narxni kiriting")
	}
	return s.inDraft(ctx, p, in.StoreID, func(tx pgx.Tx, st store, draftID string) ([]string, error) {
		lines, label, err := groupLines(ctx, tx, draftID, st.ID, in.GroupID)
		if err != nil {
			return nil, err
		}
		price := in.Price
		var ids []string
		for _, l := range lines {
			if l.posted || l.own || !sameWeight(label, l.weight, in.Weight) {
				continue
			}
			if _, err := s.setLine(ctx, tx, p, st, draftID, LineInput{ProductID: l.productID,
				Price: httpx.Optional[money.Amount]{Set: true, Value: &price}}, false); err != nil {
				return nil, err
			}
			ids = append(ids, l.productID)
		}
		if len(ids) == 0 {
			return nil, apperr.Validation("weight: у этого веса нет строк без своей цены").Uz("weight: bu vaznda oʻz narxi boʻlmagan qator yoʻq")
		}
		return ids, nil
	})
}

// SetOwnPrice — «своя цена» строки: включить (и поставить цену) или
// вернуть строке общую цену её веса.
func (s *Service) SetOwnPrice(ctx context.Context, p *identity.Principal, productID string, in OwnPriceInput) (LinesResult, error) {
	if in.Price != nil && !in.Price.Valid() {
		return LinesResult{}, apperr.Validation("price: неверная цена").Uz("price: narx notoʻgʻri")
	}
	return s.inDraft(ctx, p, in.StoreID, func(tx pgx.Tx, st store, draftID string) ([]string, error) {
		var groupID *string
		var weight string
		err := tx.QueryRow(ctx, `SELECT p.variant_group_id::text, p.variant_weight FROM start_lines l JOIN products p ON p.id = l.product_id
			WHERE l.draft_id = $1 AND l.product_id = $2`, draftID, productID).Scan(&groupID, &weight)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.NotFound("товара нет в черновике").Uz("mahsulot qoralamada yoʻq")
		}
		if err != nil {
			return nil, err
		}
		if groupID == nil {
			return nil, errNotInGroup()
		}
		lines, label, err := groupLines(ctx, tx, draftID, st.ID, *groupID)
		if err != nil {
			return nil, err
		}
		var price *money.Amount
		if in.Own {
			if _, err := tx.Exec(ctx, `INSERT INTO variant_own_prices (store_id, product_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
				st.ID, productID); err != nil {
				return nil, err
			}
			price = in.Price
		} else {
			if _, err := tx.Exec(ctx, `DELETE FROM variant_own_prices WHERE store_id = $1 AND product_id = $2`, st.ID, productID); err != nil {
				return nil, err
			}
			// Цена веса — общая цена остальных строк веса без своей цены.
			var common *string
			for _, l := range lines {
				if l.productID == productID || l.own || l.price == nil || !sameWeight(label, l.weight, weight) {
					continue
				}
				if common == nil {
					common = l.price
				} else if !samePrice(*common, *l.price) {
					common = nil
					break
				}
			}
			if common != nil {
				a := money.Amount(*common)
				price = &a
			}
		}
		if price != nil {
			if _, err := s.setLine(ctx, tx, p, st, draftID, LineInput{ProductID: productID,
				Price: httpx.Optional[money.Amount]{Set: true, Value: price}}, false); err != nil {
				return nil, err
			}
		}
		return []string{productID}, nil
	})
}

// inDraft — правка открытого черновика: fn возвращает изменённые строки.
func (s *Service) inDraft(ctx context.Context, p *identity.Principal, storeID string,
	fn func(tx pgx.Tx, st store, draftID string) ([]string, error)) (LinesResult, error) {
	out := LinesResult{Lines: []Line{}, Skipped: []string{}}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		st, err := s.store(ctx, tx, p, storeID)
		if err != nil {
			return err
		}
		id, _, err := openDraft(ctx, tx, st.WarehouseID)
		if err != nil {
			return err
		}
		if id == nil {
			return apperr.NotFound("«Начало работы» ещё не начато").Uz("«Ishni boshlash» hali boshlanmagan")
		}
		ids, err := fn(tx, st, *id)
		if err != nil {
			return err
		}
		rows, err := tx.Query(ctx, lineSelect+` WHERE l.draft_id = $1 AND l.product_id = ANY($4::uuid[])
			ORDER BY p.variant_weight_sort, p.variant_weight, p.variant_sort, loc(p.name, p.name_uz)`, *id, st.PriceTypeID, st.ID, ids)
		if err != nil {
			return err
		}
		if out.Lines, err = pgx.CollectRows(rows, scanLine); err != nil {
			return err
		}
		out.Totals, err = s.totals(ctx, tx, *id, st)
		return err
	})
	return out, err
}

func samePrice(a, b string) bool {
	x, err1 := strconv.ParseFloat(a, 64)
	y, err2 := strconv.ParseFloat(b, 64)
	return err1 == nil && err2 == nil && x == y
}
