package pos

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Штрихкода нет ни в магазине, ни в Super Market — касса ищет его в открытых
// источниках (Figma «Касса · Штрихкода нет нигде — ищем в открытых
// источниках», НШ0–НШ3):
//
//   - каталог ИКПУ tasnif.soliq.uz — название, ИКПУ, единица. Сервер до tasnif
//     не достаёт, поэтому запрос делает касса и присылает записи как есть;
//   - Open Food Facts — название, бренд, объём, фото (ИКПУ нет).
//
// FoundPreview приводит находки к виду для окна (названия — по правилам
// каталога), FoundAdd — товар, который кассир подтвердил («Это он»): он
// попадает в базу Super Market и в «Мои товары» магазина с ценой магазина.

// OFFItem — товар Open Food Facts (поля API v2 как есть).
type OFFItem struct {
	ProductName string `json:"product_name"`
	Brands      string `json:"brands"`
	Quantity    string `json:"quantity"`
	Image       string `json:"image"`
}

type FoundPreviewInput struct {
	Barcode string               `json:"barcode"`
	Tasnif  []catalog.TasnifItem `json:"tasnif"`
	Off     *OFFItem             `json:"off"`
}

// FoundCandidate — вариант для окна. Index — номер записи tasnif в запросе
// (для source = off — -1).
type FoundCandidate struct {
	Source string `json:"source"` // tasnif | off
	Index  int    `json:"index"`
	Name   string `json:"name"`
	Ikpu   string `json:"ikpu"`
	Unit   string `json:"unit"`
	Brand  string `json:"brand"`
	Image  string `json:"image"`
	Marked bool   `json:"marked"`
}

const maxFoundTasnif = 10

// FoundPreview: записи tasnif с этим штрихкодом (без алкоголя и записей без
// ИКПУ); если в tasnif ничего — товар Open Food Facts. Фото Open Food Facts
// подставляется и к записям tasnif.
func (s *Service) FoundPreview(_ context.Context, p *identity.Principal, in FoundPreviewInput) ([]FoundCandidate, error) {
	if _, err := deviceStoreID(p); err != nil {
		return nil, err
	}
	code := strings.TrimSpace(in.Barcode)
	if !barcodeRe.MatchString(code) {
		return nil, apperr.Validation("barcode: штрихкод").Uz("barcode: shtrix-kod")
	}
	if len(in.Tasnif) > maxFoundTasnif {
		in.Tasnif = in.Tasnif[:maxFoundTasnif]
	}
	img := ""
	if in.Off != nil {
		img = httpsURL(in.Off.Image)
	}
	out := []FoundCandidate{}
	for i, it := range in.Tasnif {
		if it.Validate() != nil || it.Alcohol() || (it.Barcode() != "" && it.Barcode() != code) {
			continue
		}
		out = append(out, FoundCandidate{Source: "tasnif", Index: i, Name: it.Name(), Ikpu: it.Ikpu(), Unit: it.Unit(),
			Brand: it.Brand(), Image: img, Marked: it.Marked()})
	}
	if len(out) == 0 && in.Off != nil {
		if name := OffName(*in.Off); name != "" {
			out = append(out, FoundCandidate{Source: "off", Index: -1, Name: name, Unit: "шт", Brand: offBrand(in.Off.Brands), Image: img})
		}
	}
	return out, nil
}

type FoundAddInput struct {
	Barcode string              `json:"barcode"`
	Source  string              `json:"source"`
	Tasnif  *catalog.TasnifItem `json:"tasnif"`
	Off     *OFFItem            `json:"off"`
	// Name — название, которое подтвердил (и, может быть, поправил) кассир.
	Name  string       `json:"name"`
	Price money.Amount `json:"price"`
}

// FoundAddResult — товар для каталога кассы (сразу в чек) и создан ли он.
type FoundAddResult struct {
	Product CatalogProduct `json:"product"`
	Created bool           `json:"created"`
}

// serviceCategory — служебная категория «Без карточки» (миграция 0073):
// товар, которому Super Market не нашёл раздел, ждёт владельца и модерацию.
const serviceCategory = "00000000-0000-0000-0000-00000000c0de"

