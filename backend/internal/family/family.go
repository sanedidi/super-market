// Package family — «Моя семья»: семья покупателей, приглашения через
// Telegram-бот, просьбы купить с напоминаниями и «заказать домой».
package family

import (
	"context"
	"crypto/rand"
	"errors"
	"math/big"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/delivery"
	"github.com/sanedidi/super-market/backend/internal/orders"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/phone"
	"github.com/sanedidi/super-market/backend/internal/push"
)

type Service struct {
	pool        *pgxpool.Pool
	orders      *orders.Service
	delivery    *delivery.Service
	botUsername string
	now         func() time.Time
}

func NewService(pool *pgxpool.Pool, o *orders.Service, d *delivery.Service, botUsername string) *Service {
	return &Service{pool: pool, orders: o, delivery: d, botUsername: botUsername, now: time.Now}
}

const inviteTTL = 7 * 24 * time.Hour

// Имя в семье: имя в профиле, иначе подпись («Жена»), иначе хвост номера.
const nameSQL = `COALESCE(NULLIF(u.full_name, ''), NULLIF(fm.label, ''), loc('Номер …', 'Raqam …') || right(u.phone, 4))`

type Member struct {
	UserID string `json:"user_id"`
	Name   string `json:"name"`
	Label  string `json:"label"`
	Phone  string `json:"phone"`
	Role   string `json:"role"`
	IsMe   bool   `json:"is_me"`
}

type Family struct {
	ID           string   `json:"id"`
	Name         string   `json:"name"`
	MyRole       string   `json:"my_role"`
	Members      []Member `json:"members"`
	ActiveCount  int      `json:"active_requests"`
	ForMeCount   int      `json:"requests_for_me"`
	InviteByLink bool     `json:"invite_by_link"`
}

// membership — семья пользователя и его роль; ErrNoRows — не в семье.
func membership(ctx context.Context, q db.Querier, userID string) (familyID, role string, err error) {
	err = q.QueryRow(ctx, `SELECT family_id, role FROM family_members WHERE user_id = $1`, userID).Scan(&familyID, &role)
	return
}

var errNoFamily = apperr.NotFound("вы пока не в семье").Uz("siz hozircha oilada emassiz")

func (s *Service) mustFamily(ctx context.Context, userID string) (string, string, error) {
	id, role, err := membership(ctx, s.pool, userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", errNoFamily
	}
	return id, role, err
}

// Get — семья пользователя или nil.
func (s *Service) Get(ctx context.Context, userID string) (*Family, error) {
	id, role, err := membership(ctx, s.pool, userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	f := &Family{ID: id, MyRole: role, InviteByLink: s.botUsername != ""}
	if err := s.pool.QueryRow(ctx, `
		SELECT f.name,
		       (SELECT count(*) FROM shopping_requests r WHERE r.family_id = f.id AND r.status IN ('pending', 'partial'))::int,
		       (SELECT count(*) FROM shopping_requests r WHERE r.family_id = f.id AND r.status IN ('pending', 'partial')
		          AND (r.assignee_id = $2 OR (r.assignee_id IS NULL AND r.author_id IS DISTINCT FROM $2)))::int
		FROM families f WHERE f.id = $1`, id, userID).Scan(&f.Name, &f.ActiveCount, &f.ForMeCount); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT fm.user_id, `+nameSQL+`, fm.label, u.phone, fm.role, fm.user_id = $2
		FROM family_members fm JOIN users u ON u.id = fm.user_id
		WHERE fm.family_id = $1 ORDER BY fm.role = 'owner' DESC, fm.joined_at`, id, userID)
	if err != nil {
		return nil, err
	}
	f.Members, err = pgx.CollectRows(rows, pgx.RowToStructByPos[Member])
	return f, err
}

type CreateInput struct {
	Name string `json:"name"`
}

func (s *Service) Create(ctx context.Context, userID string, in CreateInput) (*Family, error) {
	name := strings.TrimSpace(in.Name)
	if name == "" {
		name = i18n.T(ctx, "Моя семья", "Mening oilam")
	}
	if len([]rune(name)) > 40 {
		return nil, apperr.Validation("name: не длиннее 40 символов").Uz("name: 40 belgidan oshmasin")
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, _, err := membership(ctx, tx, userID); err == nil {
			return apperr.Conflict("already_in_family", "вы уже в семье").Uz("siz allaqachon oiladasiz")
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		var id string
		if err := tx.QueryRow(ctx, `INSERT INTO families (owner_id, name) VALUES ($1, $2) RETURNING id`, userID, name).Scan(&id); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO family_members (family_id, user_id, role) VALUES ($1, $2, 'owner')`, id, userID)
		if db.IsUniqueViolation(err, "") {
			return apperr.Conflict("already_in_family", "вы уже в семье").Uz("siz allaqachon oiladasiz")
		}
		return err
	})
	if err != nil {
		return nil, err
	}
	return s.Get(ctx, userID)
}

