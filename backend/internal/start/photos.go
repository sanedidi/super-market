package start

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/ai"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/media"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

const (
	PhotoProcessing = "processing"
	PhotoReady      = "ready"
	PhotoFailed     = "failed"

	// Совпадение не ниже — товар найден (если второй вариант заметно хуже).
	sureScore = 70
	// Отрыв лучшего варианта от второго, чтобы не спрашивать.
	sureGap = 8
	// Ниже — товара нет в каталоге.
	minScore = 35
)

type Candidate struct {
	ProductID    string  `json:"product_id"`
	Name         string  `json:"name"`
	Image        *string `json:"image"`
	UnitShort    string  `json:"unit_short"`
	CurrentPrice string  `json:"current_price"`
	Barcode      *string `json:"barcode"`
	Score        int     `json:"score"`
}

type PhotoItem struct {
	N       int    `json:"n"`
	Name    string `json:"name"`
	Brand   string `json:"brand"`
	Barcode string `json:"barcode"`
	Qty     string `json:"qty"`
	// found — товар найден; choose — выбрать из похожих; missing — нет в каталоге.
	State      string      `json:"state"`
	Product    *Candidate  `json:"product"`
	Candidates []Candidate `json:"candidates"`
	// Подсказки для «Нового товара»: бренд по названию и категория похожего товара.
	BrandID    *string `json:"brand_id"`
	CategoryID *string `json:"category_id"`
	// Товар уже в черновике.
	InDraft bool `json:"in_draft"`
}

type PhotoCounts struct {
	Found   int `json:"found"`
	Choose  int `json:"choose"`
	Missing int `json:"missing"`
}

type Photo struct {
	ID        string      `json:"id"`
	StoreID   string      `json:"store_id"`
	Status    string      `json:"status"`
	Error     string      `json:"error"`
	Images    []string    `json:"images"`
	Items     []PhotoItem `json:"items"`
	Counts    PhotoCounts `json:"counts"`
	CreatedAt time.Time   `json:"created_at"`
}

type PhotoInput struct {
	StoreID string   `json:"store_id"`
	Images  []string `json:"images"`
}

// errPhotosOff — сервис распознавания не настроен (текст для магазина, без технических подробностей).
var errPhotosOff = apperr.Conflict("ai_not_configured", "Поиск товаров по фото пока не включён — добавляйте товары штрихкодом, из каталога или поиском")

// CreatePhoto — фото загружены (/store/uploads); Super Market ищет на них товары.
func (s *Service) CreatePhoto(ctx context.Context, p *identity.Principal, in PhotoInput) (Photo, error) {
	if err := require(p, in.StoreID); err != nil {
		return Photo{}, err
	}
	if len(in.Images) == 0 || len(in.Images) > 6 {
		return Photo{}, apperr.Validation("images: от 1 до 6 фото")
	}
	keys := make([]string, 0, len(in.Images))
	for _, u := range in.Images {
		k, ok := media.KeyFromURL(u)
		if !ok {
			return Photo{}, apperr.Validation("images: фото должно быть загружено через /store/uploads")
		}
		keys = append(keys, k)
	}
	if _, err := s.ai.Conn(ctx); err != nil {
		if ae, ok := apperr.As(err); ok && ae.Code == "ai_not_configured" {
			return Photo{}, errPhotosOff
		}
		return Photo{}, err
	}
	var id string
	err := s.pool.QueryRow(ctx, `
		INSERT INTO start_photos (network_id, store_id, created_by, images)
		SELECT network_id, id, $3, $4 FROM stores WHERE id = $1 AND network_id = $2
		RETURNING id`, in.StoreID, p.NetworkID, p.EmployeeID, keys).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return Photo{}, apperr.NotFound("магазин не найден")
	}
	if err != nil {
		return Photo{}, err
	}
	s.startPhoto(id, p.NetworkID)
	return s.GetPhoto(ctx, p, id)
}

