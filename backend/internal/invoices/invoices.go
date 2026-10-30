// Package invoices — приход товара по фото накладной: ИИ читает накладную,
// строки сопоставляются с каталогом (штрихкод → запомненное название
// поставщика → похожее название), человек проверяет, создаётся приход.
package invoices

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/ai"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/media"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
	"github.com/sanedidi/super-market/backend/internal/push"
)

const (
	StatusProcessing = "processing"
	StatusReady      = "ready"
	StatusFailed     = "failed"
	StatusDone       = "done"

	// Похожее название ниже этого — «проверить».
	sureName = 75
	// Цена отличается от прошлого прихода больше чем на столько % — «проверить».
	priceJump = 5
)

type Service struct {
	pool  *pgxpool.Pool
	ai    *ai.Service
	media *media.Service
	inv   *inventory.Service
	log   *slog.Logger
	// run — запуск распознавания (в тестах — синхронно).
	run func(func())
}

func NewService(pool *pgxpool.Pool, aiSvc *ai.Service, mediaSvc *media.Service, inv *inventory.Service, log *slog.Logger) *Service {
	return &Service{pool: pool, ai: aiSvc, media: mediaSvc, inv: inv, log: log, run: func(f func()) { go f() }}
}

// Sync — распознавать сразу в запросе (для тестов).
func (s *Service) Sync() { s.run = func(f func()) { f() } }

type Line struct {
	Line    int    `json:"line"`
	Name    string `json:"name"`
	Barcode string `json:"barcode"`
	Unit    string `json:"unit"`
	// Количество и цена, как в накладной (в единицах накладной).
	Qty   string `json:"qty"`
	Price string `json:"price"`
	// Сумма строки, как прочитана с накладной; null — не прочитана.
	ReadSum *string `json:"read_sum"`
	// Единиц товара в единице накладной (блок по 6 → 6) и откуда это известно
	// (см. pack.go). guess — нужен ответ «блоки или штуки?».
	Pack       string `json:"pack"`
	PackSource string `json:"pack_source"`
	// На склад: qty × pack по цене cost (за единицу товара); sum = stock_qty × cost.
	StockQty    string  `json:"stock_qty"`
	Cost        string  `json:"cost"`
	Sum         string  `json:"sum"`
	ProductID   *string `json:"product_id"`
	ProductName *string `json:"product_name"`
	UnitShort   *string `json:"unit_short"`
	// Товар продаётся дробно (кг, л).
	Fractional bool `json:"fractional"`
	// barcode, alias, name, manual.
	Match      *string `json:"match"`
	Confidence int     `json:"confidence"`
	Skipped    bool    `json:"skipped"`
	// ok — готово, check — проверить, pack — блоки или штуки?, missing — не
	// найден, skipped — пропущена.
	State string `json:"state"`
	// Цена прошлого прихода этого товара и изменение, %.
	LastPrice   *string `json:"last_price"`
	PriceChange *int    `json:"price_change"`
	// Скидка поставщика (Figma С1–С3): цена без скидки за единицу накладной и
	// за единицу товара, скидка в % и в сумах; null — скидки нет.
	ListPrice   *string `json:"list_price"`
	ListCost    *string `json:"list_cost"`
	Discount    *string `json:"discount"`
	DiscountSum *string `json:"discount_sum"`
}

type Scan struct {
	ID               string    `json:"id"`
	StoreID          string    `json:"store_id"`
	Status           string    `json:"status"`
	Images           []string  `json:"images"`
	SupplierName     string    `json:"supplier_name"`
	SupplierINN      string    `json:"supplier_inn"`
	InvoiceNumber    string    `json:"invoice_number"`
	InvoiceDate      *string   `json:"invoice_date"`
	Currency         string    `json:"currency"`
	InvoiceTotal     *string   `json:"invoice_total"`
	LinesTotal       string    `json:"lines_total"`
	// Скидка поставщика по строкам и сумма строк без скидки.
	DiscountTotal string `json:"discount_total"`
	GrossTotal    string `json:"gross_total"`
	TotalMatches     *bool     `json:"total_matches"`
	CounterpartyID   *string   `json:"counterparty_id"`
	CounterpartyName *string   `json:"counterparty_name"`
	DocumentID       *string   `json:"document_id"`
	DocumentNumber   *int64    `json:"document_number"`
	DocumentStatus   *string   `json:"document_status"`
	Error            string    `json:"error"`
	DurationMs       *int      `json:"duration_ms"`
	CreatedAt        time.Time `json:"created_at"`
	Counts           Counts    `json:"counts"`
	Lines            []Line    `json:"lines"`
}

type Counts struct {
	OK      int `json:"ok"`
	Check   int `json:"check"`
	Missing int `json:"missing"`
	// Блоки или штуки? — без ответа приход не создать.
	Pack    int `json:"pack"`
	Skipped int `json:"skipped"`
}

func require(p *identity.Principal, storeID string) error {
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return err
	}
	if !httpx.IsUUID(storeID) || !p.CanAccessStore(storeID) {
		return apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	return nil
}

// ------------------------------------------------------------ создание

type CreateInput struct {
	StoreID string   `json:"store_id"`
	Images  []string `json:"images"`
}

// Create — фото загружены (/store/uploads), запускаем распознавание.
func (s *Service) Create(ctx context.Context, p *identity.Principal, in CreateInput) (Scan, error) {
	if err := require(p, in.StoreID); err != nil {
		return Scan{}, err
	}
	if len(in.Images) == 0 || len(in.Images) > 5 {
		return Scan{}, apperr.Validation("images: от 1 до 5 фото накладной").Uz("images: yuk xatining 1 dan 5 tagacha rasmi")
	}
	keys := make([]string, 0, len(in.Images))
	for _, u := range in.Images {
		k, ok := media.KeyFromURL(u)
		if !ok {
			return Scan{}, apperr.Validation("images: фото должно быть загружено через /store/uploads").Uz("images: rasm /store/uploads orqali yuklangan boʻlishi kerak")
		}
		keys = append(keys, k)
	}
	if _, err := s.ai.Conn(ctx); err != nil {
		return Scan{}, err
	}
	var id string
	err := s.pool.QueryRow(ctx, `
		INSERT INTO invoice_scans (network_id, store_id, created_by, images)
		SELECT network_id, id, $3, $4 FROM stores WHERE id = $1 AND network_id = $2
		RETURNING id`, in.StoreID, p.NetworkID, p.EmployeeID, keys).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return Scan{}, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	if err != nil {
		return Scan{}, err
	}
	s.start(id, p.NetworkID, i18n.FromContext(ctx))
	return s.Get(ctx, p, id)
}

