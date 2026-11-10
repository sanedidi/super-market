package catalognorm

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/ai"
	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Какие товары проходят автонормализацию: товары общего каталога и товары
// магазинов на модерации; не блюда кафе, не служебные; не правленные человеком.
const scopeWhere = `p.kind = 'goods' AND p.is_active AND NOT p.norm_locked
	AND ((p.network_id IS NULL AND p.moderation_status = 'approved') OR p.moderation_status = 'pending')`

// todoWhere — ещё не проходили (новые товары).
const todoWhere = scopeWhere + ` AND p.norm_at IS NULL`

// AutoLimit — сколько новых товаров берёт один автоматический прогон.
var AutoLimit = 3000

// StartInput — POST /admin/catalog-norm/runs.
type StartInput struct {
	// SectionIDs — разделы (корневые категории); пусто — весь каталог.
	SectionIDs []string `json:"section_ids"`
	// DryRun — только посмотреть: изменения в журнале, в товары не пишутся.
	DryRun bool `json:"dry_run"`
	// OnlyNew — только товары, которые ещё не проходили.
	OnlyNew bool `json:"only_new"`
}

func errBusy() error {
	return apperr.Conflict("norm_running", "автонормализация уже идёт — дождитесь окончания").Uz("avtonormallashtirish allaqachon ketmoqda — tugashini kuting")
}

// acquire — занять «один прогон за раз».
func (s *Service) acquire() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.busy {
		return false
	}
	s.busy = true
	return true
}

func (s *Service) release() {
	s.mu.Lock()
	s.busy = false
	s.mu.Unlock()
}

// Start — ручной прогон; идёт в фоне, состояние — GET /runs/{id}.
func (s *Service) Start(ctx context.Context, adminID string, in StartInput) (Run, error) {
	for _, id := range in.SectionIDs {
		if !httpx.IsUUID(id) {
			return Run{}, apperr.Validation("section_ids: раздел не найден").Uz("section_ids: boʻlim topilmadi")
		}
	}
	if len(in.SectionIDs) > 0 {
		var n int
		if err := s.pool.QueryRow(ctx, `SELECT count(*)::int FROM categories WHERE id = ANY ($1::uuid[]) AND parent_id IS NULL`, in.SectionIDs).Scan(&n); err != nil {
			return Run{}, err
		}
		if n != len(uniq(in.SectionIDs)) {
			return Run{}, apperr.Validation("section_ids: укажите разделы (корневые категории)").Uz("section_ids: boʻlimlarni (asosiy kategoriyalarni) koʻrsating")
		}
	}
	if !s.acquire() {
		return Run{}, errBusy()
	}
	var by *string
	if httpx.IsUUID(adminID) {
		by = &adminID
	}
	id, err := s.newRun(ctx, "manual", in, by)
	if err != nil {
		s.release()
		return Run{}, err
	}
	if Sync {
		s.execute(context.Background(), id, in, 0)
		s.release()
		return s.Run(ctx, id)
	}
	go func() {
		defer s.release()
		s.execute(context.Background(), id, in, 0)
	}()
	return s.Run(ctx, id)
}

func itoa(n int) string { return strconv.Itoa(n) }

func uniq(ids []string) map[string]bool {
	m := map[string]bool{}
	for _, id := range ids {
		m[id] = true
	}
	return m
}

func (s *Service) newRun(ctx context.Context, trigger string, in StartInput, by *string) (string, error) {
	secs := in.SectionIDs
	if secs == nil {
		secs = []string{}
	}
	var id string
	err := s.pool.QueryRow(ctx, `
		INSERT INTO catalog_norm_runs (trigger, section_ids, only_new, dry_run, created_by)
		VALUES ($1, $2::uuid[], $3, $4, $5) RETURNING id`, trigger, secs, in.OnlyNew, in.DryRun, by).Scan(&id)
	return id, err
}

// ---------------------------------------------------------------- дерево категорий

type tree struct {
	codes  []ai.NormCategory
	byCode map[string]string // код → id подкатегории
	codeOf map[string]string // id → код
	root   map[string]string // id категории → id раздела
	path   map[string]string // id → «Раздел / Подкатегория»
}

