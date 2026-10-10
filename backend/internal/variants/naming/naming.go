// Package naming разбирает названия товаров на линейку, вкус и вес:
// «Чипсы Lay's Пицца Пепперони, 150 г» → линейка «Чипсы Lay's»,
// вкус «Пицца Пепперони», вес «150 г». Это запасной способ собрать группы
// вариаций, когда ИИ-сервис не подключён, и разбор для товара, который
// супер-админ добавил в группу руками.
package naming

import (
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Item — товар для разбора.
type Item struct {
	ID    string
	Name  string // по-русски
	Brand string // название бренда, может быть пустым
}

// Parsed — вариация, найденная в названии.
type Parsed struct {
	ID         string
	Weight     string // «150 г», пусто — веса в названии нет
	WeightUz   string // «150 g»
	WeightSort float64
	Flavor     string // «Пицца Пепперони»
	Included   bool
	Note       string
}

// Group — предложенная группа.
type Group struct {
	Name  string // «Чипсы Lay's»
	Items []Parsed
}

// Вес в конце названия: «, 150 г», «0,5 л», «1.5L», «10 шт».
var weightRe = regexp.MustCompile(`(?i)[,\s]*(\d+(?:[.,]\d+)?)\s*(кг|гр|г|мл|л|шт|kg|g|ml|l)\.?\s*$`)

var units = map[string]struct {
	ru, uz string
	mult   float64
}{
	"г": {"г", "g", 1}, "гр": {"г", "g", 1}, "g": {"г", "g", 1},
	"кг": {"кг", "kg", 1000}, "kg": {"кг", "kg", 1000},
	"мл": {"мл", "ml", 1}, "ml": {"мл", "ml", 1},
	"л": {"л", "l", 1000}, "l": {"л", "l", 1000},
	"шт": {"шт", "dona", 1},
}

// Weight — вес из конца названия и название без него.
func Weight(name string) (rest, weight, weightUz string, sortKey float64) {
	name = strings.TrimSpace(name)
	m := weightRe.FindStringSubmatchIndex(name)
	if m == nil {
		return strings.TrimRight(name, " ,"), "", "", 0
	}
	num := name[m[2]:m[3]]
	u := units[strings.ToLower(name[m[4]:m[5]])]
	rest = strings.TrimRight(strings.TrimSpace(name[:m[0]]), " ,")
	if rest == "" {
		return strings.TrimRight(name, " ,"), "", "", 0
	}
	v, _ := strconv.ParseFloat(strings.ReplaceAll(num, ",", "."), 64)
	label := strings.ReplaceAll(num, ".", ",")
	return rest, label + " " + u.ru, label + " " + u.uz, v * u.mult
}

// WeightSort — ключ сортировки для подписи веса, которую ввёл человек.
func WeightSort(label string) float64 {
	_, _, _, k := Weight("x " + label)
	return k
}

// WeightUz — подпись веса по-узбекски: «150 г» → «150 g».
func WeightUz(label string) string {
	_, w, uz, _ := Weight("x " + label)
	if w == "" {
		return label
	}
	return uz
}

// Flavor — вкус товара относительно названия группы: «Чипсы Lay's
// Пицца Пепперони, 150 г» и «Чипсы Lay's» → «Пицца Пепперони».
func Flavor(name, group string) string {
	rest, _, _, _ := Weight(name)
	words, base := strings.Fields(rest), strings.Fields(group)
	i := 0
	for i < len(words) && i < len(base) && fold(words[i]) == fold(base[i]) {
		i++
	}
	return Capitalize(trimFlavor(strings.Join(words[i:], " ")))
}

// Suggest собирает группы из товаров одного бренда и категории: линейка —
// слова названия до бренда включительно, вкус — остаток без веса. Группа —
// от двух товаров с разными весом или вкусом.
func Suggest(items []Item) []Group {
	type parsed struct {
		Parsed
		line string
		key  string
	}
	byLine := map[string][]parsed{}
	var order []string
	for _, it := range items {
		rest, w, wuz, ws := Weight(it.Name)
		words := strings.Fields(rest)
		n := brandEnd(words, it.Brand)
		if n == 0 || n >= len(words) {
			continue
		}
		line := strings.Join(words[:n], " ")
		key := fold(line)
		if _, ok := byLine[key]; !ok {
			order = append(order, key)
		}
		byLine[key] = append(byLine[key], parsed{
			Parsed: Parsed{ID: it.ID, Weight: w, WeightUz: wuz, WeightSort: ws,
				Flavor: Capitalize(trimFlavor(strings.Join(words[n:], " "))), Included: true},
			line: line,
		})
	}
	var out []Group
	for _, key := range order {
		ps := byLine[key]
		if len(ps) < 2 {
			continue
		}
		seen := map[string]bool{}
		g := Group{Name: ps[0].line}
		distinct := 0
		for _, p := range ps {
			k := fold(p.Weight) + "|" + fold(p.Flavor)
			if seen[k] {
				p.Included = false
				p.Note = "Похоже на дубль: тот же вес и вкус"
			} else {
				seen[k] = true
				distinct++
			}
			g.Items = append(g.Items, p.Parsed)
		}
		if distinct < 2 {
			continue
		}
		sort.SliceStable(g.Items, func(i, j int) bool {
			if g.Items[i].WeightSort != g.Items[j].WeightSort {
				return g.Items[i].WeightSort < g.Items[j].WeightSort
			}
			return fold(g.Items[i].Flavor) < fold(g.Items[j].Flavor)
		})
		out = append(out, g)
	}
	return out
}

// brandEnd — сколько первых слов названия составляют линейку: до бренда
// включительно. Без бренда в названии — первые два слова.
func brandEnd(words []string, brand string) int {
	bw := strings.Fields(brand)
	if len(bw) > 0 {
		for i := 0; i+len(bw) <= len(words); i++ {
			ok := true
			for j := range bw {
				if fold(words[i+j]) != fold(bw[j]) {
					ok = false
					break
				}
			}
			if ok {
				return i + len(bw)
			}
		}
	}
	if len(words) > 2 {
		return 2
	}
	return 0
}

// trimFlavor убирает служебные слова в начале вкуса: «со вкусом сыра» → «сыра».
func trimFlavor(s string) string {
	s = strings.TrimSpace(strings.Trim(s, ",.-– "))
	low := strings.ToLower(s)
	for _, p := range []string{"со вкусом ", "с вкусом ", "вкус "} {
		if strings.HasPrefix(low, p) {
			return strings.TrimSpace(s[len(p):])
		}
	}
	return s
}

// Capitalize — первая буква заглавная.
func Capitalize(s string) string {
	r, n := utf8.DecodeRuneInString(s)
	if n == 0 {
		return s
	}
	return string(unicode.ToUpper(r)) + s[n:]
}

// fold — сравнение без регистра и с разными апострофами (Lay's / Lay’s).
func fold(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	return strings.NewReplacer("’", "'", "ʼ", "'", "`", "'", "ё", "е").Replace(s)
}

// Fold — ключ для сравнения подписей веса и вкуса.
func Fold(s string) string { return fold(s) }
