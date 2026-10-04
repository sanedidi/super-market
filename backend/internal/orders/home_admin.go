package orders

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/showcase"
)

// Редактор главной: шаблон платформы, витрина сети или одного магазина.
// Правки копятся в черновике, приложение видит только опубликованное;
// каждая публикация — новая версия, к любой можно вернуться. Супер-админ
// правит шаблон и витрины сетей, сеть — свою витрину в пределах тарифа
// (showcase.go).

// LayoutScope — чья витрина: ничего — шаблон платформы, сеть, магазин сети.
type LayoutScope struct {
	NetworkID string
	StoreID   string
}

func (sc LayoutScope) level() string {
	switch {
	case sc.StoreID != "":
		return "store"
	case sc.NetworkID != "":
		return "network"
	}
	return "platform"
}

// LayoutEditor — витрина для редактора.
type LayoutEditor struct {
	NetworkID   string     `json:"network_id,omitempty"`
	NetworkName string     `json:"network_name,omitempty"`
	StoreID     string     `json:"store_id,omitempty"`
	StoreName   string     `json:"store_name,omitempty"`
	Version     int        `json:"version"`
	PublishedAt *time.Time `json:"published_at"`
	// Опубликованные блоки. Без своей витрины — то, что видят покупатели
	// сейчас (шаблон или витрина сети, inherited = true); с этого и
	// начинается черновик.
	Blocks    []HomeBlock `json:"blocks"`
	Inherited bool        `json:"inherited"`
	// Черновик; null — правок нет.
	Draft          []HomeBlock `json:"draft"`
	DraftUpdatedAt *time.Time  `json:"draft_updated_at"`
}

// LayoutVersion — опубликованная версия витрины.
type LayoutVersion struct {
	Version     int       `json:"version"`
	PublishedAt time.Time `json:"published_at"`
	PublishedBy string    `json:"published_by"`
	Blocks      int       `json:"blocks"`
}

type layoutRow struct {
	id          string
	version     int
	publishedAt *time.Time
	blocks      []HomeBlock
	draft       []HomeBlock
	draftAt     *time.Time
	byStore     bool
}

// checkScope проверяет сеть и магазин и возвращает их названия.
func (s *Service) checkScope(ctx context.Context, sc LayoutScope) (network, store string, err error) {
	if sc.NetworkID == "" {
		return "", "", nil
	}
	if !httpx.IsUUID(sc.NetworkID) {
		return "", "", apperr.NotFound("сеть не найдена")
	}
	err = s.pool.QueryRow(ctx, `SELECT name FROM networks WHERE id = $1`, sc.NetworkID).Scan(&network)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", apperr.NotFound("сеть не найдена")
	}
	if err != nil || sc.StoreID == "" {
		return network, "", err
	}
	if !httpx.IsUUID(sc.StoreID) {
		return "", "", apperr.NotFound("магазин не найден")
	}
	err = s.pool.QueryRow(ctx, `SELECT name FROM stores WHERE id = $1 AND network_id = $2`, sc.StoreID, sc.NetworkID).Scan(&store)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", apperr.NotFound("магазин не найден")
	}
	return network, store, err
}

type rowQuerier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// layout читает витрину уровня; ok = false — строки ещё нет.
func (s *Service) layout(ctx context.Context, q rowQuerier, sc LayoutScope, lock bool) (row layoutRow, ok bool, err error) {
	if q == nil {
		q = s.pool
	}
	sql := `SELECT id, version, published_at, blocks, draft, draft_updated_at, by_store FROM home_layouts WHERE `
	args := []any{}
	switch sc.level() {
	case "store":
		sql += `scope = 'store' AND store_id = $1`
		args = append(args, sc.StoreID)
	case "network":
		sql += `scope = 'network' AND network_id = $1`
		args = append(args, sc.NetworkID)
	default:
		sql += `scope = 'platform'`
	}
	if lock {
		sql += ` FOR UPDATE`
	}
	var blocks, draft []byte
	err = q.QueryRow(ctx, sql, args...).Scan(&row.id, &row.version, &row.publishedAt, &blocks, &draft, &row.draftAt, &row.byStore)
	if errors.Is(err, pgx.ErrNoRows) {
		return row, false, nil
	}
	if err != nil {
		return row, false, err
	}
	if err := json.Unmarshal(blocks, &row.blocks); err != nil {
		return row, false, err
	}
	if draft != nil {
		if err := json.Unmarshal(draft, &row.draft); err != nil {
			return row, false, err
		}
	}
	return row, true, nil
}

