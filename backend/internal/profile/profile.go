// Package profile — профиль покупателя: имя и настройки, статистика,
// устройства для push, удаление аккаунта.
package profile

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

type Service struct {
	pool        *pgxpool.Pool
	supportURL  string
	privacyURL  string
	pushEnabled bool
}

func NewService(pool *pgxpool.Pool, supportURL, privacyURL string, pushEnabled bool) *Service {
	return &Service{pool: pool, supportURL: supportURL, privacyURL: privacyURL, pushEnabled: pushEnabled}
}

// AppConfig — настройки для приложения до входа.
type AppConfig struct {
	PushEnabled bool   `json:"push_enabled"`
	SupportURL  string `json:"support_url"`
	PrivacyURL  string `json:"privacy_url"`
}

func (s *Service) Config() AppConfig {
	return AppConfig{PushEnabled: s.pushEnabled, SupportURL: s.supportURL, PrivacyURL: s.privacyURL}
}

type Notifications struct {
	Orders   bool `json:"orders"`
	Promos   bool `json:"promos"`
	Telegram bool `json:"telegram"`
}

type Profile struct {
	Phone          string        `json:"phone"`
	FullName       string        `json:"full_name"`
	Language       string        `json:"language"`
	City           string        `json:"city"`
	Notifications  Notifications `json:"notifications"`
	TelegramLinked bool          `json:"telegram_linked"`
	SupportURL     string        `json:"support_url"`
	PrivacyURL     string        `json:"privacy_url"`
}

func (s *Service) Get(ctx context.Context, userID string) (Profile, error) {
	p := Profile{SupportURL: s.supportURL, PrivacyURL: s.privacyURL}
	err := s.pool.QueryRow(ctx, `
		SELECT u.phone, u.full_name, c.language, c.city, c.notify_orders, c.notify_promos, c.notify_telegram,
		       EXISTS (SELECT 1 FROM telegram_links tl WHERE tl.phone = u.phone)
		FROM users u JOIN customers c ON c.user_id = u.id
		WHERE u.id = $1 AND c.deleted_at IS NULL`, userID).Scan(
		&p.Phone, &p.FullName, &p.Language, &p.City,
		&p.Notifications.Orders, &p.Notifications.Promos, &p.Notifications.Telegram, &p.TelegramLinked)
	if errors.Is(err, pgx.ErrNoRows) {
		return p, apperr.NotFound("профиль не найден")
	}
	return p, err
}

type UpdateInput struct {
	FullName      *string `json:"full_name"`
	Language      *string `json:"language"`
	City          *string `json:"city"`
	Notifications *struct {
		Orders   *bool `json:"orders"`
		Promos   *bool `json:"promos"`
		Telegram *bool `json:"telegram"`
	} `json:"notifications"`
}

func trim(p *string) *string {
	if p == nil {
		return nil
	}
	v := strings.Join(strings.Fields(*p), " ")
	return &v
}

func (s *Service) Update(ctx context.Context, userID string, in UpdateInput) (Profile, error) {
	name, city := trim(in.FullName), trim(in.City)
	if name != nil && len([]rune(*name)) > 100 {
		return Profile{}, apperr.Validation("full_name: не длиннее 100 символов")
	}
	if city != nil && len([]rune(*city)) > 60 {
		return Profile{}, apperr.Validation("city: не длиннее 60 символов")
	}
	if in.Language != nil && *in.Language != "ru" && *in.Language != "uz" {
		return Profile{}, apperr.Validation("language: ru или uz")
	}
	var orders, promos, tg *bool
	if n := in.Notifications; n != nil {
		orders, promos, tg = n.Orders, n.Promos, n.Telegram
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if name != nil {
			if _, err := tx.Exec(ctx, `UPDATE users SET full_name = $2 WHERE id = $1`, userID, *name); err != nil {
				return err
			}
		}
		_, err := tx.Exec(ctx, `
			UPDATE customers SET language = COALESCE($2, language), city = COALESCE($3, city),
			       notify_orders = COALESCE($4, notify_orders), notify_promos = COALESCE($5, notify_promos),
			       notify_telegram = COALESCE($6, notify_telegram)
			WHERE user_id = $1`, userID, in.Language, city, orders, promos, tg)
		if err != nil {
			return err
		}
		if in.Language != nil {
			_, err = tx.Exec(ctx, `UPDATE devices SET language = $2 WHERE user_id = $1`, userID, *in.Language)
		}
		return err
	})
	if err != nil {
		return Profile{}, err
	}
	return s.Get(ctx, userID)
}

type ActiveOrder struct {
	ID        string `json:"id"`
	Number    int64  `json:"number"`
	Status    string `json:"status"`
	StoreName string `json:"store_name"`
}

type Stats struct {
	OrdersCount    int          `json:"orders_count"`
	Saved          string       `json:"saved"`
	AddressesCount int          `json:"addresses_count"`
	FavoritesCount int          `json:"favorites_count"`
	ActiveOrder    *ActiveOrder `json:"active_order"`
}

// activeStatuses — заказ ещё не завершён: удалить аккаунт нельзя, в профиле — карточка.
const activeStatuses = `('awaiting_payment', 'paid', 'accepted', 'picking', 'picked', 'delivering')`

