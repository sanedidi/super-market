package catalog

import (
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Чистка названия без ИИ (автонормализация каталога и товары из ИКПУ):
//   - у еды и напитков убирается тип из классификатора перед брендом:
//     «Безалкогольные напитки Coca-Cola, 0.15 л» → «Coca-Cola, 0,15 л»;
//   - упаковка из ИКПУ («Полиэтиленовый пакет», «алюминиевая банка») убирается;
//   - вес в конце — в одном виде: «150г», «62 гр», «1.0л» → «150 г», «62 г», «1 л».

// FoodIkpu — товар из групп ИКПУ 001–022 (продукты питания и напитки).
// known = false — кода нет или он неверный.
func FoodIkpu(ikpu string) (food, known bool) {
	if !ikpuRe.MatchString(ikpu) {
		return false, false
	}
	g, err := strconv.Atoi(ikpu[:3])
	if err != nil {
		return false, false
	}
	return g >= 1 && g <= 22, true
}

// SplitTypePrefix — тип перед брендом: «Безалкогольные напитки Coca-Cola, 0,15 л»
// → «Безалкогольные напитки», «Coca-Cola, 0,15 л». Без бренда в названии или
// если название начинается с бренда — prefix пустой.
func SplitTypePrefix(name, brand string) (prefix, rest string) {
	brand = strings.TrimSpace(brand)
	if brand == "" {
		return "", name
	}
	i := indexFold(name, brand)
	if i <= 0 {
		return "", name
	}
	// Бренд — отдельное слово: перед ним пробел, после — конец, пробел или знак.
	before, _ := utf8.DecodeLastRuneInString(name[:i])
	if !unicode.IsSpace(before) {
		return "", name
	}
	if after, _ := utf8.DecodeRuneInString(name[i+len(brand):]); after != utf8.RuneError && (unicode.IsLetter(after) || unicode.IsDigit(after)) {
		return "", name
	}
	prefix = strings.TrimSpace(name[:i])
	if prefix == "" || !hasLetter(prefix) {
		return "", name
	}
	return prefix, name[i:]
}

// indexFold — первое вхождение sub в s без учёта регистра (байтовый индекс в s).
func indexFold(s, sub string) int {
	if sub == "" {
		return -1
	}
	for i := range s {
		if len(s)-i < len(sub) {
			break
		}
		// Сравниваем по рунам: регистр кириллицы меняет длину не бывает, но
		// сравниваем ровно столько байт, сколько в префиксе s той же длины в рунах.
		n := utf8.RuneCountInString(sub)
		j, k := i, 0
		for k < n && j < len(s) {
			_, w := utf8.DecodeRuneInString(s[j:])
			j += w
			k++
		}
		if k == n && strings.EqualFold(s[i:j], sub) {
			return i
		}
	}
	return -1
}

func hasLetter(s string) bool {
	for _, r := range s {
		if unicode.IsLetter(r) {
			return true
		}
	}
	return false
}

var (
	// Упаковка из ИКПУ: «Полиэтиленовый пакет», «в ПЭТ упаковке», «алюминиевая банка».
	packRe  = regexp.MustCompile(`(?i)(^|[\s,(])(?:в\s+)?(?:полиэтиленов|пластиков|стеклянн|алюминиев|жестян|картонн|металлическ|пэт|пэ|ж/б)[а-яё]*\s+(?:пакет|бутыл|банк|коробк|упаковк|контейнер|пачк|стакан|туб|флакон|ёмкост|емкост)[а-яё]*`)
	tetraRe = regexp.MustCompile(`(?i)(^|[\s,(])(?:тетра\s*-?\s*пак|tetra\s*-?\s*pak|дой\s*-?\s*пак|doy\s*-?\s*pack)`)
	// Вес, объём или количество в конце.
	tailWeightRe = regexp.MustCompile(`(?i)[\s,]*(\d+(?:[.,]\d+)?)\s*(кг|гр|грамм|г|мл|л|шт|kg|gr|g|ml|l)\.?\s*$`)
	emptyParens  = regexp.MustCompile(`\(\s*[,;]?\s*\)`)
	spaceComma   = regexp.MustCompile(`\s+,`)
	doubleComma  = regexp.MustCompile(`,\s*,+`)
)

var unitRu = map[string]string{
	"кг": "кг", "kg": "кг",
	"гр": "г", "грамм": "г", "г": "г", "gr": "г", "g": "г",
	"мл": "мл", "ml": "мл",
	"л": "л", "l": "л",
	"шт": "шт",
}

// FormatAmount — «1.0» → «1», «0.150» → «0,15», «0,5» → «0,5».
func FormatAmount(num string) string {
	num = strings.ReplaceAll(num, ",", ".")
	if strings.Contains(num, ".") {
		num = strings.TrimRight(strings.TrimRight(num, "0"), ".")
	}
	if num == "" {
		num = "0"
	}
	return strings.ReplaceAll(num, ".", ",")
}

// NormalizeTailWeight — вес в конце в виде «, 150 г». Без веса — как есть.
func NormalizeTailWeight(name string) string {
	m := tailWeightRe.FindStringSubmatchIndex(name)
	if m == nil {
		return name
	}
	rest := strings.TrimRight(strings.TrimSpace(name[:m[0]]), " ,")
	if rest == "" {
		return name
	}
	unit := unitRu[strings.ToLower(name[m[4]:m[5]])]
	w := FormatAmount(name[m[2]:m[3]]) + " " + unit
	// «… по 100 г» и «4 шт. по 100 г» — вес часть фразы, запятую не ставим.
	lower := strings.ToLower(rest)
	if strings.HasSuffix(lower, " по") || strings.HasSuffix(lower, " x") || strings.HasSuffix(lower, " х") || strings.HasSuffix(lower, "*") {
		return rest + " " + w
	}
	return rest + ", " + w
}

// StripPackaging — убрать слова упаковки из ИКПУ.
func StripPackaging(name string) string {
	name = packRe.ReplaceAllString(name, "$1")
	name = tetraRe.ReplaceAllString(name, "$1")
	return tidy(name)
}

func tidy(s string) string {
	s = emptyParens.ReplaceAllString(s, "")
	s = spacesRe.ReplaceAllString(s, " ")
	s = spaceComma.ReplaceAllString(s, ",")
	s = doubleComma.ReplaceAllString(s, ",")
	return strings.Trim(strings.TrimSpace(s), " ,.;")
}

// CleanName — название без ИИ: у еды (food) без типа перед брендом, без
// упаковки, с весом в конце в одном виде.
func CleanName(name, brand string, food bool) string {
	name = tidy(name)
	if food {
		if _, rest := SplitTypePrefix(name, brand); rest != name {
			name = upperFirstLetter(rest)
		}
	}
	out := tidy(NormalizeTailWeight(StripPackaging(name)))
	if out == "" {
		return name
	}
	return out
}

// upperFirstLetter — первая буква заглавная, если название начинается с
// буквы в нижнем регистре кириллицей («не замороженные…» не бывает после
// бренда, но бренд может быть «lay's» — латиницу не трогаем).
func upperFirstLetter(s string) string {
	r, n := utf8.DecodeRuneInString(s)
	if unicode.Is(unicode.Cyrillic, r) && unicode.IsLower(r) {
		return string(unicode.ToUpper(r)) + s[n:]
	}
	return s
}
