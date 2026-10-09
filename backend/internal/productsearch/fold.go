// Package productsearch — быстрый поиск товаров по названию и штрихкоду.
//
// У товара есть колонка search_text (миграция 0043): все написания
// названия — русское и узбекское, как есть и в другой письменности, —
// в одной нормализованной строке с триграммным индексом. Пакет строит
// условия, которые этот индекс используют, и выбирает способ поиска:
// штрихкод → слова → слова в другой раскладке → слова с исправленными
// опечатками (по словарю слов каталога search_words).
package productsearch

import (
	"strings"
	"unicode"
)

// foldRunes — то же, что translate() в SQL-функции search_fold.
var foldRunes = map[rune]rune{'ё': 'е', 'ў': 'у', 'қ': 'к', 'ғ': 'г', 'ҳ': 'х'}

// dropRunes — апострофы (oʻ, o', o‘ … → o).
const dropRunes = "ʻʼ’‘`'"

// Fold — нормализация текста, как SQL-функция search_fold: нижний регистр,
// ё→е, узбекские буквы кириллицы → русские, без апострофов, всё кроме букв
// и цифр — один пробел.
func Fold(s string) string {
	var b strings.Builder
	space := false
	for _, r := range strings.ToLower(s) {
		if strings.ContainsRune(dropRunes, r) {
			continue
		}
		if m, ok := foldRunes[r]; ok {
			r = m
		}
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			if space && b.Len() > 0 {
				b.WriteByte(' ')
			}
			space = false
			b.WriteRune(r)
		} else {
			space = true
		}
	}
	return b.String()
}

// Раскладки клавиатуры: одна и та же клавиша.
const (
	layoutEn = "qwertyuiop[]asdfghjkl;'zxcvbnm,.`"
	layoutRu = "йцукенгшщзхъфывапролджэячсмитьбюё"
)

var enToRu, ruToEn = func() (map[rune]rune, map[rune]rune) {
	en, ru := []rune(layoutEn), []rune(layoutRu)
	a, b := make(map[rune]rune, len(en)), make(map[rune]rune, len(en))
	for i := range en {
		a[en[i]], b[ru[i]] = ru[i], en[i]
	}
	return a, b
}()

// SwapLayout — текст, набранный не в той раскладке: «vjkjrj» → «молоко»,
// «сщсф» → «coca». ok = false, если менять нечего (смесь латиницы и
// кириллицы или нет букв).
func SwapLayout(s string) (string, bool) {
	s = strings.ToLower(s)
	var lat, cyr bool
	for _, r := range s {
		switch {
		case r < unicode.MaxASCII && unicode.IsLetter(r):
			lat = true
		case unicode.Is(unicode.Cyrillic, r):
			cyr = true
		}
	}
	if lat == cyr {
		return "", false
	}
	m := enToRu
	if cyr {
		m = ruToEn
	}
	out := []rune(s)
	for i, r := range out {
		if t, ok := m[r]; ok {
			out[i] = t
		}
	}
	return string(out), true
}

// LooksLikeBarcode — строка может быть штрихкодом (как CHECK в
// product_barcodes: 4–32 латинских букв, цифр или «-») и в ней есть цифра.
func LooksLikeBarcode(s string) bool {
	if n := len(s); n < 4 || n > 32 {
		return false
	}
	digit := false
	for _, r := range s {
		switch {
		case r >= '0' && r <= '9':
			digit = true
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r == '-':
		default:
			return false
		}
	}
	return digit
}
