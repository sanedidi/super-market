package field

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// «Зайти потом» (П8–П11): продажник увидел магазин по дороге — одно нажатие
// «Потом», жёлтый флажок там, где он стоит, и идёт дальше. Флажки видят все
// продажники; флажок закрывается, когда кто-то отмечает магазин рядом.

const (
	// flagMaxAccuracyM — точность хуже — «подождите, уточняем место».
	flagMaxAccuracyM = 30.0
	// flagDupM — ближе уже стоит открытый флажок — второй не ставим.
	flagDupM = 30
	// flagPlaceM — ближе уже отмечен магазин с результатом — флажок не нужен.
	flagPlaceM = 50
	// flagCloseM — отметка магазина ближе этого закрывает флажок.
	flagCloseM = 50
	// flagNearM — во время обхода ближе этого: «Рядом флажок — 60 м».
	flagNearM = 100
	// flagOldDays — флажок старше — «давно».
	flagOldDays = 14
	// maxFlags — сколько флажков отдаём за раз.
	maxFlags = 2000
)

// Flag — флажок «зайти потом».
type Flag struct {
	ID       string  `json:"id"`
	Lat      float64 `json:"lat"`
	Lng      float64 `json:"lng"`
	Name     string  `json:"name"`
	PhotoURL string  `json:"photo_url"`
	// open, visited, removed.
	Status  string `json:"status"`
	RepID   string `json:"rep_id"`
	RepName string `json:"rep_name"`
	// Флажок поставил этот продажник.
	Mine      bool      `json:"mine"`
	CreatedAt time.Time `json:"created_at"`
	// Висит дольше 14 дней.
	Old         bool       `json:"old"`
	CloseReason string     `json:"close_reason"`
	ClosedAt    *time.Time `json:"closed_at"`
	ClosedBy    string     `json:"closed_by"`
	// rep — поставил продажник; osm — продуктовый магазин с карты OpenStreetMap (автора нет).
	Source string `json:"source"`
	// Тип магазина на карте OSM: convenience, supermarket, greengrocer …
	Shop      string `json:"shop"`
	DistanceM *int   `json:"distance_m,omitempty"`
}

// flagCols — колонки Flag; $me — продажник (пустая строка — супер-админ).
func flagCols(me int) string {
	return `f.id, ST_Y(f.location::geometry), ST_X(f.location::geometry), f.name, f.photo_url, f.status,
	       COALESCE(f.rep_id::text, ''), COALESCE(fr.full_name, ''), COALESCE(f.rep_id::text = $` + itoa(me) + `, false), f.created_at,
	       f.created_at < now() - interval '` + itoa(flagOldDays) + ` days', f.close_reason, f.closed_at, COALESCE(cb.full_name, ''),
	       f.source, f.shop`
}

const flagJoins = `
	FROM field_flags f
	LEFT JOIN field_reps fr ON fr.id = f.rep_id
	LEFT JOIN field_reps cb ON cb.id = f.closed_by`

func scanFlag(row pgx.CollectableRow) (Flag, error) {
	var f Flag
	err := row.Scan(&f.ID, &f.Lat, &f.Lng, &f.Name, &f.PhotoURL, &f.Status, &f.RepID, &f.RepName, &f.Mine, &f.CreatedAt,
		&f.Old, &f.CloseReason, &f.ClosedAt, &f.ClosedBy, &f.Source, &f.Shop)
	return f, err
}

func scanFlagDist(row pgx.CollectableRow) (Flag, error) {
	var (
		f Flag
		d int
	)
	err := row.Scan(&f.ID, &f.Lat, &f.Lng, &f.Name, &f.PhotoURL, &f.Status, &f.RepID, &f.RepName, &f.Mine, &f.CreatedAt,
		&f.Old, &f.CloseReason, &f.ClosedAt, &f.ClosedBy, &f.Source, &f.Shop, &d)
	f.DistanceM = &d
	return f, err
}

// ptSQL — точка продажника: $2 — широта, $3 — долгота.
const ptSQL = `ST_SetSRID(ST_MakePoint($3::float8, $2::float8), 4326)::geography`

func errFlagNotFound() error {
	return apperr.NotFound("флажок не найден").Uz("bayroqcha topilmadi")
}

func errFlagClosed() error {
	return apperr.Conflict("flag_closed", "флажок уже закрыт — магазин отметили или убрали").Uz("bayroqcha allaqachon yopilgan — doʻkon belgilangan yoki olib tashlangan")
}