// Retry — распознать заново (после ошибки).
func (s *Service) Retry(ctx context.Context, p *identity.Principal, id string) (Scan, error) {
	sc, err := s.Get(ctx, p, id)
	if err != nil {
		return sc, err
	}
	// Заново — после ошибки или распознанную, пока по ней нет прихода
	// (например, распознанную до того, как стали читать сумму строки).
	if sc.Status != StatusFailed && sc.Status != StatusReady {
		return sc, apperr.Conflict("scan_not_failed", "распознать заново можно, пока по накладной нет прихода").Uz("kirim yaratilmaguncha qayta tanib olish mumkin")
	}
	if _, err := s.ai.Conn(ctx); err != nil {
		return Scan{}, err
	}
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE invoice_scans SET status = 'processing', error = '' WHERE id = $1 AND status IN ('failed', 'ready') AND document_id IS NULL`, id)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.Conflict("scan_not_failed", "распознать заново можно, пока по накладной нет прихода").Uz("kirim yaratilmaguncha qayta tanib olish mumkin")
		}
		_, err = tx.Exec(ctx, `DELETE FROM invoice_scan_lines WHERE scan_id = $1`, id)
		return err
	})
	if err != nil {
		return Scan{}, err
	}
	s.start(id, p.NetworkID, i18n.FromContext(ctx))
	return s.Get(ctx, p, id)
}

// lang — язык того, кто сфотографировал накладную: на нём сохраняется текст ошибки.
func (s *Service) start(id, networkID, lang string) {
	s.run(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
		defer cancel()
		if err := s.process(ctx, id, networkID); err != nil {
			msg := "не удалось распознать накладную"
			msgUz := "yuk xatini tanib boʻlmadi"
			var se *ai.ErrService
			var ae *apperr.Error
			switch {
			case errors.As(err, &se):
				msg, msgUz = se.Msg, se.MsgUz
			case errors.As(err, &ae):
				msg, msgUz = ae.Message, ae.Text(i18n.UZ)
			default:
				s.log.Error("invoice scan", "id", id, "err", err)
			}
			if len([]rune(msg)) > 480 {
				msg = string([]rune(msg)[:480])
			}
			if _, err := s.pool.Exec(context.Background(), `UPDATE invoice_scans SET status = 'failed', error = $2 WHERE id = $1 AND status = 'processing'`, id, i18n.Pick(lang, msg, msgUz)); err != nil {
				s.log.Error("invoice scan fail", "id", id, "err", err)
			}
			if err := s.notifyAuthor(context.Background(), s.pool, id, "invoice_failed",
				i18n.Text{RU: "Не удалось распознать накладную", UZ: "Yuk xatini tanib boʻlmadi"}, i18n.Text{RU: msg, UZ: msgUz}); err != nil {
				s.log.Warn("push накладной", "err", err)
			}
		}
	})
}

func (s *Service) process(ctx context.Context, id, networkID string) error {
	var keys []string
	var storeID, employeeID string
	if err := s.pool.QueryRow(ctx, `SELECT images, store_id, created_by FROM invoice_scans WHERE id = $1`, id).Scan(&keys, &storeID, &employeeID); err != nil {
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
			return apperr.Validation("фото накладной не найдено в хранилище").Uz("yuk xati rasmi serverda topilmadi")
		}
		images = append(images, ai.Image{MIME: mime, Data: data})
	}
	start := time.Now()
	inv, usage, err := conn.ReadInvoice(ctx, images)
	// Расход ИИ — и при ошибке: токены уже потрачены.
	if usage.Input+usage.Output > 0 || err == nil {
		rec := ai.UsageRecord{Kind: "invoice", NetworkID: &networkID, StoreID: &storeID, EmployeeID: &employeeID, ScanID: &id,
			Provider: conn.Provider, Model: conn.Model, Usage: usage, OK: err == nil}
		if rerr := s.ai.Record(context.WithoutCancel(ctx), rec); rerr != nil {
			s.log.Error("ai usage", "scan", id, "err", rerr)
		}
	}
	if err != nil {
		return err
	}
	ms := int(time.Since(start).Milliseconds())
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var date *string
		if _, err := time.Parse("2006-01-02", inv.Date); err == nil {
			date = &inv.Date
		}
		var total *string
		if inv.Total != nil && *inv.Total >= 0 && *inv.Total < 1e15 {
			t := strconv.FormatFloat(math.Round(*inv.Total*100)/100, 'f', 2, 64)
			total = &t
		}
		cp := matchCounterparty(ctx, tx, networkID, inv.SupplierName, inv.SupplierINN)
		_, err := tx.Exec(ctx, `
			UPDATE invoice_scans SET status = 'ready', supplier_name = $2, supplier_inn = $3, invoice_number = $4,
			       invoice_date = $5, currency = $6, invoice_total = $7, counterparty_id = $8, error = '',
			       provider = $9, model = $10, duration_ms = $11
			WHERE id = $1`, id, inv.SupplierName, inv.SupplierINN, inv.Number, date, inv.Currency, total, cp, conn.Provider, conn.Model, ms)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM invoice_scan_lines WHERE scan_id = $1`, id); err != nil {
			return err
		}
		supplier, supplierUz := inv.SupplierName, inv.SupplierName
		if supplier == "" {
			supplier, supplierUz = "Накладная", "Yuk xati"
		}
		if err := s.notifyAuthor(ctx, tx, id, "invoice_ready", i18n.Text{RU: "Накладная распознана", UZ: "Yuk xati tanib olindi"}, i18n.Text{
			RU: fmt.Sprintf("%s: строк %d — проверьте и проведите приход", supplier, len(inv.Lines)),
			UZ: fmt.Sprintf("%s: %d ta qator — tekshiring va kirimni oʻtkazing", supplierUz, len(inv.Lines)),
		}); err != nil {
			return err
		}
		for i, l := range inv.Lines {
			m := matchLine(ctx, tx, networkID, cp, l.Name, l.Barcode)
			_, err := tx.Exec(ctx, `
				INSERT INTO invoice_scan_lines (scan_id, line, name, barcode, unit, qty, price, read_sum, product_id, match, confidence, list_price)
				VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)`,
				id, i+1, l.Name, l.Barcode, l.Unit, fmtNum(l.Qty, 3), fmtNum(l.Price, 4), readSum(l), m.productID, m.match, m.confidence, listPrice(l))
			if err != nil {
				return err
			}
			if err := repack(ctx, tx, networkID, id, i+1); err != nil {
				return err
			}
		}
		return nil
	})
}

