package pos

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Весы и товары без штрихкода (Figma «Панель магазина · Весы и товары без
// штрихкода» В1–В5, «Касса · Весовой товар и товары без штрихкода» К1–К3).
//
// Весовой товар (единица — кг, л) получает номер на весах (PLU) — следующий
// свободный в сети. Весы печатают наклейку EAN-13 «префикс · номер · вес»,
// касса находит товар по номеру и берёт цену из Super Market. Штучный товар
// без заводского штрихкода получает свой EAN-13 «20…» — он живёт только в
// сети и в общую базу не попадает.

// ------------------------------------------------------------ настройки

type ScaleSettings struct {
	// В магазине есть весы, которые печатают наклейки.
	Enabled bool `json:"enabled"`
	// Первые 2 цифры наклейки (21–29; 20 — у своих штрихкодов).
	Prefix string `json:"prefix"`
	// Цифр в номере товара после префикса (4–6, обычно 5).
	ItemDigits int `json:"item_digits"`
	// Что весы пишут в штрихкод: weight — вес, sum — сумму.
	Value string `json:"value"`
	// Шаг веса в штрихкоде, г: 1 (01234 = 1,234 кг) или 10.
	WeightStep int `json:"weight_step"`
}

func (s *Service) GetScaleSettings(ctx context.Context, p *identity.Principal) (ScaleSettings, error) {
	var out ScaleSettings
	var prefixes []string
	err := s.pool.QueryRow(ctx, `SELECT scales_enabled, pos_weight_prefixes, scale_item_digits, scale_value, scale_weight_step
		FROM networks WHERE id = $1`, p.NetworkID).Scan(&out.Enabled, &prefixes, &out.ItemDigits, &out.Value, &out.WeightStep)
	out.Prefix = "22"
	if len(prefixes) > 0 {
		out.Prefix = prefixes[0]
	}
	return out, err
}

func (s *Service) SaveScaleSettings(ctx context.Context, p *identity.Principal, in ScaleSettings) (ScaleSettings, error) {
	if err := p.RequireAny(identity.PermStoresManage, identity.PermCatalogManage); err != nil {
		return ScaleSettings{}, err
	}
	in.Prefix = strings.TrimSpace(in.Prefix)
	if err := checkScalePrefix(in.Prefix); err != nil {
		return ScaleSettings{}, err
	}
	if in.ItemDigits < 4 || in.ItemDigits > 6 {
		return ScaleSettings{}, apperr.Validation("item_digits: от 4 до 6 цифр").Uz("item_digits: 4 dan 6 gacha raqam")
	}
	if in.Value != "weight" && in.Value != "sum" {
		return ScaleSettings{}, apperr.Validation("value: weight или sum").Uz("value: weight yoki sum")
	}
	if in.WeightStep != 1 && in.WeightStep != 10 {
		return ScaleSettings{}, apperr.Validation("weight_step: 1 или 10 граммов").Uz("weight_step: 1 yoki 10 gramm")
	}
	var maxPLU int
	if err := s.pool.QueryRow(ctx, `SELECT COALESCE(max(plu), 0) FROM pos_plu WHERE network_id = $1`, p.NetworkID).Scan(&maxPLU); err != nil {
		return ScaleSettings{}, err
	}
	if maxPLU > maxPLUFor(in.ItemDigits) {
		return ScaleSettings{}, apperr.Validation(fmt.Sprintf("item_digits: уже есть номер %d — в %d цифр он не поместится", maxPLU, in.ItemDigits)).
			Uz(fmt.Sprintf("item_digits: %d raqami bor — %d xonaga sigʻmaydi", maxPLU, in.ItemDigits))
	}
	// Основной префикс — первым, остальные (если были) — следом.
	_, err := s.pool.Exec(ctx, `
		UPDATE networks SET scales_enabled = $2,
		       pos_weight_prefixes = ARRAY[$3::text] || array_remove(pos_weight_prefixes, $3::text),
		       scale_item_digits = $4, scale_value = $5, scale_weight_step = $6, pos_settings_at = now()
		WHERE id = $1`, p.NetworkID, in.Enabled, in.Prefix, in.ItemDigits, in.Value, in.WeightStep)
	if err != nil {
		return ScaleSettings{}, err
	}
	return s.GetScaleSettings(ctx, p)
}

func checkScalePrefix(x string) error {
	if !prefixRe.MatchString(x) {
		return apperr.Validation("prefix: две цифры от 21 до 29").Uz("prefix: 21 dan 29 gacha ikki xonali son")
	}
	if x == ownBarcodePrefix {
		return apperr.Validation("prefix: 20 — у штрихкодов Super Market, весам выберите 21–29 (обычно 22)").
			Uz("prefix: 20 — Super Market shtrix-kodlarida, tarozi uchun 21–29 ni tanlang (odatda 22)")
	}
	return nil
}

func maxPLUFor(digits int) int {
	m := 1
	for range digits {
		m *= 10
	}
	return m - 1
}

// ------------------------------------------------------- «На весах» (В1)

type ScaleItem struct {
	ProductID string `json:"product_id"`
	Name      string `json:"name"`
	Unit      string `json:"unit"`
	PLU       *int   `json:"plu"`
	Price     string `json:"price"`
	// Когда поменялась цена (магазина или сети) — для «цена изменена 20 окт».
	PriceAt *time.Time `json:"price_at"`
	Stock   string     `json:"stock"`
	// В весах: entered — введено, changed — цена или номер поменялись после
	// «Введено», new — ещё не вводили, no_plu — номера нет.
	Status    string     `json:"status"`
	EnteredAt *time.Time `json:"entered_at"`
	// Номер запомнила касса (кассир выбрал товар к наклейке, К2).
	FromPOS bool `json:"from_pos"`
	// Свой товар сети — единицу («Как продаётся») можно менять.
	Own bool `json:"own"`
}

type ScaleList struct {
	Items   []ScaleItem `json:"items"`
	NextPLU int         `json:"next_plu"`
}

func (s *Service) storeForPanel(p *identity.Principal, storeID string) error {
	if err := p.RequireAny(identity.PermCatalogManage, identity.PermPricesManage, identity.PermReportsView); err != nil {
		return err
	}
	if !httpx.IsUUID(storeID) || !p.CanAccessStore(storeID) {
		return apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	return nil
}

// ScaleProducts — весовые «Мои товары» магазина (единица дробная) и всё, у
// чего есть номер на весах: номер, цена за кг, остаток, что обновить в весах.
func (s *Service) ScaleProducts(ctx context.Context, p *identity.Principal, storeID string) (ScaleList, error) {
	if err := s.storeForPanel(p, storeID); err != nil {
		return ScaleList{}, err
	}
	priceType, err := catalog.DefaultPriceType(ctx, s.pool, p.NetworkID)
	if err != nil {
		return ScaleList{}, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT p.id, loc(p.name, p.name_uz), loc(u.short_name, u.short_name_uz), pl.plu,
		       COALESCE(sp.price, np.price, p.base_price)::text,
		       CASE WHEN sp.price IS NOT NULL THEN sp.updated_at WHEN np.price IS NOT NULL THEN np.updated_at END,
		       COALESCE((SELECT sum(b.qty_remaining) FROM batches b JOIN warehouses w ON w.id = b.warehouse_id
		                 WHERE w.store_id = $2 AND b.product_id = p.id), 0)::text,
		       CASE WHEN pl.plu IS NULL THEN 'no_plu'
		            WHEN se.product_id IS NULL THEN 'new'
		            WHEN se.plu <> pl.plu OR se.price <> COALESCE(sp.price, np.price, p.base_price) THEN 'changed'
		            ELSE 'entered' END,
		       se.entered_at, COALESCE(pl.from_pos, false), p.network_id IS NOT NULL
		FROM products p
		JOIN units u ON u.id = p.unit_id
		LEFT JOIN pos_plu pl ON pl.network_id = $1 AND pl.product_id = p.id
		LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = $3 AND sp.store_id = $2
		LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = $3 AND np.store_id IS NULL AND np.network_id = $1
		LEFT JOIN scale_entries se ON se.store_id = $2 AND se.product_id = p.id
		WHERE (p.network_id IS NULL OR p.network_id = $1) AND p.kind = 'goods' AND u.is_fractional
		  AND (pl.plu IS NOT NULL OR EXISTS (SELECT 1 FROM store_products sp2 WHERE sp2.store_id = $2 AND sp2.product_id = p.id))
		ORDER BY pl.plu NULLS LAST, loc(p.name, p.name_uz)`, p.NetworkID, storeID, priceType)
	if err != nil {
		return ScaleList{}, err
	}
	items, err := pgx.CollectRows(rows, pgx.RowToStructByPos[ScaleItem])
	if err != nil {
		return ScaleList{}, err
	}
	next, err := nextPLU(ctx, s.pool, p.NetworkID)
	return ScaleList{Items: items, NextPLU: next}, err
}

// nextPLU — следующий свободный номер на весах: после самого большого, а если
// он упёрся в предел — первый пропуск.
func nextPLU(ctx context.Context, q db.Querier, networkID string) (int, error) {
	var digits, maxPLU int
	err := q.QueryRow(ctx, `SELECT n.scale_item_digits, COALESCE((SELECT max(plu) FROM pos_plu WHERE network_id = n.id), 0)
		FROM networks n WHERE n.id = $1`, networkID).Scan(&digits, &maxPLU)
	if err != nil {
		return 0, err
	}
	if maxPLU < maxPLUFor(digits) {
		return maxPLU + 1, nil
	}
	var gap int
	err = q.QueryRow(ctx, `SELECT g FROM generate_series(1, $2::int) g
		WHERE NOT EXISTS (SELECT 1 FROM pos_plu WHERE network_id = $1 AND plu = g) LIMIT 1`, networkID, maxPLUFor(digits)).Scan(&gap)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, apperr.Conflict("plu_full", "все номера на весах заняты").Uz("tarozidagi barcha raqamlar band")
	}
	return gap, err
}

// assignPLU — дать товару номер (plu = 0 — следующий свободный). Номер уже
// есть и auto — оставляем его.
func assignPLU(ctx context.Context, tx pgx.Tx, networkID, productID string, plu int, fromPOS bool) (int, error) {
	// Номера сети выдаём по очереди — два «Добавить» сразу не получат один номер.
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('plu:' || $1))`, networkID); err != nil {
		return 0, err
	}
	if plu == 0 {
		var cur *int
		err := tx.QueryRow(ctx, `SELECT plu FROM pos_plu WHERE network_id = $1 AND product_id = $2`, networkID, productID).Scan(&cur)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return 0, err
		}
		if cur != nil {
			return *cur, nil
		}
		n, err := nextPLU(ctx, tx, networkID)
		if err != nil {
			return 0, err
		}
		plu = n
	} else {
		var digits int
		if err := tx.QueryRow(ctx, `SELECT scale_item_digits FROM networks WHERE id = $1`, networkID).Scan(&digits); err != nil {
			return 0, err
		}
		if plu > maxPLUFor(digits) {
			return 0, apperr.Validation(fmt.Sprintf("plu: номер на весах — до %d цифр", digits)).Uz(fmt.Sprintf("plu: tarozi raqami — %d xonagacha", digits))
		}
	}
	_, err := tx.Exec(ctx, `INSERT INTO pos_plu (network_id, product_id, plu, from_pos) VALUES ($1, $2, $3, $4)
		ON CONFLICT (network_id, product_id) DO UPDATE SET plu = EXCLUDED.plu, from_pos = EXCLUDED.from_pos`, networkID, productID, plu, fromPOS)
	if db.IsUniqueViolation(err, "pos_plu_code_idx") {
		return 0, apperr.Conflict("plu_taken", fmt.Sprintf("номер %d уже у другого товара", plu)).Uz(fmt.Sprintf("%d raqami boshqa mahsulotda bor", plu))
	}
	return plu, err
}

type ScaleEnteredInput struct {
	StoreID    string   `json:"store_id"`
	ProductIDs []string `json:"product_ids"`
}

// MarkScaleEntered — «Введено»: номер и цена этих товаров теперь в весах магазина.
func (s *Service) MarkScaleEntered(ctx context.Context, p *identity.Principal, in ScaleEnteredInput) (map[string]any, error) {
	if err := p.RequireAny(identity.PermCatalogManage, identity.PermPricesManage); err != nil {
		return nil, err
	}
	if err := s.storeForPanel(p, in.StoreID); err != nil {
		return nil, err
	}
	if len(in.ProductIDs) == 0 || len(in.ProductIDs) > 2000 {
		return nil, apperr.Validation("product_ids: от 1 до 2000 товаров").Uz("product_ids: 1 dan 2000 gacha mahsulot")
	}
	for _, id := range in.ProductIDs {
		if !httpx.IsUUID(id) {
			return nil, apperr.Validation("product_ids: id товара").Uz("product_ids: mahsulot id")
		}
	}
	n, err := s.enterScale(ctx, s.pool, p.NetworkID, in.StoreID, in.ProductIDs)
	if err != nil {
		return nil, err
	}
	return map[string]any{"entered": n}, nil
}

// enterScale — запомнить, что номер и текущая цена товаров введены в весы магазина.
func (s *Service) enterScale(ctx context.Context, q db.Querier, networkID, storeID string, ids []string) (int64, error) {
	priceType, err := catalog.DefaultPriceType(ctx, q, networkID)
	if err != nil {
		return 0, err
	}
	tag, err := q.Exec(ctx, `
		INSERT INTO scale_entries (store_id, product_id, plu, price)
		SELECT $2, p.id, pl.plu, COALESCE(sp.price, np.price, p.base_price)
		FROM products p
		JOIN pos_plu pl ON pl.network_id = $1 AND pl.product_id = p.id AND pl.plu IS NOT NULL
		LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = $3 AND sp.store_id = $2
		LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = $3 AND np.store_id IS NULL AND np.network_id = $1
		WHERE p.id = ANY ($4::uuid[]) AND (p.network_id IS NULL OR p.network_id = $1)
		ON CONFLICT (store_id, product_id) DO UPDATE SET plu = EXCLUDED.plu, price = EXCLUDED.price, entered_at = now()`,
		networkID, storeID, priceType, ids)
	return tag.RowsAffected(), err
}

// ------------------------------------------------ «Как продаётся» (В5)

type SellModeInput struct {
	// piece — штучно, weight — на развес.
	Mode string `json:"mode"`
	// На развес: номер на весах; 0 или нет — оставить свой или выдать следующий.
	PLU *int `json:"plu"`
}

type SellMode struct {
	ProductID  string  `json:"product_id"`
	Mode       string  `json:"mode"`
	Unit       string  `json:"unit"`
	PLU        *int    `json:"plu"`
	OwnBarcode *string `json:"own_barcode"`
	// Свой товар сети: единицу и заводской штрихкод можно менять.
	Own bool `json:"own"`
}

func (s *Service) GetSellMode(ctx context.Context, p *identity.Principal, productID string) (SellMode, error) {
	if !httpx.IsUUID(productID) {
		return SellMode{}, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
	}
	return sellMode(ctx, s.pool, p.NetworkID, productID)
}

func sellMode(ctx context.Context, q db.Querier, networkID, productID string) (SellMode, error) {
	out := SellMode{ProductID: productID}
	var frac bool
	err := q.QueryRow(ctx, `
		SELECT u.is_fractional, loc(u.short_name, u.short_name_uz),
		       (SELECT plu FROM pos_plu WHERE network_id = $2 AND product_id = p.id),
		       (SELECT barcode FROM own_barcodes WHERE network_id = $2 AND product_id = p.id),
		       p.network_id IS NOT NULL
		FROM products p JOIN units u ON u.id = p.unit_id
		WHERE p.id = $1 AND (p.network_id IS NULL OR p.network_id = $2)`, productID, networkID).Scan(&frac, &out.Unit, &out.PLU, &out.OwnBarcode, &out.Own)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
	}
	out.Mode = "piece"
	if frac {
		out.Mode = "weight"
	}
	return out, err
}

