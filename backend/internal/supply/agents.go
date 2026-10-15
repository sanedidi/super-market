package supply

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/finance"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/plans"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/push"
)

// «SM Агент» регистрируется сам (Figma «SM Агент · регистрация сам»):
// телефон и код → имя → свой бренд из каталога (нет — заявка) → склад.
// Сам зарегистрированный агент видит магазины, когда у него есть бренд.

// maxAgentBrands — сколько брендов можно выбрать.
const maxAgentBrands = 20

// errBrandPending — бренд ещё не одобрен: магазины закрыты.
var errBrandPending = apperr.Forbidden("магазины откроются, когда Super Market одобрит ваш бренд").
	Uz("doʻkonlar Super Market brendingizni tasdiqlagach ochiladi")

// BrandHit — бренд каталога в поиске агента.
type BrandHit struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Category string `json:"category"`
	// Товаров бренда в общем каталоге.
	Products int `json:"products"`
	// Сколько агентов уже возят бренд.
	Agents int `json:"agents"`
}

const brandHitSelect = `
	SELECT b.id, b.name,
	       COALESCE((SELECT loc(c.name, c.name_uz) FROM products p JOIN categories c ON c.id = p.category_id
	                 WHERE p.brand_id = b.id AND p.network_id IS NULL AND p.is_active
	                 GROUP BY c.id, c.name, c.name_uz ORDER BY count(*) DESC, c.name LIMIT 1), ''),
	       (SELECT count(*) FROM products p WHERE p.brand_id = b.id AND p.network_id IS NULL AND p.is_active)::int,
	       (SELECT count(*) FROM distributor_brands d WHERE d.brand_id = b.id)::int
	FROM brands b`

func likeArg(q string) string {
	r := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	return r.Replace(strings.TrimSpace(q))
}

// SearchBrands — бренды каталога по названию (шаг «Какой бренд вы возите?»).
func (s *Service) SearchBrands(ctx context.Context, q string, limit int) ([]BrandHit, error) {
	if limit <= 0 || limit > 50 {
		limit = 30
	}
	rows, err := s.pool.Query(ctx, brandHitSelect+`
		WHERE b.is_active AND ($1 = '' OR b.name ILIKE '%' || $1 || '%')
		ORDER BY (lower(b.name) LIKE lower($1) || '%') DESC,
		         (SELECT count(*) FROM products p WHERE p.brand_id = b.id AND p.network_id IS NULL AND p.is_active) DESC, b.name
		LIMIT $2`, likeArg(q), limit)
	return collect[BrandHit](rows, err)
}

func collect[T any](rows pgx.Rows, err error) ([]T, error) {
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, pgx.RowToStructByPos[T])
	if out == nil {
		out = []T{}
	}
	return out, err
}

// RegisterInput — шаги «Как вас зовут» и «Ваш бренд».
type RegisterInput struct {
	Ticket   string   `json:"ticket"`
	FullName string   `json:"full_name"`
	Company  string   `json:"company"`
	BrandIDs []string `json:"brand_ids"`
}

