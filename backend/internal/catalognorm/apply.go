package catalognorm

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/variants"
	"github.com/sanedidi/super-market/backend/internal/variants/naming"
)

// row — строка журнала для применения и отката.
type row struct {
	id        int64
	productID *string
	kind      string
	old, new  string
	detail    []byte
}

func loadRows(ctx context.Context, q db.Querier, sql string, args ...any) ([]row, error) {
	rows, err := q.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (row, error) {
		var x row
		err := r.Scan(&x.id, &x.productID, &x.kind, &x.old, &x.new, &x.detail)
		return x, err
	})
}

const rowCols = `SELECT id, product_id::text, kind, old_value, new_value, detail FROM catalog_norm_changes`

// applyRows — изменения товаров (название, категория, разбор, модерация) в
// товары. Товар, который за это время поправил человек или кто-то ещё
// (значение уже не «было»), пропускается — строка остаётся не применённой.
func (s *Service) applyRows(ctx context.Context, runID string, ids []int64) error {
	rs, err := loadRows(ctx, s.pool, rowCols+` WHERE run_id = $1 AND id = ANY ($2) AND NOT applied AND NOT reverted
		AND kind <> 'variant_group' ORDER BY product_id, id`, runID, ids)
	if err != nil {
		return err
	}
	byProduct := map[string][]row{}
	var order []string
	for _, r := range rs {
		if r.productID == nil {
			continue
		}
		if _, ok := byProduct[*r.productID]; !ok {
			order = append(order, *r.productID)
		}
		byProduct[*r.productID] = append(byProduct[*r.productID], r)
	}
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		for _, pid := range order {
			if err := applyProduct(ctx, tx, pid, byProduct[pid]); err != nil {
				return err
			}
		}
		return nil
	})
}

func applyProduct(ctx context.Context, tx pgx.Tx, pid string, rs []row) error {
	var name, nameUz, cat, oldName, oldUz, oldCat *string
	var norm []byte
	var mod *row
	var ids []int64
	for i := range rs {
		r := &rs[i]
		switch r.kind {
		case "name":
			name, oldName = &r.new, &r.old
		case "name_uz":
			nameUz, oldUz = &r.new, &r.old
		case "category":
			cat, oldCat = &r.new, &r.old
		case "norm":
			norm = r.detail
		case "moderation":
			mod = r
			continue
		}
		ids = append(ids, r.id)
	}
	if norm == nil {
		norm = []byte("{}")
	}
	// Поля — только если они всё ещё «было» и товар не правил человек.
	tag, err := tx.Exec(ctx, `
		UPDATE products SET
			name        = COALESCE($2, name),
			name_uz     = COALESCE($3, name_uz),
			category_id = COALESCE($4::uuid, category_id),
			attributes  = attributes || jsonb_build_object('norm', $8::jsonb),
			norm_at     = now()
		WHERE id = $1 AND NOT norm_locked
		  AND ($5::text IS NULL OR name = $5) AND ($6::text IS NULL OR name_uz = $6) AND ($7::text IS NULL OR category_id::text = $7)`,
		pid, name, nameUz, cat, oldName, oldUz, oldCat, string(norm))
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return nil
	}
	if _, err := tx.Exec(ctx, `UPDATE catalog_norm_changes SET applied = true WHERE id = ANY ($1)`, ids); err != nil {
		return err
	}
	if mod != nil {
		var d struct {
			Reason string `json:"reason"`
		}
		_ = json.Unmarshal(mod.detail, &d)
		var tag2 interface{ RowsAffected() int64 }
		if mod.new == "approved" {
			tag2, err = tx.Exec(ctx, `UPDATE products SET moderation_status = 'approved', rejection_reason = '', network_id = NULL
				WHERE id = $1 AND moderation_status = 'pending'`, pid)
		} else {
			tag2, err = tx.Exec(ctx, `UPDATE products SET moderation_status = 'rejected', rejection_reason = $2
				WHERE id = $1 AND moderation_status = 'pending'`, pid, d.Reason)
		}
		if err != nil {
			return err
		}
		if tag2.RowsAffected() > 0 {
			if _, err := tx.Exec(ctx, `UPDATE catalog_norm_changes SET applied = true WHERE id = $1`, mod.id); err != nil {
				return err
			}
		}
	}
	return nil
}

