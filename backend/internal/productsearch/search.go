package productsearch

import (
	"context"
	"fmt"
	"strings"
	"unicode"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

// Как пользоваться (s — алиас таблицы product_search, p — products):
//
//	m, err := productsearch.Resolve(ctx, pool, query, productsearch.Scope{NetworkID: net})
//	if m.Empty() { … ничего не нашлось … }
//	args := []any{…свои параметры…}
//	sql := `… FROM product_search s JOIN products p ON p.id = s.product_id
//	        WHERE ` + scope.Where("s", &args) + ` AND ` + m.Where("s", &args) + `
//	        ORDER BY ` + m.Rank("s", &args) + ` DESC, s.score DESC, ` + NameOrder("s") + `…`
//	rows, err := pool.Query(ctx, sql, productsearch.Args(args)...)
//
// Для списков по products — условие p.id IN (…): m.IDs(&args).

// Args — аргументы запроса с поиском: план строится заново под конкретные
// слова (неименованный prepared statement). С кэшем statement'ов Postgres
// после пяти запусков может перейти на общий план, не знающий текста
// поиска, и перестать брать триграммный индекс — поиск опять становится
// перебором всего каталога.
func Args(args []any) []any {
	return append([]any{pgx.QueryExecModeCacheDescribe}, args...)
}

type kind int

const (
	kindNone kind = iota
	kindBarcode
	kindText
)

// Длина слова, с которой работает триграммный индекс.
const minIndexed = 3

// Не больше стольких слов запроса — остальные отбрасываются.
const maxWords = 6

// Слова короче не исправляются (опечатку в коротком слове не угадать).
const minFix = 4

// Match — выбранный способ поиска. Пустой Match ничего не находит.
type Match struct {
	kind    kind
	barcode string
	words   []string
}

// Empty — по запросу искать нечего (пустой запрос или ничего не нашлось).
func (m Match) Empty() bool { return m.kind == kindNone }

// Text — поиск по словам запроса без проверки, что что-то найдётся.
func Text(raw string) Match {
	words := strings.Fields(Fold(raw))
	if len(words) == 0 {
		return Match{}
	}
	if len(words) > maxWords {
		words = words[:maxWords]
	}
	return Match{kind: kindText, words: words}
}

func arg(args *[]any, v any) string {
	*args = append(*args, v)
	return fmt.Sprintf("$%d", len(*args))
}

// Where — условие «строка s таблицы product_search подходит под запрос».
// Значения добавляются в args, плейсхолдеры продолжают их нумерацию.
func (m Match) Where(s string, args *[]any) string {
	switch m.kind {
	case kindBarcode:
		return fmt.Sprintf("%s.product_id IN (SELECT pb.product_id FROM product_barcodes pb WHERE pb.barcode = %s)", s, arg(args, m.barcode))
	case kindText:
		var conds []string
		indexed := false
		for _, w := range m.words {
			if len([]rune(w)) >= minIndexed {
				conds = append(conds, fmt.Sprintf("%s.text LIKE %s", s, arg(args, "%"+w+"%")))
				indexed = true
			}
		}
		if !indexed {
			// Только короткие слова. Несколько («0,5», «3,2») — вся фраза
			// подстрокой, она уже от 3 символов и идёт по индексу; одно
			// («мо») — начало названия по b-tree индексу.
			if p := m.phrase(); len(m.words) > 1 && len([]rune(p)) >= minIndexed {
				return fmt.Sprintf("(%s.text LIKE %s)", s, arg(args, "%"+p+"%"))
			}
			p := arg(args, m.words[0]+"%")
			conds = append(conds, fmt.Sprintf("(%[1]s.name LIKE %[2]s OR %[1]s.name_uz LIKE %[2]s)", s, p))
		}
		for i, w := range m.words {
			if len([]rune(w)) >= minIndexed || (!indexed && i == 0) {
				continue
			}
			conds = append(conds, fmt.Sprintf("strpos(%s.text, %s) > 0", s, arg(args, w)))
		}
		return "(" + strings.Join(conds, " AND ") + ")"
	}
	return "false"
}

// IDs — подзапрос «id подходящих товаров» для условия p.id IN (…).
func (m Match) IDs(args *[]any) string {
	return "SELECT s.product_id FROM product_search s WHERE " + m.Where("s", args)
}

// Rank — насколько товар подходит (int, больше — выше в выдаче): название
// целиком, название начинается с запроса, какое-то слово начинается с него.
func (m Match) Rank(s string, args *[]any) string {
	switch m.kind {
	case kindBarcode:
		return "3::int" // не голое число: в ORDER BY оно стало бы номером колонки
	case kindText:
		p, w := m.phrase(), m.words[0]
		return fmt.Sprintf(`(CASE WHEN %[1]s.name = %[2]s OR %[1]s.name_uz = %[2]s THEN 3
			WHEN %[1]s.name LIKE %[3]s OR %[1]s.name_uz LIKE %[3]s THEN 2
			WHEN %[1]s.text LIKE %[4]s OR %[1]s.text LIKE %[5]s OR %[1]s.text LIKE %[6]s THEN 1 ELSE 0 END)`,
			s, arg(args, p), arg(args, p+"%"), arg(args, w+"%"), arg(args, "% "+w+"%"), arg(args, "%|"+w+"%"))
	}
	return "0::int"
}

// NameOrder — название для сортировки на языке запроса (как loc()).
func NameOrder(s string) string {
	return fmt.Sprintf("(CASE WHEN current_setting('app.lang', true) = 'uz' AND %[1]s.name_uz <> '' THEN %[1]s.name_uz ELSE %[1]s.name END)", s)
}

func (m Match) phrase() string { return strings.Join(m.words, " ") }

// Filter — условие для поиска по небольшому списку товаров p (строки
// документа, черновик): слова запроса или точный штрихкод, без выбора
// способа. Пустой запрос — "true".
func Filter(p, raw string, args *[]any) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "true"
	}
	conds := []string{}
	text := Text(raw)
	if !text.Empty() {
		conds = append(conds, fmt.Sprintf("EXISTS (SELECT 1 FROM product_search s WHERE s.product_id = %s.id AND %s)", p, text.Where("s", args)))
	}
	// И в другой письменности: «kola» находит «Coca-Cola» (через «кола»).
	if alt, ok := otherScript(raw); ok {
		if t := Text(alt); !t.Empty() && t.phrase() != text.phrase() {
			conds = append(conds, fmt.Sprintf("EXISTS (SELECT 1 FROM product_search s WHERE s.product_id = %s.id AND %s)", p, t.Where("s", args)))
		}
	}
	if LooksLikeBarcode(raw) {
		conds = append(conds, fmt.Sprintf("EXISTS (SELECT 1 FROM product_barcodes pb WHERE pb.product_id = %s.id AND pb.barcode = %s)", p, arg(args, raw)))
	}
	if len(conds) == 0 {
		return "false"
	}
	return "(" + strings.Join(conds, " OR ") + ")"
}