// notifyAuthor — push тому, кто сфотографировал накладную.
func (s *Service) notifyAuthor(ctx context.Context, q db.Querier, id, kind string, title, body i18n.Text) error {
	var emp string
	if err := q.QueryRow(ctx, `SELECT created_by FROM invoice_scans WHERE id = $1`, id).Scan(&emp); err != nil {
		return err
	}
	return push.EnqueueEmployee(ctx, q, emp, kind, title, body, map[string]string{"type": "invoice", "scan_id": id})
}

// listPrice — цена без скидки, если у строки есть скидка поставщика; иначе null.
func listPrice(l ai.InvoiceLine) *string {
	if l.Discount <= 0 || l.ListPrice <= l.Price || l.ListPrice >= 1e15 {
		return nil
	}
	v := fmtNum(l.ListPrice, 4)
	return &v
}

// readSum — сумма строки из накладной; не прочитана — null.
func readSum(l ai.InvoiceLine) *string {
	if l.Sum <= 0 || l.Sum >= 1e15 {
		return nil
	}
	v := fmtNum(l.Sum, 2)
	return &v
}

func fmtNum(v float64, prec int) string {
	p := math.Pow10(prec)
	return strconv.FormatFloat(math.Round(v*p)/p, 'f', -1, 64)
}

// ------------------------------------------------------------ сопоставление

type match struct {
	productID  *string
	match      *string
	confidence int
}

func strp(s string) *string { return &s }

// NormAlias — название строки для запоминания: регистр, ё, пробелы и знаки не важны.
func NormAlias(s string) string {
	s = strings.ReplaceAll(strings.ToLower(s), "ё", "е")
	var b strings.Builder
	for _, r := range s {
		switch {
		case unicode.IsLetter(r) || unicode.IsDigit(r):
			b.WriteRune(r)
		case r == ',' || r == '.':
			b.WriteRune('.')
		default:
			b.WriteRune(' ')
		}
	}
	out := strings.Join(strings.Fields(b.String()), " ")
	if r := []rune(out); len(r) > 300 {
		out = string(r[:300])
	}
	return out
}

const visible = `(p.network_id IS NULL OR p.network_id = $1) AND p.is_active`

func matchLine(ctx context.Context, q db.Querier, networkID string, counterpartyID *string, name, barcode string) match {
	var id string
	if barcode != "" {
		err := q.QueryRow(ctx, `SELECT p.id FROM product_barcodes pb JOIN products p ON p.id = pb.product_id
			WHERE `+visible+` AND pb.barcode = $2 LIMIT 1`, networkID, barcode).Scan(&id)
		if err == nil {
			return match{productID: &id, match: strp("barcode"), confidence: 100}
		}
	}
	alias := NormAlias(name)
	if counterpartyID != nil && alias != "" {
		err := q.QueryRow(ctx, `SELECT a.product_id FROM supplier_product_aliases a JOIN products p ON p.id = a.product_id
			WHERE `+visible+` AND a.counterparty_id = $2 AND a.alias = $3 AND a.network_id = $1`, networkID, *counterpartyID, alias).Scan(&id)
		if err == nil {
			return match{productID: &id, match: strp("alias"), confidence: 100}
		}
	}
	// Похожее название — русское или узбекское. Вес или объём в названии
	// должен совпасть: «Lay's сметана 48*20гр» — не пачка 225 г.
	rows, err := q.Query(ctx, `SELECT p.id, p.name, p.name_uz, greatest(similarity(lower(p.name), $2), similarity(lower(p.name_uz), $2)) AS s FROM products p
		WHERE `+visible+` AND (lower(p.name) % $2 OR lower(p.name_uz) % $2) ORDER BY s DESC, p.name LIMIT 10`, networkID, strings.ToLower(name))
	if err != nil {
		return match{}
	}
	defer rows.Close()
	want, hasSize := SizeOf(name)
	for rows.Next() {
		var pn, pnUz string
		var sim float64
		if rows.Scan(&id, &pn, &pnUz, &sim) != nil {
			return match{}
		}
		if hasSize {
			got, ok := SizeOf(pn)
			if !ok {
				got, ok = SizeOf(pnUz)
			}
			if ok && !sameSize(want, got) {
				continue
			}
		}
		return match{productID: &id, match: strp("name"), confidence: int(math.Round(sim * 100))}
	}
	return match{}
}

// Size — вес или объём из названия в граммах или миллилитрах.
type Size struct {
	V    float64
	Kind byte // 'g' — вес, 'l' — объём
}

var sizeRe = regexp.MustCompile(`(\d+(?:[.,]\d+)?)\s*(кг|kg|гр|gr|г|g|мл|ml|л|l)(?:[^\p{L}]|$)`)

