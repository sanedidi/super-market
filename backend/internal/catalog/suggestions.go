package catalog

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/push"
)

// Исправления товара общей базы от магазинов (Figma «SM Магазин · Изменить
// товар», И2–И3). Название, фото, штрихкоды и категория общие для всех
// магазинов: магазин отправляет исправление, супер-админ принимает или
// отклоняет. Цены, остаток, блок — у магазина свои и меняются сразу.

// SuggestionChanges — только изменённое; nil — не менялось.
type SuggestionChanges struct {
	Name       *string   `json:"name,omitempty"`
	NameUz     *string   `json:"name_uz,omitempty"`
	Images     *[]string `json:"images,omitempty"`
	Barcodes   *[]string `json:"barcodes,omitempty"`
	CategoryID *string   `json:"category_id,omitempty"`
	UnitID     *string   `json:"unit_id,omitempty"`
}

func (c SuggestionChanges) empty() bool {
	return c.Name == nil && c.NameUz == nil && c.Images == nil && c.Barcodes == nil && c.CategoryID == nil && c.UnitID == nil
}

type Suggestion struct {
	ID           string            `json:"id"`
	ProductID    string            `json:"product_id"`
	ProductName  string            `json:"product_name"`
	NetworkName  string            `json:"network_name"`
	StoreName    *string           `json:"store_name"`
	AuthorName   string            `json:"author_name"`
	Status       string            `json:"status"`
	RejectReason string            `json:"reject_reason"`
	Changes      SuggestionChanges `json:"changes"`
	CategoryName *string           `json:"category_name"`
	UnitName     *string           `json:"unit_name"`
	// Как сейчас у товара — для «было / стало».
	Current             SuggestionChanges `json:"current"`
	CurrentCategoryName string            `json:"current_category_name"`
	CurrentUnitName     string            `json:"current_unit_name"`
	CreatedAt           time.Time         `json:"created_at"`
	ReviewedAt          *time.Time        `json:"reviewed_at"`
}

type SuggestInput struct {
	StoreID *string `json:"store_id"`
	SuggestionChanges
}

const suggestionSelect = `
	SELECT s.id, s.product_id, loc(p.name, p.name_uz), n.name, st.name, e.full_name, s.status, s.reject_reason,
	       s.changes, (SELECT loc(c.name, c.name_uz) FROM categories c WHERE c.id::text = s.changes->>'category_id'),
	       (SELECT loc(u.short_name, u.short_name_uz) FROM units u WHERE u.id::text = s.changes->>'unit_id'),
	       p.name, p.name_uz, p.images,
	       COALESCE((SELECT array_agg(pb.barcode ORDER BY pb.barcode) FROM product_barcodes pb WHERE pb.product_id = p.id), '{}'),
	       p.category_id::text, loc(cc.name, cc.name_uz), p.unit_id::text, loc(pu.short_name, pu.short_name_uz), s.created_at, s.reviewed_at
	FROM product_suggestions s
	JOIN products p      ON p.id = s.product_id
	JOIN networks n      ON n.id = s.network_id
	LEFT JOIN stores st  ON st.id = s.store_id
	JOIN employees e     ON e.id = s.created_by
	LEFT JOIN categories cc ON cc.id = p.category_id
	JOIN units pu        ON pu.id = p.unit_id`

func scanSuggestion(row pgx.CollectableRow) (Suggestion, error) {
	var (
		s                   Suggestion
		raw                 []byte
		name, nameUz, catID string
		unitID              string
		images, barcodes    []string
	)
	err := row.Scan(&s.ID, &s.ProductID, &s.ProductName, &s.NetworkName, &s.StoreName, &s.AuthorName, &s.Status, &s.RejectReason,
		&raw, &s.CategoryName, &s.UnitName, &name, &nameUz, &images, &barcodes, &catID, &s.CurrentCategoryName, &unitID, &s.CurrentUnitName,
		&s.CreatedAt, &s.ReviewedAt)
	if err != nil {
		return s, err
	}
	if err := json.Unmarshal(raw, &s.Changes); err != nil {
		return s, err
	}
	s.Current = SuggestionChanges{Name: &name, NameUz: &nameUz, Images: &images, Barcodes: &barcodes, CategoryID: &catID, UnitID: &unitID}
	return s, nil
}

// cleanCodes — штрихкоды без пробелов, повторов и пустых, по порядку.
func cleanCodes(codes []string) []string {
	out := make([]string, 0, len(codes))
	for _, c := range codes {
		c = strings.TrimSpace(c)
		if c != "" && !slices.Contains(out, c) {
			out = append(out, c)
		}
	}
	return out
}

