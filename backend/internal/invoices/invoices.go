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
	Line        int     `json:"line"`
	Name        string  `json:"name"`
	Barcode     string  `json:"barcode"`
	Unit        string  `json:"unit"`
	Qty         string  `json:"qty"`
	Price       string  `json:"price"`
	Sum         string  `json:"sum"`
	ProductID   *string `json:"product_id"`
	ProductName *string `json:"product_name"`
	UnitShort   *string `json:"unit_short"`
	// barcode, alias, name, manual.
	Match      *string `json:"match"`
	Confidence int     `json:"confidence"`
	Skipped    bool    `json:"skipped"`
	// ok — готово, check — проверить, missing — не найден, skipped — пропущена.
	State string `json:"state"`
	// Цена прошлого прихода этого товара и изменение, %.
	LastPrice   *string `json:"last_price"`
	PriceChange *int    `json:"price_change"`
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
	Skipped int `json:"skipped"`
}

func require(p *identity.Principal, storeID string) error {
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return err
	}
	if !httpx.IsUUID(storeID) || !p.CanAccessStore(storeID) {
		return apperr.NotFound("магазин не найден")
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
		return Scan{}, apperr.Validation("images: от 1 до 5 фото накладной")
	}
	keys := make([]string, 0, len(in.Images))
	for _, u := range in.Images {
		k, ok := media.KeyFromURL(u)
		if !ok {
			return Scan{}, apperr.Validation("images: фото должно быть загружено через /store/uploads")
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
		return Scan{}, apperr.NotFound("магазин не найден")
	}
	if err != nil {
		return Scan{}, err
	}
	s.start(id, p.NetworkID)
	return s.Get(ctx, p, id)
}

// Retry — распознать заново (после ошибки).
func (s *Service) Retry(ctx context.Context, p *identity.Principal, id string) (Scan, error) {
	sc, err := s.Get(ctx, p, id)
	if err != nil {
		return sc, err
	}
	if sc.Status != StatusFailed {
		return sc, apperr.Conflict("scan_not_failed", "распознать заново можно только после ошибки")
	}
	if _, err := s.ai.Conn(ctx); err != nil {
		return Scan{}, err
	}
	if _, err := s.pool.Exec(ctx, `UPDATE invoice_scans SET status = 'processing', error = '' WHERE id = $1`, id); err != nil {
		return Scan{}, err
	}
	s.start(id, p.NetworkID)
	return s.Get(ctx, p, id)
}

