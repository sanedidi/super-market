package productsearch

import (
	"strings"
	"unicode"
)

// Транслитерация запроса — как SQL-функции uz_lat2cyr и uz_cyr2lat
// (миграция 0043), которыми строится search_text. Названия товаров уже
// лежат в обеих письменностях, но запрос «kola» (латиницей) не совпадает ни
// с «coca cola», ни с «кока кола»; в кириллице — «кола» — совпадает.

var lat2cyrPairs = strings.NewReplacer("o'", "ў", "g'", "ғ", "sh", "ш", "ch", "ч", "yo", "йо", "yu", "ю", "ya", "я", "ye", "е")

var lat2cyrRunes = func() map[rune]rune {
	from, to := []rune("abdefghijklmnopqrstuvxyzcw"), []rune("абдефгҳижклмнопқрстувхйзкв")
	m := make(map[rune]rune, len(from))
	for i := range from {
		m[from[i]] = to[i]
	}
	return m
}()

var cyr2latPairs = strings.NewReplacer("ш", "sh", "щ", "sh", "ч", "ch", "ё", "yo", "ю", "yu", "я", "ya", "ў", "o'", "ғ", "g'")

var cyr2latRunes = func() map[rune]rune {
	from, to := []rune("абвгдежзийклмнопрстуфхцыэқҳ"), []rune("abvgdejziyklmnoprstufxsieqh")
	m := make(map[rune]rune, len(from))
	for i := range from {
		m[from[i]] = to[i]
	}
	return m
}()

// Lat2Cyr — латиница → кириллица (kola → кола, sut → сут).
func Lat2Cyr(s string) string {
	s = strings.ToLower(s)
	s = strings.Map(func(r rune) rune {
		if strings.ContainsRune("ʻʼ’‘`", r) {
			return '\''
		}
		return r
	}, s)
	s = lat2cyrPairs.Replace(s)
	return strings.Map(func(r rune) rune {
		if r == '\'' {
			return -1
		}
		if t, ok := lat2cyrRunes[r]; ok {
			return t
		}
		return r
	}, s)
}

// Cyr2Lat — кириллица → латиница (молоко → moloko).
func Cyr2Lat(s string) string {
	s = cyr2latPairs.Replace(strings.ToLower(s))
	return strings.Map(func(r rune) rune {
		if r == 'ъ' || r == 'ь' {
			return -1
		}
		if t, ok := cyr2latRunes[r]; ok {
			return t
		}
		return r
	}, s)
}

// otherScript — запрос в другой письменности, если он целиком в одной
// (латиница или кириллица) и от этого что-то меняется.
func otherScript(s string) (string, bool) {
	var lat, cyr bool
	for _, r := range strings.ToLower(s) {
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
	if lat {
		return Lat2Cyr(s), true
	}
	return Cyr2Lat(s), true
}
