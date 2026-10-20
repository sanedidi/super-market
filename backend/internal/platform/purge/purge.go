// Package purge удаляет строку вместе со всем, что на неё ссылается по
// внешним ключам, — например, сеть или магазин целиком.
//
// Что удалять, решает Scope: «своя» строка удаляется, «чужая» (другой сети,
// другого магазина, центральной базы, деньги курьеров…) остаётся, а её
// ссылка на удаляемое обнуляется. Если обнулить нельзя (колонка NOT NULL) —
// ForeignError, и вызывающий откатывает транзакцию: лучше не удалить, чем
// задеть чужие данные.
package purge

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

// Scope — какие строки «свои».
type Scope struct {
	// Ours — SQL-условие «строка таблицы table своя» по её колонкам cols
	// (только константы и литералы, без параметров). "" — у таблицы нет
	// колонок-владельцев: своя, раз на неё вышли по ссылке.
	Ours func(table string, cols map[string]bool) string
	// Keep — таблицы, строки которых никогда не удаляются.
	Keep map[string]bool
}

// ForeignError — на удаляемое ссылаются строки, которые должны остаться,
// и ссылку обнулить нельзя.
type ForeignError struct {
	Table  string // кто ссылается
	Parent string // на что
	Count  int64
	Err    error // ошибка базы, если обнулить не дал CHECK
}

func (e *ForeignError) Error() string {
	s := fmt.Sprintf("на %s ссылаются строки %s, которые нужно сохранить (%d)", e.Parent, e.Table, e.Count)
	if e.Err != nil {
		s += ": " + e.Err.Error()
	}
	return s
}

func (e *ForeignError) Unwrap() error { return e.Err }

type fk struct {
	child, parent        string
	childCols, parentCol []string
	nullable             []bool
}

// Deleter работает внутри одной транзакции.
type Deleter struct {
	ctx   context.Context
	tx    pgx.Tx
	scope Scope
	fks   []fk
	cols  map[string]map[string]bool
	types map[string]map[string]string // тип колонки (udt_name) — для сравнения без ::text
	ours  map[string]string
	sp    int

	// Deleted — сколько строк удалено по таблицам; Detached — у скольких
	// чужих строк обнулена ссылка на удалённое.
	Deleted  map[string]int64
	Detached map[string]int64
}

// New загружает схему (внешние ключи и колонки) в транзакции tx.
func New(ctx context.Context, tx pgx.Tx, scope Scope) (*Deleter, error) {
	d := &Deleter{ctx: ctx, tx: tx, scope: scope, ours: map[string]string{},
		cols: map[string]map[string]bool{}, types: map[string]map[string]string{}, Deleted: map[string]int64{}, Detached: map[string]int64{}}
	// SET NULL / SET DEFAULT база сделает сама; CASCADE обходим сами, чтобы
	// и там не задеть чужие строки.
	rows, err := tx.Query(ctx, `
		SELECT (SELECT relname FROM pg_class WHERE oid = c.conrelid)::text, (SELECT relname FROM pg_class WHERE oid = c.confrelid)::text,
		       array(SELECT a.attname::text FROM unnest(c.conkey) WITH ORDINALITY k(n, i)
		             JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.n ORDER BY k.i),
		       array(SELECT a.attname::text FROM unnest(c.confkey) WITH ORDINALITY k(n, i)
		             JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = k.n ORDER BY k.i),
		       array(SELECT NOT a.attnotnull FROM unnest(c.conkey) WITH ORDINALITY k(n, i)
		             JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.n ORDER BY k.i)
		FROM pg_constraint c
		JOIN pg_namespace ns ON ns.oid = c.connamespace AND ns.nspname = 'public'
		WHERE c.contype = 'f' AND c.confdeltype IN ('a', 'r', 'c')
		ORDER BY 1, 2, c.conname`)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var f fk
		if err := rows.Scan(&f.child, &f.parent, &f.childCols, &f.parentCol, &f.nullable); err != nil {
			rows.Close()
			return nil, err
		}
		d.fks = append(d.fks, f)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows, err = tx.Query(ctx, `SELECT table_name, column_name, udt_name FROM information_schema.columns WHERE table_schema = 'public'`)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var t, c, typ string
		if err := rows.Scan(&t, &c, &typ); err != nil {
			rows.Close()
			return nil, err
		}
		if d.cols[t] == nil {
			d.cols[t] = map[string]bool{}
			d.types[t] = map[string]string{}
		}
		d.cols[t][c] = true
		d.types[t][c] = typ
	}
	rows.Close()
	return d, rows.Err()
}

