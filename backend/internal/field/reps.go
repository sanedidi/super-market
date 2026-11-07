package field

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/phone"
)

// Продажники: супер-админ создаёт (имя, телефон, район, логин и пароль),
// продажник видит свой профиль и итоги на П1.

// Цвета линий продажников на карте супер-админа — по кругу.
var palette = []string{"#E11D2A", "#151515", "#2563EB", "#7C3AED", "#0D9488", "#D97706", "#DB2777", "#65A30D", "#0891B2", "#9333EA"}

var (
	loginRe = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{2,31}$`)
	colorRe = regexp.MustCompile(`^#[0-9A-Fa-f]{6}$`)
)

// Rep — продажник.
type Rep struct {
	ID           string     `json:"id"`
	FullName     string     `json:"full_name"`
	Phone        string     `json:"phone"`
	Login        string     `json:"login"`
	DistrictID   *string    `json:"district_id"`
	DistrictName string     `json:"district_name"`
	Status       string     `json:"status"`
	Color        string     `json:"color"`
	LastLoginAt  *time.Time `json:"last_login_at"`
	CreatedAt    time.Time  `json:"created_at"`
	Locked       bool       `json:"locked"`
}

const repSelect = `
	SELECT r.id, r.full_name, u.phone, r.login, r.district_id::text, COALESCE(d.name, ''), r.status, r.color,
	       r.last_login_at, r.created_at, COALESCE(r.locked_until > now(), false)
	FROM field_reps r
	JOIN users u ON u.id = r.user_id
	LEFT JOIN field_districts d ON d.id = r.district_id`

func scanRep(row pgx.CollectableRow) (Rep, error) {
	var r Rep
	err := row.Scan(&r.ID, &r.FullName, &r.Phone, &r.Login, &r.DistrictID, &r.DistrictName, &r.Status, &r.Color,
		&r.LastLoginAt, &r.CreatedAt, &r.Locked)
	return r, err
}

func (s *Service) rep(ctx context.Context, id string) (Rep, error) {
	if !httpx.IsUUID(id) {
		return Rep{}, errRepNotFound()
	}
	rows, err := s.pool.Query(ctx, repSelect+` WHERE r.id = $1`, id)
	if err != nil {
		return Rep{}, err
	}
	r, err := pgx.CollectExactlyOneRow(rows, scanRep)
	if errors.Is(err, pgx.ErrNoRows) {
		return Rep{}, errRepNotFound()
	}
	return r, err
}

func errRepNotFound() error {
	return apperr.NotFound("продажник не найден").Uz("savdo agenti topilmadi")
}

// Reps — список продажников.
func (s *Service) Reps(ctx context.Context, p *identity.Principal) ([]Rep, error) {
	if err := requireAdmin(p); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, repSelect+` ORDER BY r.status, r.full_name`)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, scanRep)
	if out == nil {
		out = []Rep{}
	}
	return out, err
}

// RepInput — создание и правка продажника. При правке пустые поля не меняются;
// пустой пароль — оставить прежний.
type RepInput struct {
	FullName   *string                `json:"full_name"`
	Phone      *string                `json:"phone"`
	DistrictID httpx.Optional[string] `json:"district_id"`
	Login      *string                `json:"login"`
	Password   *string                `json:"password"`
	Status     *string                `json:"status"`
	Color      *string                `json:"color"`
}

func validPassword(pw string) error {
	if n := utf8.RuneCountInString(pw); n < 8 || n > 72 {
		return apperr.Validation("password: от 8 до 72 символов").Uz("password: 8 dan 72 tagacha belgi")
	}
	return nil
}