func sameSet(a, b []string) bool {
	x, y := slices.Clone(a), slices.Clone(b)
	slices.Sort(x)
	slices.Sort(y)
	return slices.Equal(x, y)
}

// StoreSuggest — исправление товара общей базы. Свой товар сети правится
// напрямую (PATCH /store/products/{id}).
func (s *Service) StoreSuggest(ctx context.Context, pr *identity.Principal, productID string, in SuggestInput) (Suggestion, error) {
	if err := pr.Require(identity.PermCatalogManage); err != nil {
		return Suggestion{}, err
	}
	p, err := s.StoreGetProduct(ctx, pr, productID)
	if err != nil {
		return Suggestion{}, err
	}
	if p.NetworkID != nil {
		return Suggestion{}, apperr.Conflict("own_product", "это ваш товар — изменения сохраняются сразу").Uz("bu sizning mahsulotingiz — oʻzgarishlar darhol saqlanadi")
	}
	if in.StoreID != nil && (!httpx.IsUUID(*in.StoreID) || !pr.CanAccessStore(*in.StoreID)) {
		return Suggestion{}, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	// Только то, что действительно отличается.
	var ch SuggestionChanges
	if v := trimmed(in.Name); v != nil && *v != "" && *v != p.NameRu {
		ch.Name = v
	}
	if v := trimmed(in.NameUz); v != nil && *v != "" && *v != p.NameUz {
		ch.NameUz = v
	}
	if in.Images != nil {
		imgs := cleanCodes(*in.Images)
		if len(imgs) == 0 {
			return Suggestion{}, apperr.Validation("images: нужно хотя бы одно фото").Uz("images: kamida bitta rasm kerak")
		}
		if !slices.Equal(imgs, p.Images) {
			ch.Images = &imgs
		}
	}
	if in.Barcodes != nil {
		codes := cleanCodes(*in.Barcodes)
		if len(codes) > 10 {
			return Suggestion{}, apperr.Validation("barcodes: не больше 10").Uz("barcodes: 10 tadan koʻp emas")
		}
		if !sameSet(codes, p.Barcodes) {
			for _, c := range codes {
				if slices.Contains(p.Barcodes, c) {
					continue
				}
				var other string
				err := s.pool.QueryRow(ctx, `SELECT loc(p.name, p.name_uz) FROM product_barcodes pb JOIN products p ON p.id = pb.product_id
					WHERE barcode_key(pb.barcode) = barcode_key($1) AND pb.product_id <> $2 AND (p.network_id IS NULL OR p.network_id = $3) LIMIT 1`,
					c, productID, pr.NetworkID).Scan(&other)
				if err == nil {
					return Suggestion{}, apperr.Conflict("barcode_exists", "штрихкод "+c+" уже у товара «"+other+"»").Uz(c + " shtrix-kodi «" + other + "» mahsulotida bor")
				}
				if !errors.Is(err, pgx.ErrNoRows) {
					return Suggestion{}, err
				}
			}
			ch.Barcodes = &codes
		}
	}
	if in.CategoryID != nil && *in.CategoryID != p.CategoryID {
		var ok bool
		if !httpx.IsUUID(*in.CategoryID) {
			return Suggestion{}, apperr.Validation("category_id: категория не найдена").Uz("category_id: kategoriya topilmadi")
		}
		if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM categories WHERE id = $1)`, *in.CategoryID).Scan(&ok); err != nil {
			return Suggestion{}, err
		}
		if !ok {
			return Suggestion{}, apperr.Validation("category_id: категория не найдена").Uz("category_id: kategoriya topilmadi")
		}
		ch.CategoryID = in.CategoryID
	}
	if in.UnitID != nil && *in.UnitID != p.UnitID {
		var ok bool
		if httpx.IsUUID(*in.UnitID) {
			if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM units WHERE id = $1)`, *in.UnitID).Scan(&ok); err != nil {
				return Suggestion{}, err
			}
		}
		if !ok {
			return Suggestion{}, apperr.Validation("unit_id: единица не найдена").Uz("unit_id: oʻlchov birligi topilmadi")
		}
		ch.UnitID = in.UnitID
	}
	if ch.empty() {
		return Suggestion{}, apperr.Validation("ничего не изменилось").Uz("hech narsa oʻzgarmadi")
	}
	raw, err := json.Marshal(ch)
	if err != nil {
		return Suggestion{}, err
	}
	var id string
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		// Новое исправление заменяет прежнее, ещё не проверенное.
		if _, err := tx.Exec(ctx, `DELETE FROM product_suggestions WHERE network_id = $1 AND product_id = $2 AND status = 'pending'`, pr.NetworkID, productID); err != nil {
			return err
		}
		return tx.QueryRow(ctx, `INSERT INTO product_suggestions (network_id, store_id, product_id, created_by, changes)
			VALUES ($1, $2, $3, $4, $5) RETURNING id`, pr.NetworkID, in.StoreID, productID, pr.EmployeeID, raw).Scan(&id)
	})
	if err != nil {
		return Suggestion{}, err
	}
	return s.suggestion(ctx, s.pool, id)
}