// FoundAdd: «Это он». Нужен кассир с правом «Установка цен» (или ПИН старшего
// на кассе — тогда кассир в запросе — старший): цена сразу ставится в
// магазине. Товар из tasnif с понятным разделом — в общий каталог, иначе —
// свой товар сети на модерации в «Без карточки» (владелец и супер-админ
// выберут раздел, для Open Food Facts — и ИКПУ).
func (s *Service) FoundAdd(ctx context.Context, p *identity.Principal, in FoundAddInput) (FoundAddResult, error) {
	var out FoundAddResult
	storeID, err := deviceStoreID(p)
	if err != nil {
		return out, err
	}
	if err := requireCashier(p); err != nil {
		return out, err
	}
	if err := p.Require(identity.PermPricesManage); err != nil {
		return out, err
	}
	code := strings.TrimSpace(in.Barcode)
	if !barcodeRe.MatchString(code) {
		return out, apperr.Validation("barcode: штрихкод").Uz("barcode: shtrix-kod")
	}
	if !in.Price.Valid() || money.D(string(in.Price)).Sign() <= 0 {
		return out, apperr.Validation("price: цена больше нуля").Uz("price: narx noldan katta boʻlsin")
	}
	name := strings.Join(strings.Fields(in.Name), " ")
	if utf8.RuneCountInString(name) > 200 {
		return out, apperr.Validation("name: до 200 символов").Uz("name: 200 belgigacha")
	}
	var it catalog.TasnifItem
	img := ""
	if in.Off != nil {
		img = httpsURL(in.Off.Image)
	}
	switch in.Source {
	case "tasnif":
		if in.Tasnif == nil {
			return out, apperr.Validation("tasnif: запись каталога ИКПУ").Uz("tasnif: MXIK katalogi yozuvi")
		}
		it = *in.Tasnif
		if err := it.Validate(); err != nil {
			return out, err
		}
		if it.Alcohol() {
			return out, apperr.Validation("алкоголь с кассы не добавляется").Uz("alkogol kassadan qoʻshilmaydi")
		}
		if b := it.Barcode(); b != "" && b != code {
			return out, apperr.Validation("tasnif: другой штрихкод").Uz("tasnif: boshqa shtrix-kod")
		}
		it.InternationalCode = code
		if name == "" {
			name = it.Name()
		}
	case "off":
		if in.Off == nil {
			return out, apperr.Validation("off: товар Open Food Facts").Uz("off: Open Food Facts mahsuloti")
		}
		if name == "" {
			name = OffName(*in.Off)
		}
	default:
		return out, apperr.Validation("source: tasnif или off").Uz("source: tasnif yoki off")
	}
	if name == "" {
		return out, apperr.Validation("name: укажите название").Uz("name: nomini kiriting")
	}

	var pid string
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		// Две кассы подтверждают один штрихкод одновременно.
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('found:' || $1))`, code); err != nil {
			return err
		}
		// Пока искали, товар появился (другая касса, панель) — берём его.
		err := tx.QueryRow(ctx, `
			SELECT p.id FROM product_barcodes b JOIN products p ON p.id = b.product_id
			WHERE barcode_key(b.barcode) = barcode_key($2) AND p.kind = 'goods'
			  AND (p.network_id = $1 OR (p.network_id IS NULL AND p.moderation_status = 'approved'))
			ORDER BY (p.network_id IS NOT NULL) DESC LIMIT 1`, p.NetworkID, code).Scan(&pid)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if pid == "" {
			if other, err := catalog.ProductByBarcode(ctx, tx, code); err != nil {
				return err
			} else if other != "" {
				return apperr.Conflict("barcode_exists", "штрихкод "+code+" уже есть у другого товара").Uz(code + " shtrix-kodi boshqa mahsulotda allaqachon bor")
			}
			if pid, err = s.createFound(ctx, tx, p, storeID, in.Source, it, code, name, img); err != nil {
				return err
			}
			out.Created = true
		}
		_, err = tx.Exec(ctx, `
			INSERT INTO store_products (network_id, store_id, product_id) VALUES ($1, $2, $3)
			ON CONFLICT DO NOTHING`, p.NetworkID, storeID, pid)
		return err
	})
	if err != nil {
		return out, err
	}
	// Цена магазина — тем же документом, что и окно цены на кассе.
	if _, err := s.SetPrice(ctx, p, pid, PriceInput{Price: in.Price}); err != nil {
		return out, err
	}
	out.Product, err = s.catalogProduct(ctx, p, pid)
	return out, err
}

func (s *Service) createFound(ctx context.Context, tx pgx.Tx, p *identity.Principal, storeID, source string,
	it catalog.TasnifItem, code, name, img string) (string, error) {
	if source == "tasnif" {
		catID, ok, err := catalog.CategoryByIkpu(ctx, tx, it.Ikpu())
		if err != nil {
			return "", err
		}
		if !ok {
			near, err := catalog.CategoriesNearIkpu(ctx, tx, it.Ikpu(), 1)
			if err != nil {
				return "", err
			}
			if len(near) > 0 {
				catID, ok = near[0], true
			}
		}
		if ok {
			id, err := catalog.CreateTasnifProduct(ctx, tx, catalog.TasnifProduct{Item: it, CategoryID: catID, Image: img, StoreID: storeID})
			if err != nil {
				return "", err
			}
			// ИКПУ и маркировка — сразу в поля фискального чека; название —
			// как подтвердил кассир.
			_, err = tx.Exec(ctx, `UPDATE products SET ikpu = $2, is_marked = $3, name = $4 WHERE id = $1`,
				id, it.Ikpu(), it.Marked(), runeCut(name, 200))
			return id, err
		}
	}
	unitID, err := catalog.UnitID(ctx, tx, it.Unit())
	if err != nil {
		return "", err
	}
	attrs := map[string]any{"added_by_store": storeID, "added_from": "pos"}
	ikpu := ""
	if source == "tasnif" {
		ikpu = it.Ikpu()
		attrs["source"], attrs["ikpu"] = "tasnif.soliq.uz", ikpu
	} else {
		attrs["source"] = "openfoodfacts.org"
	}
	images := []string{}
	if img != "" {
		images = append(images, img)
	}
	var id string
	if err := tx.QueryRow(ctx, `
		INSERT INTO products (network_id, proposed_by, name, description, category_id, unit_id, images,
		                      moderation_status, attributes, ikpu, is_marked)
		VALUES ($1, $1, $2, '', $3, $4, $5, 'pending', $6, $7, $8) RETURNING id`,
		p.NetworkID, runeCut(name, 200), serviceCategory, unitID, images, attrs, ikpu, source == "tasnif" && it.Marked()).Scan(&id); err != nil {
		return "", err
	}
	_, err = tx.Exec(ctx, `INSERT INTO product_barcodes (barcode, product_id) VALUES ($1, $2)`, code, id)
	return id, err
}

// OffName — название товара Open Food Facts по правилам каталога: бренд +
// название + объём/вес («Nutella 350 г»), без повторов бренда и объёма.
func OffName(o OFFItem) string {
	name := strings.Join(strings.Fields(o.ProductName), " ")
	if name == "" {
		return ""
	}
	if brand := offBrand(o.Brands); brand != "" && !strings.Contains(lettersOnly(name), lettersOnly(brand)) {
		name = brand + " " + name
	}
	if m := qtyRe.FindStringSubmatch(o.Quantity); m != nil &&
		!strings.Contains(strings.ReplaceAll(name, ",", "."), strings.ReplaceAll(m[1], ",", ".")) {
		name += " " + offQuantity(o.Quantity)
	}
	return runeCut(upperFirstRune(name), 120)
}

// lettersOnly — только буквы и цифры в нижнем регистре: «Coca-Cola» = «coca cola».
func lettersOnly(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// offBrand — первый бренд из списка без юрлица: «Nutella, Ferrero» →
// «Nutella», «Red Bull GmbH» → «Red Bull», «Mars Wrigley Confectionery UK
// Limited, Snickers» → «Snickers».
func offBrand(brands string) string {
	for _, b := range strings.Split(brands, ",") {
		// Длинные — это юрлица («Mars Wrigley Confectionery UK Limited»).
		if len(strings.Fields(b)) > 3 {
			continue
		}
		if b = strings.Join(strings.Fields(legalRe.ReplaceAllString(b, " ")), " "); b != "" {
			return b
		}
	}
	return ""
}

var legalRe = regexp.MustCompile(`(?i)\b(gmbh|ltd|limited|llc|inc|sa/nv|s\.a\.|s\.p\.a\.|spa|ag|ooo|services|company|corp)\b\.?`)

var qtyRe = regexp.MustCompile(`(?i)^\s*([0-9]+(?:[.,][0-9]+)?)\s*(kg|кг|g|gr|г|гр|ml|мл|cl|l|л|lt|ltr|шт|pcs)\.?\s*$`)

// offQuantity: «350 g» → «350 г», «0.25 l» → «0,25 л», «33 cl» → «330 мл».
func offQuantity(q string) string {
	m := qtyRe.FindStringSubmatch(q)
	if m == nil {
		return ""
	}
	num := strings.ReplaceAll(m[1], ".", ",")
	switch strings.ToLower(m[2]) {
	case "kg", "кг":
		return num + " кг"
	case "g", "gr", "г", "гр":
		return num + " г"
	case "ml", "мл":
		return num + " мл"
	case "cl":
		return money.D(strings.ReplaceAll(m[1], ",", ".")).Mul(money.D("10")).Fixed(0) + " мл"
	case "l", "л", "lt", "ltr":
		return num + " л"
	default:
		return num + " шт"
	}
}

func httpsURL(s string) string {
	s = strings.TrimSpace(s)
	if !strings.HasPrefix(s, "https://") || len(s) > 500 {
		return ""
	}
	return s
}

func runeCut(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return strings.TrimSpace(string([]rune(s)[:n]))
}

func upperFirstRune(s string) string {
	r, size := utf8.DecodeRuneInString(s)
	if r == utf8.RuneError {
		return s
	}
	return string(unicode.ToUpper(r)) + s[size:]
}
