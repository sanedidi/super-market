package invoices

import (
	"context"
	"errors"
	"math"
	"regexp"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

// Упаковка строки накладной (Figma «Приход по фото накладной», Н1, Н3, Н4).
//
// В накладной количество бывает не в единицах товара, а в упаковках:
//   - «Окорочка с/з 12 кг мар  1 × 30 450, сумма 365 400» — 1 коробка по
//     12 кг, цена за кг: видно по сумме строки;
//   - «Кола 1.5 ПЭТ 12  12 × 84 000» — 12 блоков по 6 шт или 12 штук: по
//     одной строке не понять, подсказывают прошлая цена закупки, название,
//     единица «блок» и то, что уже запомнено.
//
// На склад идёт qty × pack единиц товара, цена за единицу — сумма / (qty × pack).
// Сумма строки — главная: из неё считается цена, когда меняется упаковка.

const (
	PackNone       = ""
	PackSum        = "sum"
	PackRemembered = "remembered"
	PackProduct    = "product"
	PackManual     = "manual"
	PackGuess      = "guess"
)

// PackIn — что известно о строке и товаре.
type PackIn struct {
	Qty, Price float64
	// Сумма строки из накладной; 0 — не прочитана.
	ReadSum float64
	Name    string
	// Единица в накладной («шт», «блок», «кор»).
	Unit string
	// В чём считано «Кол-во» по смыслу строки: pcs, pack или "".
	QtyIn string
	// Товар продаётся дробно (кг, л).
	Fractional bool
	// Запомнено для поставщика (по названию строки).
	Remembered *float64
	// Размер блока товара в сети; 0 — не задан.
	NetPack int
	// Цена закупки за единицу товара в прошлом приходе; 0 — нет.
	LastCost float64
}

// GuessPack — упаковка строки и откуда она.
func GuessPack(in PackIn) (float64, string) {
	if in.Qty <= 0 {
		return 1, PackNone
	}
	// Сумма строки больше, чем qty × price: в накладной упаковки, а цена — за
	// единицу товара (1 коробка × 30 450 за кг = 365 400 → 12 кг).
	if in.ReadSum > 0 && in.Price > 0 {
		if r := in.ReadSum / (in.Qty * in.Price); r > 1.05 && r <= 1000 {
			r = math.Round(r*1000) / 1000
			if in.Fractional {
				return r, PackSum
			}
			// Штуки — только целые: 5,98 → 6.
			if n := math.Round(r); n >= 2 && math.Abs(r-n)/n <= 0.03 {
				return n, PackSum
			}
		}
	}
	if in.Remembered != nil && *in.Remembered > 0 {
		return *in.Remembered, PackRemembered
	}
	if in.Fractional {
		return 1, PackNone
	}
	sum := in.ReadSum
	if sum <= 0 {
		sum = in.Qty * in.Price
	}
	unitPrice := sum / in.Qty
	// По прошлой цене за штуку: 84 000 при прошлой 14 000 — блок по 6.
	if in.LastCost > 0 && unitPrice > 0 {
		ratio := unitPrice / in.LastCost
		if ratio >= 0.8 && ratio <= 1.25 {
			return 1, PackNone
		}
		if n := math.Round(ratio); n >= 2 && n <= 200 && math.Abs(ratio-n)/n <= 0.1 {
			if int(n) == in.NetPack {
				return n, PackProduct
			}
			return n, PackGuess
		}
	}
	// По смыслу строки пришли штуки (вес строки, цена за штуку) — «48*20гр»
	// в названии лишь размер коробки.
	if in.QtyIn == "pcs" {
		return 1, PackNone
	}
	byUnit := packUnit(in.Unit)
	if in.NetPack > 1 {
		if byUnit {
			return float64(in.NetPack), PackProduct
		}
		if NamePack(in.Name) == in.NetPack {
			return float64(in.NetPack), PackGuess
		}
		return 1, PackNone
	}
	if n := NamePack(in.Name); n >= 2 {
		return float64(n), PackGuess
	}
	if byUnit {
		// «12 блок» — блоков, но сколько в блоке, не знаем: спросим.
		return 1, PackGuess
	}
	return 1, PackNone
}

var packUnitRe = regexp.MustCompile(`^(бл|блок|упак|уп|кор|короб|коробка|ящ|ящик|пач|пачка|спайка|blok|quti|upak|karobka|box|pack|pk|ctn)\.?$`)

func packUnit(u string) bool {
	return packUnitRe.MatchString(strings.ToLower(strings.TrimSpace(u)))
}

var (
	// «x12», «х 12», «*12» — не перед единицей объёма/веса.
	packTimesRe = regexp.MustCompile(`(?:^|[\s(])[xх×*]\s*(\d{1,3})(?:\s|\)|$)`)
	// «12 шт», «12шт», «12 ta», «12 dona», «12 pcs».
	packPcsRe = regexp.MustCompile(`(\d{1,3})\s*(?:шт|ta|dona|pcs)(?:[^\p{L}]|$)`)
	// «6×1,5 л», «6x0.5л».
	packMulRe = regexp.MustCompile(`(\d{1,3})\s*[xх×*]\s*\d+(?:[.,]\d+)?\s*(?:л|l|мл|ml|г|g|гр|кг|kg)`)
	// Число в конце: «Кола 1.5 ПЭТ 12».
	packTailRe = regexp.MustCompile(`\s(\d{1,3})\s*$`)
)

// NamePack — штук в упаковке по названию строки; 0 — не видно.
func NamePack(name string) int {
	s := strings.ToLower(strings.TrimSpace(name))
	for _, re := range []*regexp.Regexp{packMulRe, packPcsRe, packTimesRe, packTailRe} {
		if m := re.FindStringSubmatch(s); m != nil {
			if n, err := strconv.Atoi(m[1]); err == nil && n >= 2 && n <= 200 {
				return n
			}
		}
	}
	return 0
}

// lineCost — цена за единицу товара: сумма строки / (qty × pack).
func lineCost(qty, price, readSum, pack float64) float64 {
	sum := readSum
	if sum <= 0 {
		// Без суммы цена в накладной — за единицу накладной (блок).
		sum = qty * price
	}
	if qty <= 0 || pack <= 0 {
		return price
	}
	return math.Round(sum/(qty*pack)*100) / 100
}

// repack — заново определить упаковку и цену строки (после распознавания,
// выбора товара или поставщика).
func repack(ctx context.Context, q db.Querier, networkID, scanID string, line int) error {
	var (
		name, unit, currency, alias, qtyIn string
		qty, price                         float64
		readSum                            *float64
		productID, cp                      *string
	)
	// Сумма строки не прочитана, а строка в накладной одна — её сумма и есть
	// «Итого» накладной (так же с накладными, распознанными до 23 окт 2026).
	err := q.QueryRow(ctx, `SELECT l.name, l.unit, l.qty_in, l.qty::float8, l.price::float8,
		       COALESCE(l.read_sum, CASE WHEN (SELECT count(*) FROM invoice_scan_lines x WHERE x.scan_id = l.scan_id) = 1
		                                 THEN s.invoice_total END)::float8,
		       l.product_id, s.counterparty_id, s.currency
		FROM invoice_scan_lines l JOIN invoice_scans s ON s.id = l.scan_id WHERE l.scan_id = $1 AND l.line = $2`, scanID, line).
		Scan(&name, &unit, &qtyIn, &qty, &price, &readSum, &productID, &cp, &currency)
	if err != nil {
		return err
	}
	in := PackIn{Qty: qty, Price: price, Name: name, Unit: unit, QtyIn: qtyIn}
	if readSum != nil {
		in.ReadSum = *readSum
	}
	alias = NormAlias(name)
	if productID != nil {
		var netPack *int
		var lastCost *float64
		err := q.QueryRow(ctx, `
			SELECT u.is_fractional,
			       (SELECT pk.pack FROM network_product_packs pk WHERE pk.network_id = $1 AND pk.product_id = p.id),
			       (SELECT a.pack::float8 FROM supplier_product_aliases a
			         WHERE a.network_id = $1 AND a.counterparty_id = $3 AND a.alias = $4 AND a.product_id = p.id),
			       (SELECT i.price::float8 FROM stock_document_items i JOIN stock_documents d ON d.id = i.document_id
			         WHERE d.network_id = $1 AND d.type = 'income' AND d.status = 'posted' AND i.product_id = p.id
			           AND i.price IS NOT NULL AND d.currency = $5
			         ORDER BY d.posted_at DESC LIMIT 1)
			FROM products p JOIN units u ON u.id = p.unit_id WHERE p.id = $2`, networkID, *productID, cp, alias, currency).
			Scan(&in.Fractional, &netPack, &in.Remembered, &lastCost)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if netPack != nil {
			in.NetPack = *netPack
		}
		if lastCost != nil {
			in.LastCost = *lastCost
		}
	} else {
		// Товар не найден: единицу подсказывает накладная.
		in.Fractional = fractionalUnit(unit)
	}
	pack, src := GuessPack(in)
	cost := lineCost(qty, price, in.ReadSum, pack)
	var sum *string
	if in.ReadSum > 0 {
		v := fmtNum(in.ReadSum, 2)
		sum = &v
	}
	_, err = q.Exec(ctx, `UPDATE invoice_scan_lines SET pack = $3, pack_source = $4, cost = $5, read_sum = COALESCE(read_sum, $6::numeric)
		WHERE scan_id = $1 AND line = $2`, scanID, line, fmtNum(pack, 3), src, fmtNum(cost, 2), sum)
	return err
}

func fractionalUnit(u string) bool {
	switch strings.Trim(strings.ToLower(strings.TrimSpace(u)), ".") {
	case "кг", "kg", "л", "l", "литр", "килограмм":
		return true
	}
	return false
}