// SetSellMode — штучно или на развес. У своего товара сети меняется единица
// (шт ↔ кг); у товара общей базы единицу меняет Super Market. На развес —
// номер на весах (свой или следующий свободный).
func (s *Service) SetSellMode(ctx context.Context, p *identity.Principal, productID string, in SellModeInput) (SellMode, error) {
	if err := p.Require(identity.PermCatalogManage); err != nil {
		return SellMode{}, err
	}
	if !httpx.IsUUID(productID) {
		return SellMode{}, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
	}
	if in.Mode != "piece" && in.Mode != "weight" {
		return SellMode{}, apperr.Validation("mode: piece или weight").Uz("mode: piece yoki weight")
	}
	if in.PLU != nil && (*in.PLU < 0 || *in.PLU > 99999) {
		return SellMode{}, apperr.Validation("plu: от 1 до 99999").Uz("plu: 1 dan 99999 gacha")
	}
	var out SellMode
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var own, frac bool
		err := tx.QueryRow(ctx, `SELECT p.network_id IS NOT NULL, u.is_fractional FROM products p JOIN units u ON u.id = p.unit_id
			WHERE p.id = $1 AND (p.network_id IS NULL OR p.network_id = $2) AND p.kind = 'goods' FOR UPDATE OF p`,
			productID, p.NetworkID).Scan(&own, &frac)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
		}
		if err != nil {
			return err
		}
		want := in.Mode == "weight"
		if want != frac {
			if !own {
				return apperr.Conflict("shared_unit", "единицу товара общей базы меняет Super Market — напишите в поддержку").
					Uz("umumiy baza mahsulotining birligini Super Market oʻzgartiradi — qoʻllab-quvvatlashga yozing")
			}
			short := "шт"
			if want {
				short = "кг"
			}
			tag, err := tx.Exec(ctx, `UPDATE products SET unit_id = (SELECT id FROM units WHERE short_name = $2 AND is_fractional = $3 ORDER BY created_at LIMIT 1)
				WHERE id = $1 AND EXISTS (SELECT 1 FROM units WHERE short_name = $2 AND is_fractional = $3)`, productID, short, want)
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 0 {
				return apperr.Conflict("no_unit", "нет единицы «"+short+"»").Uz("«" + short + "» birligi yoʻq")
			}
			// Был весовым — номер на весах больше не нужен (строку не удаляем: касса узнает).
			if !want {
				if _, err := tx.Exec(ctx, `UPDATE pos_plu SET plu = NULL WHERE network_id = $1 AND product_id = $2`, p.NetworkID, productID); err != nil {
					return err
				}
			}
		}
		if want {
			plu := 0
			if in.PLU != nil {
				plu = *in.PLU
			}
			if _, err := assignPLU(ctx, tx, p.NetworkID, productID, plu, false); err != nil {
				return err
			}
			// Весовому товару свой штрихкод не нужен — весы печатают наклейку.
			if _, err := tx.Exec(ctx, `DELETE FROM own_barcodes WHERE network_id = $1 AND product_id = $2`, p.NetworkID, productID); err != nil {
				return err
			}
		}
		out, err = sellMode(ctx, tx, p.NetworkID, productID)
		return err
	})
	return out, err
}

