package pos

import (
	"context"
	"errors"
	"regexp"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Данные, которые касса берёт из панели магазина: налоговые поля товара,
// короткие коды, виды оплаты, шапка чека и весовые штрихкоды.

// --------------------------------------------------- налоговые поля товара

type TaxInput struct {
	IKPU        *string       `json:"ikpu"`
	PackageCode *string       `json:"package_code"`
	VATRate     *money.Amount `json:"vat_rate"`
	Marked      *bool         `json:"marked"`
}

type ProductTax struct {
	ProductID   string `json:"product_id"`
	IKPU        string `json:"ikpu"`
	PackageCode string `json:"package_code"`
	VATRate     string `json:"vat_rate"`
	Marked      bool   `json:"marked"`
}

var ikpuRe = regexp.MustCompile(`^[0-9]{17}$`)

// SetProductTax — ИКПУ, код упаковки, НДС и маркировка. Сеть меняет свои
// товары, супер-админ — общие товары платформы (scope = admin).
func (s *Service) SetProductTax(ctx context.Context, p *identity.Principal, productID string, in TaxInput) (ProductTax, error) {
	if !httpx.IsUUID(productID) {
		return ProductTax{}, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
	}
	admin := p.App == identity.AppAdmin
	if !admin {
		if err := p.Require(identity.PermCatalogManage); err != nil {
			return ProductTax{}, err
		}
	}
	if in.IKPU != nil {
		v := strings.TrimSpace(*in.IKPU)
		if v != "" && !ikpuRe.MatchString(v) {
			return ProductTax{}, apperr.Validation("ikpu: 17 цифр из справочника tasnif.soliq.uz").Uz("ikpu: tasnif.soliq.uz maʼlumotnomasidagi 17 ta raqam")
		}
		in.IKPU = &v
	}
	if in.PackageCode != nil {
		v := strings.TrimSpace(*in.PackageCode)
		if len(v) > 20 {
			return ProductTax{}, apperr.Validation("package_code: до 20 символов").Uz("package_code: 20 belgigacha")
		}
		in.PackageCode = &v
	}
	var vat *string
	if in.VATRate != nil {
		d := money.D(string(*in.VATRate))
		if !in.VATRate.Valid() || d.Sign() < 0 || d.Cmp(money.D("100")) > 0 {
			return ProductTax{}, apperr.Validation("vat_rate: от 0 до 100").Uz("vat_rate: 0 dan 100 gacha")
		}
		v := d.Money()
		vat = &v
	}
	var out ProductTax
	err := s.pool.QueryRow(ctx, `
		UPDATE products SET ikpu = COALESCE($3, ikpu), package_code = COALESCE($4, package_code),
		       vat_rate = COALESCE($5::numeric, vat_rate), is_marked = COALESCE($6, is_marked)
		WHERE id = $1 AND (($2::uuid IS NULL AND network_id IS NULL) OR network_id = $2::uuid)
		RETURNING id, ikpu, package_code, vat_rate::text, is_marked`,
		productID, nullIf(!admin, p.NetworkID), in.IKPU, in.PackageCode, vat, in.Marked).Scan(
		&out.ProductID, &out.IKPU, &out.PackageCode, &out.VATRate, &out.Marked)
	if errors.Is(err, pgx.ErrNoRows) {
		if admin {
			return out, apperr.NotFound("товар платформы не найден").Uz("platforma mahsuloti topilmadi")
		}
		return out, apperr.NotFound("товар не найден среди товаров сети — общие товары правит Super Market").Uz("mahsulot tarmoq mahsulotlari orasida topilmadi — umumiy mahsulotlarni Super Market tahrirlaydi")
	}
	return out, err
}

func nullIf(ok bool, v string) *string {
	if !ok {
		return nil
	}
	return &v
}

// ------------------------------------------------------------------ PLU

type PLUInput struct {
	PLU *int `json:"plu"` // null — снять код
}

func (s *Service) SetPLU(ctx context.Context, p *identity.Principal, productID string, in PLUInput) (map[string]any, error) {
	if err := p.Require(identity.PermCatalogManage); err != nil {
		return nil, err
	}
	if !httpx.IsUUID(productID) {
		return nil, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
	}
	if in.PLU != nil && (*in.PLU < 1 || *in.PLU > 99999) {
		return nil, apperr.Validation("plu: от 1 до 99999").Uz("plu: 1 dan 99999 gacha")
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var ok bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM products WHERE id = $1 AND (network_id IS NULL OR network_id = $2))`,
			productID, p.NetworkID).Scan(&ok); err != nil {
			return err
		}
		if !ok {
			return apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
		}
		_, err := tx.Exec(ctx, `INSERT INTO pos_plu (network_id, product_id, plu) VALUES ($1, $2, $3)
			ON CONFLICT (network_id, product_id) DO UPDATE SET plu = EXCLUDED.plu`, p.NetworkID, productID, in.PLU)
		if db.IsUniqueViolation(err, "pos_plu_code_idx") {
			return apperr.Conflict("plu_taken", "этот код уже у другого товара").Uz("bu kod boshqa mahsulotda bor")
		}
		return err
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{"product_id": productID, "plu": in.PLU}, nil
}

// ------------------------------------------------------- вид оплаты

type KindInput struct {
	Kind string `json:"kind"`
}

func (s *Service) SetPaymentKind(ctx context.Context, p *identity.Principal, methodID string, in KindInput) (PaymentMethod, error) {
	if err := p.Require(identity.PermFinanceManage); err != nil {
		return PaymentMethod{}, err
	}
	switch in.Kind {
	case "cash", "card", "qr", "other":
	default:
		return PaymentMethod{}, apperr.Validation("kind: cash, card, qr или other").Uz("kind: cash, card, qr yoki other")
	}
	if !httpx.IsUUID(methodID) {
		return PaymentMethod{}, apperr.NotFound("способ оплаты не найден").Uz("toʻlov usuli topilmadi")
	}
	var m PaymentMethod
	err := s.pool.QueryRow(ctx, `UPDATE payment_methods SET kind = $3 WHERE id = $1 AND network_id = $2 RETURNING id, name, kind`,
		methodID, p.NetworkID, in.Kind).Scan(&m.ID, &m.Name, &m.Kind)
	if errors.Is(err, pgx.ErrNoRows) {
		return m, apperr.NotFound("способ оплаты не найден").Uz("toʻlov usuli topilmadi")
	}
	return m, err
}

// ---------------------------------------------------- настройки кассы

type NetworkSettings struct {
	WeightPrefixes []string `json:"weight_prefixes"`
	ReceiptHeader  string   `json:"receipt_header"`
	ReceiptFooter  string   `json:"receipt_footer"`
}

var prefixRe = regexp.MustCompile(`^2[0-9]$`)

func (s *Service) GetSettings(ctx context.Context, p *identity.Principal) (NetworkSettings, error) {
	var out NetworkSettings
	err := s.pool.QueryRow(ctx, `SELECT pos_weight_prefixes, receipt_header, receipt_footer FROM networks WHERE id = $1`,
		p.NetworkID).Scan(&out.WeightPrefixes, &out.ReceiptHeader, &out.ReceiptFooter)
	return out, err
}

func (s *Service) SaveSettings(ctx context.Context, p *identity.Principal, in NetworkSettings) (NetworkSettings, error) {
	if err := p.Require(identity.PermStoresManage); err != nil {
		return NetworkSettings{}, err
	}
	if len(in.WeightPrefixes) > 10 {
		return NetworkSettings{}, apperr.Validation("weight_prefixes: не больше 10").Uz("weight_prefixes: koʻpi bilan 10 ta")
	}
	for _, x := range in.WeightPrefixes {
		if err := checkScalePrefix(x); err != nil {
			return NetworkSettings{}, err
		}
	}
	if in.WeightPrefixes == nil {
		in.WeightPrefixes = []string{}
	}
	in.ReceiptHeader, in.ReceiptFooter = strings.TrimSpace(in.ReceiptHeader), strings.TrimSpace(in.ReceiptFooter)
	if len([]rune(in.ReceiptHeader)) > 500 || len([]rune(in.ReceiptFooter)) > 500 {
		return NetworkSettings{}, apperr.Validation("текст чека: до 500 символов").Uz("chek matni: 500 belgigacha")
	}
	if _, err := s.pool.Exec(ctx, `UPDATE networks SET pos_weight_prefixes = $2, receipt_header = $3, receipt_footer = $4, pos_settings_at = now() WHERE id = $1`,
		p.NetworkID, in.WeightPrefixes, in.ReceiptHeader, in.ReceiptFooter); err != nil {
		return NetworkSettings{}, err
	}
	return s.GetSettings(ctx, p)
}
