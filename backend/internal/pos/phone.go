package pos

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Касса в телефоне (Figma «SM Магазин · Касса в телефоне»): сотрудник с
// правом «Продажа» в приложении «SM Магазин» нажимает «Продать», и его
// телефон становится кассой магазина. Дальше телефон работает через API
// кассы (/pos/…) с этим токеном: каталог, смена, продажи, долги — как POS.
//
// Касса-телефон привязана к сотруднику (продаёт только от его имени, без
// ПИНа — он уже вошёл в приложение) и в лимит касс тарифа не входит.

type PhoneInput struct {
	StoreID    string `json:"store_id"`
	AppVersion string `json:"app_version"`
}

// PhoneKassa — токен кассы для телефона и кто на ней продаёт.
type PhoneKassa struct {
	Activation
	EmployeeID   string `json:"employee_id"`
	EmployeeName string `json:"employee_name"`
}

// Phone заводит (или находит) кассу-телефон сотрудника в магазине и выдаёт
// новый токен. Старый токен этой кассы перестаёт действовать — так телефон,
// на котором сотрудник вошёл последним, и продаёт.
func (s *Service) Phone(ctx context.Context, p *identity.Principal, in PhoneInput) (PhoneKassa, error) {
	var out PhoneKassa
	if err := p.Require(identity.PermSalesPOS); err != nil {
		return out, apperr.Forbidden("у сотрудника нет права продавать").Uz("xodimda sotish huquqi yoʻq")
	}
	if p.EmployeeID == "" {
		return out, apperr.Forbidden("касса в телефоне — только для сотрудника магазина").Uz("telefondagi kassa — faqat doʻkon xodimi uchun")
	}
	if !httpx.IsUUID(in.StoreID) || !p.CanAccessStore(in.StoreID) {
		return out, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	token, err := randomToken()
	if err != nil {
		return out, err
	}
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var status string
		err := tx.QueryRow(ctx, `SELECT st.status FROM stores st JOIN networks n ON n.id = st.network_id
			WHERE st.id = $1 AND st.network_id = $2 AND n.status = 'active'`, in.StoreID, p.NetworkID).Scan(&status)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
		}
		if err != nil {
			return err
		}
		if status != "active" {
			return apperr.Conflict("store_inactive", "магазин не работает — продавать нельзя").Uz("doʻkon ishlamayapti — sotib boʻlmaydi")
		}
		if err := tx.QueryRow(ctx, `SELECT full_name FROM employees WHERE id = $1 AND network_id = $2 AND status = 'active'`,
			p.EmployeeID, p.NetworkID).Scan(&out.EmployeeName); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return errCashier
			}
			return err
		}
		name := phoneName(out.EmployeeName)
		version := strings.TrimSpace(in.AppVersion)
		err = tx.QueryRow(ctx, `
			UPDATE pos_devices SET token_hash = $3, activation_hash = NULL, activation_expires = NULL, name = $4,
			       activated_at = COALESCE(activated_at, now()), app_version = left($5, 40)
			WHERE store_id = $1 AND employee_id = $2 AND revoked_at IS NULL
			RETURNING id`, in.StoreID, p.EmployeeID, hashSecret(token), name, version).Scan(&out.DeviceID)
		if errors.Is(err, pgx.ErrNoRows) {
			// Первая продажа с этого телефона: заводим кассу (без проверки лимита касс).
			err = tx.QueryRow(ctx, `
				INSERT INTO pos_devices (network_id, store_id, name, employee_id, token_hash, activated_at, app_version)
				VALUES ($1, $2, $3, $4, $5, now(), left($6, 40)) RETURNING id`,
				p.NetworkID, in.StoreID, name, p.EmployeeID, hashSecret(token), version).Scan(&out.DeviceID)
			if db.IsUniqueViolation(err, "pos_devices_phone_idx") {
				return errRetryPhone
			}
		}
		if err != nil {
			return err
		}
		out.DeviceName = name
		return tx.QueryRow(ctx, `SELECT st.name, n.name FROM stores st JOIN networks n ON n.id = st.network_id WHERE st.id = $1`,
			in.StoreID).Scan(&out.StoreName, &out.NetworkName)
	})
	if errors.Is(err, errRetryPhone) {
		// Два запроса с одного телефона одновременно: второй найдёт кассу первого.
		return s.Phone(ctx, p, in)
	}
	if err != nil {
		return PhoneKassa{}, err
	}
	out.Token, out.StoreID, out.EmployeeID = token, in.StoreID, p.EmployeeID
	return out, nil
}

var errRetryPhone = errors.New("phone kassa created concurrently")

// phoneName — «Телефон · Дильноза» (название кассы до 60 символов).
func phoneName(employee string) string {
	n := "Телефон · " + strings.TrimSpace(employee)
	if r := []rune(n); len(r) > 60 {
		n = string(r[:60])
	}
	return strings.TrimSpace(n)
}
