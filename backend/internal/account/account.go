// Package account — удаление аккаунтов по требованиям App Store и Google
// Play: курьер «по пути» удаляет аккаунт сам, сотрудники и штатные курьеры
// (их заводит владелец сети) отправляют запрос супер-админу, а на сайте
// можно удалить аккаунт по номеру и коду без входа в приложение.
package account

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/notify"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
	"github.com/sanedidi/super-market/backend/internal/platform/phone"
	"github.com/sanedidi/super-market/backend/internal/profile"
)

type Service struct {
	pool   *pgxpool.Pool
	id     *identity.Service
	notify *notify.Notifier
	log    *slog.Logger
}

func NewService(pool *pgxpool.Pool, id *identity.Service, n *notify.Notifier, log *slog.Logger) *Service {
	return &Service{pool: pool, id: id, notify: n, log: log}
}

// ------------------------------------------------- курьер «по пути»

// DeleteCrowd — курьер «по пути» удаляет свой аккаунт (DELETE /crowd/me).
func (s *Service) DeleteCrowd(ctx context.Context, p *identity.Principal) error {
	if p == nil || p.App != identity.AppCrowd {
		return apperr.Forbidden("только для курьеров «по пути»")
	}
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error { return deleteCrowd(ctx, tx, p.UserID) })
}

// deleteCrowd обезличивает профиль курьера «по пути»: имя, дата рождения,
// хэш документа, маршрут и точка стираются, сессии закрываются. Заказы,
// начисления, выплаты и нарушения остаются (без имени). Нельзя, пока у
// курьера есть заказ на руках или невыплаченный остаток — 409.
// Заблокированному хэш документа оставляем: иначе он зарегистрируется заново
// с тем же документом.
func deleteCrowd(ctx context.Context, tx pgx.Tx, userID string) error {
	var status string
	err := tx.QueryRow(ctx, `SELECT status FROM crowd_couriers WHERE user_id = $1 AND deleted_at IS NULL FOR UPDATE`, userID).Scan(&status)
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.NotFound("профиль курьера не найден")
	}
	if err != nil {
		return err
	}
	var number int64
	err = tx.QueryRow(ctx, `
		SELECT number FROM orders WHERE crowd_courier_id = $1 AND status IN ('picked', 'delivering')
		ORDER BY crowd_accepted_at LIMIT 1`, userID).Scan(&number)
	if err == nil {
		return apperr.Conflict("active_order", fmt.Sprintf("Сначала доставьте или отмените заказ №%d — потом аккаунт можно удалить", number)).
			WithDetails(map[string]any{"account": "crowd", "order_number": number})
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	var (
		unpaid  bool
		balance string
	)
	if err := tx.QueryRow(ctx, `
		SELECT COALESCE(sum(amount), 0) > 0, COALESCE(sum(amount), 0)::numeric(18,2)::text
		FROM crowd_ledger WHERE courier_id = $1`, userID).Scan(&unpaid, &balance); err != nil {
		return err
	}
	if unpaid {
		return apperr.Conflict("unpaid_balance",
			fmt.Sprintf("К выплате %s сум — дождитесь выплаты в понедельник, потом аккаунт можно удалить", money.Group(balance))).
			WithDetails(map[string]any{"account": "crowd", "balance": balance})
	}
	for _, q := range []string{
		`UPDATE crowd_couriers SET deleted_at = now(), full_name = '', birth_date = NULL,
		        doc_hash = CASE WHEN status = 'blocked' THEN doc_hash END,
		        status = CASE WHEN status = 'blocked' THEN 'blocked' ELSE 'unverified' END,
		        online = false, dest = NULL, dest_title = '', location = NULL, located_at = NULL
		 WHERE user_id = $1`,
		`UPDATE courier_verifications SET full_name = '', birth_date = NULL, doc_hash = NULL WHERE courier_id = $1`,
		`UPDATE sessions SET revoked_at = now() WHERE user_id = $1 AND app = 'crowd' AND revoked_at IS NULL`,
	} {
		if _, err := tx.Exec(ctx, q, userID); err != nil {
			return err
		}
	}
	return identity.ReleasePhone(ctx, tx, userID)
}

// ------------------------------------------------- удаление с сайта

// Result — что сделано при удалении с сайта: deleted — удалённые аккаунты
// (client, crowd), requested — отправлены запросы супер-админу (store, courier).
type Result struct {
	Deleted   []string `json:"deleted"`
	Requested []string `json:"requested"`
}