// RegisterAgent создаёт сеть агента (вид distributor, тариф «Бизнес» с
// пробным периодом), владельца с номером ph и его бренды. Возвращает
// пользователя — для сессии. Склад агент указывает следующим шагом.
func (s *Service) RegisterAgent(ctx context.Context, ph string, in RegisterInput) (string, error) {
	name := strings.TrimSpace(in.FullName)
	company := strings.TrimSpace(in.Company)
	if name == "" {
		return "", apperr.Validation("full_name: как вас зовут?").Uz("full_name: ismingiz qanday?")
	}
	if len([]rune(name)) > 100 || len([]rune(company)) > 100 {
		return "", apperr.Validation("не длиннее 100 символов").Uz("100 belgidan oshmasin")
	}
	ids, err := brandIDs(in.BrandIDs)
	if err != nil {
		return "", err
	}
	netName := company
	if netName == "" {
		netName = name
	}
	var userID string
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var exists bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM users u JOIN employees e ON e.user_id = u.id WHERE u.phone = $1)`, ph).Scan(&exists); err != nil {
			return err
		}
		if exists {
			return identity.ErrAgentRegistered()
		}
		// Тариф новых агентов — в настройках биллинга (супер-админ).
		var planKey string
		if err := tx.QueryRow(ctx, `SELECT agent_plan FROM billing_settings WHERE id = 1`).Scan(&planKey); err != nil {
			return err
		}
		if p, err := plans.Get(ctx, tx, planKey); err != nil || !p.IsActive {
			return apperr.Conflict("plan_missing", "тариф для агентов не найден — обратитесь в поддержку").Uz("agentlar uchun tarif topilmadi — qoʻllab-quvvatlash xizmatiga murojaat qiling")
		}
		var netID string
		if err := tx.QueryRow(ctx, `INSERT INTO networks (name, kind, plan_key, self_registered) VALUES ($1, 'distributor', $2, true) RETURNING id`,
			netName, planKey).Scan(&netID); err != nil {
			return err
		}
		if _, err := identity.CreateOwner(ctx, tx, netID, ph, name); err != nil {
			return err
		}
		if err := catalog.CreateDefaultPriceType(ctx, tx, netID); err != nil {
			return err
		}
		if err := finance.CreateMainCashbox(ctx, tx, netID); err != nil {
			return err
		}
		if err := plans.StartTrial(ctx, tx, netID); err != nil {
			return err
		}
		if err := addBrands(ctx, tx, netID, ids); err != nil {
			return err
		}
		return tx.QueryRow(ctx, `SELECT id FROM users WHERE phone = $1`, ph).Scan(&userID)
	})
	if err != nil {
		return "", err
	}
	s.log.Info("агент зарегистрировался", "brands", len(ids))
	return userID, nil
}

func brandIDs(raw []string) ([]string, error) {
	if len(raw) > maxAgentBrands {
		return nil, apperr.Validation(fmt.Sprintf("brand_ids: не больше %d брендов", maxAgentBrands)).Uz(fmt.Sprintf("brand_ids: %d tadan koʻp boʻlmasin", maxAgentBrands))
	}
	seen := map[string]bool{}
	var ids []string
	for _, id := range raw {
		if !httpx.IsUUID(id) {
			return nil, apperr.Validation("brand_ids: бренд не найден").Uz("brand_ids: brend topilmadi")
		}
		if !seen[id] {
			seen[id] = true
			ids = append(ids, id)
		}
	}
	return ids, nil
}

// addBrands добавляет агенту действующие бренды каталога.
func addBrands(ctx context.Context, q db.Querier, networkID string, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	tag, err := q.Exec(ctx, `
		INSERT INTO distributor_brands (network_id, brand_id)
		SELECT $1, b.id FROM brands b WHERE b.id = ANY($2::uuid[]) AND b.is_active
		ON CONFLICT DO NOTHING`, networkID, ids)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		var n int
		if err := q.QueryRow(ctx, `SELECT count(*) FROM distributor_brands WHERE network_id = $1 AND brand_id = ANY($2::uuid[])`, networkID, ids).Scan(&n); err != nil {
			return err
		}
		if n == 0 {
			return apperr.Validation("brand_ids: бренд не найден").Uz("brand_ids: brend topilmadi")
		}
	}
	return nil
}

// verified — агент может работать с магазинами: его завёл супер-админ или
// у него есть хотя бы один бренд.
func verified(ctx context.Context, q db.Querier, networkID string) (bool, error) {
	var ok bool
	err := q.QueryRow(ctx, `
		SELECT NOT n.self_registered OR EXISTS (SELECT 1 FROM distributor_brands d WHERE d.network_id = n.id)
		FROM networks n WHERE n.id = $1`, networkID).Scan(&ok)
	return ok, err
}

// requireVerified — для разделов с магазинами.
func (s *Service) requireVerified(ctx context.Context, p *identity.Principal) error {
	if err := requireDistributor(p); err != nil {
		return err
	}
	ok, err := verified(ctx, s.pool, p.NetworkID)
	if err != nil {
		return err
	}
	if !ok {
		return errBrandPending
	}
	return nil
}

// ------------------------------------------------------------ бренды агента

// BrandRequest — заявка на новый бренд.
type BrandRequest struct {
	ID             string     `json:"id"`
	Name           string     `json:"name"`
	CategoryID     *string    `json:"category_id"`
	CategoryName   string     `json:"category_name"`
	Manufacturer   string     `json:"manufacturer"`
	Comment        string     `json:"comment"`
	LogoURL        string     `json:"logo_url"`
	Status         string     `json:"status"`
	BrandID        *string    `json:"brand_id"`
	BrandName      string     `json:"brand_name"`
	LinkedExisting bool       `json:"linked_existing"`
	Reason         string     `json:"reason"`
	CreatedAt      time.Time  `json:"created_at"`
	DecidedAt      *time.Time `json:"decided_at"`
	// Для супер-админа.
	NetworkID   string     `json:"network_id"`
	NetworkName string     `json:"network_name"`
	AgentName   string     `json:"agent_name"`
	AgentPhone  string     `json:"agent_phone"`
	AgentSince  time.Time  `json:"agent_registered_at"`
	Similar     []BrandHit `json:"similar,omitempty"`
}

const brandRequestSelect = `
	SELECT r.id, r.name, r.category_id, COALESCE(loc(c.name, c.name_uz), ''), r.manufacturer, r.comment, r.logo_url,
	       r.status, r.brand_id, COALESCE(b.name, ''), r.linked_existing, r.reason, r.created_at, r.decided_at,
	       n.id, n.name, COALESCE(oe.full_name, ''), COALESCE(ou.phone, ''), n.created_at
	FROM brand_requests r
	JOIN networks n          ON n.id = r.network_id
	LEFT JOIN categories c   ON c.id = r.category_id
	LEFT JOIN brands b       ON b.id = r.brand_id
	LEFT JOIN roles orl      ON orl.network_id = n.id AND orl.is_owner
	LEFT JOIN employees oe   ON oe.role_id = orl.id
	LEFT JOIN users ou       ON ou.id = oe.user_id`

func scanBrandRequest(row pgx.CollectableRow) (BrandRequest, error) {
	var r BrandRequest
	err := row.Scan(&r.ID, &r.Name, &r.CategoryID, &r.CategoryName, &r.Manufacturer, &r.Comment, &r.LogoURL,
		&r.Status, &r.BrandID, &r.BrandName, &r.LinkedExisting, &r.Reason, &r.CreatedAt, &r.DecidedAt,
		&r.NetworkID, &r.NetworkName, &r.AgentName, &r.AgentPhone, &r.AgentSince)
	return r, err
}

func getBrandRequest(ctx context.Context, q db.Querier, id string) (BrandRequest, error) {
	rows, err := q.Query(ctx, brandRequestSelect+` WHERE r.id = $1`, id)
	if err != nil {
		return BrandRequest{}, err
	}
	r, err := pgx.CollectExactlyOneRow(rows, scanBrandRequest)
	if errors.Is(err, pgx.ErrNoRows) {
		return BrandRequest{}, apperr.NotFound("заявка не найдена").Uz("ariza topilmadi")
	}
	return r, err
}

// AgentBrands — бренды агента и его заявки (плашка «Бренд на рассмотрении»).
type AgentBrands struct {
	// Магазины открыты (есть бренд или агента завёл супер-админ).
	Verified       bool           `json:"verified"`
	SelfRegistered bool           `json:"self_registered"`
	Brands         []BrandHit     `json:"brands"`
	Requests       []BrandRequest `json:"requests"`
}

func (s *Service) MyBrands(ctx context.Context, p *identity.Principal) (AgentBrands, error) {
	if err := requireDistributor(p); err != nil {
		return AgentBrands{}, err
	}
	var out AgentBrands
	if err := s.pool.QueryRow(ctx, `SELECT self_registered FROM networks WHERE id = $1`, p.NetworkID).Scan(&out.SelfRegistered); err != nil {
		return out, err
	}
	var err error
	if out.Verified, err = verified(ctx, s.pool, p.NetworkID); err != nil {
		return out, err
	}
	rows, err := s.pool.Query(ctx, brandHitSelect+`
		JOIN distributor_brands d ON d.brand_id = b.id AND d.network_id = $1 ORDER BY b.name`, p.NetworkID)
	if out.Brands, err = collect[BrandHit](rows, err); err != nil {
		return out, err
	}
	rows, err = s.pool.Query(ctx, brandRequestSelect+` WHERE r.network_id = $1 ORDER BY r.created_at DESC LIMIT 20`, p.NetworkID)
	if err != nil {
		return out, err
	}
	out.Requests, err = pgx.CollectRows(rows, scanBrandRequest)
	if out.Requests == nil {
		out.Requests = []BrandRequest{}
	}
	return out, err
}

// AddMyBrands — агент добавляет бренды из каталога (владелец).
func (s *Service) AddMyBrands(ctx context.Context, p *identity.Principal, raw []string) (AgentBrands, error) {
	if err := requireDistributor(p); err != nil {
		return AgentBrands{}, err
	}
	if !p.IsOwner {
		return AgentBrands{}, apperr.Forbidden("бренды выбирает владелец").Uz("brendlarni egasi tanlaydi")
	}
	ids, err := brandIDs(raw)
	if err != nil {
		return AgentBrands{}, err
	}
	if len(ids) == 0 {
		return AgentBrands{}, apperr.Validation("brand_ids: выберите бренд").Uz("brand_ids: brendni tanlang")
	}
	var total int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM distributor_brands WHERE network_id = $1`, p.NetworkID).Scan(&total); err != nil {
		return AgentBrands{}, err
	}
	if total+len(ids) > maxAgentBrands {
		return AgentBrands{}, apperr.Validation(fmt.Sprintf("не больше %d брендов", maxAgentBrands)).Uz(fmt.Sprintf("%d tadan koʻp brend boʻlmasin", maxAgentBrands))
	}
	if err := addBrands(ctx, s.pool, p.NetworkID, ids); err != nil {
		return AgentBrands{}, err
	}
	return s.MyBrands(ctx, p)
}

