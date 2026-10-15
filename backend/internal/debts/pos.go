package debts

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// Касса: покупатель по номеру, код подтверждения, должники для работы без связи.

// Lookup — что касса показывает после ввода номера.
type Lookup struct {
	Found     bool     `json:"found"`
	Phone     string   `json:"phone"`
	Debtor    *Balance `json:"debtor"`
	Purchases int      `json:"purchases"` // покупок в долг в этом магазине
	// Для нового покупателя: лимит без кода и с кодом, нужен ли код.
	UnverifiedLimit string `json:"unverified_limit"`
	DefaultLimit    string `json:"default_limit"`
	RequireCode     bool   `json:"require_code"`
	DebtEnabled     bool   `json:"debt_enabled"`
	// Покупатель найден по QR из приложения (номер QR; пусто — по номеру).
	QRID string `json:"qr_id,omitempty"`
}

func (s *Service) Lookup(ctx context.Context, p *identity.Principal, rawPhone string) (Lookup, error) {
	var out Lookup
	if err := p.RequireAny(identity.PermDebtsGive, identity.PermDebtsManage, identity.PermSalesPOS); err != nil {
		return out, err
	}
	ph, err := normPhone(rawPhone)
	if err != nil {
		return out, err
	}
	storeID := p.StoreIDs[0]
	st, err := loadSettings(ctx, s.pool, p.NetworkID)
	if err != nil {
		return out, err
	}
	out.Phone, out.UnverifiedLimit, out.DefaultLimit, out.RequireCode = ph, st.UnverifiedLimit, st.DefaultLimit, st.RequireCode
	if err := s.pool.QueryRow(ctx, `SELECT debt_enabled AND network_has_feature(network_id, 'debts') FROM stores WHERE id = $1`, storeID).Scan(&out.DebtEnabled); err != nil {
		return out, err
	}
	var id string
	err = s.pool.QueryRow(ctx, `SELECT id FROM debtors WHERE network_id = $1 AND phone = $2`, p.NetworkID, ph).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, nil
	}
	if err != nil {
		return out, err
	}
	out.Found = true
	list, err := s.balances(ctx, s.pool, p.NetworkID, []string{storeID}, &id, "")
	if err != nil {
		return out, err
	}
	if len(list) > 0 {
		out.Debtor = &list[0]
	} else {
		// Покупатель есть в сети, но в этом магазине долга не было.
		b := Balance{DebtorID: id, StoreID: storeID, Amount: "0.00"}
		limit, blocked, verified, err := effectiveLimit(ctx, s.pool, p.NetworkID, id)
		if err != nil {
			return out, err
		}
		if err := s.pool.QueryRow(ctx, `SELECT d.phone, d.full_name, s.name FROM debtors d, stores s WHERE d.id = $1 AND s.id = $2`, id, storeID).
			Scan(&b.Phone, &b.FullName, &b.StoreName); err != nil {
			return out, err
		}
		b.Limit, b.Available, b.Blocked, b.Verified = limit.Money(), limit.Money(), blocked, verified
		out.Debtor = &b
	}
	err = s.pool.QueryRow(ctx, `SELECT count(*)::int FROM debt_entries WHERE debtor_id = $1 AND store_id = $2 AND doc_type = 'sale'`,
		id, storeID).Scan(&out.Purchases)
	return out, err
}

// CatalogDebtor — должник в каталоге кассы для работы без связи.
type CatalogDebtor struct {
	Phone    string `json:"phone"`
	FullName string `json:"full_name"`
	Debt     string `json:"debt"`
	Limit    string `json:"limit"`
	Blocked  bool   `json:"blocked"`
	Verified bool   `json:"verified"`
	// Номер QR покупателя из приложения: касса без связи находит его по скану.
	QRID string `json:"qr_id"`
}

// CatalogDebtors — покупатели сети с их долгом в магазине кассы (до 5000).
func CatalogDebtors(ctx context.Context, q db.Querier, networkID, storeID string) ([]CatalogDebtor, error) {
	rows, err := q.Query(ctx, `
		SELECT d.phone, d.full_name,
		       COALESCE((SELECT sum(e.amount) FROM debt_entries e WHERE e.debtor_id = d.id AND e.store_id = $2), 0)::numeric(18,2)::text,
		       COALESCE(d.credit_limit, CASE WHEN d.verified_at IS NULL THEN ds.unverified_limit ELSE ds.default_limit END,
		                CASE WHEN d.verified_at IS NULL THEN 100000 ELSE 500000 END)::numeric(18,2)::text,
		       d.blocked, d.verified_at IS NOT NULL,
		       COALESCE((SELECT q.qr_id FROM users u JOIN client_qr q ON q.user_id = u.id
		                 JOIN customers c ON c.user_id = u.id AND c.deleted_at IS NULL
		                 WHERE u.phone = d.phone), '')
		FROM debtors d LEFT JOIN debt_settings ds ON ds.network_id = d.network_id
		WHERE d.network_id = $1
		ORDER BY d.updated_at DESC LIMIT 5000`, networkID, storeID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[CatalogDebtor])
}

