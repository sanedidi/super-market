package catalog

import (
	"context"
	"errors"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

// Свой товар сети из «Начала работы» (по фото или вручную): статус draft —
// магазин сразу видит и продаёт его, а на модерацию в общую базу он уходит
// при «Записать и закрыть» (SubmitDrafts).

// ModerationDraft — свой товар ещё не отправлен на модерацию.
const ModerationDraft = "draft"

// DraftProduct — поля нового товара.
type DraftProduct struct {
	NetworkID   string
	StoreID     string
	Name        string
	NameUz      string
	Description string
	BrandID     *string
	CategoryID  string
	UnitID      string
	Barcode     string
	Images      []string
	Source      string // photo — карточку заполнил Super Market по фото
}

// CreateDraftProduct — создать свой товар сети в статусе draft.
func CreateDraftProduct(ctx context.Context, tx pgx.Tx, in DraftProduct) (string, error) {
	name := strings.TrimSpace(in.Name)
	nameUz := strings.TrimSpace(in.NameUz)
	if name == "" {
		name = nameUz
	}
	if name == "" || utf8.RuneCountInString(name) > 300 || utf8.RuneCountInString(nameUz) > 300 {
		return "", apperr.Validation("name: от 1 до 300 символов").Uz("name: 1 dan 300 belgigacha")
	}
	if len(in.Images) > 10 {
		return "", apperr.Validation("images: не больше 10 фото").Uz("images: koʻpi bilan 10 ta rasm")
	}
	for _, u := range in.Images {
		if !strings.HasPrefix(u, "https://") && !strings.HasPrefix(u, "http://") {
			return "", apperr.Validation("images: ожидаются ссылки http(s)").Uz("images: http(s) havolalar boʻlishi kerak")
		}
	}
	if err := checkRefs(ctx, tx, in.BrandID, &in.CategoryID, &in.UnitID, nil); err != nil {
		return "", err
	}
	attrs := map[string]any{"added_by_store": in.StoreID}
	if in.Source != "" {
		attrs["source"] = in.Source
	}
	images := in.Images
	if images == nil {
		images = []string{}
	}
	desc := strings.TrimSpace(in.Description)
	if utf8.RuneCountInString(desc) > 2000 {
		desc = string([]rune(desc)[:2000])
	}
	var id string
	if err := tx.QueryRow(ctx, `
		INSERT INTO products (network_id, proposed_by, name, description, brand_id, category_id, unit_id,
		                      images, moderation_status, attributes, name_uz)
		VALUES ($1, $1, $2, $3, $4, $5, $6, $7, 'draft', $8, $9) RETURNING id`,
		in.NetworkID, name, desc, in.BrandID, in.CategoryID, in.UnitID, images, attrs, nameUz).Scan(&id); err != nil {
		return "", err
	}
	if code := strings.TrimSpace(in.Barcode); code != "" {
		if err := setBarcodes(ctx, tx, id, []string{code}); err != nil {
			return "", err
		}
	}
	return id, nil
}

// EnsureBrand — бренд по названию (без учёта регистра) или новый.
func EnsureBrand(ctx context.Context, tx pgx.Tx, name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" || utf8.RuneCountInString(name) > 100 {
		return "", apperr.Validation("brand_name: от 1 до 100 символов").Uz("brand_name: 1 dan 100 belgigacha")
	}
	return importBrand(ctx, tx, importRefs{brands: map[string]string{}}, name)
}

// BrandByName — бренд с таким названием или пусто.
func BrandByName(ctx context.Context, q db.Querier, name string) (string, error) {
	var id string
	err := q.QueryRow(ctx, `SELECT id FROM brands WHERE lower(name) = lower($1) AND is_active ORDER BY created_at LIMIT 1`, strings.TrimSpace(name)).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return id, err
}

// UnitByShort — единица по короткому имени (шт, кг…) или пусто.
func UnitByShort(ctx context.Context, q db.Querier, short string) (string, error) {
	short = strings.ToLower(strings.TrimSpace(short))
	if short == "" {
		short = "шт"
	}
	var id string
	err := q.QueryRow(ctx, `
		SELECT id FROM units WHERE is_active AND (lower(short_name) = $1 OR lower(short_name_uz) = $1 OR lower(name) = $1)
		ORDER BY (lower(short_name) = $1) DESC, created_at LIMIT 1`, short).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return id, err
}
