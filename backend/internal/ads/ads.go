// Package ads — реклама брендов на главной приложения: рекламодатели и
// кампании (полка или фото-баннер с товарами бренда), правила для сетей,
// оплачиваемые показы, доля сетей с рекламы, счета и акты брендам.
//
// Кампания показывается только в магазинах, где есть товары бренда, всегда
// с пометкой «Реклама» и не больше двух на главной. Сеть может скрыть бренд
// или категорию у себя, а на «Про» — уменьшить число рекламных блоков.
package ads

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

type Service struct {
	pool *pgxpool.Pool
	now  func() time.Time
}

func NewService(pool *pgxpool.Pool) *Service { return &Service{pool: pool, now: time.Now} }

// ------------------------------------------------------------- правила

// Settings — правила рекламы и реквизиты платформы.
type Settings struct {
	NetworkSharePct        string    `json:"network_share_pct"`
	ShareToSubscription    bool      `json:"share_to_subscription"`
	AllowHideBrands        bool      `json:"allow_hide_brands"`
	AllowExcludeCategories bool      `json:"allow_exclude_categories"`
	CompanyName            string    `json:"company_name"`
	CompanyINN             string    `json:"company_inn"`
	CompanyAddress         string    `json:"company_address"`
	CompanyBank            string    `json:"company_bank"`
	CompanyAccount         string    `json:"company_account"`
	CompanyMFO             string    `json:"company_mfo"`
	CompanyDirector        string    `json:"company_director"`
	UpdatedAt              time.Time `json:"updated_at"`
}

type SettingsInput struct {
	NetworkSharePct        *money.Amount `json:"network_share_pct"`
	ShareToSubscription    *bool         `json:"share_to_subscription"`
	AllowHideBrands        *bool         `json:"allow_hide_brands"`
	AllowExcludeCategories *bool         `json:"allow_exclude_categories"`
	CompanyName            *string       `json:"company_name"`
	CompanyINN             *string       `json:"company_inn"`
	CompanyAddress         *string       `json:"company_address"`
	CompanyBank            *string       `json:"company_bank"`
	CompanyAccount         *string       `json:"company_account"`
	CompanyMFO             *string       `json:"company_mfo"`
	CompanyDirector        *string       `json:"company_director"`
}

func GetSettings(ctx context.Context, q db.Querier) (Settings, error) {
	var s Settings
	err := q.QueryRow(ctx, `SELECT network_share_pct::text, share_to_subscription, allow_hide_brands, allow_exclude_categories,
		company_name, company_inn, company_address, company_bank, company_account, company_mfo, company_director, updated_at
		FROM ad_settings WHERE id = 1`).Scan(&s.NetworkSharePct, &s.ShareToSubscription, &s.AllowHideBrands, &s.AllowExcludeCategories,
		&s.CompanyName, &s.CompanyINN, &s.CompanyAddress, &s.CompanyBank, &s.CompanyAccount, &s.CompanyMFO, &s.CompanyDirector, &s.UpdatedAt)
	return s, err
}

func trim(p *string) *string {
	if p == nil {
		return nil
	}
	v := strings.TrimSpace(*p)
	return &v
}

func (s *Service) SaveSettings(ctx context.Context, in SettingsInput) (Settings, error) {
	var pct *string
	if in.NetworkSharePct != nil {
		d := money.D(string(*in.NetworkSharePct))
		if d.Sign() < 0 || d.Cmp(money.D("100")) > 0 {
			return Settings{}, apperr.Validation("network_share_pct: от 0 до 100").Uz("network_share_pct: 0 dan 100 gacha")
		}
		v := string(*in.NetworkSharePct)
		pct = &v
	}
	if _, err := s.pool.Exec(ctx, `UPDATE ad_settings SET
		network_share_pct = COALESCE($1::numeric, network_share_pct), share_to_subscription = COALESCE($2, share_to_subscription),
		allow_hide_brands = COALESCE($3, allow_hide_brands), allow_exclude_categories = COALESCE($4, allow_exclude_categories),
		company_name = COALESCE($5, company_name), company_inn = COALESCE($6, company_inn), company_address = COALESCE($7, company_address),
		company_bank = COALESCE($8, company_bank), company_account = COALESCE($9, company_account), company_mfo = COALESCE($10, company_mfo),
		company_director = COALESCE($11, company_director), updated_at = now() WHERE id = 1`,
		pct, in.ShareToSubscription, in.AllowHideBrands, in.AllowExcludeCategories, trim(in.CompanyName), trim(in.CompanyINN),
		trim(in.CompanyAddress), trim(in.CompanyBank), trim(in.CompanyAccount), trim(in.CompanyMFO), trim(in.CompanyDirector)); err != nil {
		return Settings{}, err
	}
	bump()
	return GetSettings(ctx, s.pool)
}