// Scope — какие товары видит тот, кто ищет.
type Scope struct {
	// NetworkID — общий каталог и товары этой сети; пусто — только общий каталог.
	NetworkID string
	// AllNetworks — товары всех сетей (супер-админ).
	AllNetworks bool
	// Inactive — и неактивные товары.
	Inactive bool
}

// Where — условие видимости для строки s таблицы product_search.
func (sc Scope) Where(s string, args *[]any) string {
	conds := []string{}
	if !sc.Inactive {
		conds = append(conds, s+".is_active")
	}
	switch {
	case sc.AllNetworks:
	case sc.NetworkID != "":
		conds = append(conds, fmt.Sprintf("(%[1]s.network_id IS NULL OR %[1]s.network_id = %[2]s::uuid)", s, arg(args, sc.NetworkID)))
	default:
		conds = append(conds, s+".network_id IS NULL")
	}
	if len(conds) == 0 {
		return "true"
	}
	return strings.Join(conds, " AND ")
}

// Resolve выбирает способ поиска — первый, который что-то находит среди
// видимых товаров: точный штрихкод → слова → слова в другой раскладке
// («vjkjrj» → «молоко») — это один запрос к базе; если ничего, — слова с
// исправленными опечатками («малоко» → «молоко»). Не нашлось ничего —
// пустой Match.
func Resolve(ctx context.Context, q db.Querier, raw string, sc Scope) (Match, error) {
	// Проверки «нашлось ли» — EXISTS: планировщик любит для них перебор
	// таблицы в надежде быстро встретить подходящую строку. Если слова
	// частые, но вместе не встречаются («молоко детский»), перебор проходит
	// всю таблицу. Индексы для всех проверок есть — перебор запрещаем.
	if b, ok := q.(interface {
		Begin(context.Context) (pgx.Tx, error)
	}); ok {
		tx, err := b.Begin(ctx)
		if err != nil {
			return Match{}, err
		}
		defer tx.Rollback(ctx) //nolint:errcheck // только чтение
		if _, err := tx.Exec(ctx, "SET LOCAL enable_seqscan = off"); err != nil {
			return Match{}, err
		}
		q = tx
	}
	return resolve(ctx, q, raw, sc)
}