// ---------------------------------------------------------------- группы вариаций

// groupPlan — строка журнала variant_group.
type groupPlan struct {
	Action     string              `json:"action"` // create | join
	GroupID    string              `json:"group_id,omitempty"`
	Name       string              `json:"name"`
	NameUz     string              `json:"name_uz"`
	BrandID    string              `json:"brand_id"`
	CategoryID string              `json:"category_id"`
	Items      []variants.AutoItem `json:"items"`
	Skipped    bool                `json:"skipped,omitempty"`
}

// planVariants — группы по разобранным товарам: ключ — бренд, категория и
// линейка. Есть подтверждённая группа с той же линейкой — товары
// добавляются в неё, иначе — новая группа (от двух разных «вес + вкус»).
// В группу идут и товары той же марки и категории, разобранные раньше.
func (s *Service) planVariants(ctx context.Context, st *runState) error {
	type bucket struct {
		brandID, categoryID, name, nameUz string
		items                             []variants.AutoItem
		seen                              map[string]bool
	}
	buckets := map[string]*bucket{}
	add := func(r result) {
		if !r.common || r.brandID == "" || r.line == "" || strings.HasPrefix(r.categoryID, "?") || (r.weight == "" && r.flavor == "") {
			return
		}
		k := r.brandID + "|" + r.categoryID + "|" + naming.Fold(r.line)
		b := buckets[k]
		if b == nil {
			b = &bucket{brandID: r.brandID, categoryID: r.categoryID, name: r.line, nameUz: r.lineUz, seen: map[string]bool{}}
			buckets[k] = b
		}
		if b.seen[r.productID] {
			return
		}
		b.seen[r.productID] = true
		b.items = append(b.items, variants.AutoItem{ProductID: r.productID, Weight: r.weight, WeightUz: r.weightUz, Flavor: r.flavor, FlavorUz: r.flavorUz})
	}
	st.mu.Lock()
	touched := map[string]bool{}
	for _, r := range st.result {
		add(r)
		if r.brandID != "" {
			touched[r.brandID+"|"+r.categoryID] = true
		}
	}
	st.mu.Unlock()

	// Разобранные раньше товары тех же марок и категорий, ещё не в группе.
	for _, k := range sortedKeys(touched) {
		brandID, catID, _ := strings.Cut(k, "|")
		if strings.HasPrefix(catID, "?") {
			continue
		}
		rows, err := s.pool.Query(ctx, `
			SELECT p.id::text, COALESCE(p.attributes -> 'norm', '{}') FROM products p
			WHERE p.network_id IS NULL AND p.is_active AND p.kind = 'goods' AND p.variant_group_id IS NULL
			  AND p.brand_id = $1 AND p.category_id = $2 AND p.attributes ? 'norm'`, brandID, catID)
		if err != nil {
			return err
		}
		type prev struct {
			id   string
			norm map[string]string
		}
		ps, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (prev, error) {
			var x prev
			err := r.Scan(&x.id, &x.norm)
			return x, err
		})
		if err != nil {
			return err
		}
		for _, p := range ps {
			st.mu.Lock()
			_, inRun := st.result[p.id]
			st.mu.Unlock()
			if inRun {
				continue
			}
			add(result{productID: p.id, brandID: brandID, categoryID: catID, line: p.norm["line"], lineUz: p.norm["line_uz"],
				flavor: p.norm["flavor"], flavorUz: p.norm["flavor_uz"], weight: p.norm["weight"], weightUz: p.norm["weight_uz"], common: true})
		}
	}

	for _, k := range sortedKeys(buckets) {
		b := buckets[k]
		gid, err := s.vars.FindConfirmed(ctx, b.brandID, b.categoryID, b.name)
		if err != nil {
			return err
		}
		plan := groupPlan{Action: "create", Name: b.name, NameUz: b.nameUz, BrandID: b.brandID, CategoryID: b.categoryID, Items: b.items}
		if gid != "" {
			plan.Action, plan.GroupID = "join", gid
		} else {
			distinct := map[string]bool{}
			for _, it := range b.items {
				distinct[naming.Fold(it.Weight)+"|"+naming.Fold(it.Flavor)] = true
			}
			if len(distinct) < 2 {
				continue
			}
		}
		d, _ := json.Marshal(plan)
		var id int64
		if err := s.pool.QueryRow(ctx, `INSERT INTO catalog_norm_changes (run_id, kind, new_value, detail) VALUES ($1, 'variant_group', $2, $3)
			RETURNING id`, st.id, plan.GroupID, d).Scan(&id); err != nil {
			return err
		}
		if st.dry {
			if plan.Action == "create" {
				st.add(func(x *Stats) { x.Groups++; x.InGroups += len(plan.Items) })
			} else {
				st.add(func(x *Stats) { x.Joined += len(plan.Items) })
			}
			continue
		}
		n, err := s.applyGroup(ctx, id, plan)
		if err != nil {
			return err
		}
		if n > 0 {
			if plan.Action == "create" {
				st.add(func(x *Stats) { x.Groups++; x.InGroups += n })
			} else {
				st.add(func(x *Stats) { x.Joined += n })
			}
		}
	}
	return nil
}

