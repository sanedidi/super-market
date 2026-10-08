// Package catalog — справочники, товары с модерацией, типы цен и цены.
package catalog

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// Общие справочники (бренды, категории, цвета, единицы) устроены одинаково:
// название + несколько своих полей + is_active. Поэтому они описаны
// таблицей dictSpec, а не четырьмя копиями одного кода. Имена таблиц и
// колонок берутся только из этих описаний, пользовательский ввод в SQL
// попадает лишь как параметры.

type fieldKind int

const (
	kindText fieldKind = iota
	kindBool
	kindInt
	kindUUID // ссылка на запись той же таблицы (категория-родитель)
)

type field struct {
	name     string
	kind     fieldKind
	required bool // обязательно при создании
	check    func(v any) error
	// uz — колонка с узбекским переводом поля (name → name_uz). В ответе
	// поле отдаётся на языке запроса, плюс сырые <поле>_ru и <поле>_uz.
	uz string
}

type dictSpec struct {
	kind  string // brands, categories, colors, units — часть URL
	table string
	title string // для сообщений об ошибках
	// titleUz — то же по-узбекски.
	titleUz string
	fields  []field
	order   string
}

// fieldErr — ошибка значения поля на двух языках.
type fieldErr i18n.Text

func (e fieldErr) Error() string { return e.RU }

var hexRe = regexp.MustCompile(`^#[0-9A-Fa-f]{6}$`)

var dicts = map[string]dictSpec{
	"brands": {
		kind: "brands", table: "brands", title: "бренд", titleUz: "brend", order: "name",
		fields: []field{{name: "name", kind: kindText, required: true}},
	},
	"categories": {
		kind: "categories", table: "categories", title: "категория", titleUz: "kategoriya", order: "sort, name",
		fields: []field{
			{name: "name", kind: kindText, required: true, uz: "name_uz"},
			{name: "name_uz", kind: kindText},
			{name: "parent_id", kind: kindUUID},
			{name: "sort", kind: kindInt},
			{name: "image_url", kind: kindText, check: func(v any) error {
				if s := v.(string); s != "" && !strings.HasPrefix(s, "https://") && !strings.HasPrefix(s, "http://") {
					return fieldErr{RU: "ожидается ссылка http(s)", UZ: "http(s) havola boʻlishi kerak"}
				}
				return nil
			}},
		},
	},
	"colors": {
		kind: "colors", table: "colors", title: "цвет", titleUz: "rang", order: "name",
		fields: []field{
			{name: "name", kind: kindText, required: true, uz: "name_uz"},
			{name: "name_uz", kind: kindText},
			{name: "hex", kind: kindText, check: func(v any) error {
				if s := v.(string); s != "" && !hexRe.MatchString(s) {
					return fieldErr{RU: "ожидается цвет вида #1A2B3C", UZ: "rang #1A2B3C koʻrinishida boʻlishi kerak"}
				}
				return nil
			}},
		},
	},
	"units": {
		kind: "units", table: "units", title: "единица измерения", titleUz: "oʻlchov birligi", order: "name",
		fields: []field{
			{name: "name", kind: kindText, required: true, uz: "name_uz"},
			{name: "name_uz", kind: kindText},
			{name: "short_name", kind: kindText, required: true, uz: "short_name_uz"},
			{name: "short_name_uz", kind: kindText},
			{name: "is_fractional", kind: kindBool},
		},
	},
}

// hasUz — у справочника есть узбекское название (name_uz).
func (d dictSpec) hasUz() bool {
	for _, f := range d.fields {
		if f.name == "name" && f.uz != "" {
			return true
		}
	}
	return false
}

// fillFromUz: если пришёл только перевод (name_uz), а русское поле не
// задано (при создании) или пустое, — перевод пишется и в основное поле.
func (d dictSpec) fillFromUz(raw map[string]json.RawMessage, create bool) {
	for _, f := range d.fields {
		if f.uz == "" {
			continue
		}
		var uz string
		if msg, ok := raw[f.uz]; !ok || json.Unmarshal(msg, &uz) != nil || strings.TrimSpace(uz) == "" {
			continue
		}
		msg, ok := raw[f.name]
		var cur string
		if ok && json.Unmarshal(msg, &cur) != nil {
			continue // неверный тип — сообщит обычная проверка
		}
		if (!ok && create) || (ok && strings.TrimSpace(cur) == "") {
			raw[f.name] = raw[f.uz]
		}
	}
}

func (d dictSpec) columns() string {
	// uuid-колонки отдаём текстом: RowToMap иначе вернёт байты.
	cols := []string{"id::text AS id"}
	for _, f := range d.fields {
		if f.kind == kindUUID {
			cols = append(cols, f.name+"::text AS "+f.name)
			continue
		}
		if f.uz != "" {
			// Название — на языке запроса; для форм — оба языка как есть.
			cols = append(cols, fmt.Sprintf("loc(%[1]s, %[2]s) AS %[1]s, %[1]s AS %[1]s_ru", f.name, f.uz))
			continue
		}
		cols = append(cols, f.name)
	}
	return strings.Join(append(cols, "is_active", "created_at"), ", ")
}