func (s *Service) loadTree(ctx context.Context) (*tree, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT c.id::text, COALESCE(c.parent_id::text, ''), c.name, COALESCE(pc.name, ''),
		       NOT EXISTS (SELECT 1 FROM categories ch WHERE ch.parent_id = c.id AND ch.is_active)
		FROM categories c LEFT JOIN categories pc ON pc.id = c.parent_id
		WHERE c.is_active AND (pc.id IS NULL OR pc.is_active)
		ORDER BY COALESCE(pc.sort, c.sort), COALESCE(pc.name, c.name), c.sort, c.name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	t := &tree{byCode: map[string]string{}, codeOf: map[string]string{}, root: map[string]string{}, path: map[string]string{}}
	for rows.Next() {
		var id, parent, name, pname string
		var leaf bool
		if err := rows.Scan(&id, &parent, &name, &pname, &leaf); err != nil {
			return nil, err
		}
		p := name
		t.root[id] = id
		if parent != "" {
			p = pname + " / " + name
			t.root[id] = parent
		}
		t.path[id] = p
		if leaf {
			code := "c" + strconv.Itoa(len(t.codes)+1)
			t.codes = append(t.codes, ai.NormCategory{Code: code, Path: p})
			t.byCode[code], t.codeOf[id] = id, code
		}
	}
	return t, rows.Err()
}

// ---------------------------------------------------------------- прогон

// result — разбор товара (для групп вариаций в конце прогона).
type result struct {
	productID, brandID, categoryID string
	line, lineUz                   string
	flavor, flavorUz               string
	weight, weightUz               string
	common                         bool // товар общего каталога после прогона
}

type runState struct {
	id     string
	dry    bool
	tree   *tree
	conn   ai.Conn
	useAI  bool
	mu     sync.Mutex
	stats  Stats
	result map[string]result
}

func (st *runState) add(f func(*Stats)) {
	st.mu.Lock()
	f(&st.stats)
	st.mu.Unlock()
}

// execute — весь прогон. limit > 0 — не больше стольких товаров (авто).
func (s *Service) execute(ctx context.Context, runID string, in StartInput, limit int) {
	st := &runState{id: runID, dry: in.DryRun, result: map[string]result{}}
	fail := func(err error) {
		s.log.Error("catalognorm: прогон не удался", "run", runID, "err", err)
		msg := err.Error()
		if e, ok := apperr.As(err); ok {
			msg = e.Text("ru")
		}
		_, _ = s.pool.Exec(context.Background(), `UPDATE catalog_norm_runs SET status = 'failed', error = $2, stats = $3, finished_at = now() WHERE id = $1`,
			runID, msg, st.snapshot())
	}
	defer func() {
		if p := recover(); p != nil {
			fail(fmt.Errorf("паника: %v", p))
		}
	}()
	set, err := s.Settings(ctx)
	if err != nil {
		fail(err)
		return
	}
	if st.tree, err = s.loadTree(ctx); err != nil {
		fail(err)
		return
	}
	st.conn, err = s.ai.Conn(ctx)
	if err != nil && !errors.Is(err, ai.ErrNotConfigured) {
		fail(err)
		return
	}
	st.useAI = err == nil
	if !st.useAI {
		fail(apperr.Conflict("ai_not_configured", "ИИ-сервис не подключён — автонормализация работает через ИИ").
			Uz("SI xizmati ulanmagan — avtonormallashtirish SI orqali ishlaydi"))
		return
	}

	ids, err := s.candidates(ctx, in, limit)
	if err != nil {
		fail(err)
		return
	}
	st.add(func(x *Stats) { x.Total = len(ids) })
	s.saveStats(st)

	// Пачки по batch_size, параллельно concurrency.
	var batches [][]string
	for i := 0; i < len(ids); i += set.BatchSize {
		batches = append(batches, ids[i:min(i+set.BatchSize, len(ids))])
	}
	work := make(chan []string)
	var wg sync.WaitGroup
	var firstErr error
	var errMu sync.Mutex
	for w := 0; w < set.Concurrency; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for b := range work {
				if err := s.batch(ctx, st, b); err != nil {
					errMu.Lock()
					if firstErr == nil {
						firstErr = err
					}
					errMu.Unlock()
				}
				s.saveStats(st)
			}
		}()
	}
	for _, b := range batches {
		errMu.Lock()
		stop := firstErr != nil
		errMu.Unlock()
		if stop {
			break
		}
		work <- b
	}
	close(work)
	wg.Wait()
	if firstErr != nil {
		fail(firstErr)
		return
	}

	// Группы вариаций — по всем разобранным товарам.
	if err := s.planVariants(ctx, st); err != nil {
		fail(err)
		return
	}
	// Исправления карточек от магазинов (решаются сразу, не в «только посмотреть»).
	if !in.DryRun && len(in.SectionIDs) == 0 {
		if err := s.reviewSuggestions(ctx, st); err != nil {
			fail(err)
			return
		}
	}
	status := "done"
	if _, err := s.pool.Exec(ctx, `
		UPDATE catalog_norm_runs SET status = $2, stats = $3, finished_at = now(),
		       applied = NOT dry_run, applied_at = CASE WHEN dry_run THEN NULL ELSE now() END
		WHERE id = $1`, runID, status, st.snapshot()); err != nil {
		s.log.Error("catalognorm: итог прогона", "run", runID, "err", err)
	}
}