func (s *Service) suggestion(ctx context.Context, q db.Querier, id string) (Suggestion, error) {
	rows, err := q.Query(ctx, suggestionSelect+` WHERE s.id = $1`, id)
	if err != nil {
		return Suggestion{}, err
	}
	sg, err := pgx.CollectExactlyOneRow(rows, scanSuggestion)
	if errors.Is(err, pgx.ErrNoRows) {
		return sg, apperr.NotFound("исправление не найдено").Uz("tuzatish topilmadi")
	}
	return sg, err
}

// StoreSuggestions — последние исправления сети по товару (первое — новое).
func (s *Service) StoreSuggestions(ctx context.Context, pr *identity.Principal, productID string) ([]Suggestion, error) {
	if !httpx.IsUUID(productID) {
		return nil, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
	}
	rows, err := s.pool.Query(ctx, suggestionSelect+` WHERE s.network_id = $1 AND s.product_id = $2 ORDER BY s.created_at DESC LIMIT 5`, pr.NetworkID, productID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanSuggestion)
}

// AdminSuggestions — исправления от магазинов (вкладка у супер-админа).
func (s *Service) AdminSuggestions(ctx context.Context, status string, page httpx.Page) ([]Suggestion, error) {
	if status == "" {
		status = "pending"
	}
	rows, err := s.pool.Query(ctx, suggestionSelect+` WHERE s.status = $1 ORDER BY s.created_at DESC LIMIT $2 OFFSET $3`, status, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanSuggestion)
}

// AdminReviewSuggestion — принять (изменения уходят в товар общей базы) или отклонить.
func (s *Service) AdminReviewSuggestion(ctx context.Context, id string, approve bool, reason string) (Suggestion, error) {
	if !httpx.IsUUID(id) {
		return Suggestion{}, apperr.NotFound("исправление не найдено").Uz("tuzatish topilmadi")
	}
	sg, err := s.suggestion(ctx, s.pool, id)
	if err != nil {
		return sg, err
	}
	if sg.Status != "pending" {
		return sg, apperr.Conflict("suggestion_reviewed", "исправление уже проверено").Uz("tuzatish allaqachon tekshirilgan")
	}
	if approve {
		in := ProductInput{Name: sg.Changes.Name, NameUz: sg.Changes.NameUz, Images: sg.Changes.Images, Barcodes: sg.Changes.Barcodes, CategoryID: sg.Changes.CategoryID,
			UnitID: sg.Changes.UnitID}
		if _, err := s.AdminUpdateProduct(ctx, sg.ProductID, in); err != nil {
			return sg, err
		}
	}
	status := "rejected"
	title := i18n.Text{RU: "Исправление отклонено", UZ: "Tuzatish rad etildi"}
	body := i18n.Text{RU: sg.ProductName + ": " + strings.TrimSpace(reason), UZ: sg.ProductName + ": " + strings.TrimSpace(reason)}
	if approve {
		status = "approved"
		title = i18n.Text{RU: "Исправление принято", UZ: "Tuzatish qabul qilindi"}
		body = i18n.Text{RU: sg.ProductName + " — изменено во всех магазинах", UZ: sg.ProductName + " — barcha doʻkonlarda oʻzgartirildi"}
	}
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var author string
		err := tx.QueryRow(ctx, `UPDATE product_suggestions SET status = $2, reject_reason = $3, reviewed_at = now()
			WHERE id = $1 AND status = 'pending' RETURNING created_by`, id, status, strings.TrimSpace(reason)).Scan(&author)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Conflict("suggestion_reviewed", "исправление уже проверено").Uz("tuzatish allaqachon tekshirilgan")
		}
		if err != nil {
			return err
		}
		return push.EnqueueEmployee(ctx, tx, author, "product_suggestion", title, body, map[string]string{"type": "product", "product_id": sg.ProductID})
	})
	if err != nil {
		return sg, err
	}
	return s.suggestion(ctx, s.pool, id)
}