// FlagInput — поставить флажок (там, где стоит продажник).
type FlagInput struct {
	Lat      *float64 `json:"lat"`
	Lng      *float64 `json:"lng"`
	Accuracy *float64 `json:"accuracy"`
	Name     string   `json:"name"`
	PhotoURL string   `json:"photo_url"`
}

// FlagPatch — фото и название (по желанию; null — не менять).
type FlagPatch struct {
	Name     *string `json:"name"`
	PhotoURL *string `json:"photo_url"`
}

func cleanFlagText(name, photo *string) error {
	if name != nil {
		*name = strings.TrimSpace(*name)
		if len([]rune(*name)) > 120 {
			return apperr.Validation("name: не длиннее 120 символов").Uz("name: 120 belgidan oshmasin")
		}
	}
	if photo != nil {
		*photo = strings.TrimSpace(*photo)
		if len(*photo) > 500 {
			return apperr.Validation("photo_url: слишком длинная ссылка").Uz("photo_url: havola juda uzun")
		}
	}
	return nil
}

// CreateFlag — «Потом» (П8): флажок там, где стоит продажник, только во время обхода.
// Рядом уже флажок — 409 flag_near (details.flag); рядом уже отмечен магазин — 409 place_near (details.place).
func (s *Service) CreateFlag(ctx context.Context, p *identity.Principal, in FlagInput) (Flag, error) {
	if err := requireRep(p); err != nil {
		return Flag{}, err
	}
	if in.Lat == nil || in.Lng == nil || *in.Lat < -90 || *in.Lat > 90 || *in.Lng < -180 || *in.Lng > 180 {
		return Flag{}, apperr.Validation("lat/lng: нет геопозиции — включите GPS").Uz("lat/lng: geojoylashuv yoʻq — GPS ni yoqing")
	}
	if in.Accuracy != nil && *in.Accuracy > flagMaxAccuracyM {
		return Flag{}, apperr.Conflict("low_accuracy", "подождите — уточняем место").Uz("kuting — joylashuv aniqlanmoqda").
			WithDetails(map[string]any{"accuracy": int(*in.Accuracy)})
	}
	if err := cleanFlagText(&in.Name, &in.PhotoURL); err != nil {
		return Flag{}, err
	}
	var id string
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var walkID string
		err := tx.QueryRow(ctx, `SELECT id FROM field_walks WHERE rep_id = $1 AND status <> 'ended'`, p.RepID).Scan(&walkID)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Conflict("no_walk", "флажок ставится во время обхода — начните обход").Uz("bayroqcha aylanish vaqtida qoʻyiladi — aylanishni boshlang")
		}
		if err != nil {
			return err
		}
		// Два продажника у одного магазина одновременно — по очереди.
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('field_flags'))`); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT `+flagCols(1)+`, ST_Distance(f.location, `+ptSQL+`)::int`+flagJoins+`
			WHERE f.status = 'open' AND ST_DWithin(f.location, `+ptSQL+`, $4)
			ORDER BY f.location <-> `+ptSQL+` LIMIT 1`, p.RepID, *in.Lat, *in.Lng, flagDupM)
		if err != nil {
			return err
		}
		near, err := pgx.CollectRows(rows, scanFlagDist)
		if err != nil {
			return err
		}
		if len(near) > 0 {
			f := near[0]
			who := f.RepName
			switch {
			case f.Mine:
				who = "ваш"
			case f.Source == "osm":
				who = "с карты"
			}
			return apperr.Conflict("flag_near", "здесь уже стоит флажок ("+who+") — можно добавить к нему фото").
				Uz("bu yerda allaqachon bayroqcha bor (" + f.RepName + ") — unga rasm qoʻshish mumkin").
				WithDetails(map[string]any{"flag": f})
		}
		rows, err = tx.Query(ctx, `SELECT `+placeCols(1)+`, ST_Distance(p.location, `+ptSQL+`)::int`+placeJoins+`
			WHERE ST_DWithin(p.location, `+ptSQL+`, $4)
			ORDER BY p.location <-> `+ptSQL+` LIMIT 1`, p.RepID, *in.Lat, *in.Lng, flagPlaceM)
		if err != nil {
			return err
		}
		places, err := pgx.CollectRows(rows, scanPlaceDist)
		if err != nil {
			return err
		}
		if len(places) > 0 {
			pl := places[0]
			return apperr.Conflict("place_near", "здесь уже отмечен магазин — откройте его отметку").
				Uz("bu yerda doʻkon allaqachon belgilangan — belgini oching").
				WithDetails(map[string]any{"place": pl})
		}
		var acc *float32
		if in.Accuracy != nil {
			a := float32(*in.Accuracy)
			acc = &a
		}
		return tx.QueryRow(ctx, `
			INSERT INTO field_flags (rep_id, walk_id, location, accuracy, name, photo_url)
			VALUES ($1, $2, ST_SetSRID(ST_MakePoint($4::float8, $3::float8), 4326)::geography, $5, $6, $7)
			RETURNING id`, p.RepID, walkID, *in.Lat, *in.Lng, acc, in.Name, in.PhotoURL).Scan(&id)
	})
	if err != nil {
		return Flag{}, err
	}
	return s.flag(ctx, p.RepID, id)
}