// -------------------------------------------------------- рекламодатели

type Advertiser struct {
	ID             string    `json:"id"`
	Name           string    `json:"name"`
	INN            string    `json:"inn"`
	Address        string    `json:"address"`
	Bank           string    `json:"bank"`
	Account        string    `json:"account"`
	MFO            string    `json:"mfo"`
	ContractNumber string    `json:"contract_number"`
	ContractDate   *string   `json:"contract_date"`
	Contact        string    `json:"contact"`
	CreatedAt      time.Time `json:"created_at"`
}

type AdvertiserInput struct {
	Name           *string `json:"name"`
	INN            *string `json:"inn"`
	Address        *string `json:"address"`
	Bank           *string `json:"bank"`
	Account        *string `json:"account"`
	MFO            *string `json:"mfo"`
	ContractNumber *string `json:"contract_number"`
	ContractDate   *string `json:"contract_date"`
	Contact        *string `json:"contact"`
}

const advertiserSelect = `SELECT id, name, inn, address, bank, account, mfo, contract_number, to_char(contract_date, 'YYYY-MM-DD'), contact, created_at FROM ad_advertisers`

func (s *Service) Advertisers(ctx context.Context, q string, page httpx.Page) ([]Advertiser, error) {
	rows, err := s.pool.Query(ctx, advertiserSelect+` WHERE ($1 = '' OR name ILIKE '%' || $1 || '%' OR inn = $1) ORDER BY name LIMIT $2 OFFSET $3`,
		strings.TrimSpace(q), page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Advertiser])
}

func (s *Service) advertiser(ctx context.Context, q db.Querier, id string) (Advertiser, error) {
	if !httpx.IsUUID(id) {
		return Advertiser{}, apperr.NotFound("рекламодатель не найден").Uz("reklama beruvchi topilmadi")
	}
	rows, err := q.Query(ctx, advertiserSelect+` WHERE id = $1`, id)
	if err != nil {
		return Advertiser{}, err
	}
	a, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Advertiser])
	if errors.Is(err, pgx.ErrNoRows) {
		return a, apperr.NotFound("рекламодатель не найден").Uz("reklama beruvchi topilmadi")
	}
	return a, err
}

func contractDate(p *string) (*time.Time, bool, error) {
	if p == nil {
		return nil, false, nil
	}
	if *p == "" {
		return nil, true, nil
	}
	t, err := time.Parse("2006-01-02", *p)
	if err != nil {
		return nil, false, apperr.Validation("contract_date: дата YYYY-MM-DD").Uz("contract_date: sana YYYY-MM-DD koʻrinishida boʻlsin")
	}
	return &t, true, nil
}

func (s *Service) SaveAdvertiser(ctx context.Context, id string, in AdvertiserInput) (Advertiser, error) {
	if in.Name != nil && strings.TrimSpace(*in.Name) == "" {
		return Advertiser{}, apperr.Validation("name: укажите юрлицо бренда").Uz("name: brendning yuridik shaxsini kiriting")
	}
	cd, cdSet, err := contractDate(in.ContractDate)
	if err != nil {
		return Advertiser{}, err
	}
	if id == "" {
		if in.Name == nil {
			return Advertiser{}, apperr.Validation("name: укажите юрлицо бренда").Uz("name: brendning yuridik shaxsini kiriting")
		}
		str := func(p *string) string {
			if p == nil {
				return ""
			}
			return strings.TrimSpace(*p)
		}
		err = s.pool.QueryRow(ctx, `INSERT INTO ad_advertisers (name, inn, address, bank, account, mfo, contract_number, contract_date, contact)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING id`,
			str(in.Name), str(in.INN), str(in.Address), str(in.Bank), str(in.Account), str(in.MFO), str(in.ContractNumber), cd, str(in.Contact)).Scan(&id)
		if err != nil {
			return Advertiser{}, err
		}
		return s.advertiser(ctx, s.pool, id)
	}
	if _, err := s.advertiser(ctx, s.pool, id); err != nil {
		return Advertiser{}, err
	}
	if _, err := s.pool.Exec(ctx, `UPDATE ad_advertisers SET name = COALESCE($2, name), inn = COALESCE($3, inn), address = COALESCE($4, address),
		bank = COALESCE($5, bank), account = COALESCE($6, account), mfo = COALESCE($7, mfo), contract_number = COALESCE($8, contract_number),
		contract_date = CASE WHEN $9 THEN $10::date ELSE contract_date END, contact = COALESCE($11, contact) WHERE id = $1`,
		id, trim(in.Name), trim(in.INN), trim(in.Address), trim(in.Bank), trim(in.Account), trim(in.MFO), trim(in.ContractNumber),
		cdSet, cd, trim(in.Contact)); err != nil {
		return Advertiser{}, err
	}
	return s.advertiser(ctx, s.pool, id)
}
