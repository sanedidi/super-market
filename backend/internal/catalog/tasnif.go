package catalog

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

// Товар из каталога ИКПУ tasnif.soliq.uz, найденный магазином («Начало
// работы»). Сервер до tasnif не достаёт, поэтому запись присылает браузер или
// телефон магазина — в том виде, в каком её отдаёт tasnif
// (/api/cls-api/mxik/search/by-params). Название собирается по тем же
// правилам, что и при импорте каталога (tools/tasnif-import/build_import.py).

// TasnifItem — запись каталога ИКПУ.
type TasnifItem struct {
	MxikCode          string `json:"mxikCode"`
	MxikName          string `json:"mxikName"`
	GroupCode         string `json:"groupCode"`
	ClassCode         string `json:"classCode"`
	GroupName         string `json:"groupName"`
	ClassName         string `json:"className"`
	PositionName      string `json:"positionName"`
	SubPositionName   string `json:"subPositionName"`
	BrandName         string `json:"brandName"`
	AttributeName     string `json:"attributeName"`
	InternationalCode string `json:"internationalCode"`
	// Label — товар с обязательной маркировкой (1). tasnif отдаёт числом.
	Label any `json:"label"`
}

var ikpuRe = regexp.MustCompile(`^[0-9]{17}$`)

// Классы алкоголя: в каталог Super Market не добавляем (как при импорте).
var alcoholClasses = map[string]bool{"02203": true, "02204": true, "02205": true, "02206": true, "02208": true}

// Ikpu — код ИКПУ (17 цифр) или пусто.
func (t TasnifItem) Ikpu() string {
	c := strings.TrimSpace(t.MxikCode)
	if !ikpuRe.MatchString(c) {
		return ""
	}
	return c
}

// Barcode — штрихкод (8–14 цифр) или пусто.
func (t TasnifItem) Barcode() string {
	c := strings.TrimSpace(t.InternationalCode)
	if !importBarcodeRe.MatchString(c) {
		return ""
	}
	return c
}

// Alcohol — алкоголь (класс ИКПУ 02203–02206, 02208).
func (t TasnifItem) Alcohol() bool {
	cls := strings.TrimSpace(t.ClassCode)
	if cls == "" && len(t.Ikpu()) >= 5 {
		cls = t.Ikpu()[:5]
	}
	return alcoholClasses[cls]
}

// Marked — товар с маркировкой.
func (t TasnifItem) Marked() bool {
	switch v := t.Label.(type) {
	case float64:
		return v == 1
	case string:
		return strings.TrimSpace(v) == "1"
	case bool:
		return v
	}
	return false
}

// Validate — запись годится для каталога Super Market.
func (t TasnifItem) Validate() error {
	if t.Ikpu() == "" {
		return apperr.Validation("item: нет кода ИКПУ").Uz("item: MXIK kodi yoʻq")
	}
	if t.Alcohol() {
		return apperr.Validation("алкоголь в каталог Super Market не добавляется").Uz("alkogol Super Market katalogiga qoʻshilmaydi")
	}
	if t.Name() == "" {
		return apperr.Validation("item: нет названия").Uz("item: nomi yoʻq")
	}
	return nil
}

// Unit — короткое имя единицы: весовые товары tasnif помечает «килограмм».
func (t TasnifItem) Unit() string {
	s := strings.ToLower(t.AttributeName + " " + t.MxikName)
	if strings.Contains(s, "весов") || strings.Contains(s, "на развес") {
		return "кг"
	}
	return "шт"
}

var (
	leadNumRe  = regexp.MustCompile(`^\d+\s*-\s*`)
	spacesRe   = regexp.MustCompile(`\s+`)
	parensRe   = regexp.MustCompile(`\s*\(.*?\)`)
	vagueTypRe = regexp.MustCompile(`всех видов|прочие|прочих|не перечисл`)
	stemWordRe = regexp.MustCompile(`[а-яёa-z]{4,}`)
	wordRe     = regexp.MustCompile(`[A-Za-zА-Яа-яЁё]+`)
)