// --------------------------------------------------- код подтверждения

const (
	codeTTL      = 10 * time.Minute
	codeCooldown = time.Minute
	codeAttempts = 5
)

type CodeInput struct {
	Phone    string `json:"phone"`
	FullName string `json:"full_name"`
	Code     string `json:"code"`
}

type CodeSent struct {
	Channel   string `json:"channel"` // sms, push, dev
	ExpiresIn int    `json:"expires_in"`
}

var errNoChannel = apperr.Conflict("no_channel", "некуда отправить код: SMS не настроены и у номера нет приложения — запишите без кода").Uz("kodni yuborishning iloji yoʻq: SMS sozlanmagan va raqamda ilova yoʻq — kodsiz yozib qoʻying")

// DebtSMSText — SMS с кодом долга (%s — магазин, %s — код). Как и код входа,
// должен совпадать с шаблоном, одобренным в кабинете Eskiz.
const DebtSMSText = "Super Market: %s doʻkoni xaridlarni raqamingizga qarzga yozmoqda. Tasdiqlash kodi: %s. Xarid qilmagan boʻlsangiz, kodni hech kimga bermang."

// SendCode отправляет покупателю код подтверждения номера: push в приложение,
// если оно есть, иначе SMS (Eskiz).
func (s *Service) SendCode(ctx context.Context, p *identity.Principal, in CodeInput) (CodeSent, error) {
	var out CodeSent
	if err := p.RequireAny(identity.PermDebtsGive, identity.PermDebtsManage); err != nil {
		return out, err
	}
	ph, err := normPhone(in.Phone)
	if err != nil {
		return out, err
	}
	now := s.now()
	var sentAt time.Time
	err = s.pool.QueryRow(ctx, `SELECT sent_at FROM debt_codes WHERE network_id = $1 AND phone = $2`, p.NetworkID, ph).Scan(&sentAt)
	if err == nil {
		if wait := codeCooldown - now.Sub(sentAt); wait > 0 {
			return out, apperr.New(http.StatusTooManyRequests, "too_many_requests", "код уже отправлен, попробуйте позже").Uz("kod allaqachon yuborilgan, keyinroq urinib koʻring").
				WithDetails(map[string]any{"retry_after": int(wait.Seconds()) + 1})
		}
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return out, err
	}
	var storeName string
	if err := s.pool.QueryRow(ctx, `SELECT name FROM stores WHERE id = $1`, p.StoreIDs[0]).Scan(&storeName); err != nil {
		return out, err
	}
	code := s.devCode
	out.Channel = "dev"
	if code == "" {
		if code, err = randomCode(); err != nil {
			return out, err
		}
		text := i18n.Text{
			RU: fmt.Sprintf("Код %s — подтверждение, что %s записывает покупки в долг на ваш номер. Если вы ничего не покупали, никому не сообщайте код.", code, storeName),
			UZ: fmt.Sprintf("Kod %s — %s xaridlarni raqamingizga qarzga yozayotganini tasdiqlash uchun. Agar hech narsa sotib olmagan boʻlsangiz, kodni hech kimga aytmang.", code, storeName),
		}
		// Покупатель с приложением — push (бесплатно), иначе SMS через Eskiz.
		app, err := hasApp(ctx, s.pool, ph)
		if err != nil {
			return out, err
		}
		switch {
		case app:
			if _, err := s.pool.Exec(ctx, `
				INSERT INTO notifications_outbox (user_id, kind, title, body, data)
				SELECT c.user_id, 'debt_code',
				       CASE WHEN c.language = 'uz' THEN $4 ELSE $2 END,
				       CASE WHEN c.language = 'uz' THEN $5 ELSE $3 END, '{}'::jsonb
				FROM users u JOIN customers c ON c.user_id = u.id AND c.deleted_at IS NULL WHERE u.phone = $1`,
				ph, "Код подтверждения: "+code, text.RU, "Tasdiqlash kodi: "+code, text.UZ); err != nil {
				return out, err
			}
			out.Channel = "push"
		case s.sms != nil:
			if err := s.sms.Send(ctx, ph, fmt.Sprintf(DebtSMSText, storeName, code)); err != nil {
				s.log.Error("код долга: SMS не отправлено", "err", err)
				return out, apperr.New(http.StatusBadGateway, "sms_send_failed", "не удалось отправить SMS, попробуйте ещё раз").Uz("SMS yuborib boʻlmadi, qayta urinib koʻring")
			}
			out.Channel = "sms"
		default:
			return out, errNoChannel
		}
	}
	if _, err := s.pool.Exec(ctx, `
		INSERT INTO debt_codes (network_id, phone, code_hash, attempts, sent_at, expires_at) VALUES ($1, $2, $3, 0, $4, $5)
		ON CONFLICT (network_id, phone) DO UPDATE SET code_hash = EXCLUDED.code_hash, attempts = 0,
		    sent_at = EXCLUDED.sent_at, expires_at = EXCLUDED.expires_at`,
		p.NetworkID, ph, s.codeHash(p.NetworkID, ph, code), now, now.Add(codeTTL)); err != nil {
		return out, err
	}
	out.ExpiresIn = int(codeTTL.Seconds())
	return out, nil
}