// BrandRequestInput — «Нет моего бренда»: заявка на новый бренд.
type BrandRequestInput struct {
	Name         string  `json:"name"`
	CategoryID   *string `json:"category_id"`
	Manufacturer string  `json:"manufacturer"`
	Comment      string  `json:"comment"`
	LogoURL      string  `json:"logo_url"`
}

func (in *BrandRequestInput) clean() error {
	in.Name = strings.TrimSpace(in.Name)
	in.Manufacturer = strings.TrimSpace(in.Manufacturer)
	in.Comment = strings.TrimSpace(in.Comment)
	in.LogoURL = strings.TrimSpace(in.LogoURL)
	switch {
	case in.Name == "":
		return apperr.Validation("name: название бренда").Uz("name: brend nomi")
	case len([]rune(in.Name)) > 100:
		return apperr.Validation("name: не длиннее 100 символов").Uz("name: 100 belgidan oshmasin")
	case len([]rune(in.Manufacturer)) > 200:
		return apperr.Validation("manufacturer: не длиннее 200 символов").Uz("manufacturer: 200 belgidan oshmasin")
	case len([]rune(in.Comment)) > 1000:
		return apperr.Validation("comment: не длиннее 1000 символов").Uz("comment: 1000 belgidan oshmasin")
	case len(in.LogoURL) > 1000 || (in.LogoURL != "" && !strings.HasPrefix(in.LogoURL, "http")):
		return apperr.Validation("logo_url: неверная ссылка").Uz("logo_url: havola notoʻgʻri")
	case in.CategoryID != nil && !httpx.IsUUID(*in.CategoryID):
		return apperr.Validation("category_id: категория не найдена").Uz("category_id: kategoriya topilmadi")
	}
	return nil
}