// oursCond — условие «строка своя»; NULL в колонке-владельце — чужая.
func (d *Deleter) oursCond(table string) string {
	if c, ok := d.ours[table]; ok {
		return c
	}
	c := "TRUE"
	if d.scope.Keep[table] {
		c = "FALSE"
	} else if d.scope.Ours != nil {
		if s := d.scope.Ours(table, d.cols[table]); s != "" {
			c = "COALESCE((" + s + "), false)"
		}
	}
	d.ours[table] = c
	return c
}

// key — выражение «ключ строки» из нескольких колонок, одинаковое для
// родителя и потомка.
func key(cols []string) string {
	if len(cols) == 1 {
		return cols[0] + "::text"
	}
	parts := make([]string, len(cols))
	for i, c := range cols {
		parts[i] = c + "::text"
	}
	return "concat_ws('|', " + strings.Join(parts, ", ") + ")"
}

// match — условие «ключ строки table по колонкам cols ∈ $1» (значения —
// текстом, как их отдаёт key). Сравнение в родном типе колонки, чтобы
// работали индексы; у составного ключа — отбор по первой колонке и точная
// проверка по склейке.
func (d *Deleter) match(table string, cols []string) string {
	typ := func(c string) string {
		if t := d.types[table][c]; t != "" {
			return t
		}
		return "text"
	}
	if len(cols) == 1 {
		return fmt.Sprintf(`%s = ANY($1::text[]::%s[])`, cols[0], typ(cols[0]))
	}
	return fmt.Sprintf(`%s = ANY((SELECT array_agg(split_part(v, '|', 1)) FROM unnest($1::text[]) v)::%s[]) AND %s = ANY($1::text[])`,
		cols[0], typ(cols[0]), key(cols))
}

// Remove удаляет строки table, у которых key(cols) ∈ vals, вместе со всем,
// что на них ссылается. Сами строки table считаются своими.
func (d *Deleter) Remove(table string, cols, vals []string) error {
	return d.remove(table, cols, vals, nil)
}

func (d *Deleter) remove(table string, cols, vals []string, path []string) error {
	if len(vals) == 0 {
		return nil
	}
	ours := "TRUE"
	if len(path) > 0 {
		ours = d.oursCond(table)
	}
	if ours == "FALSE" {
		return nil
	}
	path = append(path, table)
	for _, f := range d.fks {
		if f.parent != table {
			continue
		}
		parentVals, err := d.strings(fmt.Sprintf(`SELECT DISTINCT %s FROM %s WHERE %s AND %s`,
			key(f.parentCol), table, d.match(table, cols), ours), vals)
		if err != nil {
			return err
		}
		if len(parentVals) == 0 {
			continue
		}
		onPath := false
		for _, t := range path {
			if t == f.child {
				onPath = true
			}
		}
		if onPath {
			// Цикл (магазин ↔ склад по умолчанию, документ → документ):
			// разрываем обнулением ссылки у всех, кто ссылается.
			if err := d.detach(f, parentVals, "TRUE"); err != nil {
				return err
			}
			continue
		}
		co := d.oursCond(f.child)
		// У таблицы без владельца (строки заказа, списки покупок…) ссылка,
		// которую можно обнулить, — не повод удалять строку: она может
		// принадлежать чужому заказу (товар собран с удаляемого склада).
		// Свои такие строки удалятся по обязательной ссылке на свой документ.
		if co == "TRUE" && allNullable(f) {
			if err := d.detach(f, parentVals, "TRUE"); err != nil {
				return err
			}
			continue
		}
		// Чужие строки остаются — обнуляем у них ссылку.
		if co != "TRUE" {
			if err := d.detach(f, parentVals, "NOT "+co); err != nil {
				return err
			}
		}
		if err := d.remove(f.child, f.childCols, parentVals, path); err != nil {
			return err
		}
	}
	tag, err := d.tx.Exec(d.ctx, fmt.Sprintf(`DELETE FROM %s WHERE %s AND %s`, table, d.match(table, cols), ours), vals)
	if err != nil {
		return fmt.Errorf("%s: %w", table, err)
	}
	d.Deleted[table] += tag.RowsAffected()
	return nil
}