func (st *runState) snapshot() []byte {
	st.mu.Lock()
	defer st.mu.Unlock()
	b, _ := json.Marshal(st.stats)
	return b
}

func (s *Service) saveStats(st *runState) {
	if _, err := s.pool.Exec(context.Background(), `UPDATE catalog_norm_runs SET stats = $2 WHERE id = $1`, st.id, st.snapshot()); err != nil {
		s.log.Warn("catalognorm: счётчики", "err", err)
	}
}

// candidates — товары прогона: по разделам (текущая категория в разделе),
// порядок — категория, бренд, название (похожие товары в одной пачке).
func (s *Service) candidates(ctx context.Context, in StartInput, limit int) ([]string, error) {
	secs := in.SectionIDs
	if secs == nil {
		secs = []string{}
	}
	where := scopeWhere
	if in.OnlyNew {
		where = todoWhere
	}
	lim := "ALL"
	if limit > 0 {
		lim = strconv.Itoa(limit)
	}
	rows, err := s.pool.Query(ctx, `
		SELECT p.id::text FROM products p JOIN categories c ON c.id = p.category_id
		LEFT JOIN brands b ON b.id = p.brand_id
		WHERE `+where+`
		  AND (cardinality($1::uuid[]) = 0 OR p.category_id = ANY ($1::uuid[]) OR c.parent_id = ANY ($1::uuid[]))
		ORDER BY p.category_id, b.name NULLS LAST, p.name
		LIMIT `+lim, secs)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

// prod — товар пачки.
type prod struct {
	id, name, nameUz        string
	brandID, brand          string
	categoryID              string
	ikpu, ikpuName          string
	networkID               *string
	status                  string
	hasPhoto, hasBarcode    bool
	food, foodKnown         bool
	det                     string // название без ИИ (catalog.CleanName)
	newName, newUz, newCat  string
	line, lineUz            string
	flavor, flavorUz        string
	weight, weightUz        string
	moderation, reason      string // approved | rejected
	reasonUz, dupOf, dupNam string
}

func (s *Service) loadBatch(ctx context.Context, ids []string) ([]*prod, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT p.id::text, p.name, p.name_uz, COALESCE(p.brand_id::text, ''), COALESCE(b.name, ''), p.category_id::text,
		       COALESCE(p.attributes ->> 'ikpu', ''), COALESCE(p.attributes ->> 'ikpu_name', ''), p.network_id::text, p.moderation_status,
		       cardinality(p.images) > 0, EXISTS (SELECT 1 FROM product_barcodes pb WHERE pb.product_id = p.id)
		FROM products p LEFT JOIN brands b ON b.id = p.brand_id
		WHERE p.id = ANY ($1::uuid[]) AND `+scopeWhere+`
		ORDER BY p.category_id, b.name NULLS LAST, p.name`, ids)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (*prod, error) {
		p := &prod{}
		err := r.Scan(&p.id, &p.name, &p.nameUz, &p.brandID, &p.brand, &p.categoryID, &p.ikpu, &p.ikpuName, &p.networkID, &p.status,
			&p.hasPhoto, &p.hasBarcode)
		if err != nil {
			return nil, err
		}
		p.food, p.foodKnown = catalog.FoodIkpu(p.ikpu)
		p.det = catalog.CleanName(p.name, p.brand, p.food && p.foodKnown)
		p.newName, p.newUz, p.newCat = p.name, p.nameUz, p.categoryID
		return p, nil
	})
}

// askAI — запрос с одной повторной попыткой; расход — в ai_usage.
func askAI[T any](ctx context.Context, s *Service, st *runState, call func(context.Context) (T, ai.Usage, error)) (T, error) {
	var out T
	var err error
	for attempt := 0; attempt < 2; attempt++ {
		actx, cancel := context.WithTimeout(ctx, 150*time.Second)
		var u ai.Usage
		out, u, err = call(actx)
		cancel()
		if u.Input+u.Output > 0 || err == nil {
			st.add(func(x *Stats) { x.Input += u.Input; x.Output += u.Output })
			if rerr := s.ai.Record(context.WithoutCancel(ctx), ai.UsageRecord{Kind: "catalog_norm", Provider: st.conn.Provider,
				Model: st.conn.Model, Usage: u, OK: err == nil}); rerr != nil {
				s.log.Error("ai usage", "kind", "catalog_norm", "err", rerr)
			}
		}
		if err == nil {
			return out, nil
		}
		time.Sleep(2 * time.Second)
	}
	return out, err
}

// batch — одна пачка: ИИ → проверки → журнал (и сразу в товары, если не dry run).
func (s *Service) batch(ctx context.Context, st *runState, ids []string) error {
	ps, err := s.loadBatch(ctx, ids)
	if err != nil {
		return err
	}
	if len(ps) == 0 {
		return nil
	}
	short := map[string]*prod{}
	ask := ai.NormAsk{Categories: st.tree.codes}
	for i, p := range ps {
		code := "p" + strconv.Itoa(i+1)
		short[code] = p
		np := ai.NormProduct{ID: code, Name: p.name, Brand: p.brand, Mxik: clipRunes(p.ikpuName, 200), Category: st.tree.codeOf[p.categoryID]}
		if p.foodKnown {
			f := p.food
			np.Food = &f
		}
		ask.Products = append(ask.Products, np)
	}
	ans, err := askAI(ctx, s, st, func(c context.Context) (ai.NormAnswer, ai.Usage, error) { return st.conn.Normalize(c, ask) })
	if err != nil {
		// Пачка пропущена: товары остаются как были (norm_at не ставится —
		// автоматический прогон возьмёт их снова).
		s.log.Warn("catalognorm: ИИ не разобрал пачку", "run", st.id, "err", err)
		st.add(func(x *Stats) { x.Failed++ })
		return nil
	}
	got := map[*prod]bool{}
	var moves []ai.MoveAsk
	for _, it := range ans.Items {
		p := short[strings.TrimSpace(it.ID)]
		if p == nil || got[p] {
			continue
		}
		got[p] = true
		food := it.Food
		if p.foodKnown {
			food = p.food
		}
		if !food && !p.foodKnown {
			// Модель считает товар непищевым — тип остаётся; название без ИИ — тоже.
			p.det = catalog.CleanName(p.name, p.brand, false)
		} else if food && !p.foodKnown {
			p.det = catalog.CleanName(p.name, p.brand, true)
		}
		p.newName = p.det
		if name := tidyName(it.Name); goodName(name, p.det, p.brand) {
			p.newName = name
		}
		if uz := tidyName(it.NameUz); goodUz(uz, p.newName, p.brand) {
			p.newUz = uz
		}
		p.line, p.lineUz = clipRunes(tidyName(it.Line), 120), clipRunes(tidyName(it.LineUz), 120)
		p.flavor, p.flavorUz = clipRunes(tidyName(it.Flavor), 80), clipRunes(tidyName(it.FlavorUz), 80)
		p.weight, p.weightUz = clipRunes(tidyName(it.Weight), 40), clipRunes(tidyName(it.WeightUz), 40)
		if cat := st.tree.byCode[strings.TrimSpace(it.Category)]; cat != "" && cat != p.categoryID {
			from, okFrom := st.tree.root[p.categoryID]
			if !okFrom || st.tree.codeOf[p.categoryID] == "" || from == st.tree.root[cat] {
				// Та же секция, служебная или неактивная категория — сразу.
				p.newCat = cat
			} else {
				moves = append(moves, ai.MoveAsk{ID: it.ID, Name: p.newName, Mxik: clipRunes(p.ikpuName, 200),
					From: st.tree.path[p.categoryID], To: st.tree.path[cat]})
				p.newCat = "?" + cat
			}
		}
	}
	// Второе мнение о переносе в другой раздел.
	if len(moves) > 0 {
		ok := map[string]bool{}
		if mv, err := askAI(ctx, s, st, func(c context.Context) (ai.MoveAnswer, ai.Usage, error) { return st.conn.ConfirmMoves(c, moves) }); err == nil {
			for _, m := range mv.Items {
				ok[strings.TrimSpace(m.ID)] = m.Move
			}
		}
		for _, m := range moves {
			p := short[m.ID]
			if ok[m.ID] {
				p.newCat = strings.TrimPrefix(p.newCat, "?")
				st.add(func(x *Stats) { x.Moves++ })
			} else {
				p.newCat = p.categoryID
				st.add(func(x *Stats) { x.MovesKept++ })
			}
		}
	}
	// Товары магазинов на модерации.
	if err := s.moderate(ctx, st, ps, got); err != nil {
		return err
	}
	return s.record(ctx, st, ps, got)
}

// moderate — решения по товарам магазинов, которые ИИ разобрал в этой пачке.
func (s *Service) moderate(ctx context.Context, st *runState, ps []*prod, got map[*prod]bool) error {
	var asks []ai.ModerationAsk
	short := map[string]*prod{}
	sim := map[string]string{}
	for _, p := range ps {
		if !got[p] || p.status != "pending" {
			continue
		}
		code := "m" + strconv.Itoa(len(asks)+1)
		short[code] = p
		a := ai.ModerationAsk{ID: code, Name: p.newName, Brand: p.brand, Category: st.tree.path[strings.TrimPrefix(p.newCat, "?")],
			HasPhoto: p.hasPhoto, HasBarcode: p.hasBarcode}
		rows, err := s.pool.Query(ctx, `
			SELECT p.id::text, p.name FROM products p
			WHERE p.network_id IS NULL AND p.is_active AND p.kind = 'goods' AND p.id <> $2
			  AND lower(p.name) % lower($1)
			ORDER BY similarity(lower(p.name), lower($1)) DESC LIMIT 3`, p.newName, p.id)
		if err != nil {
			return err
		}
		for rows.Next() {
			var id, name string
			if err := rows.Scan(&id, &name); err != nil {
				rows.Close()
				return err
			}
			sc := "s" + strconv.Itoa(len(sim)+1)
			sim[sc] = id + "\x00" + name
			a.Similar = append(a.Similar, ai.ModerationSimilar{ID: sc, Name: name})
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		asks = append(asks, a)
	}
	if len(asks) == 0 {
		return nil
	}
	ans, err := askAI(ctx, s, st, func(c context.Context) (ai.ModerationAnswer, ai.Usage, error) { return st.conn.Moderate(c, asks) })
	if err != nil {
		// Без решения товары остаются на модерации — возьмём в следующий раз.
		for _, p := range short {
			got[p] = false
		}
		st.add(func(x *Stats) { x.Failed++ })
		return nil
	}
	for _, it := range ans.Items {
		p := short[strings.TrimSpace(it.ID)]
		if p == nil || p.moderation != "" {
			continue
		}
		reason, reasonUz := strings.TrimSpace(it.Reason), strings.TrimSpace(it.ReasonUz)
		switch it.Decision {
		case "duplicate":
			if v, ok := sim[strings.TrimSpace(it.DupOf)]; ok {
				id, name, _ := strings.Cut(v, "\x00")
				p.moderation, p.dupOf, p.dupNam = "rejected", id, name
				p.reason = "Такой товар уже есть в общей базе: «" + name + "»"
				p.reasonUz = "Bu mahsulot umumiy bazada allaqachon bor: «" + name + "»"
				continue
			}
			p.moderation = "approved"
		case "reject":
			if reason == "" {
				reason = "Карточка товара не подходит для общего каталога"
			}
			if reasonUz == "" {
				reasonUz = "Mahsulot kartochkasi umumiy katalogga mos emas"
			}
			p.moderation, p.reason, p.reasonUz = "rejected", clipRunes(reason, 300), clipRunes(reasonUz, 300)
		default:
			p.moderation = "approved"
		}
	}
	// Товары без ответа модели — в следующий раз.
	for _, p := range short {
		if p.moderation == "" {
			got[p] = false
		}
	}
	return nil
}

// record — журнал пачки; не dry run — сразу в товары.
func (s *Service) record(ctx context.Context, st *runState, ps []*prod, got map[*prod]bool) error {
	var rowIDs []int64
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		ins := func(p *prod, kind, old, nw string, detail any) error {
			d, _ := json.Marshal(detail)
			if detail == nil {
				d = []byte("{}")
			}
			var id int64
			if err := tx.QueryRow(ctx, `INSERT INTO catalog_norm_changes (run_id, product_id, kind, old_value, new_value, detail)
				VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`, st.id, p.id, kind, old, nw, d).Scan(&id); err != nil {
				return err
			}
			rowIDs = append(rowIDs, id)
			return nil
		}
		for _, p := range ps {
			if !got[p] {
				continue
			}
			if p.newName != p.name {
				if err := ins(p, "name", p.name, p.newName, nil); err != nil {
					return err
				}
				st.add(func(x *Stats) { x.Names++ })
			}
			if p.newUz != p.nameUz {
				if err := ins(p, "name_uz", p.nameUz, p.newUz, nil); err != nil {
					return err
				}
				st.add(func(x *Stats) { x.NamesUz++ })
			}
			if p.newCat != p.categoryID {
				if err := ins(p, "category", p.categoryID, p.newCat, nil); err != nil {
					return err
				}
				st.add(func(x *Stats) { x.Categories++ })
			}
			if p.moderation != "" {
				old := ""
				if p.networkID != nil {
					old = *p.networkID
				}
				if err := ins(p, "moderation", old, p.moderation, map[string]string{"reason": p.reason, "reason_uz": p.reasonUz,
					"duplicate_of": p.dupOf, "duplicate_name": p.dupNam}); err != nil {
					return err
				}
				st.add(func(x *Stats) {
					switch {
					case p.dupOf != "":
						x.Duplicate++
					case p.moderation == "approved":
						x.Approved++
					default:
						x.Rejected++
					}
				})
			}
			norm := map[string]string{"line": p.line, "line_uz": p.lineUz, "flavor": p.flavor, "flavor_uz": p.flavorUz,
				"weight": p.weight, "weight_uz": p.weightUz}
			if err := ins(p, "norm", "", "", norm); err != nil {
				return err
			}
			st.add(func(x *Stats) { x.Processed++ })
			// Для групп вариаций: товары общего каталога (и одобренные сейчас).
			common := p.networkID == nil || p.moderation == "approved" && p.dupOf == ""
			st.mu.Lock()
			st.result[p.id] = result{productID: p.id, brandID: p.brandID, categoryID: p.newCat, line: p.line, lineUz: p.lineUz,
				flavor: p.flavor, flavorUz: p.flavorUz, weight: p.weight, weightUz: p.weightUz, common: common}
			st.mu.Unlock()
		}
		return nil
	})
	if err != nil || st.dry || len(rowIDs) == 0 {
		return err
	}
	return s.applyRows(ctx, st.id, rowIDs)
}

// ---------------------------------------------------------------- проверки ответа ИИ

var numRe = regexp.MustCompile(`\d+(?:[.,]\d+)?`)

func tidyName(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	return strings.Trim(s, " ,;")
}

func clipRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return strings.TrimSpace(string(r[:n]))
}

// numbers — числа названия: «0.150» и «0,15» — одно и то же.
func numbers(s string) map[string]bool {
	out := map[string]bool{}
	for _, n := range numRe.FindAllString(s, -1) {
		out[catalog.FormatAmount(n)] = true
	}
	return out
}

func foldBrand(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// goodName — название от ИИ можно брать: не пустое, бренд на месте, ни одно
// число из исходного (очищенного) названия не потерялось.
func goodName(name, det, brand string) bool {
	if name == "" || utf8.RuneCountInString(name) > 200 {
		return false
	}
	if fb := foldBrand(brand); fb != "" && strings.Contains(foldBrand(det), fb) && !strings.Contains(foldBrand(name), fb) {
		return false
	}
	have := numbers(name)
	for n := range numbers(det) {
		if !have[n] {
			return false
		}
	}
	return true
}

// goodUz — узбекское название: латиница (кириллица допустима только в
// бренде), те же числа, что в русском.
func goodUz(uz, ru, brand string) bool {
	if uz == "" || utf8.RuneCountInString(uz) > 200 {
		return false
	}
	rest := uz
	if brand != "" {
		rest = strings.ReplaceAll(strings.ToLower(rest), strings.ToLower(brand), "")
	}
	for _, r := range rest {
		if unicode.Is(unicode.Cyrillic, r) {
			return false
		}
	}
	have := numbers(uz)
	for n := range numbers(ru) {
		if !have[n] {
			return false
		}
	}
	return true
}

// sortedKeys — для стабильного порядка групп.
func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
