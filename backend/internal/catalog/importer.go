package catalog

import (
	"context"
	"errors"
	"regexp"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// Импорт товаров в общий каталог пачками (супер-админ). Источник — каталог
// ИКПУ tasnif.soliq.uz: товары со штрихкодом. Повторный импорт той же пачки
// безопасен: товар ищется по штрихкоду.

// ImportItem — один товар пачки.
type ImportItem struct {
	Barcode     string   `json:"barcode"`
	Name        string   `json:"name"`
	Brand       string   `json:"brand"`
	Category    []string `json:"category"` // ["Раздел", "Подкатегория"]
	Unit        string   `json:"unit"`     // короткое имя единицы: шт, кг
	Description string   `json:"description"`
	// Переводы на узбекский (необязательно): название, описание и путь
	// категории — того же размера, что Category. Без русского названия
	// товара берётся узбекское.
	NameUz        string         `json:"name_uz"`
	DescriptionUz string         `json:"description_uz"`
	CategoryUz    []string       `json:"category_uz"`
	Attributes    map[string]any `json:"attributes"`
	// Ikpu — код ИКПУ: по нему воркер ищет фото у источника.
	Ikpu string `json:"ikpu"`
	// AttachTo — точное название уже существующего товара общего каталога:
	// товар не создаётся, ему добавляются штрихкод и атрибуты.
	AttachTo string `json:"attach_to"`
}

type ImportInput struct {
	Source string       `json:"source"`
	Items  []ImportItem `json:"items"`
}

type ImportError struct {
	Barcode string `json:"barcode"`
	Message string `json:"message"`
}

type ImportResult struct {
	Created  int           `json:"created"`
	Attached int           `json:"attached"`
	Skipped  int           `json:"skipped"`
	Errors   []ImportError `json:"errors"`
}

var importBarcodeRe = regexp.MustCompile(`^[0-9]{8,14}$`)

const importMaxItems = 500

// importRefs — найденные в этой пачке бренды, категории и единицы.
type importRefs struct {
	brands map[string]string
	cats   map[string]string
	units  map[string]string
}

func (s *Service) Import(ctx context.Context, in ImportInput) (ImportResult, error) {
	out := ImportResult{Errors: []ImportError{}}
	if in.Source != "tasnif" {
		return out, apperr.Validation("source: ожидается tasnif").Uz("source: tasnif boʻlishi kerak")
	}
	if len(in.Items) == 0 || len(in.Items) > importMaxItems {
		return out, apperr.Validation("items: от 1 до 500 товаров").Uz("items: 1 dan 500 tagacha mahsulot")
	}
	refs := importRefs{brands: map[string]string{}, cats: map[string]string{}, units: map[string]string{}}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		for _, it := range in.Items {
			// Каждый товар — в своей точке сохранения: ошибка одного не отменяет пачку.
			sp, err := tx.Begin(ctx)
			if err != nil {
				return err
			}
			res, err := s.importOne(ctx, sp, refs, in.Source, it)
			if err != nil {
				if rbErr := sp.Rollback(ctx); rbErr != nil {
					return rbErr
				}
				// Созданные в откаченной точке бренды и категории больше не существуют.
				clear(refs.brands)
				clear(refs.cats)
				var ae *apperr.Error
				if !errors.As(err, &ae) {
					return err
				}
				out.Errors = append(out.Errors, ImportError{Barcode: it.Barcode, Message: ae.Text(i18n.FromContext(ctx))})
				continue
			}
			if err := sp.Commit(ctx); err != nil {
				return err
			}
			switch res {
			case "created":
				out.Created++
			case "attached":
				out.Attached++
			default:
				out.Skipped++
			}
		}
		return nil
	})
	return out, err
}

