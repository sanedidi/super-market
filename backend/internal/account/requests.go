package account

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// DeletionRequest — запрос на удаление аккаунта сотрудника или штатного
// курьера. Удаляет супер-админ: отключает сотрудника в сети (для владельца —
// закрывает сеть) и отмечает запрос выполненным.
type DeletionRequest struct {
	ID          string     `json:"id"`
	App         string     `json:"app"`    // store — «SM Магазин», courier — приложение курьера
	Source      string     `json:"source"` // app — из приложения, web — с сайта
	Status      string     `json:"status"` // pending, done, rejected
	IsOwner     bool       `json:"is_owner"`
	Phone       string     `json:"phone"`
	FullName    string     `json:"full_name"`
	Reason      string     `json:"reason"`
	Note        string     `json:"note"`
	UserID      *string    `json:"user_id"`
	EmployeeID  *string    `json:"employee_id"`
	NetworkID   *string    `json:"network_id"`
	NetworkName *string    `json:"network_name"`
	CreatedAt   time.Time  `json:"created_at"`
	ResolvedAt  *time.Time `json:"resolved_at"`
}

const requestSelect = `
	SELECT r.id, r.app, r.source, r.status, r.is_owner, r.phone, r.full_name, r.reason, r.note,
	       r.user_id, r.employee_id, r.network_id, n.name, r.created_at, r.resolved_at
	FROM account_deletion_requests r LEFT JOIN networks n ON n.id = r.network_id`

func scanRequest(row pgx.Row) (DeletionRequest, error) {
	var r DeletionRequest
	err := row.Scan(&r.ID, &r.App, &r.Source, &r.Status, &r.IsOwner, &r.Phone, &r.FullName, &r.Reason, &r.Note,
		&r.UserID, &r.EmployeeID, &r.NetworkID, &r.NetworkName, &r.CreatedAt, &r.ResolvedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return r, apperr.NotFound("запрос не найден").Uz("soʻrov topilmadi")
	}
	return r, err
}

// createRequest создаёт запрос на удаление для сотрудника; если открытый
// запрос уже есть, возвращает его (isNew = false).
func createRequest(ctx context.Context, tx pgx.Tx, employeeID, app, source, reason string) (DeletionRequest, bool, error) {
	var id string
	err := tx.QueryRow(ctx, `SELECT id FROM account_deletion_requests WHERE employee_id = $1 AND status = 'pending'`, employeeID).Scan(&id)
	switch {
	case err == nil:
		r, err := scanRequest(tx.QueryRow(ctx, requestSelect+` WHERE r.id = $1`, id))
		return r, false, err
	case !errors.Is(err, pgx.ErrNoRows):
		return DeletionRequest{}, false, err
	}
	err = tx.QueryRow(ctx, `
		INSERT INTO account_deletion_requests (user_id, employee_id, network_id, app, source, is_owner, phone, full_name, reason)
		SELECT e.user_id, e.id, e.network_id, $2, $3, r.is_owner, u.phone, e.full_name, $4
		FROM employees e JOIN users u ON u.id = e.user_id JOIN roles r ON r.id = e.role_id
		WHERE e.id = $1
		RETURNING id`, employeeID, app, source, reason).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return DeletionRequest{}, false, apperr.NotFound("сотрудник не найден").Uz("xodim topilmadi")
	}
	if err != nil {
		return DeletionRequest{}, false, err
	}
	r, err := scanRequest(tx.QueryRow(ctx, requestSelect+` WHERE r.id = $1`, id))
	return r, true, err
}