func (s *Service) startPhoto(id, networkID string) {
	s.run(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
		defer cancel()
		if err := s.processPhoto(ctx, id, networkID); err != nil {
			// Магазину — понятный текст; технические причины (ключ, модель, сеть) — только в лог.
			msg := "Super Market не смог разобрать фото — попробуйте ещё раз чуть позже"
			var se *ai.ErrService
			var ae *apperr.Error
			switch {
			case errors.As(err, &se) && strings.HasPrefix(se.Msg, "на фото"):
				msg = se.Msg
			case errors.As(err, &ae) && ae.Code == "ai_not_configured":
				msg = errPhotosOff.Message
			case errors.As(err, &ae) && ae.Status < 500:
				msg = ae.Message
			default:
				s.log.Error("start photo", "id", id, "err", err)
			}
			if r := []rune(msg); len(r) > 480 {
				msg = string(r[:480])
			}
			if _, err := s.pool.Exec(context.Background(),
				`UPDATE start_photos SET status = 'failed', error = $2 WHERE id = $1 AND status = 'processing'`, id, msg); err != nil {
				s.log.Error("start photo fail", "id", id, "err", err)
			}
		}
	})
}

func (s *Service) processPhoto(ctx context.Context, id, networkID string) error {
	var keys []string
	var storeID, employeeID string
	if err := s.pool.QueryRow(ctx, `SELECT images, store_id, created_by FROM start_photos WHERE id = $1`, id).
		Scan(&keys, &storeID, &employeeID); err != nil {
		return err
	}
	conn, err := s.ai.Conn(ctx)
	if err != nil {
		return err
	}
	images := make([]ai.Image, 0, len(keys))
	for _, k := range keys {
		data, mime, err := s.media.Read(ctx, k)
		if err != nil {
			return apperr.Validation("фото не найдено в хранилище")
		}
		images = append(images, ai.Image{MIME: mime, Data: data})
	}
	start := time.Now()
	items, usage, err := conn.RecognizeShelf(ctx, images)
	if usage.Input+usage.Output > 0 || err == nil {
		rec := ai.UsageRecord{Kind: "shelf", NetworkID: &networkID, StoreID: &storeID, EmployeeID: &employeeID, PhotoID: &id,
			Provider: conn.Provider, Model: conn.Model, Usage: usage, OK: err == nil}
		if rerr := s.ai.Record(context.WithoutCancel(ctx), rec); rerr != nil {
			s.log.Error("ai usage", "photo", id, "err", rerr)
		}
	}
	if err != nil {
		return err
	}
	ms := int(time.Since(start).Milliseconds())
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DELETE FROM start_photo_items WHERE photo_id = $1`, id); err != nil {
			return err
		}
		for i, it := range items {
			best, score, cands, err := match(ctx, tx, networkID, it)
			if err != nil {
				return err
			}
			raw, _ := json.Marshal(cands)
			if _, err := tx.Exec(ctx, `
				INSERT INTO start_photo_items (photo_id, n, name, brand, barcode, qty, product_id, score, candidates)
				VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
				id, i+1, it.Name, it.Brand, it.Barcode, strconv.FormatFloat(it.Qty, 'f', -1, 64), best, score, raw); err != nil {
				return err
			}
		}
		_, err := tx.Exec(ctx, `
			UPDATE start_photos SET status = 'ready', error = '', provider = $2, model = $3, duration_ms = $4 WHERE id = $1`,
			id, conn.Provider, conn.Model, ms)
		return err
	})
}

type cand struct {
	ProductID string `json:"product_id"`
	Score     int    `json:"score"`
}

const visible = `(p.network_id IS NULL OR p.network_id = $1) AND p.is_active`