// CreateBrandRequest — заявка на новый бренд. Если бренд с таким названием
// уже есть в каталоге — он сразу добавляется агенту (заявка одобрена).
func (s *Service) CreateBrandRequest(ctx context.Context, p *identity.Principal, in BrandRequestInput) (BrandRequest, error) {
	if err := requireDistributor(p); err != nil {
		return BrandRequest{}, err
	}
	if !p.IsOwner {
		return BrandRequest{}, apperr.Forbidden("бренды выбирает владелец").Uz("brendlarni egasi tanlaydi")
	}
	if err := in.clean(); err != nil {
		return BrandRequest{}, err
	}
	var id string
	var existing bool
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if err := checkCategory(ctx, tx, in.CategoryID); err != nil {
			return err
		}
		var brandID string
		err := tx.QueryRow(ctx, `SELECT id FROM brands WHERE lower(name) = lower($1) AND is_active`, in.Name).Scan(&brandID)
		switch {
		case err == nil:
			existing = true
			if err := addBrands(ctx, tx, p.NetworkID, []string{brandID}); err != nil {
				return err
			}
			return tx.QueryRow(ctx, `
				INSERT INTO brand_requests (network_id, employee_id, name, category_id, manufacturer, comment, logo_url,
				                            status, brand_id, linked_existing, decided_at)
				VALUES ($1, $2, $3, $4, $5, $6, $7, 'approved', $8, true, now()) RETURNING id`,
				p.NetworkID, p.EmployeeID, in.Name, in.CategoryID, in.Manufacturer, in.Comment, in.LogoURL, brandID).Scan(&id)
		case !errors.Is(err, pgx.ErrNoRows):
			return err
		}
		// Уже ждёт заявка с этим названием — обновляем её.
		err = tx.QueryRow(ctx, `
			UPDATE brand_requests SET category_id = $3, manufacturer = $4, comment = $5, logo_url = $6
			WHERE network_id = $1 AND lower(name) = lower($2) AND status = 'pending' RETURNING id`,
			p.NetworkID, in.Name, in.CategoryID, in.Manufacturer, in.Comment, in.LogoURL).Scan(&id)
		if err == nil {
			return nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		var pending int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM brand_requests WHERE network_id = $1 AND status = 'pending'`, p.NetworkID).Scan(&pending); err != nil {
			return err
		}
		if pending >= 5 {
			return apperr.Conflict("too_many_requests", "уже 5 заявок ждут проверки — дождитесь решения").Uz("5 ta ariza tekshiruvni kutmoqda — qarorni kuting")
		}
		return tx.QueryRow(ctx, `
			INSERT INTO brand_requests (network_id, employee_id, name, category_id, manufacturer, comment, logo_url)
			VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id`,
			p.NetworkID, p.EmployeeID, in.Name, in.CategoryID, in.Manufacturer, in.Comment, in.LogoURL).Scan(&id)
	})
	if err != nil {
		return BrandRequest{}, err
	}
	r, err := getBrandRequest(ctx, s.pool, id)
	if err == nil && !existing {
		s.notifyAdmins(fmt.Sprintf("Заявка на новый бренд «%s»\nАгент: %s, %s (%s)\nОбработайте в панели супер-админа: Каталог → Заявки на бренды.",
			r.Name, r.AgentName, r.AgentPhone, r.NetworkName))
	}
	return r, err
}

// UpdateBrandRequest — агент исправляет свою заявку (ждёт проверки или
// отклонена): она снова уходит на проверку.
func (s *Service) UpdateBrandRequest(ctx context.Context, p *identity.Principal, id string, in BrandRequestInput) (BrandRequest, error) {
	if err := requireDistributor(p); err != nil {
		return BrandRequest{}, err
	}
	if !p.IsOwner {
		return BrandRequest{}, apperr.Forbidden("бренды выбирает владелец").Uz("brendlarni egasi tanlaydi")
	}
	if !httpx.IsUUID(id) {
		return BrandRequest{}, apperr.NotFound("заявка не найдена").Uz("ariza topilmadi")
	}
	if err := in.clean(); err != nil {
		return BrandRequest{}, err
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if err := checkCategory(ctx, tx, in.CategoryID); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `
			UPDATE brand_requests SET name = $3, category_id = $4, manufacturer = $5, comment = $6, logo_url = $7,
			       status = 'pending', reason = '', decided_at = NULL, decided_by = NULL
			WHERE id = $1 AND network_id = $2 AND status IN ('pending', 'rejected')`,
			id, p.NetworkID, in.Name, in.CategoryID, in.Manufacturer, in.Comment, in.LogoURL)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.Conflict("request_closed", "заявка уже одобрена или не найдена").Uz("ariza allaqachon tasdiqlangan yoki topilmadi")
		}
		return nil
	})
	if err != nil {
		return BrandRequest{}, err
	}
	r, err := getBrandRequest(ctx, s.pool, id)
	if err == nil {
		s.notifyAdmins(fmt.Sprintf("Агент исправил заявку на бренд «%s»\nАгент: %s, %s (%s)", r.Name, r.AgentName, r.AgentPhone, r.NetworkName))
	}
	return r, err
}

func checkCategory(ctx context.Context, q db.Querier, id *string) error {
	if id == nil {
		return nil
	}
	var ok bool
	if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM categories WHERE id = $1 AND is_active)`, *id).Scan(&ok); err != nil {
		return err
	}
	if !ok {
		return apperr.Validation("category_id: категория не найдена").Uz("category_id: kategoriya topilmadi")
	}
	return nil
}

