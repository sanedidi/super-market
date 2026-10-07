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
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/showcase"
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
	// false — только фото, без заголовка поверх.
	ShowText bool `json:"show_text"`
	// platform — баннер супер-админа; network — сеть загрузила сама
	// (проходит модерацию: pending → approved или rejected с причиной).
	Owner        string `json:"owner"`
	Moderation   string `json:"moderation"`
	RejectReason string `json:"reject_reason"`
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
	ShowText *bool                     `json:"show_text"`
}

const bannerSelect = `SELECT id, title, subtitle, image_url, color, link_type, link_id, network_id,
	(SELECT n.name FROM networks n WHERE n.id = banners.network_id), starts_at, ends_at, sort, is_active, created_at, show_text, owner, moderation, reject_reason FROM banners`

var colorRe = regexp.MustCompile(`^#[0-9A-Fa-f]{6}$`)

func (in BannerInput) validate(create bool) error {
	if create && in.Title == nil {
		return apperr.Validation("title: обязательное поле").Uz("title: majburiy maydon")
	}
	if in.Title != nil && strings.TrimSpace(*in.Title) == "" {
		return apperr.Validation("title: не может быть пустым").Uz("title: boʻsh boʻlishi mumkin emas")
	}
	if in.Color != nil && !colorRe.MatchString(*in.Color) {
		return apperr.Validation("color: ожидается #RRGGBB").Uz("color: #RRGGBB koʻrinishida boʻlsin")
	}
	if in.ImageURL != nil && *in.ImageURL != "" && !strings.HasPrefix(*in.ImageURL, "https://") && !strings.HasPrefix(*in.ImageURL, "http://") {
		return apperr.Validation("image_url: ожидается ссылка http(s)").Uz("image_url: http(s) havola boʻlishi kerak")
	}
	if in.LinkType != nil {
		switch *in.LinkType {
		case "none", "promotion", "category", "product", "store":
		default:
			return apperr.Validation("link_type: none, promotion, category, product или store").Uz("link_type: none, promotion, category, product yoki store")
		}
		if *in.LinkType != "none" && (in.LinkID == nil || !httpx.IsUUID(*in.LinkID)) {
			return apperr.Validation("link_id: укажите, куда ведёт баннер").Uz("link_id: banner qayerga olib borishini koʻrsating")
		}
	}
	if in.NetworkID != nil && *in.NetworkID != "" && !httpx.IsUUID(*in.NetworkID) {
		return apperr.Validation("network_id: сеть не найдена").Uz("network_id: tarmoq topilmadi")
	}
	return nil
}

