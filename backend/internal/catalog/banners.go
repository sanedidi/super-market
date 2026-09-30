package catalog

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Баннеры на главной приложения. Ведёт супер-админ.

type Banner struct {
	ID        string  `json:"id"`
	Title     string  `json:"title"`
	Subtitle  string  `json:"subtitle"`
	ImageURL  string  `json:"image_url"`
	Color     string  `json:"color"`
	LinkType  string  `json:"link_type"` // none | promotion | category | product | store
	LinkID    *string `json:"link_id"`
	NetworkID *string `json:"network_id"`
	// Название сети, если баннер только для неё.
	NetworkName *string    `json:"network_name"`
	StartsAt    *time.Time `json:"starts_at"`
	EndsAt      *time.Time `json:"ends_at"`
	Sort        int        `json:"sort"`
	IsActive    bool       `json:"is_active"`
	CreatedAt   time.Time  `json:"created_at"`
}

type BannerInput struct {
	Title     *string `json:"title"`
	Subtitle  *string `json:"subtitle"`
	ImageURL  *string `json:"image_url"`
	Color     *string `json:"color"`
	LinkType  *string `json:"link_type"`
	LinkID    *string `json:"link_id"`
	NetworkID *string `json:"network_id"`
	// Период показа: ключа нет — не менять, null — снять ограничение.
	StartsAt httpx.Optional[time.Time] `json:"starts_at"`
	EndsAt   httpx.Optional[time.Time] `json:"ends_at"`
	Sort     *int                      `json:"sort"`
	IsActive *bool                     `json:"is_active"`
}

const bannerSelect = `SELECT id, title, subtitle, image_url, color, link_type, link_id, network_id,
	(SELECT n.name FROM networks n WHERE n.id = banners.network_id), starts_at, ends_at, sort, is_active, created_at FROM banners`

var colorRe = regexp.MustCompile(`^#[0-9A-Fa-f]{6}$`)

func (in BannerInput) validate(create bool) error {
	if create && in.Title == nil {
		return apperr.Validation("title: обязательное поле")
	}
	if in.Title != nil && strings.TrimSpace(*in.Title) == "" {
		return apperr.Validation("title: не может быть пустым")
	}
	if in.Color != nil && !colorRe.MatchString(*in.Color) {
		return apperr.Validation("color: ожидается #RRGGBB")
	}
	if in.ImageURL != nil && *in.ImageURL != "" && !strings.HasPrefix(*in.ImageURL, "https://") && !strings.HasPrefix(*in.ImageURL, "http://") {
		return apperr.Validation("image_url: ожидается ссылка http(s)")
	}
	if in.LinkType != nil {
		switch *in.LinkType {
		case "none", "promotion", "category", "product", "store":
		default:
			return apperr.Validation("link_type: none, promotion, category, product или store")
		}
		if *in.LinkType != "none" && (in.LinkID == nil || !httpx.IsUUID(*in.LinkID)) {
			return apperr.Validation("link_id: укажите, куда ведёт баннер")
		}
	}
	if in.NetworkID != nil && *in.NetworkID != "" && !httpx.IsUUID(*in.NetworkID) {
		return apperr.Validation("network_id: сеть не найдена")
	}
	return nil
}

func (s *Service) ListBanners(ctx context.Context, page httpx.Page) ([]Banner, error) {
	rows, err := s.pool.Query(ctx, bannerSelect+` ORDER BY is_active DESC, sort, created_at DESC, id LIMIT $1 OFFSET $2`,
		page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Banner])
}

func (s *Service) getBanner(ctx context.Context, q db.Querier, id string) (Banner, error) {
	rows, err := q.Query(ctx, bannerSelect+` WHERE id = $1`, id)
	if err != nil {
		return Banner{}, err
	}
	b, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Banner])
	if errors.Is(err, pgx.ErrNoRows) {
		return b, apperr.NotFound("баннер не найден")
	}
	return b, err
}

func emptyToNil(p *string) *string {
	if p == nil || *p == "" {
		return nil
	}
	return p
}