// Service — вся логика каталога.
type Service struct {
	pool *pgxpool.Pool
}

func NewService(pool *pgxpool.Pool) *Service { return &Service{pool: pool} }

func dictFor(kind string) (dictSpec, error) {
	d, ok := dicts[kind]
	if !ok {
		return dictSpec{}, apperr.NotFound("справочник не найден").Uz("maʼlumotnoma topilmadi")
	}
	return d, nil
}

// DictFilter — поиск по справочнику. Page == nil — без ограничения
// (панель магазина берёт справочник целиком).
type DictFilter struct {
	Query string
	// ExcludeTree — только для категорий: исключить категорию и всех её
	// потомков (варианты родителя при правке).
	ExcludeTree string
	Page        *httpx.Page
}

// ListDict возвращает записи справочника. onlyActive — для панели магазина.
// У категорий в списке есть parent_name.
func (s *Service) ListDict(ctx context.Context, kind string, onlyActive bool, f DictFilter) ([]map[string]any, error) {
	d, err := dictFor(kind)
	if err != nil {
		return nil, err
	}
	if f.ExcludeTree != "" && (kind != "categories" || !httpx.IsUUID(f.ExcludeTree)) {
		return nil, apperr.Validation("exclude_tree: ожидается id категории").Uz("exclude_tree: kategoriya id boʻlishi kerak")
	}
	cols := d.columns()
	where := `(t.is_active OR NOT $1) AND ($2 = '' OR t.name ILIKE '%' || $2 || '%')`
	if d.hasUz() {
		// Ищем и по русскому, и по узбекскому названию.
		where = `(t.is_active OR NOT $1) AND ($2 = '' OR t.name ILIKE '%' || $2 || '%' OR t.name_uz ILIKE '%' || $2 || '%')`
	}
	args := []any{onlyActive, strings.TrimSpace(f.Query)}
	if kind == "categories" {
		cols += `, (SELECT loc(pc.name, pc.name_uz) FROM categories pc WHERE pc.id = t.parent_id) AS parent_name`
		where += ` AND ($3 = '' OR t.id NOT IN (
			WITH RECURSIVE sub AS (
				SELECT id FROM categories WHERE id::text = $3
				UNION SELECT c.id FROM categories c JOIN sub ON c.parent_id = sub.id)
			SELECT id FROM sub))`
		args = append(args, f.ExcludeTree)
	}
	limit := ""
	if f.Page != nil {
		limit = fmt.Sprintf(" LIMIT %d OFFSET %d", f.Page.Limit, f.Page.Offset)
	}
	rows, err := s.pool.Query(ctx, fmt.Sprintf(
		`SELECT %s FROM %s t WHERE %s ORDER BY %s, t.id%s`, cols, d.table, where, d.order, limit), args...)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToMap)
}

// parseInput проверяет JSON по описанию справочника. При создании
// обязательные поля должны быть, при изменении — любое подмножество.
func (d dictSpec) parseInput(raw map[string]json.RawMessage, create bool) ([]string, []any, error) {
	var cols []string
	var vals []any
	d.fillFromUz(raw, create)
	known := map[string]bool{"is_active": true}
	for _, f := range d.fields {
		known[f.name] = true
	}
	for k := range raw {
		if !known[k] {
			return nil, nil, apperr.Validation(k + ": неизвестное поле").Uz(k + ": nomaʼlum maydon")
		}
	}
	all := append(append([]field{}, d.fields...), field{name: "is_active", kind: kindBool})
	for _, f := range all {
		msg, ok := raw[f.name]
		if !ok {
			if create && f.required {
				return nil, nil, apperr.Validation(f.name + ": обязательное поле").Uz(f.name + ": majburiy maydon")
			}
			continue
		}
		v, err := decodeField(f, msg)
		if err != nil {
			fe := fieldErr{RU: err.Error()}
			errors.As(err, &fe)
			return nil, nil, apperr.Validation(f.name + ": " + fe.RU).Uz(f.name + ": " + fe.UZ)
		}
		cols = append(cols, f.name)
		vals = append(vals, v)
	}
	if len(cols) == 0 {
		return nil, nil, apperr.Validation("нет полей для изменения").Uz("oʻzgartirish uchun maydon yoʻq")
	}
	return cols, vals, nil
}