// Category — категория первого уровня (поле «Категория» в заявке).
type Category struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

func (s *Service) Categories(ctx context.Context) ([]Category, error) {
	rows, err := s.pool.Query(ctx, `SELECT id, loc(name, name_uz) FROM categories WHERE parent_id IS NULL AND is_active ORDER BY sort, name`)
	return collect[Category](rows, err)
}

// notifyAdmins — супер-админам в Telegram (вне транзакции, не влияет на ответ).
func (s *Service) notifyAdmins(text string) {
	if s.notifier == nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		s.notifier.SuperAdmins(ctx, text)
	}()
}

// -------------------------------------------------------- супер-админ

// BrandRequests — список заявок и счётчики вкладок.
type BrandRequests struct {
	Items    []BrandRequest `json:"items"`
	Pending  int            `json:"pending"`
	Approved int            `json:"approved"`
	Rejected int            `json:"rejected"`
}

func requireAdmin(p *identity.Principal) error {
	if p == nil || p.App != identity.AppAdmin {
		return apperr.Forbidden("только для супер-админа").Uz("faqat super-admin uchun")
	}
	return nil
}

// ListBrandRequests — «Каталог → Заявки на бренды».
func (s *Service) ListBrandRequests(ctx context.Context, p *identity.Principal, status, q string, page httpx.Page) (BrandRequests, error) {
	if err := requireAdmin(p); err != nil {
		return BrandRequests{}, err
	}
	if status == "" {
		status = "pending"
	}
	if status != "pending" && status != "approved" && status != "rejected" {
		return BrandRequests{}, apperr.Validation("status: pending, approved или rejected").Uz("status: pending, approved yoki rejected")
	}
	var out BrandRequests
	if err := s.pool.QueryRow(ctx, `
		SELECT count(*) FILTER (WHERE status = 'pending')::int, count(*) FILTER (WHERE status = 'approved')::int,
		       count(*) FILTER (WHERE status = 'rejected')::int FROM brand_requests`).Scan(&out.Pending, &out.Approved, &out.Rejected); err != nil {
		return out, err
	}
	order := "r.created_at"
	if status != "pending" {
		order = "COALESCE(r.decided_at, r.created_at) DESC"
	}
	rows, err := s.pool.Query(ctx, brandRequestSelect+`
		WHERE r.status = $1 AND ($2 = '' OR r.name ILIKE '%' || $2 || '%' OR n.name ILIKE '%' || $2 || '%'
		      OR oe.full_name ILIKE '%' || $2 || '%' OR ou.phone LIKE '%' || $2 || '%')
		ORDER BY `+order+` LIMIT $3 OFFSET $4`, status, likeArg(q), page.Limit, page.Offset)
	if err != nil {
		return out, err
	}
	out.Items, err = pgx.CollectRows(rows, scanBrandRequest)
	if out.Items == nil {
		out.Items = []BrandRequest{}
	}
	return out, err
}