func (s *Service) flag(ctx context.Context, me, id string) (Flag, error) {
	if !httpx.IsUUID(id) {
		return Flag{}, errFlagNotFound()
	}
	rows, err := s.pool.Query(ctx, `SELECT `+flagCols(2)+flagJoins+` WHERE f.id = $1`, id, me)
	if err != nil {
		return Flag{}, err
	}
	f, err := pgx.CollectExactlyOneRow(rows, scanFlag)
	if errors.Is(err, pgx.ErrNoRows) {
		return Flag{}, errFlagNotFound()
	}
	return f, err
}

// GetFlag — карточка флажка (П10).
func (s *Service) GetFlag(ctx context.Context, p *identity.Principal, id string) (Flag, error) {
	me := ""
	switch {
	case p != nil && p.App == identity.AppField && p.RepID != "":
		me = p.RepID
	case requireAdmin(p) != nil:
		return Flag{}, requireRep(p)
	}
	return s.flag(ctx, me, id)
}

// UpdateFlag — фото и название (П9; к чужому флажку тоже можно добавить фото).
func (s *Service) UpdateFlag(ctx context.Context, p *identity.Principal, id string, in FlagPatch) (Flag, error) {
	if err := requireRep(p); err != nil {
		return Flag{}, err
	}
	if !httpx.IsUUID(id) {
		return Flag{}, errFlagNotFound()
	}
	if err := cleanFlagText(in.Name, in.PhotoURL); err != nil {
		return Flag{}, err
	}
	var status string
	err := s.pool.QueryRow(ctx, `
		UPDATE field_flags SET name = COALESCE($2, name), photo_url = COALESCE($3, photo_url)
		WHERE id = $1 AND status = 'open'
		RETURNING status`, id, in.Name, in.PhotoURL).Scan(&status)
	if errors.Is(err, pgx.ErrNoRows) {
		if _, err := s.flag(ctx, p.RepID, id); err != nil {
			return Flag{}, err
		}
		return Flag{}, errFlagClosed()
	}
	if err != nil {
		return Flag{}, err
	}
	return s.flag(ctx, p.RepID, id)
}

// DeleteFlag — автор удаляет свой флажок («Отменить», «Удалить флажок — поставил по ошибке»).
func (s *Service) DeleteFlag(ctx context.Context, p *identity.Principal, id string) (Flag, error) {
	if err := requireRep(p); err != nil {
		return Flag{}, err
	}
	f, err := s.flag(ctx, p.RepID, id)
	if err != nil {
		return Flag{}, err
	}
	if !f.Mine {
		return Flag{}, apperr.Forbidden("удалить можно только свой флажок — для чужого «Не магазин»").Uz("faqat oʻz bayroqchangizni oʻchirish mumkin — boshqasi uchun «Doʻkon emas»")
	}
	if f.Status != "open" {
		return f, nil
	}
	if _, err := s.pool.Exec(ctx, `
		UPDATE field_flags SET status = 'removed', close_reason = 'deleted', closed_at = now(), closed_by = $2
		WHERE id = $1 AND status = 'open'`, id, p.RepID); err != nil {
		return Flag{}, err
	}
	return s.flag(ctx, p.RepID, id)
}

// NotStore — «Не магазин»: флажок убирается у всех (видно, кто убрал).
func (s *Service) NotStore(ctx context.Context, p *identity.Principal, id string) (Flag, error) {
	if err := requireRep(p); err != nil {
		return Flag{}, err
	}
	if !httpx.IsUUID(id) {
		return Flag{}, errFlagNotFound()
	}
	tag, err := s.pool.Exec(ctx, `
		UPDATE field_flags SET status = 'removed', close_reason = 'not_store', closed_at = now(), closed_by = $2
		WHERE id = $1 AND status = 'open'`, id, p.RepID)
	if err != nil {
		return Flag{}, err
	}
	f, err := s.flag(ctx, p.RepID, id)
	if err != nil {
		return Flag{}, err
	}
	if tag.RowsAffected() == 0 {
		return Flag{}, errFlagClosed()
	}
	return f, nil
}

