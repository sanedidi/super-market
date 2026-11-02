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
	// «Требовать пересчёт при закрытии дня»: касса не закрывает день одной
	// кнопкой — Enter ведёт в пересчёт ящика (Figma ЗД4). Расхождение и тут
	// не блокирует. Не прислали (старая панель) — не меняем.
	RequireRecount *bool `json:"require_recount"`
}

var prefixRe = regexp.MustCompile(`^2[0-9]$`)

func (s *Service) GetSettings(ctx context.Context, p *identity.Principal) (NetworkSettings, error) {
	var out NetworkSettings
	var recount bool
	err := s.pool.QueryRow(ctx, `SELECT pos_weight_prefixes, receipt_header, receipt_footer, pos_require_recount FROM networks WHERE id = $1`,
		p.NetworkID).Scan(&out.WeightPrefixes, &out.ReceiptHeader, &out.ReceiptFooter, &recount)
	out.RequireRecount = &recount
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
	if _, err := s.pool.Exec(ctx, `UPDATE networks SET pos_weight_prefixes = $2, receipt_header = $3, receipt_footer = $4,
		pos_require_recount = COALESCE($5, pos_require_recount), pos_settings_at = now() WHERE id = $1`,
		p.NetworkID, in.WeightPrefixes, in.ReceiptHeader, in.ReceiptFooter, in.RequireRecount); err != nil {
		return NetworkSettings{}, err
	}
	return s.GetSettings(ctx, p)
}

// ------------------------------------------- касса магазина: размен и пересчёт

// CashSettings — настройки кассы магазина (Figma М6). Магазин задаёт их сам,
// значений по умолчанию нет.
type CashSettings struct {
	StoreID string `json:"store_id"`
	// Норма размена: столько остаётся в ящике после «Закрыть день», остальное —
	// «К сдаче» владельцу. null — не задана: в ящике остаётся всё, как раньше.
	CashFloat *string `json:"cash_float"`
	// Пересчёт ящика при «Закрыть день»: null — не требовать, 1 — каждый
	// день, 7 — раз в 7 дней.
	RecountEveryDays *int `json:"recount_every_days"`
	// Уведомление в 21:00, если есть «К сдаче».
	HandoverRemind bool `json:"handover_remind"`
}

type CashSettingsInput struct {
	StoreID          string        `json:"store_id"`
	CashFloat        *money.Amount `json:"cash_float"`
	RecountEveryDays *int          `json:"recount_every_days"`
	// Не прислали — не меняем.
	HandoverRemind *bool `json:"handover_remind"`
}

func (s *Service) storeOf(p *identity.Principal, storeID string) error {
	if !httpx.IsUUID(storeID) || !p.CanAccessStore(storeID) {
		return apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	return nil
}

func (s *Service) GetCashSettings(ctx context.Context, p *identity.Principal, storeID string) (CashSettings, error) {
	out := CashSettings{StoreID: storeID}
	if err := p.RequireAny(identity.PermFinanceManage, identity.PermStoresManage); err != nil {
		return out, err
	}
	if err := s.storeOf(p, storeID); err != nil {
		return out, err
	}
	err := s.pool.QueryRow(ctx, `SELECT cash_float::text, recount_every_days, handover_remind FROM stores WHERE id = $1 AND network_id = $2`,
		storeID, p.NetworkID).Scan(&out.CashFloat, &out.RecountEveryDays, &out.HandoverRemind)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	return out, err
}

// SaveCashSettings — магазин задаёт норму размена и пересчёт. Касса узнаёт о
// них со следующей выгрузкой каталога.
func (s *Service) SaveCashSettings(ctx context.Context, p *identity.Principal, in CashSettingsInput) (CashSettings, error) {
	if err := p.RequireAny(identity.PermFinanceManage, identity.PermStoresManage); err != nil {
		return CashSettings{}, err
	}
	if err := s.storeOf(p, in.StoreID); err != nil {
		return CashSettings{}, err
	}
	var float *string
	if in.CashFloat != nil {
		d := money.D(string(*in.CashFloat))
		if !in.CashFloat.Valid() || d.Sign() < 0 {
			return CashSettings{}, apperr.Validation("cash_float: норма размена — сумма от нуля").Uz("cash_float: maydalik meʼyori — noldan katta summa")
		}
		v := d.Money()
		float = &v
	}
	if in.RecountEveryDays != nil && *in.RecountEveryDays != 1 && *in.RecountEveryDays != 7 {
		return CashSettings{}, apperr.Validation("recount_every_days: 1 — каждый день, 7 — раз в 7 дней, null — не требовать").Uz("recount_every_days: 1 — har kuni, 7 — 7 kunda bir marta, null — talab qilinmaydi")
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE stores SET cash_float = $3::numeric, recount_every_days = $4,
			handover_remind = COALESCE($5, handover_remind) WHERE id = $1 AND network_id = $2`,
			in.StoreID, p.NetworkID, float, in.RecountEveryDays, in.HandoverRemind)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
		}
		_, err = tx.Exec(ctx, `UPDATE networks SET pos_settings_at = now() WHERE id = $1`, p.NetworkID)
		return err
	})
	if err != nil {
		return CashSettings{}, err
	}
	return s.GetCashSettings(ctx, p, in.StoreID)
}