// GetBrandRequest — карточка заявки с похожими брендами каталога.
func (s *Service) GetBrandRequest(ctx context.Context, p *identity.Principal, id string) (BrandRequest, error) {
	if err := requireAdmin(p); err != nil {
		return BrandRequest{}, err
	}
	if !httpx.IsUUID(id) {
		return BrandRequest{}, apperr.NotFound("заявка не найдена").Uz("ariza topilmadi")
	}
	r, err := getBrandRequest(ctx, s.pool, id)
	if err != nil {
		return r, err
	}
	rows, err := s.pool.Query(ctx, brandHitSelect+`
		WHERE b.is_active AND (similarity(lower(b.name), lower($1)) > 0.3
		      OR lower(b.name) LIKE lower(split_part($1, ' ', 1)) || '%')
		ORDER BY similarity(lower(b.name), lower($1)) DESC LIMIT 5`, r.Name)
	r.Similar, err = collect[BrandHit](rows, err)
	return r, err
}

// ApproveInput — «Одобрить»: название и категорию можно поправить.
type ApproveInput struct {
	Name       string  `json:"name"`
	CategoryID *string `json:"category_id"`
}

// ApproveBrandRequest создаёт бренд (или берёт существующий с тем же
// названием) и добавляет его агенту.
func (s *Service) ApproveBrandRequest(ctx context.Context, p *identity.Principal, id string, in ApproveInput) (BrandRequest, error) {
	if err := requireAdmin(p); err != nil {
		return BrandRequest{}, err
	}
	name := strings.TrimSpace(in.Name)
	if name != "" && len([]rune(name)) > 100 {
		return BrandRequest{}, apperr.Validation("name: не длиннее 100 символов").Uz("name: 100 belgidan oshmasin")
	}
	return s.decide(ctx, p, id, func(ctx context.Context, tx pgx.Tx, r BrandRequest) (string, bool, error) {
		if name == "" {
			name = r.Name
		}
		cat := r.CategoryID
		if in.CategoryID != nil {
			if !httpx.IsUUID(*in.CategoryID) {
				return "", false, apperr.Validation("category_id: категория не найдена").Uz("category_id: kategoriya topilmadi")
			}
			if err := checkCategory(ctx, tx, in.CategoryID); err != nil {
				return "", false, err
			}
			cat = in.CategoryID
		}
		if _, err := tx.Exec(ctx, `UPDATE brand_requests SET name = $2, category_id = $3 WHERE id = $1`, r.ID, name, cat); err != nil {
			return "", false, err
		}
		var brandID string
		err := tx.QueryRow(ctx, `SELECT id FROM brands WHERE lower(name) = lower($1)`, name).Scan(&brandID)
		if err == nil {
			_, err = tx.Exec(ctx, `UPDATE brands SET is_active = true WHERE id = $1 AND NOT is_active`, brandID)
			return brandID, true, err
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return "", false, err
		}
		err = tx.QueryRow(ctx, `INSERT INTO brands (name) VALUES ($1) RETURNING id`, name).Scan(&brandID)
		return brandID, false, err
	})
}