// FlagList — П11 «Зайти потом рядом»: открытые флажки по расстоянию.
type FlagList struct {
	Items []Flag `json:"items"`
	// Всего открытых флажков и сколько из них мои.
	All  int `json:"all"`
	Mine int `json:"mine"`
}

// Flags — открытые флажки; lat/lng — по расстоянию от продажника, иначе новые сверху.
// mine — только поставленные мной.
func (s *Service) Flags(ctx context.Context, p *identity.Principal, lat, lng *float64, mine bool, limit int) (FlagList, error) {
	if err := requireRep(p); err != nil {
		return FlagList{}, err
	}
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	out := FlagList{Items: []Flag{}}
	if err := s.pool.QueryRow(ctx, `
		SELECT count(*)::int, count(*) FILTER (WHERE rep_id::text = $1)::int FROM field_flags WHERE status = 'open'`,
		p.RepID).Scan(&out.All, &out.Mine); err != nil {
		return out, err
	}
	var (
		rows pgx.Rows
		err  error
	)
	if lat != nil && lng != nil {
		rows, err = s.pool.Query(ctx, `SELECT `+flagCols(1)+`, ST_Distance(f.location, `+ptSQL+`)::int`+flagJoins+`
			WHERE f.status = 'open' AND (NOT $4 OR f.rep_id::text = $1)
			ORDER BY f.location <-> `+ptSQL+` LIMIT $5`, p.RepID, *lat, *lng, mine, limit)
		if err != nil {
			return out, err
		}
		out.Items, err = pgx.CollectRows(rows, scanFlagDist)
	} else {
		rows, err = s.pool.Query(ctx, `SELECT `+flagCols(1)+flagJoins+`
			WHERE f.status = 'open' AND (NOT $2 OR f.rep_id::text = $1)
			ORDER BY f.created_at DESC LIMIT $3`, p.RepID, mine, limit)
		if err != nil {
			return out, err
		}
		out.Items, err = pgx.CollectRows(rows, scanFlag)
	}
	if out.Items == nil {
		out.Items = []Flag{}
	}
	return out, err
}

// flagsIn — открытые флажки в области карты.
func (s *Service) flagsIn(ctx context.Context, me string, b BBox) ([]Flag, error) {
	rows, err := s.pool.Query(ctx, `SELECT `+flagCols(1)+flagJoins+`
		WHERE f.status = 'open' AND ST_Intersects(f.location, ST_MakeEnvelope($2, $3, $4, $5, 4326)::geography)
		ORDER BY f.created_at DESC LIMIT $6`, me, b.MinLng, b.MinLat, b.MaxLng, b.MaxLat, maxFlags)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, scanFlag)
	if out == nil {
		out = []Flag{}
	}
	return out, err
}

// nearestFlagTx — открытый флажок ближе 100 м к продажнику (баннер «Рядом флажок — 60 м»).
func nearestFlagTx(ctx context.Context, tx pgx.Tx, me string, lat, lng float64) (*Flag, error) {
	rows, err := tx.Query(ctx, `SELECT `+flagCols(1)+`, ST_Distance(f.location, `+ptSQL+`)::int`+flagJoins+`
		WHERE f.status = 'open' AND ST_DWithin(f.location, `+ptSQL+`, $4)
		ORDER BY f.location <-> `+ptSQL+` LIMIT 1`, me, lat, lng, flagNearM)
	if err != nil {
		return nil, err
	}
	fl, err := pgx.CollectRows(rows, scanFlagDist)
	if err != nil || len(fl) == 0 {
		return nil, err
	}
	return &fl[0], nil
}

// closeFlagsNearTx — отметили магазин: открытые флажки ближе 50 м закрываются.
func closeFlagsNearTx(ctx context.Context, tx pgx.Tx, repID, placeID string, lat, lng float64) error {
	_, err := tx.Exec(ctx, `
		UPDATE field_flags SET status = 'visited', close_reason = 'visited', closed_at = now(), closed_by = $1, place_id = $2
		WHERE status = 'open' AND ST_DWithin(location, ST_SetSRID(ST_MakePoint($4::float8, $3::float8), 4326)::geography, $5)`,
		repID, placeID, lat, lng, flagCloseM)
	return err
}