func tasnifStrip(s string) string {
	return strings.TrimSpace(leadNumRe.ReplaceAllString(strings.TrimSpace(s), ""))
}

func tasnifClean(s string) string {
	s = strings.Trim(strings.TrimSpace(spacesRe.ReplaceAllString(s, " ")), " ,.;")
	if s == "---" || s == "-" || s == "--" {
		return ""
	}
	return s
}

func letters(s string) []rune {
	var out []rune
	for _, r := range s {
		if unicode.IsLetter(r) {
			out = append(out, r)
		}
	}
	return out
}

// prettyBrand — «COCA-COLA» → «Coca-Cola»; бренды в обычном регистре не трогаем.
func prettyBrand(b string) string {
	b = tasnifClean(b)
	if b == "" {
		return ""
	}
	ls := letters(b)
	if len(ls) == 0 || utf8.RuneCountInString(b) <= 3 {
		return b
	}
	for _, r := range ls {
		if !unicode.IsUpper(r) {
			return b
		}
	}
	return wordRe.ReplaceAllStringFunc(strings.ToLower(b), func(w string) string {
		r, n := utf8.DecodeRuneInString(w)
		return string(unicode.ToUpper(r)) + w[n:]
	})
}

func upperFirst(s string) string {
	if s == "" {
		return s
	}
	r, n := utf8.DecodeRuneInString(s)
	return string(unicode.ToUpper(r)) + s[n:]
}

func lowerFirst(s string) string {
	if s == "" {
		return s
	}
	r, n := utf8.DecodeRuneInString(s)
	return string(unicode.ToLower(r)) + s[n:]
}

// fixCase — характеристика КАПСОМ → обычный регистр, первая буква заглавная.
func fixCase(a string) string {
	ls := letters(a)
	if len(ls) > 6 {
		up := 0
		for _, r := range ls {
			if unicode.IsUpper(r) {
				up++
			}
		}
		if float64(up)/float64(len(ls)) > 0.8 {
			a = strings.ToLower(a)
		}
	}
	return upperFirst(a)
}

func runePrefix(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		r = r[:n]
	}
	return string(r)
}

// Name — название для каталога: «Бренд, характеристика» (с видом товара,
// если его нет в характеристике), иначе — вид товара и бренд или название ИКПУ.
func (t TasnifItem) Name() string {
	brand := prettyBrand(tasnifStrip(t.BrandName))
	attr := fixCase(tasnifClean(t.AttributeName))
	sub := tasnifStrip(t.SubPositionName)
	typ := strings.TrimSpace(strings.Split(parensRe.ReplaceAllString(sub, ""), ",")[0])
	if vagueTypRe.MatchString(strings.ToLower(typ)) {
		typ = ""
	}
	hasType := true
	if words := stemWordRe.FindAllString(strings.ToLower(typ), -1); len(words) > 0 {
		hasType = false
		la := strings.ToLower(attr)
		for _, w := range words {
			n := utf8.RuneCountInString(w)
			if strings.Contains(la, runePrefix(w, min(n-1, 5))) {
				hasType = true
				break
			}
		}
	}
	var name string
	switch {
	case brand != "" && attr != "":
		a2 := attr
		// «Сладкий» → «сладкий» после бренда; латиница («Active Baby Dry») и
		// аббревиатуры («UHT») — как есть.
		if two := []rune(attr); len(two) >= 2 && unicode.Is(unicode.Cyrillic, two[0]) && unicode.IsLetter(two[1]) &&
			!(unicode.IsUpper(two[0]) && unicode.IsUpper(two[1])) {
			a2 = lowerFirst(attr)
		}
		switch {
		case strings.HasPrefix(strings.ToLower(attr), strings.ToLower(brand)):
			name = attr
		case !hasType && typ != "":
			name = typ + " " + brand + ", " + a2
		default:
			name = brand + ", " + a2
		}
	case brand != "":
		name = sub + ", " + brand
	case attr != "":
		if strings.HasPrefix(strings.ToLower(attr), runePrefix(strings.ToLower(sub), 8)) {
			name = attr
		} else {
			name = sub + ", " + lowerFirst(attr)
		}
	default:
		name = tasnifClean(t.MxikName)
	}
	name = strings.Trim(strings.TrimSpace(spacesRe.ReplaceAllString(name, " ")), " ,.")
	return runePrefix(name, 300)
}