type Invite struct {
	Code      string    `json:"code"`
	URL       string    `json:"url"`
	ExpiresAt time.Time `json:"expires_at"`
}

const codeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" // без 0/O, 1/I

func newCode() (string, error) {
	b := make([]byte, 8)
	for i := range b {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(codeAlphabet))))
		if err != nil {
			return "", err
		}
		b[i] = codeAlphabet[n.Int64()]
	}
	return string(b), nil
}

// CreateInvite — код и ссылка в Telegram-бот для приглашения в семью.
func (s *Service) CreateInvite(ctx context.Context, userID string) (Invite, error) {
	familyID, _, err := s.mustFamily(ctx, userID)
	if err != nil {
		return Invite{}, err
	}
	var n int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM family_members WHERE family_id = $1`, familyID).Scan(&n); err != nil {
		return Invite{}, err
	}
	if n >= 10 {
		return Invite{}, apperr.Conflict("family_full", "в семье уже 10 человек").Uz("oilada allaqachon 10 kishi bor")
	}
	code, err := newCode()
	if err != nil {
		return Invite{}, err
	}
	inv := Invite{Code: code, ExpiresAt: s.now().Add(inviteTTL)}
	if _, err := s.pool.Exec(ctx, `INSERT INTO family_invites (code, family_id, created_by, expires_at) VALUES ($1, $2, $3, $4)`,
		code, familyID, userID, inv.ExpiresAt); err != nil {
		return Invite{}, err
	}
	if s.botUsername != "" {
		inv.URL = "https://t.me/" + s.botUsername + "?start=fam_" + code
	}
	return inv, nil
}

type JoinInput struct {
	Code  string `json:"code"`
	Label string `json:"label"`
}

// Join — вступить в семью по коду приглашения.
func (s *Service) Join(ctx context.Context, userID string, in JoinInput) (*Family, error) {
	code := strings.ToUpper(strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(in.Code), "fam_")))
	label := strings.TrimSpace(in.Label)
	if len([]rune(label)) > 40 {
		return nil, apperr.Validation("label: не длиннее 40 символов").Uz("label: 40 belgidan oshmasin")
	}
	var familyID, familyName string
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if fid, _, err := membership(ctx, tx, userID); err == nil {
			var cur string
			_ = tx.QueryRow(ctx, `SELECT family_id FROM family_invites WHERE code = $1`, code).Scan(&cur)
			if cur == fid {
				familyID = fid
				return nil // уже в этой семье — повторный переход по ссылке
			}
			return apperr.Conflict("already_in_family", "вы уже в другой семье — сначала выйдите из неё").Uz("siz allaqachon boshqa oiladasiz — avval undan chiqing")
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		var used bool
		var expires time.Time
		err := tx.QueryRow(ctx, `SELECT i.family_id, f.name, i.used_at IS NOT NULL, i.expires_at
			FROM family_invites i JOIN families f ON f.id = i.family_id WHERE i.code = $1 FOR UPDATE OF i`, code).
			Scan(&familyID, &familyName, &used, &expires)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && (used || s.now().After(expires))) {
			return apperr.Validation("code: приглашение не найдено или устарело — попросите новое").Uz("code: taklif topilmadi yoki eskirgan — yangisini soʻrang")
		}
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO family_members (family_id, user_id, label) VALUES ($1, $2, $3)`, familyID, userID, label); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE family_invites SET used_by = $2, used_at = now() WHERE code = $1`, code, userID); err != nil {
			return err
		}
		// Остальным — что в семье новый человек.
		var name string
		if err := tx.QueryRow(ctx, `SELECT `+nameSQL+` FROM family_members fm JOIN users u ON u.id = fm.user_id WHERE fm.user_id = $1`, userID).Scan(&name); err != nil {
			return err
		}
		return notifyFamily(ctx, tx, familyID, userID, "family_joined",
			i18n.Text{RU: "В семье пополнение", UZ: "Oilaga yangi aʼzo qoʻshildi"},
			i18n.Text{RU: name + " теперь в «" + familyName + "»", UZ: name + " endi «" + familyName + "» aʼzosi"},
			map[string]string{"type": "family"})
	})
	if err != nil {
		return nil, err
	}
	return s.Get(ctx, userID)
}

// JoinByPhone — вход из Telegram-бота: пользователь найден по номеру (или
// создаётся, как при первом входе в приложение).
func (s *Service) JoinByPhone(ctx context.Context, rawPhone, code string) (string, error) {
	ph, err := phone.Normalize(rawPhone)
	if err != nil {
		return "", err
	}
	var userID string
	if err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `INSERT INTO users (phone) VALUES ($1) ON CONFLICT (phone) DO UPDATE SET phone = EXCLUDED.phone RETURNING id`, ph).Scan(&userID); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO customers (user_id) VALUES ($1) ON CONFLICT (user_id) DO UPDATE SET deleted_at = NULL WHERE customers.deleted_at IS NOT NULL`, userID)
		return err
	}); err != nil {
		return "", err
	}
	f, err := s.Join(ctx, userID, JoinInput{Code: code})
	if err != nil {
		return "", err
	}
	return f.Name, nil
}