// SizeOf — последний вес/объём в названии: «Lay's 48*20гр» → 20 г, «Кола 1,5 л» → 1500 мл.
func SizeOf(name string) (Size, bool) {
	m := sizeRe.FindAllStringSubmatch(strings.ToLower(name), -1)
	if len(m) == 0 {
		return Size{}, false
	}
	last := m[len(m)-1]
	v, err := strconv.ParseFloat(strings.ReplaceAll(last[1], ",", "."), 64)
	if err != nil || v <= 0 {
		return Size{}, false
	}
	switch last[2] {
	case "кг", "kg":
		return Size{v * 1000, 'g'}, true
	case "гр", "gr", "г", "g":
		return Size{v, 'g'}, true
	case "л", "l":
		return Size{v * 1000, 'l'}, true
	}
	return Size{v, 'l'}, true
}

func sameSize(a, b Size) bool {
	if a.Kind != b.Kind {
		return true // вес против объёма — не сравниваем
	}
	return math.Abs(a.V-b.V) <= math.Max(a.V, b.V)*0.02
}

func matchCounterparty(ctx context.Context, q db.Querier, networkID, name, inn string) *string {
	var id string
	if inn != "" {
		if q.QueryRow(ctx, `SELECT id FROM counterparties WHERE network_id = $1 AND is_active AND regexp_replace(inn, '\D', '', 'g') = $2 LIMIT 1`, networkID, inn).Scan(&id) == nil {
			return &id
		}
	}
	n := strings.ToLower(supplierCore(name))
	if n == "" {
		return nil
	}
	if q.QueryRow(ctx, `SELECT id FROM counterparties WHERE network_id = $1 AND is_active AND similarity(lower(name), $2) >= 0.5
		ORDER BY similarity(lower(name), $2) DESC LIMIT 1`, networkID, n).Scan(&id) == nil {
		return &id
	}
	return nil
}

// supplierCore — «ООО «Тест Савдо»» → «Тест Савдо».
func supplierCore(s string) string {
	s = strings.NewReplacer("«", " ", "»", " ", "\"", " ", "'", " ").Replace(s)
	var out []string
	for _, w := range strings.Fields(s) {
		switch strings.ToUpper(strings.Trim(w, ".,")) {
		case "ООО", "OOO", "МЧЖ", "MCHJ", "ИП", "ЧП", "XK", "ХК", "АО", "AJ", "LLC", "QK":
			continue
		}
		out = append(out, w)
	}
	return strings.Join(out, " ")
}

// ------------------------------------------------------------ чтение

const scanCols = `s.id, s.store_id, s.status, s.images, s.supplier_name, s.supplier_inn, s.invoice_number,
	to_char(s.invoice_date, 'YYYY-MM-DD'), s.currency, s.invoice_total::text, s.counterparty_id, c.name,
	s.document_id, d.number, d.status, s.error, s.duration_ms, s.created_at`

const scanFrom = ` FROM invoice_scans s
	LEFT JOIN counterparties c ON c.id = s.counterparty_id
	LEFT JOIN stock_documents d ON d.id = s.document_id`

func scanRow(row pgx.Row, sc *Scan) error {
	return row.Scan(&sc.ID, &sc.StoreID, &sc.Status, &sc.Images, &sc.SupplierName, &sc.SupplierINN, &sc.InvoiceNumber,
		&sc.InvoiceDate, &sc.Currency, &sc.InvoiceTotal, &sc.CounterpartyID, &sc.CounterpartyName,
		&sc.DocumentID, &sc.DocumentNumber, &sc.DocumentStatus, &sc.Error, &sc.DurationMs, &sc.CreatedAt)
}