// ------------------------------------------- «Без штрихкода» (В3, В4)

const ownBarcodePrefix = "20"

type NoBarcodeItem struct {
	ProductID  string  `json:"product_id"`
	Name       string  `json:"name"`
	Unit       string  `json:"unit"`
	Price      string  `json:"price"`
	OwnBarcode *string `json:"own_barcode"`
	Own        bool    `json:"own"`
}

// NoBarcodeProducts — штучные «Мои товары» без заводского штрихкода и свой
// штрихкод «20…», если уже выдан. Без кода — первыми.
func (s *Service) NoBarcodeProducts(ctx context.Context, p *identity.Principal, storeID string) ([]NoBarcodeItem, error) {
	if err := s.storeForPanel(p, storeID); err != nil {
		return nil, err
	}
	priceType, err := catalog.DefaultPriceType(ctx, s.pool, p.NetworkID)
	if err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT p.id, loc(p.name, p.name_uz), loc(u.short_name, u.short_name_uz), COALESCE(sp.price, np.price, p.base_price)::text,
		       ob.barcode, p.network_id IS NOT NULL
		FROM store_products mine
		JOIN products p ON p.id = mine.product_id
		JOIN units u ON u.id = p.unit_id
		LEFT JOIN own_barcodes ob ON ob.network_id = $1 AND ob.product_id = p.id
		LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = $3 AND sp.store_id = $2
		LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = $3 AND np.store_id IS NULL AND np.network_id = $1
		WHERE mine.store_id = $2 AND p.kind = 'goods' AND NOT u.is_fractional
		  AND NOT EXISTS (SELECT 1 FROM product_barcodes b WHERE b.product_id = p.id)
		ORDER BY ob.barcode IS NOT NULL, ob.created_at, loc(p.name, p.name_uz)`, p.NetworkID, storeID, priceType)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[NoBarcodeItem])
}

type ScaleCounts struct {
	Scales    int `json:"scales"`
	NoBarcode int `json:"no_barcode"`
	// Строки «обновите в весах» и «введите в весы».
	ToUpdate int `json:"to_update"`
}

// ScaleCountsFor — числа на вкладках «На весах» и «Без штрихкода».
func (s *Service) ScaleCountsFor(ctx context.Context, p *identity.Principal, storeID string) (ScaleCounts, error) {
	list, err := s.ScaleProducts(ctx, p, storeID)
	if err != nil {
		return ScaleCounts{}, err
	}
	out := ScaleCounts{Scales: len(list.Items)}
	for _, it := range list.Items {
		if it.Status == "new" || it.Status == "changed" {
			out.ToUpdate++
		}
	}
	err = s.pool.QueryRow(ctx, `
		SELECT count(*) FROM store_products mine
		JOIN products p ON p.id = mine.product_id JOIN units u ON u.id = p.unit_id
		WHERE mine.store_id = $1 AND p.kind = 'goods' AND NOT u.is_fractional
		  AND NOT EXISTS (SELECT 1 FROM product_barcodes b WHERE b.product_id = p.id)`, storeID).Scan(&out.NoBarcode)
	return out, err
}

type OwnBarcodesInput struct {
	ProductIDs []string `json:"product_ids"`
}

type OwnBarcode struct {
	ProductID string `json:"product_id"`
	Barcode   string `json:"barcode"`
	// Выдан сейчас (а не раньше).
	New bool `json:"new"`
}

// IssueOwnBarcodes — выдать свой штрихкод «20…» штучным товарам без
// заводского. У кого уже есть — возвращаем прежний.
func (s *Service) IssueOwnBarcodes(ctx context.Context, p *identity.Principal, in OwnBarcodesInput) ([]OwnBarcode, error) {
	if err := p.Require(identity.PermCatalogManage); err != nil {
		return nil, err
	}
	if len(in.ProductIDs) == 0 || len(in.ProductIDs) > 500 {
		return nil, apperr.Validation("product_ids: от 1 до 500 товаров").Uz("product_ids: 1 dan 500 gacha mahsulot")
	}
	for _, id := range in.ProductIDs {
		if !httpx.IsUUID(id) {
			return nil, apperr.Validation("product_ids: id товара").Uz("product_ids: mahsulot id")
		}
	}
	out := make([]OwnBarcode, 0, len(in.ProductIDs))
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		seen := map[string]bool{}
		for _, id := range in.ProductIDs {
			if seen[id] {
				continue
			}
			seen[id] = true
			code, isNew, err := issueOwnBarcode(ctx, tx, p.NetworkID, id)
			if err != nil {
				return err
			}
			out = append(out, OwnBarcode{ProductID: id, Barcode: code, New: isNew})
		}
		return nil
	})
	return out, err
}

func issueOwnBarcode(ctx context.Context, tx pgx.Tx, networkID, productID string) (string, bool, error) {
	var name string
	var frac, factory bool
	var cur *string
	err := tx.QueryRow(ctx, `
		SELECT loc(p.name, p.name_uz), u.is_fractional,
		       EXISTS (SELECT 1 FROM product_barcodes b WHERE b.product_id = p.id),
		       (SELECT barcode FROM own_barcodes WHERE network_id = $2 AND product_id = p.id)
		FROM products p JOIN units u ON u.id = p.unit_id
		WHERE p.id = $1 AND (p.network_id IS NULL OR p.network_id = $2) AND p.kind = 'goods'`, productID, networkID).
		Scan(&name, &frac, &factory, &cur)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", false, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
	}
	if err != nil {
		return "", false, err
	}
	if cur != nil {
		return *cur, false, nil
	}
	if frac {
		return "", false, apperr.Conflict("weighted", "«"+name+"» продаётся на развес — штрихкод печатают весы").
			Uz("«" + name + "» tortib sotiladi — shtrix-kodni tarozi chop etadi")
	}
	if factory {
		return "", false, apperr.Conflict("has_barcode", "у «"+name+"» есть заводской штрихкод").Uz("«" + name + "» ning zavod shtrix-kodi bor")
	}
	// Следующий номер сети; код, который уже занят в общей базе, пропускаем.
	for range 50 {
		var seq int64
		if err := tx.QueryRow(ctx, `UPDATE networks SET own_barcode_seq = own_barcode_seq + 1 WHERE id = $1 RETURNING own_barcode_seq`,
			networkID).Scan(&seq); err != nil {
			return "", false, err
		}
		code := Ean13(fmt.Sprintf("%s%010d", ownBarcodePrefix, seq))
		var taken bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM product_barcodes WHERE barcode_key(barcode) = barcode_key($1))
			OR EXISTS (SELECT 1 FROM own_barcodes WHERE network_id = $2 AND barcode = $1)`, code, networkID).Scan(&taken); err != nil {
			return "", false, err
		}
		if taken {
			continue
		}
		if _, err := tx.Exec(ctx, `INSERT INTO own_barcodes (network_id, product_id, barcode) VALUES ($1, $2, $3)`,
			networkID, productID, code); err != nil {
			return "", false, err
		}
		return code, true, nil
	}
	return "", false, apperr.Conflict("barcode_busy", "не удалось подобрать свободный штрихкод").Uz("boʻsh shtrix-kod topilmadi")
}