func decodeField(f field, msg json.RawMessage) (any, error) {
	var v any
	switch f.kind {
	case kindText:
		var s string
		if err := json.Unmarshal(msg, &s); err != nil {
			return nil, fieldErr{RU: "ожидается строка", UZ: "satr boʻlishi kerak"}
		}
		s = strings.TrimSpace(s)
		if f.required && s == "" {
			return nil, fieldErr{RU: "не может быть пустым", UZ: "boʻsh boʻlishi mumkin emas"}
		}
		v = s
	case kindBool:
		var b bool
		if err := json.Unmarshal(msg, &b); err != nil {
			return nil, fieldErr{RU: "ожидается true или false", UZ: "true yoki false boʻlishi kerak"}
		}
		v = b
	case kindInt:
		var n int
		if err := json.Unmarshal(msg, &n); err != nil {
			return nil, fieldErr{RU: "ожидается целое число", UZ: "butun son boʻlishi kerak"}
		}
		v = n
	case kindUUID:
		var p *string
		if err := json.Unmarshal(msg, &p); err != nil || (p != nil && !httpx.IsUUID(*p)) {
			return nil, fieldErr{RU: "ожидается id или null", UZ: "id yoki null boʻlishi kerak"}
		}
		if p == nil {
			return nil, nil
		}
		v = *p
	}
	if f.check != nil {
		if err := f.check(v); err != nil {
			return nil, err
		}
	}
	return v, nil
}

func (s *Service) CreateDict(ctx context.Context, kind string, raw map[string]json.RawMessage) (map[string]any, error) {
	d, err := dictFor(kind)
	if err != nil {
		return nil, err
	}
	cols, vals, err := d.parseInput(raw, true)
	if err != nil {
		return nil, err
	}
	ph := make([]string, len(cols))
	for i := range cols {
		ph[i] = fmt.Sprintf("$%d", i+1)
	}
	rows, err := s.pool.Query(ctx, fmt.Sprintf(`INSERT INTO %s (%s) VALUES (%s) RETURNING %s`,
		d.table, strings.Join(cols, ", "), strings.Join(ph, ", "), d.columns()), vals...)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectExactlyOneRow(rows, pgx.RowToMap)
	return out, d.mapErr(err)
}

func (s *Service) UpdateDict(ctx context.Context, kind, id string, raw map[string]json.RawMessage) (map[string]any, error) {
	d, err := dictFor(kind)
	if err != nil {
		return nil, err
	}
	cols, vals, err := d.parseInput(raw, false)
	if err != nil {
		return nil, err
	}
	sets := make([]string, len(cols))
	var parent any
	for i, c := range cols {
		sets[i] = fmt.Sprintf("%s = $%d", c, i+2)
		if c == "parent_id" {
			parent = vals[i]
		}
	}
	var out map[string]any
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if p, ok := parent.(string); ok {
			if err := checkNoCycle(ctx, tx, id, p); err != nil {
				return err
			}
		}
		rows, err := tx.Query(ctx, fmt.Sprintf(`UPDATE %s SET %s WHERE id = $1 RETURNING %s`,
			d.table, strings.Join(sets, ", "), d.columns()), append([]any{id}, vals...)...)
		if err != nil {
			return err
		}
		out, err = pgx.CollectExactlyOneRow(rows, pgx.RowToMap)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.NotFound(d.title + ": запись не найдена").Uz(d.titleUz + ": yozuv topilmadi")
		}
		return d.mapErr(err)
	})
	return out, err
}

// checkNoCycle не даёт сделать родителем категории её саму или её потомка:
// иначе дерево зациклится. Смены родителя идут по одной (advisory-lock),
// чтобы две встречные правки не создали цикл вместе.
func checkNoCycle(ctx context.Context, tx pgx.Tx, id, parent string) error {
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('categories:tree'))`); err != nil {
		return err
	}
	var cycle bool
	err := tx.QueryRow(ctx, `
		WITH RECURSIVE sub AS (
			SELECT id FROM categories WHERE id = $1
			UNION SELECT c.id FROM categories c JOIN sub ON c.parent_id = sub.id)
		SELECT EXISTS (SELECT 1 FROM sub WHERE id = $2)`, id, parent).Scan(&cycle)
	if err != nil {
		return err
	}
	if cycle {
		return apperr.Validation("parent_id: нельзя вложить категорию в саму себя или в её подкатегорию").Uz("parent_id: kategoriyani oʻziga yoki oʻz ichki kategoriyasiga joylab boʻlmaydi")
	}
	return nil
}

func (d dictSpec) mapErr(err error) error {
	switch {
	case err == nil:
		return nil
	case db.IsUniqueViolation(err, ""):
		return apperr.Conflict("already_exists", d.title+": запись с таким названием уже есть").Uz(d.titleUz + ": bunday nomli yozuv allaqachon bor")
	case db.IsForeignKeyViolation(err):
		return apperr.Validation("parent_id: родитель не найден").Uz("parent_id: yuqori element topilmadi")
	case db.IsCheckViolation(err):
		return apperr.Validation(d.title + ": недопустимое значение").Uz(d.titleUz + ": notoʻgʻri qiymat")
	}
	return err
}
