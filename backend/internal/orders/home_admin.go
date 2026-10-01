package orders

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Редактор главной в админке («Каталог → Главная приложения»): шаблон для
// всех сетей или витрина одной сети. Правки копятся в черновике, приложение
// видит только опубликованное; каждая публикация — новая версия, к любой
// можно вернуться.

// LayoutEditor — витрина для редактора.
type LayoutEditor struct {
	// "" — шаблон платформы, иначе сеть.
	NetworkID   string     `json:"network_id,omitempty"`
	NetworkName string     `json:"network_name,omitempty"`
	Version     int        `json:"version"`
	PublishedAt *time.Time `json:"published_at"`
	// Опубликованные блоки. Сеть без своей витрины видит шаблон платформы
	// (inherited = true) — с него и начинается её черновик.
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
}

func (s *Service) checkNetwork(ctx context.Context, networkID string) (string, error) {
	if networkID == "" {
		return "", nil
	}
	if !httpx.IsUUID(networkID) {
		return "", apperr.NotFound("сеть не найдена")
	}
	var name string
	err := s.pool.QueryRow(ctx, `SELECT name FROM networks WHERE id = $1`, networkID).Scan(&name)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", apperr.NotFound("сеть не найдена")
	}
	return name, err
}

// layout читает витрину уровня; ok = false — строки ещё нет.
func (s *Service) layout(ctx context.Context, q pgx.Tx, networkID string, lock bool) (row layoutRow, ok bool, err error) {
	sql := `SELECT id, version, published_at, blocks, draft, draft_updated_at FROM home_layouts WHERE `
	args := []any{}
	if networkID == "" {
		sql += `scope = 'platform'`
	} else {
		sql += `scope = 'network' AND network_id = $1`
		args = append(args, networkID)
	}
	if lock {
		sql += ` FOR UPDATE`
	}
	var blocks, draft []byte
	var qr pgx.Row
	if q != nil {
		qr = q.QueryRow(ctx, sql, args...)
	} else {
		qr = s.pool.QueryRow(ctx, sql, args...)
	}
	err = qr.Scan(&row.id, &row.version, &row.publishedAt, &blocks, &draft, &row.draftAt)
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

// LayoutForEditor — витрина шаблона или сети с черновиком.
func (s *Service) LayoutForEditor(ctx context.Context, networkID string) (LayoutEditor, error) {
	name, err := s.checkNetwork(ctx, networkID)
	if err != nil {
		return LayoutEditor{}, err
	}
	out := LayoutEditor{NetworkID: networkID, NetworkName: name, Blocks: []HomeBlock{}}
	row, ok, err := s.layout(ctx, nil, networkID, false)
	if err != nil {
		return out, err
	}
	if ok {
		out.Version, out.PublishedAt, out.Draft, out.DraftUpdatedAt = row.version, row.publishedAt, row.draft, row.draftAt
		if row.version > 0 {
			out.Blocks = row.blocks
		}
	}
	if networkID != "" && out.Version == 0 {
		platform, _, err := s.layout(ctx, nil, "", false)
		if err != nil {
			return out, err
		}
		out.Blocks, out.Inherited = platform.blocks, true
	}
	if out.Blocks == nil {
		out.Blocks = []HomeBlock{}
	}
	return out, nil
}

// SaveDraft сохраняет черновик (приложение его не видит).
func (s *Service) SaveDraft(ctx context.Context, networkID string, blocks []HomeBlock) (LayoutEditor, error) {
	if _, err := s.checkNetwork(ctx, networkID); err != nil {
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
	if networkID == "" {
		_, err = s.pool.Exec(ctx, `UPDATE home_layouts SET draft = $1, draft_updated_at = now(), updated_at = now() WHERE scope = 'platform'`, raw)
	} else {
		_, err = s.pool.Exec(ctx, `
			INSERT INTO home_layouts (scope, network_id, blocks, version, published_at, draft, draft_updated_at)
			VALUES ('network', $1, '[]', 0, NULL, $2, now())
			ON CONFLICT (network_id) WHERE scope = 'network'
			DO UPDATE SET draft = EXCLUDED.draft, draft_updated_at = now(), updated_at = now()`, networkID, raw)
	}
	if err != nil {
		return LayoutEditor{}, err
	}
	return s.LayoutForEditor(ctx, networkID)
}

// DiscardDraft отменяет правки.
func (s *Service) DiscardDraft(ctx context.Context, networkID string) (LayoutEditor, error) {
	if _, err := s.checkNetwork(ctx, networkID); err != nil {
		return LayoutEditor{}, err
	}
	var err error
	if networkID == "" {
		_, err = s.pool.Exec(ctx, `UPDATE home_layouts SET draft = NULL, draft_updated_at = NULL WHERE scope = 'platform'`)
	} else {
		// Сеть без опубликованной витрины — строка была только ради черновика.
		_, err = s.pool.Exec(ctx, `DELETE FROM home_layouts WHERE scope = 'network' AND network_id = $1 AND version = 0`, networkID)
		if err == nil {
			_, err = s.pool.Exec(ctx, `UPDATE home_layouts SET draft = NULL, draft_updated_at = NULL WHERE scope = 'network' AND network_id = $1`, networkID)
		}
	}
	if err != nil {
		return LayoutEditor{}, err
	}
	return s.LayoutForEditor(ctx, networkID)
}

// Publish делает черновик витриной: новая версия, кэш главных сброшен.
func (s *Service) Publish(ctx context.Context, networkID, userID string) (LayoutEditor, error) {
	if _, err := s.checkNetwork(ctx, networkID); err != nil {
		return LayoutEditor{}, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return LayoutEditor{}, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	row, ok, err := s.layout(ctx, tx, networkID, true)
	if err != nil {
		return LayoutEditor{}, err
	}
	if !ok || row.draft == nil {
		return LayoutEditor{}, apperr.Conflict("no_draft", "нет изменений для публикации")
	}
	if err := ValidateBlocks(row.draft); err != nil {
		return LayoutEditor{}, err
	}
	var by *string
	if httpx.IsUUID(userID) {
		by = &userID
	}
	raw, _ := json.Marshal(row.draft)
	next := row.version + 1
	if _, err := tx.Exec(ctx, `
		UPDATE home_layouts SET blocks = $2, version = $3, published_at = now(), published_by = $4,
			draft = NULL, draft_updated_at = NULL, updated_at = now()
		WHERE id = $1`, row.id, raw, next, by); err != nil {
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
	return s.LayoutForEditor(ctx, networkID)
}

// Versions — история публикаций, новые сверху.
func (s *Service) Versions(ctx context.Context, networkID string) ([]LayoutVersion, error) {
	if _, err := s.checkNetwork(ctx, networkID); err != nil {
		return nil, err
	}
	row, ok, err := s.layout(ctx, nil, networkID, false)
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
func (s *Service) RestoreVersion(ctx context.Context, networkID string, version int) (LayoutEditor, error) {
	if _, err := s.checkNetwork(ctx, networkID); err != nil {
		return LayoutEditor{}, err
	}
	row, ok, err := s.layout(ctx, nil, networkID, false)
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
	return s.LayoutForEditor(ctx, networkID)
}

// ResetNetwork убирает витрину сети: её магазины снова видят шаблон.
func (s *Service) ResetNetwork(ctx context.Context, networkID string) (LayoutEditor, error) {
	if networkID == "" {
		return LayoutEditor{}, apperr.Validation("шаблон платформы удалить нельзя")
	}
	if _, err := s.checkNetwork(ctx, networkID); err != nil {
		return LayoutEditor{}, err
	}
	if _, err := s.pool.Exec(ctx, `DELETE FROM home_layouts WHERE scope = 'network' AND network_id = $1`, networkID); err != nil {
		return LayoutEditor{}, err
	}
	s.forgetHomes()
	return s.LayoutForEditor(ctx, networkID)
}

// PreviewHome — главная магазина из переданных блоков (для предпросмотра в
// редакторе): с настоящими товарами и баннерами, без кэша.
func (s *Service) PreviewHome(ctx context.Context, storeID string, blocks []HomeBlock) (StoreHome, error) {
	if blocks == nil {
		blocks = []HomeBlock{}
	}
	if err := ValidateBlocks(blocks); err != nil {
		return StoreHome{}, err
	}
	st, err := s.storeForClient(ctx, s.pool, storeID)
	if err != nil {
		return StoreHome{}, err
	}
	filled, err := s.fillBlocks(ctx, storeID, st.NetworkID, blocks, s.now())
	return StoreHome{Blocks: filled}, err
}

// PreviewStore — магазин для предпросмотра в списке редактора.
type PreviewStore struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	NetworkID   string `json:"network_id"`
	NetworkName string `json:"network_name"`
}

// PreviewStores — магазины, которые принимают заказы (на них можно смотреть
// предпросмотр); для сети — только её.
func (s *Service) PreviewStores(ctx context.Context, networkID string) ([]PreviewStore, error) {
	if networkID != "" && !httpx.IsUUID(networkID) {
		return nil, apperr.NotFound("сеть не найдена")
	}
	rows, err := s.pool.Query(ctx, `
		SELECT s.id, s.name, n.id, n.name FROM stores s JOIN networks n ON n.id = s.network_id
		WHERE s.accepts_online AND s.status = 'active' AND n.status = 'active'
		  AND ($1 = '' OR n.id::text = $1)
		ORDER BY n.name, s.name LIMIT 200`, networkID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []PreviewStore{}
	for rows.Next() {
		var p PreviewStore
		if err := rows.Scan(&p.ID, &p.Name, &p.NetworkID, &p.NetworkName); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}