// Ean13 — 12 цифр + контрольная цифра.
func Ean13(d12 string) string {
	sum := 0
	for i, r := range d12 {
		d := int(r - '0')
		if i%2 == 1 {
			d *= 3
		}
		sum += d
	}
	return d12 + string(rune('0'+(10-sum%10)%10))
}

// -------------------------------------------- касса запоминает номер (К2)

type RememberPLUInput struct {
	ProductID string `json:"product_id"`
	PLU       int    `json:"plu"`
}

// RememberPLU — кассир выбрал товар к незнакомому номеру на наклейке:
// дальше касса находит его сама, владелец видит строку в «На весах».
// Номер уже введён в весы (наклейку напечатали) — помечаем «введено».
func (s *Service) RememberPLU(ctx context.Context, p *identity.Principal, in RememberPLUInput) (CatalogProduct, error) {
	storeID, err := deviceStoreID(p)
	if err != nil {
		return CatalogProduct{}, err
	}
	if p.EmployeeID == "" {
		return CatalogProduct{}, apperr.New(401, "cashier_required", "войдите кассиром по ПИНу").Uz("PIN-kod bilan kassir sifatida kiring")
	}
	if !httpx.IsUUID(in.ProductID) {
		return CatalogProduct{}, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
	}
	if in.PLU < 1 || in.PLU > 99999 {
		return CatalogProduct{}, apperr.Validation("plu: от 1 до 99999").Uz("plu: 1 dan 99999 gacha")
	}
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var frac bool
		var cur *int
		err := tx.QueryRow(ctx, `SELECT u.is_fractional, (SELECT plu FROM pos_plu WHERE network_id = $2 AND product_id = p.id)
			FROM products p JOIN units u ON u.id = p.unit_id
			WHERE p.id = $1 AND (p.network_id IS NULL OR p.network_id = $2) AND p.kind = 'goods'`, in.ProductID, p.NetworkID).Scan(&frac, &cur)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
		}
		if err != nil {
			return err
		}
		if !frac {
			return apperr.Conflict("not_weighted", "штучный товар — номер на весах ему не нужен").Uz("donali mahsulot — unga tarozi raqami kerak emas")
		}
		if cur != nil && *cur != in.PLU {
			return apperr.Conflict("has_plu", fmt.Sprintf("у товара уже №%d на весах — поменять можно в панели", *cur)).
				Uz(fmt.Sprintf("mahsulotda tarozida №%d bor — panelda oʻzgartirish mumkin", *cur))
		}
		if _, err := assignPLU(ctx, tx, p.NetworkID, in.ProductID, in.PLU, true); err != nil {
			return err
		}
		_, err = s.enterScale(ctx, tx, p.NetworkID, storeID, []string{in.ProductID})
		return err
	})
	if err != nil {
		return CatalogProduct{}, err
	}
	return s.catalogProduct(ctx, p, in.ProductID)
}