func (s *Service) start(id, networkID string) {
	s.run(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
		defer cancel()
		if err := s.process(ctx, id, networkID); err != nil {
			msg := "не удалось распознать накладную"
			var se *ai.ErrService
			var ae *apperr.Error
			switch {
			case errors.As(err, &se):
				msg = se.Msg
			case errors.As(err, &ae):
				msg = ae.Message
			default:
				s.log.Error("invoice scan", "id", id, "err", err)
			}
			if len([]rune(msg)) > 480 {
				msg = string([]rune(msg)[:480])
			}
			if _, err := s.pool.Exec(context.Background(), `UPDATE invoice_scans SET status = 'failed', error = $2 WHERE id = $1 AND status = 'processing'`, id, msg); err != nil {
				s.log.Error("invoice scan fail", "id", id, "err", err)
			}
			if err := s.notifyAuthor(context.Background(), s.pool, id, "invoice_failed", "Не удалось распознать накладную", msg); err != nil {
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
			return apperr.Validation("фото накладной не найдено в хранилище")
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
		supplier := inv.SupplierName
		if supplier == "" {
			supplier = "Накладная"
		}
		if err := s.notifyAuthor(ctx, tx, id, "invoice_ready", "Накладная распознана",
			fmt.Sprintf("%s: строк %d — проверьте и проведите приход", supplier, len(inv.Lines))); err != nil {
			return err
		}
		for i, l := range inv.Lines {
			m := matchLine(ctx, tx, networkID, cp, l.Name, l.Barcode)
			_, err := tx.Exec(ctx, `
				INSERT INTO invoice_scan_lines (scan_id, line, name, barcode, unit, qty, price, product_id, match, confidence)
				VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
				id, i+1, l.Name, l.Barcode, l.Unit, fmtNum(l.Qty, 3), fmtNum(l.Price, 4), m.productID, m.match, m.confidence)
			if err != nil {
				return err
			}
		}
		return nil
	})
}

// notifyAuthor — push тому, кто сфотографировал накладную.
func (s *Service) notifyAuthor(ctx context.Context, q db.Querier, id, kind, title, body string) error {
	var emp string
	if err := q.QueryRow(ctx, `SELECT created_by FROM invoice_scans WHERE id = $1`, id).Scan(&emp); err != nil {
		return err
	}
	return push.EnqueueEmployee(ctx, q, emp, kind, title, body, map[string]string{"type": "invoice", "scan_id": id})
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
	var sim float64
	err := q.QueryRow(ctx, `SELECT p.id, similarity(lower(p.name), $2) AS s FROM products p
		WHERE `+visible+` AND lower(p.name) % $2 ORDER BY s DESC, p.name LIMIT 1`, networkID, strings.ToLower(name)).Scan(&id, &sim)
	if err == nil {
		return match{productID: &id, match: strp("name"), confidence: int(math.Round(sim * 100))}
	}
	return match{}
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
		return Scan{}, apperr.NotFound("накладная не найдена")
	}
	var sc Scan
	err := scanRow(s.pool.QueryRow(ctx, `SELECT `+scanCols+scanFrom+` WHERE s.id = $1 AND s.network_id = $2`, id, p.NetworkID), &sc)
	if errors.Is(err, pgx.ErrNoRows) {
		return sc, apperr.NotFound("накладная не найдена")
	}
	if err != nil {
		return sc, err
	}
	if err := require(p, sc.StoreID); err != nil {
		return Scan{}, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT l.line, l.name, l.barcode, l.unit, l.qty::text, l.price::text, round(l.qty * l.price, 2)::text,
		       l.product_id, p.name, u.short_name, l.match, l.confidence, l.skipped,
		       (SELECT i.price::text FROM stock_document_items i JOIN stock_documents d ON d.id = i.document_id
		         WHERE d.network_id = $2 AND d.type = 'income' AND d.status = 'posted' AND i.product_id = l.product_id
		           AND i.price IS NOT NULL AND d.currency = $3
		         ORDER BY d.posted_at DESC LIMIT 1)
		FROM invoice_scan_lines l
		LEFT JOIN products p ON p.id = l.product_id
		LEFT JOIN units u ON u.id = p.unit_id
		WHERE l.scan_id = $1 ORDER BY l.line`, id, p.NetworkID, sc.Currency)
	if err != nil {
		return sc, err
	}
	sc.Lines, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (Line, error) {
		var l Line
		err := r.Scan(&l.Line, &l.Name, &l.Barcode, &l.Unit, &l.Qty, &l.Price, &l.Sum, &l.ProductID, &l.ProductName, &l.UnitShort,
			&l.Match, &l.Confidence, &l.Skipped, &l.LastPrice)
		return l, err
	})
	if err != nil {
		return sc, err
	}
	var total float64
	for i := range sc.Lines {
		l := &sc.Lines[i]
		l.State = lineState(l)
		switch l.State {
		case "ok":
			sc.Counts.OK++
		case "check":
			sc.Counts.Check++
		case "missing":
			sc.Counts.Missing++
		default:
			sc.Counts.Skipped++
		}
		if !l.Skipped {
			v, _ := strconv.ParseFloat(l.Sum, 64)
			total += v
		}
	}
	sc.LinesTotal = strconv.FormatFloat(math.Round(total*100)/100, 'f', 2, 64)
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

func lineState(l *Line) string {
	if l.Skipped {
		return "skipped"
	}
	if l.ProductID == nil {
		return "missing"
	}
	if l.LastPrice != nil {
		last, _ := strconv.ParseFloat(*l.LastPrice, 64)
		cur, _ := strconv.ParseFloat(l.Price, 64)
		if last > 0 {
			ch := int(math.Round((cur - last) / last * 100))
			if ch != 0 {
				l.PriceChange = &ch
			}
		}
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
		return "", nil, apperr.NotFound("накладная не найдена")
	}
	var status string
	err = tx.QueryRow(ctx, `SELECT store_id, status, counterparty_id FROM invoice_scans WHERE id = $1 AND network_id = $2 FOR UPDATE`,
		id, p.NetworkID).Scan(&storeID, &status, &cp)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil, apperr.NotFound("накладная не найдена")
	}
	if err != nil {
		return "", nil, err
	}
	if err := require(p, storeID); err != nil {
		return "", nil, err
	}
	if status != StatusReady {
		return "", nil, apperr.Conflict("scan_not_ready", "накладная ещё распознаётся или приход уже создан")
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
				return apperr.Validation("поставщик не распознан — выберите его из списка")
			}
			if err := tx.QueryRow(ctx, `INSERT INTO counterparties (network_id, name, inn) VALUES ($1, $2, $3) RETURNING id`,
				p.NetworkID, name, inn).Scan(&cp); err != nil {
				return err
			}
		case in.CounterpartyID != nil && httpx.IsUUID(*in.CounterpartyID):
			err := tx.QueryRow(ctx, `SELECT id FROM counterparties WHERE id = $1 AND network_id = $2 AND is_active`, *in.CounterpartyID, p.NetworkID).Scan(&cp)
			if errors.Is(err, pgx.ErrNoRows) {
				return apperr.Validation("counterparty_id: поставщик не найден")
			}
			if err != nil {
				return err
			}
		default:
			return apperr.Validation("counterparty_id: выберите поставщика")
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
		return nil
	})
	if err != nil {
		return Scan{}, err
	}
	return s.Get(ctx, p, id)
}

type LineInput struct {
	ProductID *string      `json:"product_id"`
	Qty       *money.Qty   `json:"qty"`
	Price     *money.Price `json:"price"`
	Skip      *bool        `json:"skip"`
	// Запомнить название строки для этого поставщика.
	Remember bool `json:"remember"`
}

// SetLine — человек выбрал товар, поправил количество/цену или пропустил строку.
func (s *Service) SetLine(ctx context.Context, p *identity.Principal, id string, line int, in LineInput) (Scan, error) {
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		_, cp, err := s.editable(ctx, tx, p, id)
		if err != nil {
			return err
		}
		var name string
		err = tx.QueryRow(ctx, `SELECT name FROM invoice_scan_lines WHERE scan_id = $1 AND line = $2 FOR UPDATE`, id, line).Scan(&name)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.NotFound("строка не найдена")
		}
		if err != nil {
			return err
		}
		if in.ProductID != nil {
			var pid string
			err := tx.QueryRow(ctx, `SELECT p.id FROM products p WHERE p.id::text = $2 AND `+visible, p.NetworkID, *in.ProductID).Scan(&pid)
			if errors.Is(err, pgx.ErrNoRows) {
				return apperr.Validation("product_id: товар не найден")
			}
			if err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `UPDATE invoice_scan_lines SET product_id = $3, match = 'manual', confidence = 100, skipped = false
				WHERE scan_id = $1 AND line = $2`, id, line, pid); err != nil {
				return err
			}
			if in.Remember {
				if cp == nil {
					return apperr.Validation("remember: сначала выберите поставщика")
				}
				if alias := NormAlias(name); alias != "" {
					if _, err := tx.Exec(ctx, `
						INSERT INTO supplier_product_aliases (network_id, counterparty_id, alias, product_id) VALUES ($1, $2, $3, $4)
						ON CONFLICT (network_id, counterparty_id, alias) DO UPDATE SET product_id = EXCLUDED.product_id, created_at = now()`,
						p.NetworkID, *cp, alias, pid); err != nil {
						return err
					}
				}
			}
		}
		if in.Qty != nil {
			if !in.Qty.Valid() {
				return apperr.Validation("qty: неверное количество")
			}
			if _, err := tx.Exec(ctx, `UPDATE invoice_scan_lines SET qty = $3 WHERE scan_id = $1 AND line = $2`, id, line, string(*in.Qty)); err != nil {
				return err
			}
		}
		if in.Price != nil {
			if !in.Price.Valid() {
				return apperr.Validation("price: неверная цена")
			}
			if _, err := tx.Exec(ctx, `UPDATE invoice_scan_lines SET price = $3 WHERE scan_id = $1 AND line = $2`, id, line, string(*in.Price)); err != nil {
				return err
			}
		}
		if in.Skip != nil {
			if _, err := tx.Exec(ctx, `UPDATE invoice_scan_lines SET skipped = $3 WHERE scan_id = $1 AND line = $2`, id, line, *in.Skip); err != nil {
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

type Suggestion struct {
	ProductID string  `json:"product_id"`
	Name      string  `json:"name"`
	Barcode   *string `json:"barcode"`
	UnitShort string  `json:"unit_short"`
	Score     int     `json:"score"`
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
		SELECT p.id, p.name, (SELECT min(pb.barcode) FROM product_barcodes pb WHERE pb.product_id = p.id), u.short_name,
		       round(greatest(similarity(lower(p.name), $2), word_similarity($2, lower(p.name))) * 100)::int AS s
		FROM products p JOIN units u ON u.id = p.unit_id
		WHERE `+visible+` AND (lower(p.name) % $2 OR $2 <% lower(p.name) OR lower(p.name) LIKE '%' || $2 || '%'
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
		return sc, apperr.Conflict("scan_not_ready", "накладная ещё распознаётся или приход уже создан")
	case sc.CounterpartyID == nil:
		return sc, apperr.Validation("counterparty_id: выберите поставщика")
	case sc.Counts.Missing > 0:
		return sc, apperr.Conflict("lines_unmatched", fmt.Sprintf("не сопоставлено строк: %d — выберите товар или пропустите строку", sc.Counts.Missing))
	}
	wh := in.WarehouseID
	if wh == nil {
		var def *string
		if err := s.pool.QueryRow(ctx, `SELECT default_warehouse_id FROM stores WHERE id = $1`, sc.StoreID).Scan(&def); err != nil {
			return sc, err
		}
		if def == nil {
			return sc, apperr.Validation("warehouse_id: у магазина нет основного склада")
		}
		wh = def
	}
	var items []inventory.ItemInput
	for _, l := range sc.Lines {
		if l.Skipped || l.ProductID == nil {
			continue
		}
		price := money.Price(l.Price)
		items = append(items, inventory.ItemInput{ProductID: *l.ProductID, Qty: money.Qty(trimZeros(l.Qty)), Price: &price})
	}
	if len(items) == 0 {
		return sc, apperr.Validation("в накладной нет строк для прихода")
	}
	// Одна накладная — один приход: занимаем её, пока создаём документ.
	tag, err := s.pool.Exec(ctx, `UPDATE invoice_scans SET status = 'done' WHERE id = $1 AND status = 'ready'`, id)
	if err != nil {
		return sc, err
	}
	if tag.RowsAffected() == 0 {
		return sc, apperr.Conflict("scan_not_ready", "приход по этой накладной уже создаётся")
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
	_, err := s.pool.Exec(ctx, `UPDATE invoice_scans SET status = 'failed', error = 'распознавание прервалось — нажмите «Распознать заново»'
		WHERE status = 'processing' AND updated_at < now() - interval '10 minutes'`)
	return err
}