// match — товар каталога для того, что увидели на фото: штрихкод, иначе
// похожее название (бренд с упаковки добавляет уверенности).
func match(ctx context.Context, q db.Querier, networkID string, it ai.ShelfItem) (*string, int, []cand, error) {
	if it.Barcode != "" {
		var id string
		err := q.QueryRow(ctx, `SELECT p.id FROM product_barcodes pb JOIN products p ON p.id = pb.product_id
			WHERE `+visible+` AND pb.barcode = $2`, networkID, it.Barcode).Scan(&id)
		if err == nil {
			return &id, 100, []cand{{ProductID: id, Score: 100}}, nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return nil, 0, nil, err
		}
	}
	name := strings.ToLower(strings.TrimSpace(it.Name))
	brand := strings.ToLower(strings.TrimSpace(it.Brand))
	rows, err := q.Query(ctx, `
		SELECT p.id, least(100, round(greatest(similarity(lower(p.name), $2), word_similarity($2, lower(p.name))) * 100
		       + CASE WHEN $3 <> '' AND (lower(b.name) = $3 OR lower(p.name) LIKE '%' || $3 || '%') THEN 15 ELSE 0 END))::int AS s
		FROM products p LEFT JOIN brands b ON b.id = p.brand_id
		WHERE `+visible+` AND (lower(p.name) % $2 OR $2 <% lower(p.name) OR ($3 <> '' AND lower(b.name) = $3))
		ORDER BY s DESC, p.name LIMIT 4`, networkID, name, brand)
	if err != nil {
		return nil, 0, nil, err
	}
	cands, err := pgx.CollectRows(rows, pgx.RowToStructByPos[cand])
	if err != nil {
		return nil, 0, nil, err
	}
	var keep []cand
	for _, c := range cands {
		if c.Score >= minScore-10 {
			keep = append(keep, c)
		}
	}
	if len(keep) == 0 {
		return nil, 0, []cand{}, nil
	}
	top := keep[0]
	if top.Score >= sureScore && (len(keep) == 1 || top.Score-keep[1].Score >= sureGap) {
		return &top.ProductID, top.Score, keep, nil
	}
	return nil, top.Score, keep, nil
}