// published — опубликованные блоки уровня (nil — своей витрины нет).
func (s *Service) published(ctx context.Context, sc LayoutScope) ([]HomeBlock, bool, error) {
	row, ok, err := s.layout(ctx, nil, sc, false)
	if err != nil || !ok || row.version == 0 {
		return nil, false, err
	}
	return row.blocks, true, nil
}

// inheritedBlocks — что видят покупатели уровня без своей витрины.
func (s *Service) inheritedBlocks(ctx context.Context, sc LayoutScope) ([]HomeBlock, error) {
	if sc.level() == "store" {
		if b, ok, err := s.published(ctx, LayoutScope{NetworkID: sc.NetworkID}); err != nil || ok {
			return b, err
		}
	}
	b, _, err := s.published(ctx, LayoutScope{})
	return b, err
}

// LayoutForEditor — витрина уровня с черновиком.
func (s *Service) LayoutForEditor(ctx context.Context, sc LayoutScope) (LayoutEditor, error) {
	network, store, err := s.checkScope(ctx, sc)
	if err != nil {
		return LayoutEditor{}, err
	}
	out := LayoutEditor{NetworkID: sc.NetworkID, NetworkName: network, StoreID: sc.StoreID, StoreName: store, Blocks: []HomeBlock{}}
	row, ok, err := s.layout(ctx, nil, sc, false)
	if err != nil {
		return out, err
	}
	if ok {
		out.Version, out.PublishedAt, out.Draft, out.DraftUpdatedAt = row.version, row.publishedAt, row.draft, row.draftAt
		if row.version > 0 {
			out.Blocks = row.blocks
		}
	}
	if sc.level() != "platform" && out.Version == 0 {
		if out.Blocks, err = s.inheritedBlocks(ctx, sc); err != nil {
			return out, err
		}
		out.Inherited = true
	}
	if out.Blocks == nil {
		out.Blocks = []HomeBlock{}
	}
	return out, nil
}

// SaveDraft сохраняет черновик (приложение его не видит).
func (s *Service) SaveDraft(ctx context.Context, sc LayoutScope, blocks []HomeBlock) (LayoutEditor, error) {
	if _, _, err := s.checkScope(ctx, sc); err != nil {
		return LayoutEditor{}, err
	}
	if blocks == nil {
		blocks = []HomeBlock{}
	}
	if err := ValidateBlocks(blocks); err != nil {
		return LayoutEditor{}, err
	}
	for i := range blocks {
		blocks[i].Products, blocks[i].Banners = nil, nil
	}
	raw, _ := json.Marshal(blocks)
	var err error
	switch sc.level() {
	case "platform":
		_, err = s.pool.Exec(ctx, `UPDATE home_layouts SET draft = $1, draft_updated_at = now(), updated_at = now() WHERE scope = 'platform'`, raw)
	case "network":
		_, err = s.pool.Exec(ctx, `
			INSERT INTO home_layouts (scope, network_id, blocks, version, published_at, draft, draft_updated_at)
			VALUES ('network', $1, '[]', 0, NULL, $2, now())
			ON CONFLICT (network_id) WHERE scope = 'network'
			DO UPDATE SET draft = EXCLUDED.draft, draft_updated_at = now(), updated_at = now()`, sc.NetworkID, raw)
	case "store":
		_, err = s.pool.Exec(ctx, `
			INSERT INTO home_layouts (scope, network_id, store_id, blocks, version, published_at, draft, draft_updated_at)
			VALUES ('store', $1, $2, '[]', 0, NULL, $3, now())
			ON CONFLICT (store_id) WHERE scope = 'store'
			DO UPDATE SET draft = EXCLUDED.draft, draft_updated_at = now(), updated_at = now()`, sc.NetworkID, sc.StoreID, raw)
	}
	if err != nil {
		return LayoutEditor{}, err
	}
	return s.LayoutForEditor(ctx, sc)
}