func (s *Service) Stats(ctx context.Context, userID string) (Stats, error) {
	var st Stats
	err := s.pool.QueryRow(ctx, `
		SELECT (SELECT count(*) FROM orders WHERE customer_id = $1 AND status NOT IN ('awaiting_payment', 'expired')),
		       (SELECT COALESCE(sum(discount), 0)::numeric(18,2)::text FROM orders WHERE customer_id = $1 AND status = 'delivered'),
		       (SELECT count(*) FROM customer_addresses WHERE user_id = $1),
		       (SELECT count(*) FROM favorites WHERE user_id = $1)`, userID).Scan(
		&st.OrdersCount, &st.Saved, &st.AddressesCount, &st.FavoritesCount)
	if err != nil {
		return st, err
	}
	var a ActiveOrder
	err = s.pool.QueryRow(ctx, `
		SELECT o.id, o.number, o.status, s.name FROM orders o JOIN stores s ON s.id = o.store_id
		WHERE o.customer_id = $1 AND o.status IN `+activeStatuses+`
		ORDER BY o.created_at DESC LIMIT 1`, userID).Scan(&a.ID, &a.Number, &a.Status, &a.StoreName)
	if err == nil {
		st.ActiveOrder = &a
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return st, err
	}
	return st, nil
}

// ------------------------------------------------------------ устройства

type DeviceInput struct {
	Token    string `json:"token"`
	Platform string `json:"platform"`
	Language string `json:"language"`
}

// RegisterDevice привязывает токен FCM к покупателю и текущей сессии.
// Тот же токен с другого аккаунта переходит к новому владельцу.
func (s *Service) RegisterDevice(ctx context.Context, userID, sessionID string, in DeviceInput) error {
	in.Token = strings.TrimSpace(in.Token)
	if len(in.Token) < 20 || len(in.Token) > 4096 {
		return apperr.Validation("token: неверный токен устройства")
	}
	if in.Platform != "ios" && in.Platform != "android" {
		return apperr.Validation("platform: ios или android")
	}
	if in.Language == "" {
		if err := s.pool.QueryRow(ctx, `SELECT language FROM customers WHERE user_id = $1`, userID).Scan(&in.Language); err != nil {
			return err
		}
	}
	if in.Language != "ru" && in.Language != "uz" {
		return apperr.Validation("language: ru или uz")
	}
	_, err := s.pool.Exec(ctx, `
		INSERT INTO devices (user_id, session_id, token, platform, language)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (token) DO UPDATE SET user_id = EXCLUDED.user_id, session_id = EXCLUDED.session_id,
		       platform = EXCLUDED.platform, language = EXCLUDED.language, last_seen_at = now()`,
		userID, sessionID, in.Token, in.Platform, in.Language)
	return err
}

func (s *Service) RemoveDevice(ctx context.Context, userID, token string) error {
	_, err := s.pool.Exec(ctx, `DELETE FROM devices WHERE user_id = $1 AND token = $2`, userID, token)
	return err
}

// ------------------------------------------------------ удаление аккаунта

// Delete удаляет аккаунт покупателя: закрывает сессии, стирает имя, адреса,
// избранное и устройства. Заказы остаются для учёта и фискализации, но без
// телефона и адреса (координаты огрубляются до ~1 км). Номер телефона
// освобождается — новый вход с ним создаст новый аккаунт. У сотрудников и
// супер-админов номер остаётся (он нужен для входа в панели).
func (s *Service) Delete(ctx context.Context, userID string) error {
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var active int64
		err := tx.QueryRow(ctx, `SELECT number FROM orders WHERE customer_id = $1 AND status IN `+activeStatuses+` LIMIT 1`, userID).Scan(&active)
		if err == nil {
			return apperr.Conflict("active_order", fmt.Sprintf("Дождитесь завершения заказа №%d — потом аккаунт можно удалить", active))
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		for _, q := range []string{
			`DELETE FROM devices WHERE user_id = $1`,
			`DELETE FROM favorites WHERE user_id = $1`,
			`DELETE FROM customer_addresses WHERE user_id = $1`,
			`DELETE FROM notifications_outbox WHERE user_id = $1 AND status = 'pending'`,
			`UPDATE sessions SET revoked_at = now() WHERE user_id = $1 AND app = 'client' AND revoked_at IS NULL`,
			`UPDATE customers SET deleted_at = now(), city = '', language = 'ru',
			        notify_orders = true, notify_promos = true, notify_telegram = true WHERE user_id = $1`,
			`UPDATE orders SET customer_phone = '', entrance = '', floor = '', apartment = '', address_comment = '',
			        comment = '', address = 'Адрес удалён',
			        location = ST_SetSRID(ST_MakePoint(round(ST_X(location::geometry)::numeric, 2)::float8,
			                                           round(ST_Y(location::geometry)::numeric, 2)::float8), 4326)::geography
			 WHERE customer_id = $1`,
		} {
			if _, err := tx.Exec(ctx, q, userID); err != nil {
				return err
			}
		}
		var staff bool
		if err := tx.QueryRow(ctx, `
			SELECT EXISTS (SELECT 1 FROM employees WHERE user_id = $1)
			    OR EXISTS (SELECT 1 FROM platform_admins WHERE user_id = $1)`, userID).Scan(&staff); err != nil {
			return err
		}
		if staff {
			return nil
		}
		tomb, err := tombstonePhone()
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM telegram_links WHERE phone = (SELECT phone FROM users WHERE id = $1)`, userID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM auth_codes WHERE phone = (SELECT phone FROM users WHERE id = $1)`, userID); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE users SET full_name = '', phone = $2 WHERE id = $1`, userID, tomb)
		return err
	})
}

// tombstonePhone — номер вида +999…: код +999 не выдаётся ни одной стране.
func tombstonePhone() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("+999%012d", n.Int64()), nil
}