// LinkBrandRequest — «Это существующий бренд»: агента привязывают к бренду
// каталога, новый бренд не создаётся.
func (s *Service) LinkBrandRequest(ctx context.Context, p *identity.Principal, id, brandID string) (BrandRequest, error) {
	if err := requireAdmin(p); err != nil {
		return BrandRequest{}, err
	}
	if !httpx.IsUUID(brandID) {
		return BrandRequest{}, apperr.Validation("brand_id: бренд не найден").Uz("brand_id: brend topilmadi")
	}
	return s.decide(ctx, p, id, func(ctx context.Context, tx pgx.Tx, _ BrandRequest) (string, bool, error) {
		var ok bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM brands WHERE id = $1 AND is_active)`, brandID).Scan(&ok); err != nil {
			return "", false, err
		}
		if !ok {
			return "", false, apperr.Validation("brand_id: бренд не найден").Uz("brand_id: brend topilmadi")
		}
		return brandID, true, nil
	})
}

// decide — общий путь одобрения: бренд → агенту, заявка закрыта, push агенту.
func (s *Service) decide(ctx context.Context, p *identity.Principal, id string,
	pick func(ctx context.Context, tx pgx.Tx, r BrandRequest) (brandID string, existing bool, err error)) (BrandRequest, error) {
	if !httpx.IsUUID(id) {
		return BrandRequest{}, apperr.NotFound("заявка не найдена").Uz("ariza topilmadi")
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var status string
		if err := tx.QueryRow(ctx, `SELECT status FROM brand_requests WHERE id = $1 FOR UPDATE`, id).Scan(&status); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return apperr.NotFound("заявка не найдена").Uz("ariza topilmadi")
			}
			return err
		}
		if status != "pending" {
			return apperr.Conflict("request_closed", "по заявке уже есть решение").Uz("ariza boʻyicha qaror allaqachon bor")
		}
		r, err := getBrandRequest(ctx, tx, id)
		if err != nil {
			return err
		}
		brandID, existing, err := pick(ctx, tx, r)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO distributor_brands (network_id, brand_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
			r.NetworkID, brandID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			UPDATE brand_requests SET status = 'approved', brand_id = $2, linked_existing = $3, reason = '',
			       decided_at = now(), decided_by = $4 WHERE id = $1`, id, brandID, existing, p.UserID); err != nil {
			return err
		}
		var bname string
		if err := tx.QueryRow(ctx, `SELECT name FROM brands WHERE id = $1`, brandID).Scan(&bname); err != nil {
			return err
		}
		return s.pushAgent(ctx, tx, r.NetworkID, "brand_approved",
			i18n.Text{RU: fmt.Sprintf("Бренд «%s» одобрен", bname), UZ: fmt.Sprintf("«%s» brendi tasdiqlandi", bname)},
			i18n.Text{RU: "Магазины открыты: смотрите, кому чего не хватает, и договаривайтесь.",
				UZ: "Doʻkonlar ochildi: kimga nima yetishmayotganini koʻring va kelishing."},
			map[string]string{"request_id": id})
	})
	if err != nil {
		return BrandRequest{}, err
	}
	return getBrandRequest(ctx, s.pool, id)
}