func scopeWhere(sc LayoutScope) (string, []any) {
	switch sc.level() {
	case "store":
		return `scope = 'store' AND store_id = $1`, []any{sc.StoreID}
	case "network":
		return `scope = 'network' AND network_id = $1`, []any{sc.NetworkID}
	}
	return `scope = 'platform'`, nil
}

// DiscardDraft отменяет правки.
func (s *Service) DiscardDraft(ctx context.Context, sc LayoutScope) (LayoutEditor, error) {
	if _, _, err := s.checkScope(ctx, sc); err != nil {
		return LayoutEditor{}, err
	}
	where, args := scopeWhere(sc)
	// Без опубликованной витрины строка была только ради черновика.
	if sc.level() != "platform" {
		if _, err := s.pool.Exec(ctx, `DELETE FROM home_layouts WHERE version = 0 AND `+where, args...); err != nil {
			return LayoutEditor{}, err
		}
	}
	if _, err := s.pool.Exec(ctx, `UPDATE home_layouts SET draft = NULL, draft_updated_at = NULL WHERE `+where, args...); err != nil {
		return LayoutEditor{}, err
	}
	return s.LayoutForEditor(ctx, sc)
}

// Publish делает черновик витриной: новая версия, кэш главных сброшен.
// check — проверка блоков перед публикацией (лимиты тарифа у магазина);
// byStore — опубликовала сеть (тогда при показе действует её тариф).
func (s *Service) Publish(ctx context.Context, sc LayoutScope, userID string, byStore bool, check func([]HomeBlock) error) (LayoutEditor, error) {
	if _, _, err := s.checkScope(ctx, sc); err != nil {
		return LayoutEditor{}, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return LayoutEditor{}, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	row, ok, err := s.layout(ctx, tx, sc, true)
	if err != nil {
		return LayoutEditor{}, err
	}
	if !ok || row.draft == nil {
		return LayoutEditor{}, apperr.Conflict("no_draft", "нет изменений для публикации")
	}
	if err := ValidateBlocks(row.draft); err != nil {
		return LayoutEditor{}, err
	}
	if check != nil {
		if err := check(row.draft); err != nil {
			return LayoutEditor{}, err
		}
	}
	var by *string
	if httpx.IsUUID(userID) {
		by = &userID
	}
	raw, _ := json.Marshal(row.draft)
	next := row.version + 1
	if _, err := tx.Exec(ctx, `
		UPDATE home_layouts SET blocks = $2, version = $3, published_at = now(), published_by = $4, by_store = $5,
			draft = NULL, draft_updated_at = NULL, updated_at = now()
		WHERE id = $1`, row.id, raw, next, by, byStore); err != nil {
		return LayoutEditor{}, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO home_layout_versions (layout_id, version, blocks, published_by) VALUES ($1, $2, $3, $4)`,
		row.id, next, raw, by); err != nil {
		return LayoutEditor{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return LayoutEditor{}, err
	}
	s.forgetHomes()
	return s.LayoutForEditor(ctx, sc)
}

// Versions — история публикаций, новые сверху.
func (s *Service) Versions(ctx context.Context, sc LayoutScope) ([]LayoutVersion, error) {
	if _, _, err := s.checkScope(ctx, sc); err != nil {
		return nil, err
	}
	row, ok, err := s.layout(ctx, nil, sc, false)
	out := []LayoutVersion{}
	if err != nil || !ok {
		return out, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT v.version, v.published_at, COALESCE(NULLIF(u.full_name, ''), u.phone, ''), jsonb_array_length(v.blocks)
		FROM home_layout_versions v LEFT JOIN users u ON u.id = v.published_by
		WHERE v.layout_id = $1 ORDER BY v.version DESC LIMIT 50`, row.id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var v LayoutVersion
		if err := rows.Scan(&v.Version, &v.PublishedAt, &v.PublishedBy, &v.Blocks); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

// RestoreVersion кладёт блоки старой версии в черновик — опубликовать их
// нужно отдельно, после проверки.
func (s *Service) RestoreVersion(ctx context.Context, sc LayoutScope, version int) (LayoutEditor, error) {
	if _, _, err := s.checkScope(ctx, sc); err != nil {
		return LayoutEditor{}, err
	}
	row, ok, err := s.layout(ctx, nil, sc, false)
	if err != nil {
		return LayoutEditor{}, err
	}
	if !ok {
		return LayoutEditor{}, apperr.NotFound("версия не найдена")
	}
	tag, err := s.pool.Exec(ctx, `
		UPDATE home_layouts l SET draft = v.blocks, draft_updated_at = now(), updated_at = now()
		FROM home_layout_versions v WHERE l.id = $1 AND v.layout_id = l.id AND v.version = $2`, row.id, version)
	if err != nil {
		return LayoutEditor{}, err
	}
	if tag.RowsAffected() == 0 {
		return LayoutEditor{}, apperr.NotFound("версия не найдена")
	}
	return s.LayoutForEditor(ctx, sc)
}

// ResetLayout убирает витрину сети или магазина: покупатели снова видят
// витрину уровнем выше.
func (s *Service) ResetLayout(ctx context.Context, sc LayoutScope) (LayoutEditor, error) {
	if sc.level() == "platform" {
		return LayoutEditor{}, apperr.Validation("шаблон платформы удалить нельзя")
	}
	if _, _, err := s.checkScope(ctx, sc); err != nil {
		return LayoutEditor{}, err
	}
	where, args := scopeWhere(sc)
	if _, err := s.pool.Exec(ctx, `DELETE FROM home_layouts WHERE `+where, args...); err != nil {
		return LayoutEditor{}, err
	}
	s.forgetHomes()
	return s.LayoutForEditor(ctx, sc)
}

// PreviewHome — главная магазина из переданных блоков (для предпросмотра в
// редакторе): с настоящими товарами и баннерами, без кэша. networkID не
// пуст — магазин должен быть этой сети.
func (s *Service) PreviewHome(ctx context.Context, networkID, storeID string, blocks []HomeBlock) (StoreHome, error) {
	if blocks == nil {
		blocks = []HomeBlock{}
	}
	if err := ValidateBlocks(blocks); err != nil {
		return StoreHome{}, err
	}
	st, err := s.storeForBrowse(ctx, s.pool, storeID)
	if err != nil {
		return StoreHome{}, err
	}
	if networkID != "" && st.NetworkID != networkID {
		return StoreHome{}, apperr.NotFound("магазин не найден")
	}
	plan, err := showcase.ForNetwork(ctx, s.pool, st.NetworkID)
	if err != nil {
		return StoreHome{}, err
	}
	platform, _, err := s.published(ctx, LayoutScope{})
	if err != nil {
		return StoreHome{}, err
	}
	filled, err := s.fillBlocks(ctx, storeID, st.NetworkID, mergePinned(platform, blocks), s.now(), true, showcase.Allowed(plan.Effective.Banners))
	return StoreHome{Blocks: filled}, err
}

// PreviewStore — магазин для предпросмотра в списке редактора.
type PreviewStore struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	NetworkID   string `json:"network_id"`
	NetworkName string `json:"network_name"`
	// Принимает заказы — по нему можно смотреть предпросмотр.
	Online bool `json:"online"`
}

// PreviewStores — магазины для предпросмотра; online = false — пока не
// принимает заказы (предпросмотр недоступен). Для сети — только её.
func (s *Service) PreviewStores(ctx context.Context, networkID string, onlyOnline bool) ([]PreviewStore, error) {
	if networkID != "" && !httpx.IsUUID(networkID) {
		return nil, apperr.NotFound("сеть не найдена")
	}
	rows, err := s.pool.Query(ctx, `
		SELECT s.id, s.name, n.id, n.name, s.accepts_online AND s.status = 'active' AND n.status = 'active'
		FROM stores s JOIN networks n ON n.id = s.network_id
		WHERE ($1 = '' OR n.id::text = $1) AND s.status = 'active'
		  AND (NOT $2 OR (s.accepts_online AND n.status = 'active'))
		ORDER BY n.name, s.name LIMIT 200`, networkID, onlyOnline)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []PreviewStore{}
	for rows.Next() {
		var p PreviewStore
		if err := rows.Scan(&p.ID, &p.Name, &p.NetworkID, &p.NetworkName, &p.Online); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}