func (in *RepInput) validate(create bool) (login, ph string, err error) {
	if create && (in.FullName == nil || in.Phone == nil || in.Login == nil || in.Password == nil) {
		return "", "", apperr.Validation("заполните имя, телефон, логин и пароль").Uz("ism, telefon, login va parolni toʻldiring")
	}
	if in.FullName != nil {
		v := strings.TrimSpace(*in.FullName)
		if v == "" || utf8.RuneCountInString(v) > 100 {
			return "", "", apperr.Validation("full_name: имя продажника, до 100 символов").Uz("full_name: agent ismi, 100 belgigacha")
		}
		in.FullName = &v
	}
	if in.Phone != nil {
		if ph, err = phone.Normalize(*in.Phone); err != nil {
			return "", "", apperr.Validation("phone: номер в формате +998 XX XXX XX XX").Uz("phone: raqam +998 XX XXX XX XX formatida")
		}
	}
	if in.Login != nil {
		login = identity.NormalizeLogin(*in.Login)
		if !loginRe.MatchString(login) {
			return "", "", apperr.Validation("login: латиница, цифры, точка, дефис или _ — от 3 до 32 символов").Uz("login: lotin harflari, raqamlar, nuqta, defis yoki _ — 3 dan 32 tagacha belgi")
		}
	}
	if in.Password != nil && (*in.Password != "" || create) {
		if err := validPassword(*in.Password); err != nil {
			return "", "", err
		}
	}
	if in.Status != nil && *in.Status != "active" && *in.Status != "blocked" {
		return "", "", apperr.Validation("status: active или blocked").Uz("status: active yoki blocked")
	}
	if in.Color != nil && !colorRe.MatchString(*in.Color) {
		return "", "", apperr.Validation("color: #RRGGBB").Uz("color: #RRGGBB")
	}
	if in.DistrictID.Set && in.DistrictID.Value != nil && !httpx.IsUUID(*in.DistrictID.Value) {
		return "", "", errDistrictNotFound()
	}
	return login, ph, nil
}

func loginTaken(err error) error {
	if db.IsUniqueViolation(err, "field_reps_login_key") {
		return apperr.Conflict("login_taken", "логин уже занят — придумайте другой").Uz("login band — boshqasini oʻylab toping")
	}
	if db.IsUniqueViolation(err, "field_reps_user_id_key") {
		return apperr.Conflict("phone_taken", "продажник с этим номером уже есть").Uz("bu raqamli savdo agenti allaqachon bor")
	}
	if db.IsForeignKeyViolation(err) {
		return errDistrictNotFound()
	}
	return err
}

