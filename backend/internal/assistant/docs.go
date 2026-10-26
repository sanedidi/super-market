package assistant

import (
	_ "embed"
	"sort"
	"strings"
	"sync"
)

// Документация API для модели: копия docs/api.md (тест TestAssistantDocsCopy
// следит, чтобы копия не отставала). Модель ищет в ней нужный раздел
// инструментом search_docs, а список маршрутов берёт из роутера (list_routes).

//go:embed api.md
var apiDocs string

type docSection struct {
	title string
	body  string
	lower string
}

var (
	docsOnce sync.Once
	docsList []docSection
)

// sections — документация по заголовкам (##, ###).
func sections() []docSection {
	docsOnce.Do(func() {
		cur := docSection{title: "API"}
		var b strings.Builder
		flush := func() {
			cur.body = strings.TrimSpace(b.String())
			if cur.body != "" {
				cur.lower = strings.ToLower(cur.title + "\n" + cur.body)
				docsList = append(docsList, cur)
			}
			b.Reset()
		}
		for _, line := range strings.Split(apiDocs, "\n") {
			if strings.HasPrefix(line, "## ") || strings.HasPrefix(line, "### ") {
				flush()
				cur = docSection{title: strings.TrimLeft(line, "# ")}
				continue
			}
			b.WriteString(line)
			b.WriteByte('\n')
		}
		flush()
	})
	return docsList
}

// searchDocs — разделы, где чаще всего встречаются слова запроса; не длиннее
// maxChars всего.
func searchDocs(query string, maxChars int) string {
	words := []string{}
	for _, w := range strings.Fields(strings.ToLower(query)) {
		w = strings.Trim(w, "«»\"'(),.;:")
		if len([]rune(w)) >= 3 {
			words = append(words, w)
		}
	}
	if len(words) == 0 {
		return "уточните запрос: 2–5 ключевых слов, например «приход документ строки» или «остатки склад»"
	}
	type hit struct {
		sec   docSection
		score int
	}
	hits := []hit{}
	for _, sec := range sections() {
		score := 0
		for _, w := range words {
			n := strings.Count(sec.lower, w)
			if n > 0 {
				score += 3 + min(n, 20)
				if strings.Contains(strings.ToLower(sec.title), w) {
					score += 10
				}
			}
		}
		if score > 0 {
			hits = append(hits, hit{sec, score})
		}
	}
	if len(hits) == 0 {
		return "ничего не нашёл — попробуйте другие слова или list_routes"
	}
	sort.SliceStable(hits, func(i, j int) bool { return hits[i].score > hits[j].score })
	var b strings.Builder
	for i, h := range hits {
		if i >= 4 || b.Len() >= maxChars {
			break
		}
		body := h.sec.body
		room := maxChars - b.Len()
		if len(body) > room {
			body = cut(body, room) + "\n…(обрезано)"
		}
		b.WriteString("## " + h.sec.title + "\n" + body + "\n\n")
	}
	return b.String()
}

// cut — не рвать UTF-8.
func cut(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !isRuneStart(s[n]) {
		n--
	}
	return s[:n]
}

func isRuneStart(b byte) bool { return b&0xC0 != 0x80 }