// Brand — бренд для справочника брендов.
func (t TasnifItem) Brand() string { return prettyBrand(tasnifStrip(t.BrandName)) }

// IkpuPath — путь в классификаторе для подсказки: группа / класс / позиция / субпозиция.
func (t TasnifItem) IkpuPath() string {
	parts := []string{}
	for _, s := range []string{t.GroupName, t.ClassName, t.PositionName, t.SubPositionName} {
		if s = tasnifStrip(s); s != "" {
			parts = append(parts, s)
		}
	}
	return strings.Join(parts, " / ")
}

// CategoryByIkpu — категория, в которой лежит больше всего товаров общего
// каталога с той же субпозицией ИКПУ (11 цифр), иначе с той же позицией (8).
func CategoryByIkpu(ctx context.Context, q db.Querier, ikpu string) (string, bool, error) {
	if !ikpuRe.MatchString(ikpu) {
		return "", false, nil
	}
	for _, n := range []int{11, 8} {
		var id string
		err := q.QueryRow(ctx, `
			SELECT p.category_id FROM products p JOIN categories c ON c.id = p.category_id AND c.is_active
			WHERE p.network_id IS NULL AND p.attributes ? 'ikpu' AND (p.attributes ->> 'ikpu') LIKE $1 || '%'
			GROUP BY p.category_id ORDER BY count(*) DESC, p.category_id LIMIT 1`, ikpu[:n]).Scan(&id)
		if err == nil {
			return id, true, nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return "", false, err
		}
	}
	return "", false, nil
}