// GetPhoto — распознавание с найденными товарами и похожими вариантами.
func (s *Service) GetPhoto(ctx context.Context, p *identity.Principal, id string) (Photo, error) {
	var ph Photo
	err := s.pool.QueryRow(ctx, `
		SELECT id, store_id, status, error, images, created_at FROM start_photos WHERE id = $1 AND network_id = $2`, id, p.NetworkID).
		Scan(&ph.ID, &ph.StoreID, &ph.Status, &ph.Error, &ph.Images, &ph.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return ph, apperr.NotFound("фото не найдено")
	}
	if err != nil {
		return ph, err
	}
	st, err := s.store(ctx, s.pool, p, ph.StoreID)
	if err != nil {
		return ph, err
	}
	ph.Items = []PhotoItem{}
	rows, err := s.pool.Query(ctx, `
		SELECT n, name, brand, barcode, trim_scale(qty)::text, product_id, score, candidates
		FROM start_photo_items WHERE photo_id = $1 ORDER BY n`, id)
	if err != nil {
		return ph, err
	}
	type raw struct {
		item  PhotoItem
		best  *string
		score int
		cands []cand
	}
	var raws []raw
	need := map[string]bool{}
	for rows.Next() {
		var r raw
		var cj []byte
		if err := rows.Scan(&r.item.N, &r.item.Name, &r.item.Brand, &r.item.Barcode, &r.item.Qty, &r.best, &r.score, &cj); err != nil {
			rows.Close()
			return ph, err
		}
		_ = json.Unmarshal(cj, &r.cands)
		for _, c := range r.cands {
			need[c.ProductID] = true
		}
		if r.best != nil {
			need[*r.best] = true
		}
		raws = append(raws, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return ph, err
	}
	info, cats, err := s.products(ctx, p, st, keysOf(need))
	if err != nil {
		return ph, err
	}
	draftIDs := map[string]bool{}
	if did, _, err := openDraft(ctx, s.pool, st.WarehouseID); err != nil {
		return ph, err
	} else if did != nil {
		ids, err := pgxStrings(ctx, s, `SELECT product_id::text FROM start_lines WHERE draft_id = $1`, *did)
		if err != nil {
			return ph, err
		}
		for _, x := range ids {
			draftIDs[x] = true
		}
	}
	for _, r := range raws {
		it := r.item
		it.Candidates = []Candidate{}
		for _, c := range r.cands {
			if pi, ok := info[c.ProductID]; ok {
				pi.Score = c.Score
				it.Candidates = append(it.Candidates, pi)
			}
		}
		if r.best != nil {
			if pi, ok := info[*r.best]; ok {
				pi.Score = r.score
				it.Product = &pi
				it.InDraft = draftIDs[pi.ProductID]
			}
		}
		switch {
		case it.Product != nil:
			it.State = "found"
			ph.Counts.Found++
		case len(it.Candidates) > 0 && r.score >= minScore:
			it.State = "choose"
			ph.Counts.Choose++
		default:
			it.State = "missing"
			ph.Counts.Missing++
		}
		if len(it.Candidates) > 0 {
			if c, ok := cats[it.Candidates[0].ProductID]; ok {
				it.CategoryID = &c
			}
		}
		if it.Brand != "" {
			var bid string
			if s.pool.QueryRow(ctx, `SELECT id FROM brands WHERE lower(name) = lower($1) AND is_active`, it.Brand).Scan(&bid) == nil {
				it.BrandID = &bid
			}
		}
		ph.Items = append(ph.Items, it)
	}
	return ph, nil
}

func keysOf(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

func pgxStrings(ctx context.Context, s *Service, sql string, args ...any) ([]string, error) {
	rows, err := s.pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

// products — карточки товаров для вариантов (с действующей ценой магазина).
func (s *Service) products(ctx context.Context, p *identity.Principal, st store, ids []string) (map[string]Candidate, map[string]string, error) {
	out := map[string]Candidate{}
	cats := map[string]string{}
	if len(ids) == 0 {
		return out, cats, nil
	}
	rows, err := s.pool.Query(ctx, `
		SELECT p.id, p.name, p.images[1], u.short_name, COALESCE(sp.price, np.price, p.base_price)::text,
		       (SELECT min(pb.barcode) FROM product_barcodes pb WHERE pb.product_id = p.id), p.category_id
		FROM products p
		JOIN units u ON u.id = p.unit_id
		LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = $2 AND sp.store_id = $3
		LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = $2 AND np.store_id IS NULL
		WHERE p.id = ANY($4::uuid[]) AND (p.network_id IS NULL OR p.network_id = $1)`,
		p.NetworkID, st.PriceTypeID, st.ID, ids)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var c Candidate
		var cat string
		if err := rows.Scan(&c.ProductID, &c.Name, &c.Image, &c.UnitShort, &c.CurrentPrice, &c.Barcode, &cat); err != nil {
			return nil, nil, err
		}
		out[c.ProductID] = c
		cats[c.ProductID] = cat
	}
	return out, cats, rows.Err()
}

// RetryPhoto — найти товары заново (после ошибки).
func (s *Service) RetryPhoto(ctx context.Context, p *identity.Principal, id string) (Photo, error) {
	ph, err := s.GetPhoto(ctx, p, id)
	if err != nil {
		return ph, err
	}
	if ph.Status != PhotoFailed {
		return ph, apperr.Conflict("photo_not_failed", "повторить можно только после ошибки")
	}
	if _, err := s.ai.Conn(ctx); err != nil {
		return ph, err
	}
	if _, err := s.pool.Exec(ctx, `UPDATE start_photos SET status = 'processing', error = '' WHERE id = $1`, id); err != nil {
		return ph, err
	}
	s.startPhoto(id, p.NetworkID)
	return s.GetPhoto(ctx, p, id)
}