// Leave — выйти из семьи. Владелец передаёт семью самому давнему участнику;
// последний участник — семья удаляется.
func (s *Service) Leave(ctx context.Context, userID string) error {
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error { return RemoveUser(ctx, tx, userID) })
}

// RemoveUser убирает человека из семьи (выход, удаление аккаунта).
func RemoveUser(ctx context.Context, tx pgx.Tx, userID string) error {
	familyID, role, err := membership(ctx, tx, userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM family_members WHERE user_id = $1`, userID); err != nil {
		return err
	}
	var next string
	err = tx.QueryRow(ctx, `SELECT user_id FROM family_members WHERE family_id = $1 ORDER BY joined_at LIMIT 1`, familyID).Scan(&next)
	if errors.Is(err, pgx.ErrNoRows) {
		_, err = tx.Exec(ctx, `DELETE FROM families WHERE id = $1`, familyID)
		return err
	}
	if err != nil {
		return err
	}
	if role == "owner" {
		if _, err := tx.Exec(ctx, `UPDATE family_members SET role = 'owner' WHERE family_id = $1 AND user_id = $2`, familyID, next); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE families SET owner_id = $2 WHERE id = $1`, familyID, next); err != nil {
			return err
		}
	}
	// Просьбы, адресованные ушедшему, — теперь любому.
	_, err = tx.Exec(ctx, `UPDATE shopping_requests SET assignee_id = NULL WHERE family_id = $1 AND assignee_id = $2`, familyID, userID)
	return err
}

// RemoveMember — владелец убирает участника.
func (s *Service) RemoveMember(ctx context.Context, userID, memberID string) error {
	familyID, role, err := s.mustFamily(ctx, userID)
	if err != nil {
		return err
	}
	if role != "owner" {
		return apperr.Forbidden("убрать участника может только владелец семьи").Uz("aʼzoni faqat oila egasi chiqarishi mumkin")
	}
	if memberID == userID {
		return apperr.Validation("чтобы выйти из семьи, используйте «Выйти»").Uz("oiladan chiqish uchun «Chiqish» tugmasidan foydalaning")
	}
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		fid, _, err := membership(ctx, tx, memberID)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && fid != familyID) {
			return apperr.NotFound("участник не найден").Uz("aʼzo topilmadi")
		}
		if err != nil {
			return err
		}
		return RemoveUser(ctx, tx, memberID)
	})
}

type MemberInput struct {
	Label string `json:"label"`
}

// UpdateMember — подпись участника («Жена»): владелец — любому, остальные — себе.
func (s *Service) UpdateMember(ctx context.Context, userID, memberID string, in MemberInput) (*Family, error) {
	familyID, role, err := s.mustFamily(ctx, userID)
	if err != nil {
		return nil, err
	}
	if role != "owner" && memberID != userID {
		return nil, apperr.Forbidden("подпись другого участника меняет владелец семьи").Uz("boshqa aʼzoning nomini oila egasi oʻzgartiradi")
	}
	label := strings.TrimSpace(in.Label)
	if len([]rune(label)) > 40 {
		return nil, apperr.Validation("label: не длиннее 40 символов").Uz("label: 40 belgidan oshmasin")
	}
	tag, err := s.pool.Exec(ctx, `UPDATE family_members SET label = $3 WHERE family_id = $1 AND user_id = $2`, familyID, memberID, label)
	if err != nil {
		return nil, err
	}
	if tag.RowsAffected() == 0 {
		return nil, apperr.NotFound("участник не найден").Uz("aʼzo topilmadi")
	}
	return s.Get(ctx, userID)
}

// notifyFamily — уведомление всем в семье, кроме except.
func notifyFamily(ctx context.Context, q db.Querier, familyID, except, kind string, title, body i18n.Text, data map[string]string) error {
	rows, err := q.Query(ctx, `SELECT user_id FROM family_members WHERE family_id = $1 AND user_id <> $2`, familyID, except)
	if err != nil {
		return err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	for _, id := range ids {
		if err := push.Enqueue(ctx, q, id, kind, title, body, data); err != nil {
			return err
		}
	}
	return nil
}

func validUUID(id string) error {
	if !httpx.IsUUID(id) {
		return apperr.NotFound("не найдено").Uz("topilmadi")
	}
	return nil
}