// CategoriesNearIkpu — категории товаров того же класса ИКПУ (5 цифр):
// подсказка для подбора категории.
func CategoriesNearIkpu(ctx context.Context, q db.Querier, ikpu string, limit int) ([]string, error) {
	if !ikpuRe.MatchString(ikpu) {
		return nil, nil
	}
	rows, err := q.Query(ctx, `
		SELECT p.category_id::text FROM products p JOIN categories c ON c.id = p.category_id AND c.is_active
		WHERE p.network_id IS NULL AND p.attributes ? 'ikpu' AND (p.attributes ->> 'ikpu') LIKE $1 || '%'
		GROUP BY p.category_id ORDER BY count(*) DESC LIMIT $2`, ikpu[:5], limit)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

// ProductByBarcode — товар с этим штрихкодом (любой сети) или пусто.
func ProductByBarcode(ctx context.Context, q db.Querier, code string) (string, error) {
	var id string
	err := q.QueryRow(ctx, `SELECT product_id FROM product_barcodes WHERE barcode = $1`, code).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return id, err
}

// NewCategory — категория, которую создаёт магазин при добавлении товара:
// подкатегория в существующем разделе (ParentID) или в новом (ParentName).
type NewCategory struct {
	ParentID     *string `json:"parent_id"`
	ParentName   string  `json:"parent_name"`
	ParentNameUz string  `json:"parent_name_uz"`
	Name         string  `json:"name"`
	NameUz       string  `json:"name_uz"`
}

// EnsureCategory — найти по названию или создать категорию (и раздел).
func EnsureCategory(ctx context.Context, tx pgx.Tx, in NewCategory) (string, error) {
	name := strings.TrimSpace(in.Name)
	if name == "" || utf8.RuneCountInString(name) > 100 {
		return "", apperr.Validation("new_category.name: от 1 до 100 символов").Uz("new_category.name: 1 dan 100 belgigacha")
	}
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('categories:tree'))`); err != nil {
		return "", err
	}
	path := []string{name}
	pathUz := []string{strings.TrimSpace(in.NameUz)}
	refs := importRefs{brands: map[string]string{}, cats: map[string]string{}, units: map[string]string{}}
	if in.ParentID != nil && *in.ParentID != "" {
		var parentName string
		err := tx.QueryRow(ctx, `SELECT name FROM categories WHERE id::text = $1 AND is_active AND parent_id IS NULL`, *in.ParentID).Scan(&parentName)
		if errors.Is(err, pgx.ErrNoRows) {
			return "", apperr.Validation("new_category.parent_id: раздел не найден").Uz("new_category.parent_id: boʻlim topilmadi")
		}
		if err != nil {
			return "", err
		}
		refs.cats["/"+strings.ToLower(parentName)] = *in.ParentID
		path = []string{parentName, name}
		pathUz = []string{"", strings.TrimSpace(in.NameUz)}
	} else if p := strings.TrimSpace(in.ParentName); p != "" {
		if utf8.RuneCountInString(p) > 100 {
			return "", apperr.Validation("new_category.parent_name: до 100 символов").Uz("new_category.parent_name: 100 belgigacha")
		}
		path = []string{p, name}
		pathUz = []string{strings.TrimSpace(in.ParentNameUz), strings.TrimSpace(in.NameUz)}
	}
	return importCategory(ctx, tx, refs, path, pathUz)
}

// TasnifProduct — товар общего каталога из записи ИКПУ.
type TasnifProduct struct {
	Item       TasnifItem
	CategoryID string
	NameUz     string
	Image      string
	StoreID    string
	// UnitID — единица, выбранная магазином; пусто — шт (кг для весовых).
	UnitID string
}

// CreateTasnifProduct — создать товар общего каталога (штрихкод, ИКПУ, бренд,
// фото). Штрихкод должен быть свободен — проверяет вызывающий.
func CreateTasnifProduct(ctx context.Context, tx pgx.Tx, in TasnifProduct) (string, error) {
	it := in.Item
	if err := it.Validate(); err != nil {
		return "", err
	}
	var ok bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM categories WHERE id::text = $1 AND is_active)`, in.CategoryID).Scan(&ok); err != nil {
		return "", err
	}
	if !ok {
		return "", apperr.Validation("category_id: категория не найдена").Uz("category_id: kategoriya topilmadi")
	}
	refs := importRefs{brands: map[string]string{}, cats: map[string]string{}, units: map[string]string{}}
	unitID := strings.TrimSpace(in.UnitID)
	if unitID != "" {
		var ok bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM units WHERE id::text = $1 AND is_active)`, unitID).Scan(&ok); err != nil {
			return "", err
		}
		if !ok {
			return "", apperr.Validation("unit_id: единица не найдена").Uz("unit_id: oʻlchov birligi topilmadi")
		}
	} else {
		var err error
		if unitID, err = importUnit(ctx, tx, refs, it.Unit()); err != nil {
			return "", err
		}
	}
	var brandID *string
	if b := it.Brand(); b != "" {
		id, err := importBrand(ctx, tx, refs, b)
		if err != nil {
			return "", err
		}
		brandID = &id
	}
	attrs := map[string]any{"source": "tasnif.soliq.uz", "ikpu": it.Ikpu(), "ikpu_name": tasnifClean(it.MxikName)}
	if it.Marked() {
		attrs["marked"] = true
	}
	if in.StoreID != "" {
		attrs["added_by_store"] = in.StoreID
	}
	images := []string{}
	if in.Image != "" {
		images = append(images, in.Image)
	}
	var id string
	if err := tx.QueryRow(ctx, `
		INSERT INTO products (name, description, brand_id, category_id, unit_id, attributes, name_uz, description_uz, images)
		VALUES ($1, '', $2, $3, $4, $5, $6, '', $7) RETURNING id`,
		it.Name(), brandID, in.CategoryID, unitID, attrs, runePrefix(strings.TrimSpace(in.NameUz), 300), images).Scan(&id); err != nil {
		return "", err
	}
	if code := it.Barcode(); code != "" {
		if _, err := tx.Exec(ctx, `INSERT INTO product_barcodes (barcode, product_id) VALUES ($1, $2)`, code, id); err != nil {
			return "", err
		}
	}
	return id, nil
}