// ListBanners — баннеры для супер-админа; moderation — только с таким
// статусом (очередь модерации — pending).
func (s *Service) ListBanners(ctx context.Context, moderation string, page httpx.Page) ([]Banner, error) {
	if moderation != "" && moderation != "pending" && moderation != "approved" && moderation != "rejected" {
		return nil, apperr.Validation("moderation: pending, approved или rejected").Uz("moderation: pending, approved yoki rejected")
	}
	rows, err := s.pool.Query(ctx, bannerSelect+` WHERE ($3 = '' OR moderation = $3)
		ORDER BY moderation = 'pending' DESC, is_active DESC, sort, created_at DESC, id LIMIT $1 OFFSET $2`,
		page.Limit, page.Offset, moderation)
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
		return b, apperr.NotFound("баннер не найден").Uz("banner topilmadi")
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
	showText := true
	if in.ShowText != nil {
		showText = *in.ShowText
	}
	var id string
	err := s.pool.QueryRow(ctx, `
		INSERT INTO banners (title, subtitle, image_url, color, link_type, link_id, network_id, starts_at, ends_at, sort, is_active, show_text)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12) RETURNING id`,
		str(in.Title, ""), str(in.Subtitle, ""), str(in.ImageURL, ""), str(in.Color, "#155EEF"), str(in.LinkType, "none"),
		emptyToNil(in.LinkID), emptyToNil(in.NetworkID), in.StartsAt.Or(), in.EndsAt.Or(), sort, active, showText).Scan(&id)
	if db.IsCheckViolation(err) {
		return Banner{}, apperr.Validation("баннер: проверьте даты и ссылку").Uz("banner: sanalar va havolani tekshiring")
	}
	if db.IsForeignKeyViolation(err) {
		return Banner{}, apperr.Validation("network_id: сеть не найдена").Uz("network_id: tarmoq topilmadi")
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
			sort = COALESCE($15, sort), is_active = COALESCE($16, is_active), show_text = COALESCE($17, show_text), updated_at = now()
		WHERE id = $1`,
		id, trim(in.Title), trim(in.Subtitle), trim(in.ImageURL), in.Color, in.LinkType,
		setLink, emptyToNil(in.LinkID), setNetwork, emptyToNil(in.NetworkID),
		in.StartsAt.Set, in.StartsAt.Value, in.EndsAt.Set, in.EndsAt.Value, in.Sort, in.IsActive, in.ShowText)
	if db.IsCheckViolation(err) {
		return Banner{}, apperr.Validation("баннер: проверьте даты и ссылку").Uz("banner: sanalar va havolani tekshiring")
	}
	if db.IsForeignKeyViolation(err) {
		return Banner{}, apperr.Validation("network_id: сеть не найдена").Uz("network_id: tarmoq topilmadi")
	}
	if err != nil {
		return Banner{}, err
	}
	if tag.RowsAffected() == 0 {
		return Banner{}, apperr.NotFound("баннер не найден").Uz("banner topilmadi")
	}
	return s.getBanner(ctx, s.pool, id)
}

// ActiveBanners — баннеры для приложения: платформенные и сетей networkIDs,
// действующие сейчас.
func ActiveBanners(ctx context.Context, q db.Querier, networkIDs []string) ([]Banner, error) {
	rows, err := q.Query(ctx, bannerSelect+`
		WHERE is_active AND moderation = 'approved' AND (starts_at IS NULL OR starts_at <= now()) AND (ends_at IS NULL OR ends_at > now())
		  AND (network_id IS NULL OR network_id = ANY($1::uuid[]))
		ORDER BY sort, created_at DESC LIMIT 10`, networkIDs)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Banner])
}

// HomeBanners — баннеры для главной магазина сети: платформенные и сети.
// Своих баннеров сети показывается не больше ownLimit (лимит тарифа —
// после понижения лишние скрываются, но не удаляются); preview — ещё и
// баннеры на модерации (их видит только сама сеть в предпросмотре).
func HomeBanners(ctx context.Context, q db.Querier, networkID string, ownLimit int, preview bool) ([]Banner, error) {
	rows, err := q.Query(ctx, `SELECT * FROM (`+bannerSelect+`
		WHERE is_active AND (starts_at IS NULL OR starts_at <= now()) AND (ends_at IS NULL OR ends_at > now())
		  AND (network_id IS NULL OR network_id = $1::uuid)
		  AND (moderation = 'approved' OR ($3 AND owner = 'network' AND moderation = 'pending'))) b
		WHERE b.owner <> 'network' OR b.id IN (
			SELECT id FROM banners WHERE owner = 'network' AND network_id = $1::uuid AND is_active AND moderation <> 'rejected'
			ORDER BY sort, created_at LIMIT $2)
		ORDER BY b.sort, b.created_at DESC LIMIT 20`, networkID, ownLimit, preview)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Banner])
}

// ---------------------------------------------- баннеры сети и модерация

// NetworkBanners — свои баннеры сети.
func (s *Service) NetworkBanners(ctx context.Context, networkID string) ([]Banner, error) {
	rows, err := s.pool.Query(ctx, bannerSelect+` WHERE owner = 'network' AND network_id = $1 ORDER BY is_active DESC, sort, created_at`, networkID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Banner])
}

// ActiveNetworkBanners — сколько своих баннеров у сети занимает лимит
// (включённые и не отклонённые).
func ActiveNetworkBanners(ctx context.Context, q db.Querier, networkID string) (int, error) {
	var n int
	err := q.QueryRow(ctx, `SELECT count(*) FROM banners WHERE owner = 'network' AND network_id = $1 AND is_active AND moderation <> 'rejected'`,
		networkID).Scan(&n)
	return n, err
}

// CreateNetworkBanner — сеть загружает свой баннер; он уходит на модерацию.
// Сколько своих баннеров можно — по тарифу витрины.
func (s *Service) CreateNetworkBanner(ctx context.Context, networkID string, in BannerInput) (Banner, error) {
	plan, err := showcase.ForNetwork(ctx, s.pool, networkID)
	if err != nil {
		return Banner{}, err
	}
	used, err := ActiveNetworkBanners(ctx, s.pool, networkID)
	if err != nil {
		return Banner{}, err
	}
	if limit := showcase.Allowed(plan.Effective.Banners); used >= limit {
		return Banner{}, showcase.Limit("banners", plan.Effective, limit, used,
			i18n.Text{RU: "лимит своих баннеров на тарифе «" + plan.Effective.Name + "»", UZ: "«" + plan.Effective.Name + "» tarifida oʻz bannerlaringiz limiti tugadi"})
	}
	if in.LinkType != nil && *in.LinkType == "store" {
		return Banner{}, apperr.Validation("link_type: баннер сети не ведёт в другой магазин").Uz("link_type: tarmoq banneri boshqa doʻkonga olib bormaydi")
	}
	in.NetworkID = &networkID
	b, err := s.CreateBanner(ctx, in)
	if err != nil {
		return b, err
	}
	if _, err := s.pool.Exec(ctx, `UPDATE banners SET owner = 'network', moderation = 'pending' WHERE id = $1`, b.ID); err != nil {
		return b, err
	}
	return s.getBanner(ctx, s.pool, b.ID)
}

// UpdateNetworkBanner — сеть меняет свой баннер; новый текст или фото
// снова уходят на модерацию. Включить баннер обратно можно, только если
// есть место в лимите.
func (s *Service) UpdateNetworkBanner(ctx context.Context, networkID, id string, in BannerInput) (Banner, error) {
	b, err := s.getBanner(ctx, s.pool, id)
	if err != nil {
		return b, err
	}
	if b.Owner != "network" || b.NetworkID == nil || *b.NetworkID != networkID {
		return Banner{}, apperr.NotFound("баннер не найден").Uz("banner topilmadi")
	}
	if in.LinkType != nil && *in.LinkType == "store" {
		return Banner{}, apperr.Validation("link_type: баннер сети не ведёт в другой магазин").Uz("link_type: tarmoq banneri boshqa doʻkonga olib bormaydi")
	}
	if in.IsActive != nil && *in.IsActive && !b.IsActive {
		plan, err := showcase.ForNetwork(ctx, s.pool, networkID)
		if err != nil {
			return Banner{}, err
		}
		used, err := ActiveNetworkBanners(ctx, s.pool, networkID)
		if err != nil {
			return Banner{}, err
		}
		if limit := showcase.Allowed(plan.Effective.Banners); used >= limit {
			return Banner{}, showcase.Limit("banners", plan.Effective, limit, used, i18n.Text{RU: "лимит своих баннеров на тарифе «" + plan.Effective.Name + "»", UZ: "«" + plan.Effective.Name + "» tarifida oʻz bannerlaringiz limiti tugadi"})
		}
	}
	in.NetworkID = nil
	if _, err := s.UpdateBanner(ctx, id, in); err != nil {
		return Banner{}, err
	}
	changed := in.Title != nil || in.Subtitle != nil || in.ImageURL != nil || in.LinkType != nil || in.LinkID != nil || in.ShowText != nil
	if changed {
		if _, err := s.pool.Exec(ctx, `UPDATE banners SET moderation = 'pending', reject_reason = '' WHERE id = $1`, id); err != nil {
			return Banner{}, err
		}
	}
	return s.getBanner(ctx, s.pool, id)
}

// ModerateBanner — супер-админ принимает баннер сети или отклоняет с причиной.
func (s *Service) ModerateBanner(ctx context.Context, id string, approve bool, reason string) (Banner, error) {
	reason = strings.TrimSpace(reason)
	if !approve && reason == "" {
		return Banner{}, apperr.Validation("reason: укажите причину, сеть её увидит").Uz("reason: sababini kiriting, tarmoq uni koʻradi")
	}
	status := "approved"
	if !approve {
		status = "rejected"
	}
	tag, err := s.pool.Exec(ctx, `UPDATE banners SET moderation = $2, reject_reason = $3, updated_at = now() WHERE id = $1 AND owner = 'network'`,
		id, status, reason)
	if err != nil {
		return Banner{}, err
	}
	if tag.RowsAffected() == 0 {
		return Banner{}, apperr.NotFound("баннер сети не найден").Uz("tarmoq banneri topilmadi")
	}
	return s.getBanner(ctx, s.pool, id)
}