// applyGroup — создать группу или добавить товары; в журнал — что вошло.
func (s *Service) applyGroup(ctx context.Context, rowID int64, plan groupPlan) (int, error) {
	var used []variants.AutoItem
	var err error
	if plan.Action == "join" {
		used, err = s.vars.AutoJoin(ctx, plan.GroupID, plan.Items)
	} else {
		plan.GroupID, used, err = s.vars.AutoCreate(ctx, variants.AutoGroup{Name: plan.Name, NameUz: plan.NameUz, BrandID: plan.BrandID,
			CategoryID: plan.CategoryID, Items: plan.Items})
	}
	if err != nil {
		return 0, err
	}
	if len(used) == 0 {
		plan.Skipped = true
		d, _ := json.Marshal(plan)
		_, err := s.pool.Exec(ctx, `UPDATE catalog_norm_changes SET detail = $2 WHERE id = $1`, rowID, d)
		return 0, err
	}
	plan.Items = used
	d, _ := json.Marshal(plan)
	_, err = s.pool.Exec(ctx, `UPDATE catalog_norm_changes SET applied = true, new_value = $2, detail = $3 WHERE id = $1`, rowID, plan.GroupID, d)
	return len(used), err
}

// ---------------------------------------------------------------- применить просмотренный прогон

// Apply — применить прогон «только посмотреть». Идёт в фоне.
func (s *Service) Apply(ctx context.Context, id string) (Run, error) {
	r, err := s.Run(ctx, id)
	if err != nil {
		return r, err
	}
	if !r.DryRun || r.Applied || r.Status != "done" {
		return r, apperr.Conflict("norm_not_applicable", "применить можно только завершённый прогон «только посмотреть»").
			Uz("faqat tugagan «faqat koʻrish» ishga tushirishini qoʻllash mumkin")
	}
	if !s.acquire() {
		return r, errBusy()
	}
	if _, err := s.pool.Exec(ctx, `UPDATE catalog_norm_runs SET status = 'applying' WHERE id = $1`, id); err != nil {
		s.release()
		return r, err
	}
	do := func() {
		defer s.release()
		bctx := context.Background()
		err := s.applyRun(bctx, id)
		if err != nil {
			s.log.Error("catalognorm: применение", "run", id, "err", err)
			_, _ = s.pool.Exec(bctx, `UPDATE catalog_norm_runs SET status = 'done', error = $2 WHERE id = $1`, id, err.Error())
			return
		}
		_, _ = s.pool.Exec(bctx, `UPDATE catalog_norm_runs SET status = 'done', applied = true, applied_at = now(), error = '' WHERE id = $1`, id)
	}
	if Sync {
		do()
	} else {
		go do()
	}
	return s.Run(ctx, id)
}