// detach обнуляет ссылку f у строк потомка, подходящих под where.
func (d *Deleter) detach(f fk, parentVals []string, where string) error {
	cond := fmt.Sprintf(`%s AND %s`, d.match(f.child, f.childCols), where)
	var sets []string
	for i, c := range f.childCols {
		if f.nullable[i] {
			sets = append(sets, c+" = NULL")
		}
	}
	if len(sets) == 0 {
		var n int64
		if err := d.tx.QueryRow(d.ctx, fmt.Sprintf(`SELECT count(*) FROM %s WHERE %s`, f.child, cond), parentVals).Scan(&n); err != nil {
			return err
		}
		if n > 0 {
			return &ForeignError{Table: f.child, Parent: f.parent, Count: n}
		}
		return nil
	}
	// Точка сохранения: если обнулить не даст CHECK, вернём понятную ошибку.
	d.sp++
	sp := fmt.Sprintf("purge_sp%d", d.sp)
	if _, err := d.tx.Exec(d.ctx, "SAVEPOINT "+sp); err != nil {
		return err
	}
	tag, err := d.tx.Exec(d.ctx, fmt.Sprintf(`UPDATE %s SET %s WHERE %s`, f.child, strings.Join(sets, ", "), cond), parentVals)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && (pgErr.Code == "23514" || pgErr.Code == "23502" || pgErr.Code == "23505") {
			if _, rerr := d.tx.Exec(d.ctx, "ROLLBACK TO SAVEPOINT "+sp); rerr != nil {
				return rerr
			}
			return &ForeignError{Table: f.child, Parent: f.parent, Count: 1, Err: err}
		}
		return fmt.Errorf("%s: %w", f.child, err)
	}
	if _, err := d.tx.Exec(d.ctx, "RELEASE SAVEPOINT "+sp); err != nil {
		return err
	}
	if n := tag.RowsAffected(); n > 0 {
		d.Detached[f.child] += n
	}
	return nil
}

func allNullable(f fk) bool {
	for _, n := range f.nullable {
		if !n {
			return false
		}
	}
	return true
}