// RejectBrandRequest — «Отклонить» с причиной (её увидит агент).
func (s *Service) RejectBrandRequest(ctx context.Context, p *identity.Principal, id, reason string) (BrandRequest, error) {
	if err := requireAdmin(p); err != nil {
		return BrandRequest{}, err
	}
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return BrandRequest{}, apperr.Validation("reason: укажите причину — её увидит агент").Uz("reason: sababni yozing — uni agent koʻradi")
	}
	if len([]rune(reason)) > 500 {
		return BrandRequest{}, apperr.Validation("reason: не длиннее 500 символов").Uz("reason: 500 belgidan oshmasin")
	}
	if !httpx.IsUUID(id) {
		return BrandRequest{}, apperr.NotFound("заявка не найдена").Uz("ariza topilmadi")
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var networkID, name string
		err := tx.QueryRow(ctx, `
			UPDATE brand_requests SET status = 'rejected', reason = $2, decided_at = now(), decided_by = $3
			WHERE id = $1 AND status = 'pending' RETURNING network_id, name`, id, reason, p.UserID).Scan(&networkID, &name)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Conflict("request_closed", "по заявке уже есть решение или она не найдена").Uz("ariza boʻyicha qaror bor yoki u topilmadi")
		}
		if err != nil {
			return err
		}
		return s.pushAgent(ctx, tx, networkID, "brand_rejected",
			i18n.Text{RU: fmt.Sprintf("Бренд «%s» не одобрен", name), UZ: fmt.Sprintf("«%s» brendi tasdiqlanmadi", name)},
			i18n.Text{RU: "Причина: " + reason, UZ: "Sabab: " + reason},
			map[string]string{"request_id": id})
	})
	if err != nil {
		return BrandRequest{}, err
	}
	return getBrandRequest(ctx, s.pool, id)
}

// pushAgent — push владельцу сети агента.
func (s *Service) pushAgent(ctx context.Context, q db.Querier, networkID, kind string, title, body i18n.Text, data map[string]string) error {
	owner, err := ownerEmployee(ctx, q, networkID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	return push.EnqueueEmployee(ctx, q, owner, kind, title, body, data)
}