func (s *Service) Get(ctx context.Context, p *identity.Principal, id string) (Scan, error) {
	if !httpx.IsUUID(id) {
		return Scan{}, apperr.NotFound("накладная не найдена").Uz("yuk xati topilmadi")
	}
	var sc Scan
	err := scanRow(s.pool.QueryRow(ctx, `SELECT `+scanCols+scanFrom+` WHERE s.id = $1 AND s.network_id = $2`, id, p.NetworkID), &sc)
	if errors.Is(err, pgx.ErrNoRows) {
		return sc, apperr.NotFound("накладная не найдена").Uz("yuk xati topilmadi")
	}
	if err != nil {
		return sc, err
	}
	if err := require(p, sc.StoreID); err != nil {
		return Scan{}, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT l.line, l.name, l.barcode, l.unit, l.qty::text, l.price::text, l.read_sum::text, l.pack::text, l.pack_source,
		       round(l.qty * l.pack, 3)::text, round(coalesce(l.cost, l.price / l.pack), 2)::text,
		       round(l.qty * l.pack * round(coalesce(l.cost, l.price / l.pack), 2), 2)::text,
		       l.product_id, loc(p.name, p.name_uz), loc(u.short_name, u.short_name_uz), coalesce(u.is_fractional, false), l.match, l.confidence, l.skipped,
		       (SELECT i.price::text FROM stock_document_items i JOIN stock_documents d ON d.id = i.document_id
		         WHERE d.network_id = $2 AND d.type = 'income' AND d.status = 'posted' AND i.product_id = l.product_id
		           AND i.price IS NOT NULL AND d.currency = $3
		         ORDER BY d.posted_at DESC LIMIT 1),
		       l.list_price::text,
		       -- Без скидки за единицу товара: цена закупки × (без скидки / со скидкой).
		       (CASE WHEN l.price > 0 THEN round(coalesce(l.cost, l.price / l.pack) * l.list_price / l.price, 2)
		             ELSE round(l.list_price / l.pack, 2) END)::text
		FROM invoice_scan_lines l
		LEFT JOIN products p ON p.id = l.product_id
		LEFT JOIN units u ON u.id = p.unit_id
		WHERE l.scan_id = $1 ORDER BY l.line`, id, p.NetworkID, sc.Currency)
	if err != nil {
		return sc, err
	}
	sc.Lines, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (Line, error) {
		var l Line
		err := r.Scan(&l.Line, &l.Name, &l.Barcode, &l.Unit, &l.Qty, &l.Price, &l.ReadSum, &l.Pack, &l.PackSource,
			&l.StockQty, &l.Cost, &l.Sum, &l.ProductID, &l.ProductName, &l.UnitShort, &l.Fractional,
			&l.Match, &l.Confidence, &l.Skipped, &l.LastPrice, &l.ListPrice, &l.ListCost)
		return l, err
	})
	if err != nil {
		return sc, err
	}
	var total, discount float64
	for i := range sc.Lines {
		l := &sc.Lines[i]
		l.State = lineState(l)
		if d, ok := lineDiscount(l); ok && !l.Skipped {
			discount += d
		}
		switch l.State {
		case "ok":
			sc.Counts.OK++
		case "check":
			sc.Counts.Check++
		case "missing":
			sc.Counts.Missing++
		case "pack":
			sc.Counts.Pack++
		default:
			sc.Counts.Skipped++
		}
		if !l.Skipped {
			v, _ := strconv.ParseFloat(l.Sum, 64)
			total += v
		}
	}
	sc.LinesTotal = strconv.FormatFloat(math.Round(total*100)/100, 'f', 2, 64)
	sc.DiscountTotal = strconv.FormatFloat(math.Round(discount*100)/100, 'f', 2, 64)
	sc.GrossTotal = strconv.FormatFloat(math.Round((total+discount)*100)/100, 'f', 2, 64)
	if sc.InvoiceTotal != nil {
		t, _ := strconv.ParseFloat(*sc.InvoiceTotal, 64)
		ok := math.Abs(t-total) < 1
		sc.TotalMatches = &ok
	}
	if sc.Lines == nil {
		sc.Lines = []Line{}
	}
	return sc, nil
}

// lineDiscount — скидка строки в % и в сумах (заполняет Discount, DiscountSum);
// вернёт сумму скидки.
func lineDiscount(l *Line) (float64, bool) {
	if l.ListPrice == nil {
		return 0, false
	}
	list, _ := strconv.ParseFloat(*l.ListPrice, 64)
	price, _ := strconv.ParseFloat(l.Price, 64)
	stock, _ := strconv.ParseFloat(l.StockQty, 64)
	sum, _ := strconv.ParseFloat(l.Sum, 64)
	listCost := 0.0
	if l.ListCost != nil {
		listCost, _ = strconv.ParseFloat(*l.ListCost, 64)
	}
	if list <= 0 || list <= price {
		l.ListPrice, l.ListCost = nil, nil
		return 0, false
	}
	pct := strconv.FormatFloat(math.Round((1-price/list)*10000)/100, 'f', -1, 64)
	d := math.Round((stock*listCost-sum)*100) / 100
	if d < 0 {
		d = 0
	}
	ds := strconv.FormatFloat(d, 'f', 2, 64)
	l.Discount, l.DiscountSum = &pct, &ds
	return d, true
}

func lineState(l *Line) string {
	if l.Skipped {
		return "skipped"
	}
	if l.ProductID == nil {
		return "missing"
	}
	if l.LastPrice != nil {
		last, _ := strconv.ParseFloat(*l.LastPrice, 64)
		cur, _ := strconv.ParseFloat(l.Cost, 64)
		if last > 0 {
			ch := int(math.Round((cur - last) / last * 100))
			if ch != 0 {
				l.PriceChange = &ch
			}
		}
	}
	if l.PackSource == PackGuess {
		return "pack"
	}
	m := ""
	if l.Match != nil {
		m = *l.Match
	}
	if m == "manual" {
		return "ok"
	}
	if l.PriceChange != nil && (*l.PriceChange > priceJump || *l.PriceChange < -priceJump) {
		return "check"
	}
	if m == "name" && l.Confidence < sureName {
		return "check"
	}
	return "ok"
}

// List — последние накладные магазина (без строк).
func (s *Service) List(ctx context.Context, p *identity.Principal, storeID string, page httpx.Page) ([]Scan, error) {
	if err := require(p, storeID); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `SELECT `+scanCols+scanFrom+`
		WHERE s.store_id = $1 AND s.network_id = $2 ORDER BY s.created_at DESC LIMIT $3 OFFSET $4`,
		storeID, p.NetworkID, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Scan, error) {
		var sc Scan
		err := scanRow(r, &sc)
		sc.Lines = []Line{}
		return sc, err
	})
}

// ------------------------------------------------------------ правка

// editable — накладную ещё можно править (распознана, прихода нет).
func (s *Service) editable(ctx context.Context, tx pgx.Tx, p *identity.Principal, id string) (storeID string, cp *string, err error) {
	if !httpx.IsUUID(id) {
		return "", nil, apperr.NotFound("накладная не найдена").Uz("yuk xati topilmadi")
	}
	var status string
	err = tx.QueryRow(ctx, `SELECT store_id, status, counterparty_id FROM invoice_scans WHERE id = $1 AND network_id = $2 FOR UPDATE`,
		id, p.NetworkID).Scan(&storeID, &status, &cp)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil, apperr.NotFound("накладная не найдена").Uz("yuk xati topilmadi")
	}
	if err != nil {
		return "", nil, err
	}
	if err := require(p, storeID); err != nil {
		return "", nil, err
	}
	if status != StatusReady {
		return "", nil, apperr.Conflict("scan_not_ready", "накладная ещё распознаётся или приход уже создан").Uz("yuk xati hali tanib olinmoqda yoki kirim allaqachon yaratilgan")
	}
	return storeID, cp, nil
}

type SupplierInput struct {
	// Существующий контрагент или create: true — завести из распознанного поставщика.
	CounterpartyID *string `json:"counterparty_id"`
	Create         bool    `json:"create"`
}

// SetSupplier — выбрать поставщика; строки без ручного выбора сопоставляются заново
// (у поставщика могут быть запомненные названия).
func (s *Service) SetSupplier(ctx context.Context, p *identity.Principal, id string, in SupplierInput) (Scan, error) {
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, _, err := s.editable(ctx, tx, p, id); err != nil {
			return err
		}
		var cp string
		switch {
		case in.Create:
			var name, inn string
			if err := tx.QueryRow(ctx, `SELECT supplier_name, supplier_inn FROM invoice_scans WHERE id = $1`, id).Scan(&name, &inn); err != nil {
				return err
			}
			if strings.TrimSpace(name) == "" {
				return apperr.Validation("поставщик не распознан — выберите его из списка").Uz("yetkazib beruvchi aniqlanmadi — uni roʻyxatdan tanlang")
			}
			if err := tx.QueryRow(ctx, `INSERT INTO counterparties (network_id, name, inn) VALUES ($1, $2, $3) RETURNING id`,
				p.NetworkID, name, inn).Scan(&cp); err != nil {
				return err
			}
		case in.CounterpartyID != nil && httpx.IsUUID(*in.CounterpartyID):
			err := tx.QueryRow(ctx, `SELECT id FROM counterparties WHERE id = $1 AND network_id = $2 AND is_active`, *in.CounterpartyID, p.NetworkID).Scan(&cp)
			if errors.Is(err, pgx.ErrNoRows) {
				return apperr.Validation("counterparty_id: поставщик не найден").Uz("counterparty_id: yetkazib beruvchi topilmadi")
			}
			if err != nil {
				return err
			}
		default:
			return apperr.Validation("counterparty_id: выберите поставщика").Uz("counterparty_id: yetkazib beruvchini tanlang")
		}
		if _, err := tx.Exec(ctx, `UPDATE invoice_scans SET counterparty_id = $2 WHERE id = $1`, id, cp); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT line, name, barcode FROM invoice_scan_lines WHERE scan_id = $1 AND (match IS NULL OR match = 'name')`, id)
		if err != nil {
			return err
		}
		type l struct {
			n             int
			name, barcode string
		}
		ls, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (l, error) {
			var x l
			return x, r.Scan(&x.n, &x.name, &x.barcode)
		})
		if err != nil {
			return err
		}
		for _, x := range ls {
			m := matchLine(ctx, tx, p.NetworkID, &cp, x.name, x.barcode)
			if _, err := tx.Exec(ctx, `UPDATE invoice_scan_lines SET product_id = $3, match = $4, confidence = $5 WHERE scan_id = $1 AND line = $2`,
				id, x.n, m.productID, m.match, m.confidence); err != nil {
				return err
			}
		}
		// У поставщика может быть запомнена упаковка.
		return repackAll(ctx, tx, p.NetworkID, id)
	})
	if err != nil {
		return Scan{}, err
	}
	return s.Get(ctx, p, id)
}

