package start

import (
	"math"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// Тот же товар или нет. Правила (по порядку):
//  1. Штрихкод совпал (с точностью до ведущих нулей, см. barcode_key) — тот же.
//  2. Штрихкоды разные — решают разобранные поля, а не похожесть названия:
//     бренд, объём/вес, количество в упаковке и прочие числа (№110, 3в1)
//     должны не противоречить друг другу, а «ядро» названия (без чисел и
//     единиц) — совпадать почти полностью (CoreMin). Отличается объём или
//     фасовка — это точно разные товары: «Piala, 10 пакетиков» и «Piala,
//     25 пакетиков». Совпало всё, а штрихкод другой — скорее всего, тот же
//     товар с другого завода или в новой упаковке: решает магазин («Это он»
//     привязывает штрихкод к товару).
// Похожесть названия (pg_trgm) только отбирает кандидатов — CandidateMin.

const (
	// CandidateMin — с какой похожести названий (pg_trgm) товар вообще
	// сравнивается по полям.
	CandidateMin = 0.45
	// CoreMin — похожесть «ядер» названий (без чисел и единиц), с которой
	// товары с одинаковыми полями считаются одним товаром.
	CoreMin = 0.6
)

// coreSQL — «ядро» названия для сравнения в SQL: без чисел с единицами.
func coreSQL(expr string) string {
	return `regexp_replace(lower(` + expr + `), '[0-9]+([.,][0-9]+)?\s*(мл|ml|литр[а-я]*|л|l|гр|г|g|кг|kg|шт|штук[а-я]*|пакетик[а-я]*|пак[а-я]*|таб[а-я]*|капс[а-я]*|рулон[а-я]*|dona|ta)?\.?', ' ', 'g')`
}

// Spec — разобранные из названия (и ответа Super Market) поля товара.
type Spec struct {
	Size float64  // объём в мл или вес в г; 0 — не указан
	Base string   // "ml" или "g"
	Pack int      // штук в упаковке; 0 — не указано
	Nums []string // прочие числа названия по порядку (№110, 3в1)
}

var (
	sizeRe = regexp.MustCompile(`(?i)(\d+(?:[.,]\d+)?)\s*(мл|ml|литр[а-я]*|л|l|гр|г|g|кг|kg)\.?(?:[^\p{L}]|$)`)
	packRe = regexp.MustCompile(`(?i)(\d+)\s*(?:шт|штук[а-я]*|пакетик[а-я]*|пак[а-я]*|таб[а-я]*|капс[а-я]*|рулон[а-я]*|салфет[а-я]*|dona|ta)\.?(?:[^\p{L}]|$)|(\d+)\s*[xх×]\s*\d`)
	numRe  = regexp.MustCompile(`\d+(?:[.,]\d+)?`)
)

func num(s string) float64 {
	f, _ := strconv.ParseFloat(strings.ReplaceAll(s, ",", "."), 64)
	return f
}

// ParseSpec — объём/вес, фасовка и прочие числа из названия.
func ParseSpec(name string) Spec {
	var sp Spec
	used := make([]bool, len(name))
	mark := func(a, b int) {
		for i := a; i < b; i++ {
			used[i] = true
		}
	}
	if m := sizeRe.FindStringSubmatchIndex(name); m != nil {
		v := num(name[m[2]:m[3]])
		switch u := strings.ToLower(name[m[4]:m[5]]); {
		case u == "мл" || u == "ml":
			sp.Size, sp.Base = v, "ml"
		case u == "л" || u == "l" || strings.HasPrefix(u, "литр"):
			sp.Size, sp.Base = v*1000, "ml"
		case u == "кг" || u == "kg":
			sp.Size, sp.Base = v*1000, "g"
		default:
			sp.Size, sp.Base = v, "g"
		}
		mark(m[2], m[3])
	}
	if m := packRe.FindStringSubmatchIndex(name); m != nil {
		a, b := m[2], m[3]
		if a < 0 {
			a, b = m[4], m[5]
		}
		sp.Pack, _ = strconv.Atoi(name[a:b])
		mark(a, b)
	}
	for _, m := range numRe.FindAllStringIndex(name, -1) {
		if !used[m[0]] {
			sp.Nums = append(sp.Nums, strings.ReplaceAll(name[m[0]:m[1]], ",", "."))
		}
	}
	return sp
}

// specOf — поля карточки: из названия, недостающее — из ответа Super Market.
func specOf(name, size string, pack int) Spec {
	sp := ParseSpec(name)
	if sp.Base == "" && size != "" {
		if a := ParseSpec(size); a.Base != "" {
			sp.Size, sp.Base = a.Size, a.Base
		}
	}
	if sp.Pack == 0 && pack > 0 {
		sp.Pack = pack
	}
	return sp
}

// Conflicts — поля говорят, что это точно разные товары. Поле, которого нет
// у одного из товаров, не противоречит (решит магазин).
func (a Spec) Conflicts(b Spec) bool {
	if a.Base != "" && b.Base != "" {
		if a.Base != b.Base || math.Abs(a.Size-b.Size) > 0.001*math.Max(a.Size, b.Size) {
			return true
		}
	}
	if a.Pack > 0 && b.Pack > 0 && a.Pack != b.Pack {
		return true
	}
	if len(a.Nums) > 0 && len(b.Nums) > 0 {
		x, y := slices.Clone(a.Nums), slices.Clone(b.Nums)
		slices.Sort(x)
		slices.Sort(y)
		if !slices.Equal(x, y) {
			return true
		}
	}
	return false
}

// brandConflicts — у обоих товаров бренд известен и он разный.
func brandConflicts(aID *string, aName string, bID *string, bName string) bool {
	if aID != nil && bID != nil {
		return *aID != *bID
	}
	a, b := strings.ToLower(strings.TrimSpace(aName)), strings.ToLower(strings.TrimSpace(bName))
	return a != "" && b != "" && a != b
}

// ------------------------------------------------------------ штрихкоды

func digits(s string) bool {
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return s != ""
}

// BarcodeKey — штрихкод для сравнения (как barcode_key в БД).
func BarcodeKey(code string) string {
	code = strings.TrimSpace(code)
	if digits(code) && len(code) >= 8 && len(code) <= 14 {
		if k := strings.TrimLeft(code, "0"); k != "" {
			return k
		}
		return "0"
	}
	return code
}

// BarcodeValid — контрольная цифра EAN-8, UPC-A, EAN-13, GTIN-14 сходится.
// Коды других форматов проверить нельзя — считаются верными.
func BarcodeValid(code string) bool {
	code = strings.TrimSpace(code)
	if !digits(code) {
		return true
	}
	switch len(code) {
	case 8, 12, 13, 14:
	default:
		return true
	}
	sum := 0
	for i := len(code) - 2; i >= 0; i-- {
		d := int(code[i] - '0')
		if (len(code)-2-i)%2 == 0 {
			d *= 3
		}
		sum += d
	}
	return (10-sum%10)%10 == int(code[len(code)-1]-'0')
}

// InternalBarcode — внутренний код магазина (EAN-13 на 2…, UPC-A на 2… и 4…):
// у разных сетей один такой код — разные товары.
func InternalBarcode(code string) bool {
	code = strings.TrimSpace(code)
	if !digits(code) {
		return false
	}
	return (len(code) == 13 && code[0] == '2') || (len(code) == 12 && (code[0] == '2' || code[0] == '4'))
}