func resolve(ctx context.Context, q db.Querier, raw string, sc Scope) (Match, error) {
	raw = strings.TrimSpace(raw)
	var cands []Match
	if LooksLikeBarcode(raw) {
		cands = append(cands, Match{kind: kindBarcode, barcode: raw})
	}
	text := Text(raw)
	if !text.Empty() {
		cands = append(cands, text)
	}
	if alt, ok := SwapLayout(raw); ok {
		if t := Text(alt); !t.Empty() && t.phrase() != text.phrase() {
			cands = append(cands, t)
		}
	}
	// Та же речь в другой письменности: «kola» → «кола» (у «Coca-Cola» в
	// search_text есть «кока кола»).
	if alt, ok := otherScript(raw); ok {
		if t := Text(alt); !t.Empty() && t.phrase() != text.phrase() {
			cands = append(cands, t)
		}
	}
	if len(cands) == 0 {
		return Match{}, nil
	}
	// CASE проверяет варианты по очереди и останавливается на первом найденном.
	args := []any{}
	var b strings.Builder
	b.WriteString("SELECT CASE")
	for i, c := range cands {
		fmt.Fprintf(&b, " WHEN EXISTS (SELECT 1 FROM product_search s WHERE %s AND %s) THEN %d", sc.Where("s", &args), c.Where("s", &args), i)
	}
	b.WriteString(" ELSE -1 END")
	var i int
	if err := q.QueryRow(ctx, b.String(), Args(args)...).Scan(&i); err != nil {
		return Match{}, err
	}
	if i >= 0 {
		return cands[i], nil
	}
	if text.Empty() {
		return Match{}, nil
	}
	return fixTypos(ctx, q, text, sc)
}

// fixTypos — запрос с опечатками («малоко», «кифир»): каждое слово от 4
// символов заменяется ближайшим словом словаря каталога (search_words,
// похожесть по триграммам), и, если так что-то находится, ищем по нему.
func fixTypos(ctx context.Context, q db.Querier, text Match, sc Scope) (Match, error) {
	var long []string
	for _, w := range text.words {
		if len([]rune(w)) >= minFix && strings.ContainsFunc(w, unicode.IsLetter) {
			long = append(long, w)
		}
	}
	if len(long) == 0 {
		return Match{}, nil
	}
	rows, err := q.Query(ctx, `
		SELECT w, (SELECT d.word FROM search_words d WHERE d.word % w
		           ORDER BY similarity(d.word, w) DESC, d.freq DESC, d.word LIMIT 1)
		FROM unnest($1::text[]) AS w`, Args([]any{long})...)
	if err != nil {
		return Match{}, err
	}
	fix := map[string]string{}
	for rows.Next() {
		var w string
		var to *string
		if err := rows.Scan(&w, &to); err != nil {
			rows.Close()
			return Match{}, err
		}
		if to != nil && *to != w {
			fix[w] = *to
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil || len(fix) == 0 {
		return Match{}, err
	}
	fixed := Match{kind: kindText, words: make([]string, len(text.words))}
	for i, w := range text.words {
		fixed.words[i] = w
		if to, ok := fix[w]; ok {
			fixed.words[i] = to
		}
	}
	args := []any{}
	var found bool
	if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM product_search s WHERE `+sc.Where("s", &args)+` AND `+fixed.Where("s", &args)+`)`,
		Args(args)...).Scan(&found); err != nil || !found {
		return Match{}, err
	}
	return fixed, nil
}