var errNoAccount = apperr.New(http.StatusNotFound, "account_not_found", "аккаунт с этим номером не найден")

// RequestCode отправляет код на номер, как при входе (Telegram или SMS, та же
// пауза между запросами). Только для номера, у которого есть аккаунт, —
// чтобы сайт не рассылал коды на любые номера.
func (s *Service) RequestCode(ctx context.Context, rawPhone string) (int, string, error) {
	ph, err := phone.Normalize(rawPhone)
	if err != nil {
		return 0, "", apperr.Validation("неверный номер телефона")
	}
	var exists bool
	if err := s.pool.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM users u WHERE u.phone = $1 AND (
		       EXISTS (SELECT 1 FROM customers c WHERE c.user_id = u.id AND c.deleted_at IS NULL)
		    OR EXISTS (SELECT 1 FROM crowd_couriers cc WHERE cc.user_id = u.id AND cc.deleted_at IS NULL)
		    OR EXISTS (SELECT 1 FROM employees e WHERE e.user_id = u.id)))`, ph).Scan(&exists); err != nil {
		return 0, "", err
	}
	if !exists {
		return 0, "", errNoAccount
	}
	return s.id.RequestCodeVia(ctx, ph, "")
}

// Confirm проверяет код (те же 5 попыток, что при входе) и удаляет всё, что
// человек может удалить сам: аккаунт покупателя и курьера «по пути» — по
// тем же правилам, что в приложениях (409, пока есть незавершённый заказ или
// невыплаченный остаток; тогда не удаляется ничего). Сотруднику и штатному
// курьеру создаётся запрос супер-админу.
func (s *Service) Confirm(ctx context.Context, rawPhone, code string) (Result, error) {
	res := Result{Deleted: []string{}, Requested: []string{}}
	ph, err := s.id.ConsumeCode(ctx, rawPhone, code)
	if err != nil {
		return res, err
	}
	var userID string
	err = s.pool.QueryRow(ctx, `SELECT id FROM users WHERE phone = $1`, ph).Scan(&userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return res, errNoAccount
	}
	if err != nil {
		return res, err
	}
	var created *DeletionRequest
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		res = Result{Deleted: []string{}, Requested: []string{}}
		var crowd, client bool
		var employeeID *string
		if err := tx.QueryRow(ctx, `
			SELECT EXISTS (SELECT 1 FROM crowd_couriers WHERE user_id = $1 AND deleted_at IS NULL),
			       EXISTS (SELECT 1 FROM customers WHERE user_id = $1 AND deleted_at IS NULL),
			       (SELECT id FROM employees WHERE user_id = $1)`, userID).Scan(&crowd, &client, &employeeID); err != nil {
			return err
		}
		// Сначала курьер: тогда при удалении покупателя номер освободится.
		if crowd {
			if err := deleteCrowd(ctx, tx, userID); err != nil {
				return err
			}
			res.Deleted = append(res.Deleted, "crowd")
		}
		if client {
			if err := profile.DeleteClient(ctx, tx, userID); err != nil {
				return err
			}
			res.Deleted = append(res.Deleted, "client")
		}
		if employeeID != nil {
			// Курьер — сотрудник с правом доставки и логином для приложения
			// курьера. Логин теперь есть у всех, кто входит в панель, поэтому
			// смотрим и на роль.
			var courier bool
			if err := tx.QueryRow(ctx, `
				SELECT NOT r.is_owner AND 'orders.deliver' = ANY(r.permissions)
				       AND EXISTS (SELECT 1 FROM employee_logins el WHERE el.employee_id = e.id)
				FROM employees e JOIN roles r ON r.id = e.role_id
				WHERE e.id = $1`, *employeeID).Scan(&courier); err != nil {
				return err
			}
			app := identity.AppStore
			if courier {
				app = identity.AppCourier
			}
			r, isNew, err := createRequest(ctx, tx, *employeeID, app, "web", "")
			if err != nil {
				return err
			}
			if isNew {
				created = &r
			}
			res.Requested = append(res.Requested, r.App)
		}
		return nil
	})
	if err != nil {
		return Result{Deleted: []string{}, Requested: []string{}}, err
	}
	if created != nil {
		s.announce(ctx, *created)
	}
	return res, nil
}