func (s *Service) importOne(ctx context.Context, tx pgx.Tx, refs importRefs, source string, it ImportItem) (string, error) {
	code := strings.TrimSpace(it.Barcode)
	if !importBarcodeRe.MatchString(code) {
		return "", apperr.Validation("неверный штрихкод").Uz("shtrix-kod notoʻgʻri")
	}
	attrs := it.Attributes
	if attrs == nil {
		attrs = map[string]any{}
	}
	ikpu := strings.TrimSpace(it.Ikpu)
	if ikpu != "" {
		attrs["ikpu"] = ikpu
	}

	nameUz, descUz := strings.TrimSpace(it.NameUz), strings.TrimSpace(it.DescriptionUz)
	if len([]rune(nameUz)) > 300 {
		nameUz = string([]rune(nameUz)[:300])
	}
	// Пустые узбекские поля товара дополняются из пачки.
	const fillUz = `name_uz = CASE WHEN name_uz = '' THEN $3 ELSE name_uz END,
		description_uz = CASE WHEN description_uz = '' THEN $4 ELSE description_uz END`

	// Уже есть товар с этим штрихкодом — дополняем ИКПУ, если его не было.
	var existing string
	err := tx.QueryRow(ctx, `SELECT product_id FROM product_barcodes WHERE barcode = $1`, code).Scan(&existing)
	if err == nil {
		_, err = tx.Exec(ctx, `UPDATE products SET attributes = $2 || attributes, `+fillUz+` WHERE id = $1`, existing, attrs, nameUz, descUz)
		return "skipped", err
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return "", err
	}

	if name := strings.TrimSpace(it.AttachTo); name != "" {
		rows, err := tx.Query(ctx, `SELECT id, cardinality(images) FROM products WHERE network_id IS NULL AND name = $1 LIMIT 2`, name)
		if err != nil {
			return "", err
		}
		type hit struct {
			id     string
			images int
		}
		hits, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (hit, error) {
			var h hit
			err := r.Scan(&h.id, &h.images)
			return h, err
		})
		if err != nil {
			return "", err
		}
		if len(hits) == 1 {
			if _, err := tx.Exec(ctx, `INSERT INTO product_barcodes (barcode, product_id) VALUES ($1, $2)`, code, hits[0].id); err != nil {
				return "", err
			}
			if _, err := tx.Exec(ctx, `UPDATE products SET attributes = attributes || $2, `+fillUz+` WHERE id = $1`, hits[0].id, attrs, nameUz, descUz); err != nil {
				return "", err
			}
			if hits[0].images == 0 && ikpu != "" {
				if err := enqueuePhoto(ctx, tx, hits[0].id, source, ikpu); err != nil {
					return "", err
				}
			}
			return "attached", nil
		}
		// Не нашли однозначно — создаём новый товар.
	}

	name := strings.TrimSpace(it.Name)
	if name == "" {
		name = nameUz
	}
	if name == "" {
		return "", apperr.Validation("пустое название").Uz("nomi boʻsh")
	}
	if len([]rune(name)) > 300 {
		name = string([]rune(name)[:300])
	}
	if len(it.Category) == 0 {
		return "", apperr.Validation("нет категории").Uz("kategoriya yoʻq")
	}
	unitID, err := importUnit(ctx, tx, refs, it.Unit)
	if err != nil {
		return "", err
	}
	catID, err := importCategory(ctx, tx, refs, it.Category, it.CategoryUz)
	if err != nil {
		return "", err
	}
	var brandID *string
	if b := strings.TrimSpace(it.Brand); b != "" {
		id, err := importBrand(ctx, tx, refs, b)
		if err != nil {
			return "", err
		}
		brandID = &id
	}
	var id string
	if err := tx.QueryRow(ctx, `
		INSERT INTO products (name, description, brand_id, category_id, unit_id, attributes, name_uz, description_uz)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id`,
		name, strings.TrimSpace(it.Description), brandID, catID, unitID, attrs, nameUz, descUz).Scan(&id); err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO product_barcodes (barcode, product_id) VALUES ($1, $2)`, code, id); err != nil {
		return "", err
	}
	if ikpu != "" {
		if err := enqueuePhoto(ctx, tx, id, source, ikpu); err != nil {
			return "", err
		}
	}
	return "created", nil
}

func enqueuePhoto(ctx context.Context, q db.Querier, productID, source, ref string) error {
	_, err := q.Exec(ctx, `
		INSERT INTO product_photo_jobs (product_id, source, ref) VALUES ($1, $2, $3)
		ON CONFLICT (product_id) DO NOTHING`, productID, source, ref)
	return err
}

func importBrand(ctx context.Context, tx pgx.Tx, refs importRefs, name string) (string, error) {
	key := strings.ToLower(name)
	if id, ok := refs.brands[key]; ok {
		return id, nil
	}
	var id string
	err := tx.QueryRow(ctx, `SELECT id FROM brands WHERE lower(name) = $1 ORDER BY is_active DESC, created_at LIMIT 1`, key).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		err = tx.QueryRow(ctx, `INSERT INTO brands (name) VALUES ($1) RETURNING id`, name).Scan(&id)
	}
	if err != nil {
		return "", err
	}
	refs.brands[key] = id
	return id, nil
}

// importCategory — путь «Раздел / Подкатегория»: находит или создаёт каждый
// уровень. pathUz — те же уровни по-узбекски (может быть короче или пустым):
// ими заполняются пустые name_uz.
func importCategory(ctx context.Context, tx pgx.Tx, refs importRefs, path, pathUz []string) (string, error) {
	var parent *string
	key := ""
	for i, raw := range path {
		name := strings.TrimSpace(raw)
		nameUz := ""
		if i < len(pathUz) {
			nameUz = strings.TrimSpace(pathUz[i])
		}
		if name == "" {
			return "", apperr.Validation("пустое название категории").Uz("kategoriya nomi boʻsh")
		}
		key += "/" + strings.ToLower(name)
		if id, ok := refs.cats[key]; ok {
			parent = &id
			continue
		}
		var id string
		err := tx.QueryRow(ctx, `
			SELECT id FROM categories WHERE parent_id IS NOT DISTINCT FROM $1 AND lower(name) = lower($2)
			ORDER BY is_active DESC, created_at LIMIT 1`, parent, name).Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			err = tx.QueryRow(ctx, `
				INSERT INTO categories (parent_id, name, sort, name_uz)
				VALUES ($1, $2, (SELECT COALESCE(max(sort), 0) + 1 FROM categories WHERE parent_id IS NOT DISTINCT FROM $1), $3)
				RETURNING id`, parent, name, nameUz).Scan(&id)
		} else if err == nil && nameUz != "" {
			_, err = tx.Exec(ctx, `UPDATE categories SET name_uz = $2 WHERE id = $1 AND name_uz = ''`, id, nameUz)
		}
		if err != nil {
			return "", err
		}
		refs.cats[key] = id
		parent = &id
	}
	return *parent, nil
}

func importUnit(ctx context.Context, tx pgx.Tx, refs importRefs, short string) (string, error) {
	short = strings.ToLower(strings.TrimSpace(short))
	if short == "" {
		short = "шт"
	}
	if id, ok := refs.units[short]; ok {
		return id, nil
	}
	var id string
	err := tx.QueryRow(ctx, `
		SELECT id FROM units WHERE lower(short_name) = $1 OR lower(name) = $1
		                        OR lower(short_name_uz) = $1 OR lower(name_uz) = $1
		ORDER BY is_active DESC, (lower(short_name) = $1 OR lower(name) = $1) DESC, created_at LIMIT 1`, short).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", apperr.Validation("нет единицы измерения «" + short + "»").Uz("«" + short + "» oʻlchov birligi yoʻq")
	}
	if err != nil {
		return "", err
	}
	refs.units[short] = id
	return id, nil
}

// ImportStatus — ход импорта и загрузки фото.
type ImportStatus struct {
	Products       int            `json:"products"`
	WithPhoto      int            `json:"with_photo"`
	WithoutPhoto   int            `json:"without_photo"`
	PhotoJobs      map[string]int `json:"photo_jobs"`
	LastPhotoError string         `json:"last_photo_error"`
}

func (s *Service) ImportStatus(ctx context.Context) (ImportStatus, error) {
	out := ImportStatus{PhotoJobs: map[string]int{"pending": 0, "working": 0, "done": 0, "none": 0, "failed": 0}}
	if err := s.pool.QueryRow(ctx, `
		SELECT count(*), count(*) FILTER (WHERE cardinality(images) > 0), count(*) FILTER (WHERE cardinality(images) = 0)
		FROM products WHERE network_id IS NULL`).Scan(&out.Products, &out.WithPhoto, &out.WithoutPhoto); err != nil {
		return out, err
	}
	rows, err := s.pool.Query(ctx, `SELECT status, count(*) FROM product_photo_jobs GROUP BY status`)
	if err != nil {
		return out, err
	}
	for rows.Next() {
		var st string
		var n int
		if err := rows.Scan(&st, &n); err != nil {
			rows.Close()
			return out, err
		}
		out.PhotoJobs[st] = n
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return out, err
	}
	err = s.pool.QueryRow(ctx, `SELECT error FROM product_photo_jobs WHERE error <> '' ORDER BY updated_at DESC LIMIT 1`).Scan(&out.LastPhotoError)
	if errors.Is(err, pgx.ErrNoRows) {
		err = nil
	}
	return out, err
}

// RetryPhotos — вернуть в очередь задачи с ошибкой (например, после сбоя сети).
func (s *Service) RetryPhotos(ctx context.Context) (int, error) {
	tag, err := s.pool.Exec(ctx, `
		UPDATE product_photo_jobs SET status = 'pending', attempts = 0, error = '', next_at = now(), updated_at = now()
		WHERE status = 'failed'`)
	return int(tag.RowsAffected()), err
}