func (s *Service) CreateBanner(ctx context.Context, in BannerInput) (Banner, error) {
	if err := in.validate(true); err != nil {
		return Banner{}, err
	}
	str := func(p *string, def string) string {
		if p == nil {
			return def
		}
		return strings.TrimSpace(*p)
	}
	sort := 0
	if in.Sort != nil {
		sort = *in.Sort
	}
	active := true
	if in.IsActive != nil {
		active = *in.IsActive
	}
	var id string
	err := s.pool.QueryRow(ctx, `
		INSERT INTO banners (title, subtitle, image_url, color, link_type, link_id, network_id, starts_at, ends_at, sort, is_active)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) RETURNING id`,
		str(in.Title, ""), str(in.Subtitle, ""), str(in.ImageURL, ""), str(in.Color, "#155EEF"), str(in.LinkType, "none"),
		emptyToNil(in.LinkID), emptyToNil(in.NetworkID), in.StartsAt.Or(), in.EndsAt.Or(), sort, active).Scan(&id)
	if db.IsCheckViolation(err) {
		return Banner{}, apperr.Validation("баннер: проверьте даты и ссылку")
	}
	if db.IsForeignKeyViolation(err) {
		return Banner{}, apperr.Validation("network_id: сеть не найдена")
	}
	if err != nil {
		return Banner{}, err
	}
	return s.getBanner(ctx, s.pool, id)
}

func (s *Service) UpdateBanner(ctx context.Context, id string, in BannerInput) (Banner, error) {
	if err := in.validate(false); err != nil {
		return Banner{}, err
	}
	trim := func(p *string) *string {
		if p == nil {
			return nil
		}
		v := strings.TrimSpace(*p)
		return &v
	}
	setLink := in.LinkID != nil
	setNetwork := in.NetworkID != nil
	tag, err := s.pool.Exec(ctx, `
		UPDATE banners SET
			title = COALESCE($2, title), subtitle = COALESCE($3, subtitle), image_url = COALESCE($4, image_url),
			color = COALESCE($5, color), link_type = COALESCE($6, link_type),
			link_id = CASE WHEN $7 THEN $8::uuid ELSE link_id END,
			network_id = CASE WHEN $9 THEN $10::uuid ELSE network_id END,
			starts_at = CASE WHEN $11 THEN $12::timestamptz ELSE starts_at END,
			ends_at = CASE WHEN $13 THEN $14::timestamptz ELSE ends_at END,
			sort = COALESCE($15, sort), is_active = COALESCE($16, is_active), updated_at = now()
		WHERE id = $1`,
		id, trim(in.Title), trim(in.Subtitle), trim(in.ImageURL), in.Color, in.LinkType,
		setLink, emptyToNil(in.LinkID), setNetwork, emptyToNil(in.NetworkID),
		in.StartsAt.Set, in.StartsAt.Value, in.EndsAt.Set, in.EndsAt.Value, in.Sort, in.IsActive)
	if db.IsCheckViolation(err) {
		return Banner{}, apperr.Validation("баннер: проверьте даты и ссылку")
	}
	if db.IsForeignKeyViolation(err) {
		return Banner{}, apperr.Validation("network_id: сеть не найдена")
	}
	if err != nil {
		return Banner{}, err
	}
	if tag.RowsAffected() == 0 {
		return Banner{}, apperr.NotFound("баннер не найден")
	}
	return s.getBanner(ctx, s.pool, id)
}

// ActiveBanners — баннеры для приложения: платформенные и сетей networkIDs,
// действующие сейчас.
func ActiveBanners(ctx context.Context, q db.Querier, networkIDs []string) ([]Banner, error) {
	rows, err := q.Query(ctx, bannerSelect+`
		WHERE is_active AND (starts_at IS NULL OR starts_at <= now()) AND (ends_at IS NULL OR ends_at > now())
		  AND (network_id IS NULL OR network_id = ANY($1::uuid[]))
		ORDER BY sort, created_at DESC LIMIT 10`, networkIDs)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Banner])
}