// VerifyCode проверяет код и помечает номер подтверждённым (заводит
// покупателя, если его ещё нет).
func (s *Service) VerifyCode(ctx context.Context, p *identity.Principal, in CodeInput) (Lookup, error) {
	if err := p.RequireAny(identity.PermDebtsGive, identity.PermDebtsManage); err != nil {
		return Lookup{}, err
	}
	ph, err := normPhone(in.Phone)
	if err != nil {
		return Lookup{}, err
	}
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var hash []byte
		var attempts int
		var expires time.Time
		err := tx.QueryRow(ctx, `SELECT code_hash, attempts, expires_at FROM debt_codes WHERE network_id = $1 AND phone = $2 FOR UPDATE`,
			p.NetworkID, ph).Scan(&hash, &attempts, &expires)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Validation("код неверный или устарел").Uz("kod notoʻgʻri yoki eskirgan")
		}
		if err != nil {
			return err
		}
		if s.now().After(expires) || attempts >= codeAttempts {
			return apperr.Validation("код неверный или устарел — отправьте новый").Uz("kod notoʻgʻri yoki eskirgan — yangisini yuboring")
		}
		if !bytes.Equal(hash, s.codeHash(p.NetworkID, ph, in.Code)) {
			_, _ = tx.Exec(ctx, `UPDATE debt_codes SET attempts = attempts + 1 WHERE network_id = $1 AND phone = $2`, p.NetworkID, ph)
			return errWrongCode
		}
		if _, err := tx.Exec(ctx, `DELETE FROM debt_codes WHERE network_id = $1 AND phone = $2`, p.NetworkID, ph); err != nil {
			return err
		}
		id, err := upsertDebtor(ctx, tx, p.NetworkID, ph, in.FullName)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE debtors SET verified_at = COALESCE(verified_at, now()) WHERE id = $1`, id)
		return err
	})
	if errors.Is(err, errWrongCode) {
		return Lookup{}, apperr.Validation("код неверный").Uz("kod notoʻgʻri")
	}
	if err != nil {
		return Lookup{}, err
	}
	return s.Lookup(ctx, p, ph)
}

var errWrongCode = errors.New("wrong code")

func randomCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(10000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%04d", n.Int64()), nil
}

// ShiftDebt — строки X/Z-отчёта по долгам.
type ShiftDebt struct {
	Given      string `json:"debt_given"`
	GivenCount int    `json:"debt_given_count"`
	PaidCash   string `json:"debt_paid_cash"`
	PaidOther  string `json:"debt_paid_other"`
	PaidCount  int    `json:"debt_paid_count"`
}

func ShiftTotals(ctx context.Context, q db.Querier, shiftID string) (ShiftDebt, error) {
	var d ShiftDebt
	err := q.QueryRow(ctx, `
		SELECT (SELECT COALESCE(sum(debt_amount), 0) FROM sales WHERE shift_id = $1)::numeric(18,2)::text,
		       (SELECT count(*) FROM sales WHERE shift_id = $1 AND debt_amount > 0)::int,
		       (SELECT COALESCE(sum(dp.amount), 0) FROM debt_payments dp JOIN payment_methods m ON m.id = dp.payment_method_id
		          WHERE dp.shift_id = $1 AND m.kind = 'cash')::numeric(18,2)::text,
		       (SELECT COALESCE(sum(dp.amount), 0) FROM debt_payments dp JOIN payment_methods m ON m.id = dp.payment_method_id
		          WHERE dp.shift_id = $1 AND m.kind <> 'cash')::numeric(18,2)::text,
		       (SELECT count(*) FROM debt_payments WHERE shift_id = $1)::int`, shiftID).
		Scan(&d.Given, &d.GivenCount, &d.PaidCash, &d.PaidOther, &d.PaidCount)
	return d, err
}