// announce сообщает о новом запросе в Telegram супер-админам и владельцу
// сети (если просит не он сам).
func (s *Service) announce(ctx context.Context, r DeletionRequest) {
	app, appUz := "«SM Магазин»", "«SM Магазин» ilovasi"
	if r.App == identity.AppCourier {
		app, appUz = "приложение курьера", "kuryer ilovasi"
	}
	network := ""
	if r.NetworkName != nil {
		network = *r.NetworkName
	}
	text := fmt.Sprintf("Запрос на удаление аккаунта\n%s, %s\nСеть «%s», %s", r.FullName, r.Phone, network, app)
	textUz := fmt.Sprintf("Akkauntni oʻchirish soʻrovi\n%s, %s\nTarmoq «%s», %s", r.FullName, r.Phone, network, appUz)
	if r.IsOwner {
		text += "\nЭто владелец сети: удаление аккаунта — закрытие сети."
	}
	if r.Source == "web" {
		text += "\nОтправлен с сайта."
		textUz += "\nSaytdan yuborilgan."
	}
	if r.Reason != "" {
		text += "\nПричина: " + r.Reason
		textUz += "\nSabab: " + r.Reason
	}
	s.notify.SuperAdmins(ctx, text+"\n\nОбработайте в панели супер-админа.")
	if !r.IsOwner && r.NetworkID != nil {
		// Владельцу сети — на его языке (users.language).
		s.notify.NetworkOwners(ctx, *r.NetworkID, identity.PermStaffManage, i18n.Text{
			RU: text + "\n\nСотрудника можно отключить в разделе «Сотрудники»; аккаунт удалит поддержка.",
			UZ: textUz + "\n\nXodimni «Xodimlar» boʻlimida faolsizlantirish mumkin; akkauntni qoʻllab-quvvatlash xizmati oʻchiradi.",
		})
	}
}

// RequestInput — тело запроса на удаление из приложения.
type RequestInput struct {
	Reason string `json:"reason"`
}

// Request — сотрудник («SM Магазин») или штатный курьер просит удалить свой
// аккаунт. Повторный запрос, пока первый не обработан, возвращает тот же
// (isNew = false).
func (s *Service) Request(ctx context.Context, p *identity.Principal, in RequestInput) (DeletionRequest, bool, error) {
	if p == nil || p.EmployeeID == "" || (p.App != identity.AppStore && p.App != identity.AppCourier) {
		return DeletionRequest{}, false, apperr.Forbidden("только для сотрудников и курьеров магазина").Uz("faqat doʻkon xodimlari va kuryerlari uchun")
	}
	reason := strings.TrimSpace(in.Reason)
	if len([]rune(reason)) > 500 {
		return DeletionRequest{}, false, apperr.Validation("reason: не длиннее 500 символов").Uz("reason: 500 belgidan oshmasin")
	}
	var (
		r     DeletionRequest
		isNew bool
	)
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var err error
		r, isNew, err = createRequest(ctx, tx, p.EmployeeID, p.App, "app", reason)
		return err
	})
	if err != nil {
		return r, false, err
	}
	if isNew {
		s.announce(ctx, r)
	}
	return r, isNew, nil
}

// AdminRequests — запросы на удаление для супер-админа, новые сверху.
func (s *Service) AdminRequests(ctx context.Context, status string, page httpx.Page) ([]DeletionRequest, error) {
	if status != "" && status != "pending" && status != "done" && status != "rejected" {
		return nil, apperr.Validation("status: pending, done или rejected").Uz("status: pending, done yoki rejected")
	}
	rows, err := s.pool.Query(ctx, requestSelect+`
		WHERE $1 = '' OR r.status = $1
		ORDER BY r.status <> 'pending', r.created_at DESC
		LIMIT $2 OFFSET $3`, status, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (DeletionRequest, error) { return scanRequest(row) })
}

// ResolveInput — комментарий супер-админа к решению.
type ResolveInput struct {
	Note string `json:"note"`
}

// AdminResolve отмечает запрос выполненным (done) или отклонённым (rejected).
// Сам аккаунт супер-админ удаляет вручную (отключает сотрудника, закрывает сеть).
func (s *Service) AdminResolve(ctx context.Context, admin *identity.Principal, id, status string, in ResolveInput) (DeletionRequest, error) {
	note := strings.TrimSpace(in.Note)
	if len([]rune(note)) > 500 {
		return DeletionRequest{}, apperr.Validation("note: не длиннее 500 символов").Uz("note: 500 belgidan oshmasin")
	}
	tag, err := s.pool.Exec(ctx, `
		UPDATE account_deletion_requests SET status = $2, note = $3, resolved_by = $4, resolved_at = now()
		WHERE id = $1 AND status = 'pending'`, id, status, note, admin.UserID)
	if err != nil {
		return DeletionRequest{}, err
	}
	r, err := scanRequest(s.pool.QueryRow(ctx, requestSelect+` WHERE r.id = $1`, id))
	if err != nil {
		return r, err
	}
	if tag.RowsAffected() == 0 {
		return r, apperr.Conflict("already_resolved", "запрос уже обработан").Uz("soʻrov allaqachon koʻrib chiqilgan")
	}
	return r, nil
}