type LineInput struct {
	ProductID *string `json:"product_id"`
	// Количество и цена в единицах накладной.
	Qty   *money.Qty   `json:"qty"`
	Price *money.Price `json:"price"`
	// Единиц товара в единице накладной (блок по 6 → 6; 1 — как у товара).
	Pack *money.Qty `json:"pack"`
	// Цена закупки за единицу товара; без неё — сумма строки / (qty × pack).
	Cost *money.Price `json:"cost"`
	// Цена без скидки за единицу накладной (С2); "" или 0 — скидки нет.
	ListPrice *money.Price `json:"list_price"`
	Skip      *bool        `json:"skip"`
	// Запомнить название строки (и упаковку) для этого поставщика.
	Remember bool `json:"remember"`
}

// SetLine — человек выбрал товар, поправил количество, упаковку или цену,
// пропустил строку.
func (s *Service) SetLine(ctx context.Context, p *identity.Principal, id string, line int, in LineInput) (Scan, error) {
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		_, cp, err := s.editable(ctx, tx, p, id)
		if err != nil {
			return err
		}
		var name string
		var productID *string
		err = tx.QueryRow(ctx, `SELECT name, product_id FROM invoice_scan_lines WHERE scan_id = $1 AND line = $2 FOR UPDATE`, id, line).Scan(&name, &productID)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.NotFound("строка не найдена").Uz("qator topilmadi")
		}
		if err != nil {
			return err
		}
		exec := func(sql string, args ...any) error {
			_, err := tx.Exec(ctx, sql, append([]any{id, line}, args...)...)
			return err
		}
		changed := false
		if in.ProductID != nil {
			var pid string
			err := tx.QueryRow(ctx, `SELECT p.id FROM products p WHERE p.id::text = $2 AND `+visible, p.NetworkID, *in.ProductID).Scan(&pid)
			if errors.Is(err, pgx.ErrNoRows) {
				return apperr.Validation("product_id: товар не найден").Uz("product_id: mahsulot topilmadi")
			}
			if err != nil {
				return err
			}
			changed = productID == nil || *productID != pid
			productID = &pid
			if err := exec(`UPDATE invoice_scan_lines SET product_id = $3, match = 'manual', confidence = 100, skipped = false
				WHERE scan_id = $1 AND line = $2`, pid); err != nil {
				return err
			}
		}
		if in.Qty != nil {
			if !in.Qty.Valid() {
				return apperr.Validation("qty: неверное количество").Uz("qty: miqdor notoʻgʻri")
			}
			if err := exec(`UPDATE invoice_scan_lines SET qty = $3 WHERE scan_id = $1 AND line = $2`, string(*in.Qty)); err != nil {
				return err
			}
		}
		if in.Price != nil {
			if !in.Price.Valid() {
				return apperr.Validation("price: неверная цена").Uz("price: narx notoʻgʻri")
			}
			// Цена за единицу накладной: цена за единицу товара — price / pack.
			if err := exec(`UPDATE invoice_scan_lines SET price = $3, cost = round($3::numeric / pack, 4) WHERE scan_id = $1 AND line = $2`, string(*in.Price)); err != nil {
				return err
			}
		}
		// Другой товар — упаковка и цена определяются заново (если их не прислали).
		if changed && in.Pack == nil {
			if err := repack(ctx, tx, p.NetworkID, id, line); err != nil {
				return err
			}
		}
		if in.Pack != nil {
			n, err := strconv.ParseFloat(string(*in.Pack), 64)
			if !in.Pack.Valid() || err != nil || n <= 0 || n > 1000 {
				return apperr.Validation("pack: от 1 до 1000").Uz("pack: 1 dan 1000 gacha")
			}
			if err := exec(`UPDATE invoice_scan_lines SET pack = $3, pack_source = 'manual' WHERE scan_id = $1 AND line = $2`, string(*in.Pack)); err != nil {
				return err
			}
			if in.Cost == nil {
				if err := exec(`UPDATE invoice_scan_lines SET cost = round(coalesce(read_sum, qty * price) / nullif(qty * pack, 0), 2)
					WHERE scan_id = $1 AND line = $2`); err != nil {
					return err
				}
			}
		}
		if in.Cost != nil {
			if !in.Cost.Valid() {
				return apperr.Validation("cost: неверная цена").Uz("cost: narx notoʻgʻri")
			}
			if err := exec(`UPDATE invoice_scan_lines SET cost = $3 WHERE scan_id = $1 AND line = $2`, string(*in.Cost)); err != nil {
				return err
			}
		}
		if in.ListPrice != nil {
			var v *string
			if s := strings.TrimSpace(string(*in.ListPrice)); s != "" && s != "0" {
				if !in.ListPrice.Valid() {
					return apperr.Validation("list_price: неверная цена без скидки").Uz("list_price: chegirmasiz narx notoʻgʻri")
				}
				v = &s
			}
			if err := exec(`UPDATE invoice_scan_lines SET list_price = $3 WHERE scan_id = $1 AND line = $2`, v); err != nil {
				return err
			}
		}
		if in.Skip != nil {
			if err := exec(`UPDATE invoice_scan_lines SET skipped = $3 WHERE scan_id = $1 AND line = $2`, *in.Skip); err != nil {
				return err
			}
		}
		if in.Remember && productID != nil {
			if cp == nil {
				return apperr.Validation("remember: сначала выберите поставщика").Uz("remember: avval yetkazib beruvchini tanlang")
			}
			if err := remember(ctx, tx, p.NetworkID, *cp, id, line, name, *productID, in.Pack != nil); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return Scan{}, err
	}
	return s.Get(ctx, p, id)
}