func (s *Service) applyRun(ctx context.Context, id string) error {
	// Товары — по 200 за раз.
	for {
		rows, err := s.pool.Query(ctx, `
			SELECT DISTINCT product_id::text FROM catalog_norm_changes
			WHERE run_id = $1 AND kind = 'norm' AND NOT applied AND NOT reverted LIMIT 200`, id)
		if err != nil {
			return err
		}
		pids, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			return err
		}
		if len(pids) == 0 {
			break
		}
		rows, err = s.pool.Query(ctx, `SELECT id FROM catalog_norm_changes
			WHERE run_id = $1 AND product_id = ANY ($2::uuid[]) AND kind <> 'variant_group' AND NOT applied AND NOT reverted`, id, pids)
		if err != nil {
			return err
		}
		ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
		if err != nil {
			return err
		}
		if err := s.applyRows(ctx, id, ids); err != nil {
			return err
		}
		// Пропущенные (товар успели изменить или поправил человек) больше не берём.
		if _, err := s.pool.Exec(ctx, `UPDATE catalog_norm_changes SET reverted = true, detail = detail || '{"skipped": true}'
			WHERE id = ANY ($1) AND NOT applied`, ids); err != nil {
			return err
		}
	}
	rs, err := loadRows(ctx, s.pool, rowCols+` WHERE run_id = $1 AND kind = 'variant_group' AND NOT applied AND NOT reverted ORDER BY id`, id)
	if err != nil {
		return err
	}
	for _, r := range rs {
		var plan groupPlan
		if err := json.Unmarshal(r.detail, &plan); err != nil {
			continue
		}
		if _, err := s.applyGroup(ctx, r.id, plan); err != nil {
			return err
		}
	}
	return nil
}

// ---------------------------------------------------------------- откат

// Rollback — вернуть всё, что сделал прогон: названия и категории (если их
// с тех пор не меняли), решения модерации, группы вариаций.
func (s *Service) Rollback(ctx context.Context, id string) (Run, error) {
	r, err := s.Run(ctx, id)
	if err != nil {
		return r, err
	}
	if !r.Applied || r.Status == "rolled_back" || r.Status == "running" || r.Status == "applying" {
		return r, apperr.Conflict("norm_not_applied", "откатить можно только применённый прогон").Uz("faqat qoʻllangan ishga tushirishni bekor qilish mumkin")
	}
	if !s.acquire() {
		return r, errBusy()
	}
	defer s.release()
	rs, err := loadRows(ctx, s.pool, rowCols+` WHERE run_id = $1 AND applied AND NOT reverted ORDER BY id DESC`, id)
	if err != nil {
		return r, err
	}
	// Сначала группы, потом модерация и поля.
	for _, x := range rs {
		if x.kind != "variant_group" {
			continue
		}
		var plan groupPlan
		if err := json.Unmarshal(x.detail, &plan); err != nil || plan.GroupID == "" {
			continue
		}
		var pids []string
		for _, it := range plan.Items {
			pids = append(pids, it.ProductID)
		}
		if err := s.vars.AutoUndo(ctx, plan.GroupID, pids, plan.Action == "create"); err != nil {
			return r, err
		}
		if _, err := s.pool.Exec(ctx, `UPDATE catalog_norm_changes SET reverted = true WHERE id = $1`, x.id); err != nil {
			return r, err
		}
	}
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		for _, x := range rs {
			if x.productID == nil || x.kind == "variant_group" || x.kind == "norm" {
				continue
			}
			var q string
			args := []any{*x.productID, x.old, x.new}
			switch x.kind {
			case "name":
				q = `UPDATE products SET name = $2 WHERE id = $1 AND name = $3`
			case "name_uz":
				q = `UPDATE products SET name_uz = $2 WHERE id = $1 AND name_uz = $3`
			case "category":
				q = `UPDATE products SET category_id = $2::uuid WHERE id = $1 AND category_id::text = $3`
			case "moderation":
				if x.new == "approved" {
					q = `UPDATE products SET moderation_status = 'pending', network_id = NULLIF($2, '')::uuid
						WHERE id = $1 AND moderation_status = 'approved' AND network_id IS NULL`
					args = []any{*x.productID, x.old}
				} else {
					q = `UPDATE products SET moderation_status = 'pending', rejection_reason = ''
						WHERE id = $1 AND moderation_status = 'rejected'`
					args = []any{*x.productID}
				}
			default:
				continue
			}
			if _, err := tx.Exec(ctx, q, args...); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE catalog_norm_changes SET reverted = true WHERE run_id = $1 AND applied`, id); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `UPDATE catalog_norm_runs SET status = 'rolled_back', rolled_back_at = now() WHERE id = $1`, id)
		return err
	})
	if err != nil {
		return r, err
	}
	return s.Run(ctx, id)
}
