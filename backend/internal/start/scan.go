package start

import (
	"context"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/ai"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/media"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Шаг «Инвентаризация: Начало работы» работает тем же сканером и поиском, что
// и шаг «Мои товары»: штрихкод ищется сначала среди добавленных строк (сразу
// количество и цены), потом в центральной базе (предложить добавить).

// ScanResult — что нашлось по штрихкоду на шаге «Инвентаризация».
type ScanResult struct {
	// Status: line — товар уже в «Моих товарах» (открываем ввод количества и
	// цен), product — есть в центральной базе, но не добавлен, none — нигде нет
	// (дальше каталог ИКПУ или новый товар по фото, как на шаге 1).
	Status  string      `json:"status"`
	Code    string      `json:"code"`
	Line    *Line       `json:"line"`
	Product *SearchItem `json:"product"`
}

// Scan — товар по штрихкоду для шага «Инвентаризация».
func (s *Service) Scan(ctx context.Context, p *identity.Principal, storeID, code string) (ScanResult, error) {
	code = strings.TrimSpace(code)
	res := ScanResult{Status: "none", Code: code}
	if !barcodeRe.MatchString(code) {
		return res, apperr.Validation("code: штрихкод из 4–32 символов").Uz("code: 4–32 belgidan iborat shtrix-kod")
	}
	st, err := s.store(ctx, s.pool, p, storeID)
	if err != nil {
		return res, err
	}
	draft, err := s.draftID(ctx, s.pool, st)
	if err != nil {
		return res, err
	}
	if draft != "" {
		rows, qerr := s.pool.Query(ctx, lineSelect+`
			WHERE l.draft_id = $1
			  AND EXISTS (SELECT 1 FROM product_barcodes pb WHERE pb.product_id = l.product_id AND pb.barcode = $4)
			ORDER BY l.added_at DESC LIMIT 1`, draft, st.PriceTypeID, st.ID, code)
		if qerr != nil {
			return res, qerr
		}
		lines, cerr := pgx.CollectRows(rows, scanLine)
		if cerr != nil {
			return res, cerr
		}
		if len(lines) > 0 {
			res.Status, res.Line = "line", &lines[0]
			return res, nil
		}
	}
	items, err := s.Search(ctx, p, SearchFilter{StoreID: storeID, Query: code, Page: httpx.Page{Limit: 5}})
	if err != nil {
		return res, err
	}
	for i := range items {
		if items[i].Barcode != nil && *items[i].Barcode == code {
			res.Status, res.Product = "product", &items[i]
			return res, nil
		}
	}
	return res, nil
}

// SetStep — магазин перешёл к инвентаризации (2) или вернулся к выбору
// товаров (1). Шаг общий для панели и «SM Магазин»: на шаге 2 кнопка
// «Штрихкод» на главной открывает ввод количества и цен, а не добавление.
func (s *Service) SetStep(ctx context.Context, p *identity.Principal, storeID string, step int) (Draft, error) {
	if step != 1 && step != 2 {
		return Draft{}, apperr.Validation("step: 1 или 2").Uz("step: 1 yoki 2")
	}
	st, err := s.store(ctx, s.pool, p, storeID)
	if err != nil {
		return Draft{}, err
	}
	if _, err := s.pool.Exec(ctx, `UPDATE start_drafts SET step = $2 WHERE warehouse_id = $1 AND status = 'open'`, st.WarehouseID, step); err != nil {
		return Draft{}, err
	}
	return s.Get(ctx, p, storeID, Filter{Limit: 1})
}

// SetMode — «Как начнём?»: stock — «Сразу с остатками», prices — «Только
// товары и цены». Черновик создаётся сам; режим можно поменять, пока
// «Начало работы» не записано — введённое не теряется.
func (s *Service) SetMode(ctx context.Context, p *identity.Principal, storeID, mode string) (Draft, error) {
	if mode != ModeStock && mode != ModePrices {
		return Draft{}, apperr.Validation("mode: stock или prices").Uz("mode: stock yoki prices")
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		st, err := s.store(ctx, tx, p, storeID)
		if err != nil {
			return err
		}
		id, err := s.ensureDraft(ctx, tx, p, st)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE start_drafts SET mode = $2 WHERE id = $1`, id, mode)
		return err
	})
	if err != nil {
		return Draft{}, err
	}
	return s.Get(ctx, p, storeID, Filter{Limit: 1})
}

// SetPhoto — фото товара прямо из инвентаризации. Без фото покупатель не
// увидит товар, поэтому «Записать и закрыть» с такими строками не проходит.
// Фото ставится только товару из черновика и только если его ещё нет.
func (s *Service) SetPhoto(ctx context.Context, p *identity.Principal, storeID, productID string, images []string) (LinesResult, error) {
	out := LinesResult{Lines: []Line{}, Skipped: []string{}}
	var photo string
	if len(images) == 0 || len(images) > 6 {
		return out, apperr.Validation("images: от 1 до 6 фото").Uz("images: 1 tadan 6 tagacha rasm")
	}
	for _, u := range images {
		if _, ok := media.KeyFromURL(u); !ok {
			return out, apperr.Validation("images: фото должно быть загружено через /store/uploads").Uz("images: rasm /store/uploads orqali yuklangan boʻlishi kerak")
		}
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		st, err := s.store(ctx, tx, p, storeID)
		if err != nil {
			return err
		}
		draft, err := s.draftID(ctx, tx, st)
		if err != nil {
			return err
		}
		var exists bool
		if draft != "" {
			if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM start_lines WHERE draft_id = $1 AND product_id = $2)`, draft, productID).Scan(&exists); err != nil {
				return err
			}
		}
		if !exists {
			return apperr.NotFound("товар не в «Моих товарах»").Uz("mahsulot «Mahsulotlarim»da yoʻq")
		}
		tag, err := tx.Exec(ctx, `UPDATE products SET images = $2 WHERE id = $1 AND COALESCE(cardinality(images), 0) = 0`, productID, images)
		if err != nil {
			return err
		}
		// Фото не было — Super Market делает из снимка чистое фото (в фоне).
		if tag.RowsAffected() == 1 {
			keys, base := photoSources(images)
			if photo, err = s.enqueuePhoto(ctx, tx, ai.StoreJob{NetworkID: p.NetworkID, StoreID: st.ID, EmployeeID: p.EmployeeID,
				ProductID: &productID, Sources: keys, MediaBase: base, Lines: true}); err != nil {
				return err
			}
		}
		rows, err := tx.Query(ctx, lineSelect+` WHERE l.draft_id = $1 AND l.product_id = $4::uuid`, draft, st.PriceTypeID, st.ID, productID)
		if err != nil {
			return err
		}
		if out.Lines, err = pgx.CollectRows(rows, scanLine); err != nil {
			return err
		}
		out.Totals, err = s.totals(ctx, tx, draft, st)
		return err
	})
	if err == nil {
		s.kickPhotos(photo)
	}
	return out, err
}