// remember — название строки поставщика → товар (и упаковка: «Кола 1.5 ПЭТ» =
// блок по 6). Если блок выбрал человек — это и размер блока товара в сети.
func remember(ctx context.Context, tx pgx.Tx, networkID, cp, scanID string, line int, name, productID string, packSet bool) error {
	var pack float64
	var src string
	var fractional bool
	if err := tx.QueryRow(ctx, `SELECT l.pack::float8, l.pack_source, u.is_fractional FROM invoice_scan_lines l
		JOIN products p ON p.id = $3 JOIN units u ON u.id = p.unit_id WHERE l.scan_id = $1 AND l.line = $2`, scanID, line, productID).
		Scan(&pack, &src, &fractional); err != nil {
		return err
	}
	// Упаковку запоминаем, только когда она известна (не догадка).
	var aliasPack *string
	if src != PackGuess {
		v := fmtNum(pack, 3)
		aliasPack = &v
	}
	if alias := NormAlias(name); alias != "" {
		if _, err := tx.Exec(ctx, `
			INSERT INTO supplier_product_aliases (network_id, counterparty_id, alias, product_id, pack) VALUES ($1, $2, $3, $4, $5)
			ON CONFLICT (network_id, counterparty_id, alias) DO UPDATE SET product_id = EXCLUDED.product_id, pack = EXCLUDED.pack, created_at = now()`,
			networkID, cp, alias, productID, aliasPack); err != nil {
			return err
		}
	}
	if packSet && !fractional && pack >= 2 && pack == math.Trunc(pack) {
		if _, err := tx.Exec(ctx, `
			INSERT INTO network_product_packs (network_id, product_id, pack) VALUES ($1, $2, $3)
			ON CONFLICT (network_id, product_id) DO UPDATE SET pack = EXCLUDED.pack, updated_at = now()`,
			networkID, productID, int(pack)); err != nil {
			return err
		}
	}
	return nil
}

// repackAll — упаковка всех строк, кроме выбранной человеком.
func repackAll(ctx context.Context, tx pgx.Tx, networkID, scanID string) error {
	rows, err := tx.Query(ctx, `SELECT line FROM invoice_scan_lines WHERE scan_id = $1 AND pack_source <> 'manual' ORDER BY line`, scanID)
	if err != nil {
		return err
	}
	lines, err := pgx.CollectRows(rows, pgx.RowTo[int])
	if err != nil {
		return err
	}
	for _, n := range lines {
		if err := repack(ctx, tx, networkID, scanID, n); err != nil {
			return err
		}
	}
	return nil
}

type Suggestion struct {
	ProductID string  `json:"product_id"`
	Name      string  `json:"name"`
	Barcode   *string `json:"barcode"`
	UnitShort string  `json:"unit_short"`
	Score     int     `json:"score"`
	// Продаётся дробно (кг, л).
	Fractional bool `json:"fractional"`
}

// Suggest — похожие товары для строки (или по строке поиска q).
func (s *Service) Suggest(ctx context.Context, p *identity.Principal, id string, line int, q string) ([]Suggestion, error) {
	sc, err := s.Get(ctx, p, id)
	if err != nil {
		return nil, err
	}
	term := strings.ToLower(strings.TrimSpace(q))
	if term == "" {
		for _, l := range sc.Lines {
			if l.Line == line {
				term = strings.ToLower(l.Name)
			}
		}
	}
	if term == "" {
		return []Suggestion{}, nil
	}
	rows, err := s.pool.Query(ctx, `
		SELECT p.id, loc(p.name, p.name_uz), (SELECT min(pb.barcode) FROM product_barcodes pb WHERE pb.product_id = p.id),
		       loc(u.short_name, u.short_name_uz),
		       round(greatest(similarity(lower(p.name), $2), word_similarity($2, lower(p.name)),
		                      similarity(lower(p.name_uz), $2), word_similarity($2, lower(p.name_uz))) * 100)::int AS s,
		       u.is_fractional
		FROM products p JOIN units u ON u.id = p.unit_id
		WHERE `+visible+` AND (lower(p.name) % $2 OR $2 <% lower(p.name) OR lower(p.name) LIKE '%' || $2 || '%'
		      OR lower(p.name_uz) % $2 OR $2 <% lower(p.name_uz) OR lower(p.name_uz) LIKE '%' || $2 || '%'
		      OR EXISTS (SELECT 1 FROM product_barcodes pb WHERE pb.product_id = p.id AND pb.barcode = $2))
		ORDER BY s DESC, p.name LIMIT 8`, p.NetworkID, term)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Suggestion])
}