// CreateRep — «Добавить продажника».
func (s *Service) CreateRep(ctx context.Context, p *identity.Principal, in RepInput) (Rep, error) {
	if err := requireAdmin(p); err != nil {
		return Rep{}, err
	}
	login, ph, err := in.validate(true)
	if err != nil {
		return Rep{}, err
	}
	hash, err := identity.HashPassword(*in.Password)
	if err != nil {
		return Rep{}, err
	}
	var id string
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var userID string
		if err := tx.QueryRow(ctx, `
			INSERT INTO users (phone, full_name) VALUES ($1, $2)
			ON CONFLICT (phone) DO UPDATE SET full_name = CASE WHEN users.full_name = '' THEN EXCLUDED.full_name ELSE users.full_name END
			RETURNING id`, ph, *in.FullName).Scan(&userID); err != nil {
			return err
		}
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*)::int FROM field_reps`).Scan(&n); err != nil {
			return err
		}
		color := palette[n%len(palette)]
		if in.Color != nil {
			color = *in.Color
		}
		return tx.QueryRow(ctx, `
			INSERT INTO field_reps (user_id, full_name, district_id, login, password_hash, color)
			VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`,
			userID, *in.FullName, in.DistrictID.Or(), login, hash, color).Scan(&id)
	})
	if err != nil {
		return Rep{}, loginTaken(err)
	}
	return s.rep(ctx, id)
}

// UpdateRep — правка, новый пароль, блокировка. Новый пароль или блокировка
// закрывают сессии продажника; при блокировке открытый обход заканчивается.
func (s *Service) UpdateRep(ctx context.Context, p *identity.Principal, id string, in RepInput) (Rep, error) {
	if err := requireAdmin(p); err != nil {
		return Rep{}, err
	}
	if !httpx.IsUUID(id) {
		return Rep{}, errRepNotFound()
	}
	login, ph, err := in.validate(false)
	if err != nil {
		return Rep{}, err
	}
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var userID, status string
		err := tx.QueryRow(ctx, `SELECT user_id, status FROM field_reps WHERE id = $1 FOR UPDATE`, id).Scan(&userID, &status)
		if errors.Is(err, pgx.ErrNoRows) {
			return errRepNotFound()
		}
		if err != nil {
			return err
		}
		revoke := false
		if in.FullName != nil {
			if _, err := tx.Exec(ctx, `UPDATE field_reps SET full_name = $2 WHERE id = $1`, id, *in.FullName); err != nil {
				return err
			}
		}
		if in.Phone != nil {
			// Номер — у пользователя; другой номер — другой пользователь.
			var newUser string
			if err := tx.QueryRow(ctx, `
				INSERT INTO users (phone) VALUES ($1) ON CONFLICT (phone) DO UPDATE SET phone = EXCLUDED.phone
				RETURNING id`, ph).Scan(&newUser); err != nil {
				return err
			}
			if newUser != userID {
				if _, err := tx.Exec(ctx, `UPDATE field_reps SET user_id = $2 WHERE id = $1`, id, newUser); err != nil {
					return err
				}
				if err := identity.RevokeUserSessions(ctx, tx, userID, identity.AppField); err != nil {
					return err
				}
			}
		}
		if in.DistrictID.Set {
			if _, err := tx.Exec(ctx, `UPDATE field_reps SET district_id = $2 WHERE id = $1`, id, in.DistrictID.Value); err != nil {
				return err
			}
		}
		if in.Login != nil {
			if _, err := tx.Exec(ctx, `UPDATE field_reps SET login = $2 WHERE id = $1`, id, login); err != nil {
				return err
			}
		}
		if in.Password != nil && *in.Password != "" {
			hash, err := identity.HashPassword(*in.Password)
			if err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `UPDATE field_reps SET password_hash = $2, failed_attempts = 0, locked_until = NULL WHERE id = $1`, id, hash); err != nil {
				return err
			}
			revoke = true
		}
		if in.Color != nil {
			if _, err := tx.Exec(ctx, `UPDATE field_reps SET color = $2 WHERE id = $1`, id, *in.Color); err != nil {
				return err
			}
		}
		if in.Status != nil && *in.Status != status {
			if _, err := tx.Exec(ctx, `UPDATE field_reps SET status = $2 WHERE id = $1`, id, *in.Status); err != nil {
				return err
			}
			if *in.Status == "blocked" {
				revoke = true
				var walkID string
				err := tx.QueryRow(ctx, `SELECT id FROM field_walks WHERE rep_id = $1 AND status <> 'ended' FOR UPDATE`, id).Scan(&walkID)
				if err == nil {
					if err := endWalk(ctx, tx, walkID, "auto", s.now(), walkRow{}); err != nil {
						return err
					}
				} else if !errors.Is(err, pgx.ErrNoRows) {
					return err
				}
			}
		}
		if revoke {
			var cur string
			if err := tx.QueryRow(ctx, `SELECT user_id FROM field_reps WHERE id = $1`, id).Scan(&cur); err != nil {
				return err
			}
			return identity.RevokeUserSessions(ctx, tx, cur, identity.AppField)
		}
		return nil
	})
	if err != nil {
		return Rep{}, loginTaken(err)
	}
	return s.rep(ctx, id)
}

// ----------------------------------------------------------------- П1

// Me — П1 «Обход»: профиль, район, итоги, открытый обход, напоминания.
type Me struct {
	Rep      Rep       `json:"rep"`
	District *District `json:"district"`
	Today    DayTotals `json:"today"`
	// За 7 дней (включая сегодня).
	WeekM float64 `json:"week_m"`
	// Где продажник был за всё время и сколько из них — «Подключить».
	Places    int     `json:"places"`
	Leads     int     `json:"leads"`
	Walk      *Walk   `json:"walk"`
	Recent    []Walk  `json:"recent"`
	Reminders []Place `json:"reminders"`
	Grid      Grid    `json:"grid"`
}

// DayTotals — итоги дня.
type DayTotals struct {
	DistanceM float64 `json:"distance_m"`
	ActiveSec int     `json:"active_sec"`
	Places    int     `json:"places"`
	Leads     int     `json:"leads"`
	OtherM    float64 `json:"other_m"`
}

func (s *Service) Me(ctx context.Context, p *identity.Principal) (Me, error) {
	if err := requireRep(p); err != nil {
		return Me{}, err
	}
	out := Me{Grid: grid(), Recent: []Walk{}}
	var err error
	if out.Rep, err = s.rep(ctx, p.RepID); err != nil {
		return out, err
	}
	if out.District, err = s.repDistrict(ctx, p.RepID); err != nil {
		return out, err
	}
	if out.District != nil {
		if err := s.fill(ctx, out.District); err != nil {
			return out, err
		}
	}
	if out.Today, err = s.dayTotals(ctx, p.RepID, time.Time{}); err != nil {
		return out, err
	}
	if err := s.pool.QueryRow(ctx, `
		SELECT COALESCE(sum(distance_m), 0) FROM field_walks
		WHERE rep_id = $1 AND (started_at AT TIME ZONE 'Asia/Tashkent')::date > `+todaySQL+` - 7`, p.RepID).Scan(&out.WeekM); err != nil {
		return out, err
	}
	if err := s.pool.QueryRow(ctx, `
		SELECT count(DISTINCT place_id)::int, count(*) FILTER (WHERE result = 'lead')::int
		FROM field_visits WHERE rep_id = $1`, p.RepID).Scan(&out.Places, &out.Leads); err != nil {
		return out, err
	}
	rows, err := s.pool.Query(ctx, walkSelect+` WHERE w.rep_id = $1 ORDER BY w.started_at DESC LIMIT 6`, p.RepID)
	if err != nil {
		return out, err
	}
	walks, err := pgx.CollectRows(rows, scanWalk)
	if err != nil {
		return out, err
	}
	for _, w := range walks {
		if w.Status != WalkEnded && out.Walk == nil {
			out.Walk = &w
			continue
		}
		if len(out.Recent) < 5 {
			out.Recent = append(out.Recent, w)
		}
	}
	out.Reminders, err = s.reminders(ctx, p.RepID)
	return out, err
}

// dayTotals — итоги дня продажника (day — дата по Ташкенту; нулевая — сегодня).
func (s *Service) dayTotals(ctx context.Context, repID string, day time.Time) (DayTotals, error) {
	var t DayTotals
	d := todaySQL
	args := []any{repID}
	if !day.IsZero() {
		d = `$2::date`
		args = append(args, day.Format("2006-01-02"))
	}
	err := s.pool.QueryRow(ctx, `
		SELECT COALESCE(sum(w.distance_m), 0), COALESCE(sum(w.other_m), 0),
		       COALESCE(sum(GREATEST(0, EXTRACT(EPOCH FROM (COALESCE(w.ended_at, now()) - w.started_at))::int - w.pause_sec
		           - CASE WHEN w.status = 'paused' AND w.paused_at IS NOT NULL THEN EXTRACT(EPOCH FROM (now() - w.paused_at))::int ELSE 0 END)), 0)::int
		FROM field_walks w
		WHERE w.rep_id = $1 AND (w.started_at AT TIME ZONE 'Asia/Tashkent')::date = `+d, args...).Scan(&t.DistanceM, &t.OtherM, &t.ActiveSec)
	if err != nil {
		return t, err
	}
	err = s.pool.QueryRow(ctx, `
		SELECT count(*)::int, count(*) FILTER (WHERE result = 'lead')::int FROM field_visits
		WHERE rep_id = $1 AND (created_at AT TIME ZONE 'Asia/Tashkent')::date = `+d, args...).Scan(&t.Places, &t.Leads)
	return t, err
}