func (d *Deleter) strings(sql string, args ...any) ([]string, error) {
	rows, err := d.tx.Query(d.ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

// Try выполняет удаление в точке сохранения; при нарушении внешнего ключа
// откатывает только его и возвращает false.
func (d *Deleter) Try(sql string, args ...any) (bool, error) {
	d.sp++
	name := fmt.Sprintf("purge_sp%d", d.sp)
	if _, err := d.tx.Exec(d.ctx, "SAVEPOINT "+name); err != nil {
		return false, err
	}
	if _, err := d.tx.Exec(d.ctx, sql, args...); err != nil {
		if !db.IsForeignKeyViolation(err) {
			return false, err
		}
		if _, rerr := d.tx.Exec(d.ctx, "ROLLBACK TO SAVEPOINT "+name); rerr != nil {
			return false, rerr
		}
		return false, nil
	}
	_, err := d.tx.Exec(d.ctx, "RELEASE SAVEPOINT "+name)
	return err == nil, err
}

// Total — всего удалено строк.
func (d *Deleter) Total() int64 {
	var n int64
	for _, v := range d.Deleted {
		n += v
	}
	return n
}

// Tables — таблицы с удалёнными строками, по алфавиту (для журнала).
func (d *Deleter) Tables() []string {
	t := make([]string, 0, len(d.Deleted))
	for k, v := range d.Deleted {
		if v > 0 {
			t = append(t, k)
		}
	}
	sort.Strings(t)
	return t
}

// lit — строковый литерал SQL для UUID (вызывающий уже проверил формат).
func lit(id string) string { return "'" + strings.ReplaceAll(id, "'", "") + "'::uuid" }

func litArray(ids []string) string {
	if len(ids) == 0 {
		return "ARRAY[]::uuid[]"
	}
	parts := make([]string, len(ids))
	for i, id := range ids {
		parts[i] = lit(id)
	}
	return "ARRAY[" + strings.Join(parts, ", ") + "]"
}

// Всегда остаются: курьеры «по пути» — живые люди со своими деньгами.
var alwaysKeep = []string{"crowd_couriers", "crowd_ledger", "courier_incidents"}

func keep(extra ...string) map[string]bool {
	m := map[string]bool{}
	for _, t := range append(append([]string{}, alwaysKeep...), extra...) {
		m[t] = true
	}
	return m
}

// NetworkScope — удаление сети networkID с магазинами storeIDs. Своё —
// строки, где сеть указана владельцем: network_id, а у связей «агент —
// магазин» любая из сторон (store_network_id, distributor_id, магазин сети).
// У контрагента distributor_id и store_id — лишь ссылки на другую сторону:
// контрагент принадлежит своей сети. Товары центральной базы (network_id
// пустой) — чужие: у них лишь обнуляется proposed_by.
func NetworkScope(networkID string, storeIDs []string) Scope {
	id, stores := lit(networkID), litArray(storeIDs)
	return Scope{
		Keep: keep(),
		Ours: func(table string, cols map[string]bool) string {
			owners := []string{"network_id", "store_network_id", "distributor_id"}
			if table == "counterparties" {
				owners = []string{"network_id"}
			}
			var parts []string
			for _, c := range owners {
				if cols[c] {
					parts = append(parts, c+" = "+id)
				}
			}
			if cols["store_id"] && table != "counterparties" {
				parts = append(parts, "store_id = ANY("+stores+")")
			}
			return strings.Join(parts, " OR ")
		},
	}
}

// StoreScope — удаление магазина storeID со складами warehouseIDs и кассами
// cashboxIDs. Своё — строки этого магазина, его складов и касс. Строки сети
// (с network_id, но без привязки к магазину) — чужие: товары, сотрудники,
// контрагенты, баланс и счета сети остаются.
func StoreScope(storeID string, warehouseIDs, cashboxIDs []string) Scope {
	id, wh, cb := lit(storeID), litArray(warehouseIDs), litArray(cashboxIDs)
	return Scope{
		Keep: keep("balance_entries", "payouts", "subscription_invoices", "counterparties"),
		Ours: func(table string, cols map[string]bool) string {
			var parts []string
			if cols["store_id"] {
				parts = append(parts, "store_id = "+id)
			}
			if cols["warehouse_id"] {
				parts = append(parts, "warehouse_id = ANY("+wh+")")
			}
			if cols["cashbox_id"] {
				parts = append(parts, "cashbox_id = ANY("+cb+")")
			}
			switch table {
			case "cash_transfers":
				parts = append(parts, "from_id = ANY("+cb+")")
			// Строки, у которых есть только network_id, принадлежат магазину
			// через обязательного родителя: движение денег — через смену,
			// спор — через запись долга.
			case "pos_cash_moves":
				parts = append(parts, "shift_id IN (SELECT id FROM pos_shifts WHERE store_id = "+id+")")
			case "debt_disputes":
				parts = append(parts, "entry_id IN (SELECT id FROM debt_entries WHERE store_id = "+id+")")
			}
			if len(parts) == 0 && cols["network_id"] {
				return "FALSE"
			}
			return strings.Join(parts, " OR ")
		},
	}
}