// ------------------------------------------------------------ приход

type DocumentInput struct {
	// Склад; по умолчанию — основной склад магазина.
	WarehouseID *string `json:"warehouse_id"`
	// Сразу провести.
	Post bool `json:"post"`
}

// CreateDocument — приход из накладной: черновик или сразу проведённый.
func (s *Service) CreateDocument(ctx context.Context, p *identity.Principal, id string, in DocumentInput) (Scan, error) {
	sc, err := s.Get(ctx, p, id)
	if err != nil {
		return sc, err
	}
	switch {
	case sc.Status != StatusReady:
		return sc, apperr.Conflict("scan_not_ready", "накладная ещё распознаётся или приход уже создан").Uz("yuk xati hali tanib olinmoqda yoki kirim allaqachon yaratilgan")
	case sc.CounterpartyID == nil:
		return sc, apperr.Validation("counterparty_id: выберите поставщика").Uz("counterparty_id: yetkazib beruvchini tanlang")
	case sc.Counts.Missing > 0:
		return sc, apperr.Conflict("lines_unmatched", fmt.Sprintf("не сопоставлено строк: %d — выберите товар или пропустите строку", sc.Counts.Missing)).Uz(fmt.Sprintf("mos kelmagan qatorlar: %d — mahsulotni tanlang yoki qatorni oʻtkazib yuboring", sc.Counts.Missing))
	case sc.Counts.Pack > 0:
		return sc, apperr.Conflict("lines_pack", fmt.Sprintf("блоки или штуки? — ответьте в строках: %d", sc.Counts.Pack)).Uz(fmt.Sprintf("bloklarmi yoki donami? — qatorlarda javob bering: %d", sc.Counts.Pack))
	}
	wh := in.WarehouseID
	if wh == nil {
		var def *string
		if err := s.pool.QueryRow(ctx, `SELECT default_warehouse_id FROM stores WHERE id = $1`, sc.StoreID).Scan(&def); err != nil {
			return sc, err
		}
		if def == nil {
			return sc, apperr.Validation("warehouse_id: у магазина нет основного склада").Uz("warehouse_id: doʻkonda asosiy ombor yoʻq")
		}
		wh = def
	}
	var items []inventory.ItemInput
	for _, l := range sc.Lines {
		if l.Skipped || l.ProductID == nil {
			continue
		}
		// На склад — в единицах товара: qty × pack по цене за единицу.
		price := money.Price(trimZeros(l.Cost))
		it := inventory.ItemInput{ProductID: *l.ProductID, Qty: money.Qty(trimZeros(l.StockQty)), Price: &price}
		// Скидка поставщика: цена без скидки — за единицу товара.
		if l.ListCost != nil {
			lc := money.Price(trimZeros(*l.ListCost))
			it.ListPrice = &lc
		}
		items = append(items, it)
	}
	if len(items) == 0 {
		return sc, apperr.Validation("в накладной нет строк для прихода").Uz("yuk xatida kirim uchun qator yoʻq")
	}
	// Одна накладная — один приход: занимаем её, пока создаём документ.
	tag, err := s.pool.Exec(ctx, `UPDATE invoice_scans SET status = 'done' WHERE id = $1 AND status = 'ready'`, id)
	if err != nil {
		return sc, err
	}
	if tag.RowsAffected() == 0 {
		return sc, apperr.Conflict("scan_not_ready", "приход по этой накладной уже создаётся").Uz("bu yuk xati boʻyicha kirim allaqachon yaratilmoqda")
	}
	note := "По фото накладной"
	if sc.InvoiceNumber != "" {
		note += " № " + sc.InvoiceNumber
	}
	if sc.InvoiceDate != nil {
		if d, err := time.Parse("2006-01-02", *sc.InvoiceDate); err == nil {
			note += " от " + d.Format("02.01.2006")
		}
	}
	cur := sc.Currency
	doc, err := s.inv.Create(ctx, p, inventory.Input{
		Type: inventory.TypeIncome, WarehouseID: wh, CounterpartyID: sc.CounterpartyID, Currency: &cur, Note: &note, Items: &items,
	})
	if err == nil && in.Post {
		if _, perr := s.inv.Post(ctx, p, doc.ID); perr != nil {
			// Черновик остаётся привязан к накладной — его можно провести в разделе «Приход».
			_, _ = s.pool.Exec(ctx, `UPDATE invoice_scans SET document_id = $2 WHERE id = $1`, id, doc.ID)
			return sc, perr
		}
	}
	if err != nil {
		_, _ = s.pool.Exec(ctx, `UPDATE invoice_scans SET status = 'ready' WHERE id = $1`, id)
		return sc, err
	}
	if _, err := s.pool.Exec(ctx, `UPDATE invoice_scans SET document_id = $2 WHERE id = $1`, id, doc.ID); err != nil {
		return sc, err
	}
	return s.Get(ctx, p, id)
}

func trimZeros(s string) string {
	if strings.Contains(s, ".") {
		s = strings.TrimRight(strings.TrimRight(s, "0"), ".")
	}
	return s
}

// Tick — зависшие распознавания (перезапуск сервера) считаем неудачными.
func (s *Service) Tick(ctx context.Context) error {
	// Текст — на языке того, кто сфотографировал накладную.
	_, err := s.pool.Exec(ctx, `UPDATE invoice_scans SET status = 'failed',
		error = CASE WHEN (SELECT u.language FROM employees e JOIN users u ON u.id = e.user_id WHERE e.id = invoice_scans.created_by) = 'uz'
		             THEN 'tanib olish toʻxtab qoldi — «Qayta tanib olish» tugmasini bosing'
		             ELSE 'распознавание прервалось — нажмите «Распознать заново»' END
		WHERE status = 'processing' AND updated_at < now() - interval '10 minutes'`)
	return err
}
