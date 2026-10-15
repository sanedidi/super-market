package debts

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

// QR покупателя для продажи в долг (Figma «Долги · QR-код покупателя вместо
// номера телефона»).
//
// Приложение покупателя получает секрет и считает QR само — без интернета:
//
//	«99» + qr_id (10 цифр) + код (8 цифр)
//
// Код — как в Google Authenticator (TOTP): HMAC-SHA256(секрет, номер
// 30-секундного шага), динамическое усечение, 8 цифр. Касса сканирует QR
// и спрашивает сервер (/pos/debtors/qr): тот проверяет код, находит номер
// покупателя и отвечает так же, как поиск по номеру. Вход в приложение уже
// подтвердил номер, поэтому покупатель по QR сразу «подтверждён».

const (
	QRPrefix = "99"
	QRStep   = 30 * time.Second
	QRDigits = 8
	qrIDLen  = 10

	// Шаги, которые касса принимает: часы телефона могут отставать или
	// спешить, а покупатель — открыть QR чуть раньше. Итого ~1,5 минуты.
	qrPastSteps   = 2
	qrFutureSteps = 1
)

// ClientQR — то, из чего приложение покупателя считает QR.
type ClientQR struct {
	QRID   string `json:"qr_id"`
	Secret string `json:"secret"` // hex, 32 байта
	Prefix string `json:"prefix"`
	Step   int    `json:"step"`   // секунд
	Digits int    `json:"digits"` // цифр в коде
	// Время сервера (unix, мс): приложение поправляет свои часы.
	ServerTime int64 `json:"server_time"`
}

// ClientQR выдаёт покупателю секрет QR (заводит при первом запросе).
func (s *Service) ClientQR(ctx context.Context, p *identity.Principal) (ClientQR, error) {
	out := ClientQR{Prefix: QRPrefix, Step: int(QRStep / time.Second), Digits: QRDigits}
	var secret []byte
	for attempt := 0; ; attempt++ {
		err := s.pool.QueryRow(ctx, `SELECT qr_id, secret FROM client_qr WHERE user_id = $1`, p.UserID).Scan(&out.QRID, &secret)
		if err == nil {
			break
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return out, err
		}
		if attempt >= 5 {
			return out, errors.New("client_qr: не удалось выдать номер QR")
		}
		id, err := randomQRID()
		if err != nil {
			return out, err
		}
		key := make([]byte, 32)
		if _, err := rand.Read(key); err != nil {
			return out, err
		}
		_, err = s.pool.Exec(ctx, `INSERT INTO client_qr (user_id, qr_id, secret) VALUES ($1, $2, $3) ON CONFLICT (user_id) DO NOTHING`,
			p.UserID, id, key)
		var pgErr *pgconn.PgError
		if err != nil && !(errors.As(err, &pgErr) && pgErr.Code == "23505") { // совпал qr_id — пробуем другой
			return out, err
		}
	}
	out.Secret = hex.EncodeToString(secret)
	out.ServerTime = s.now().UnixMilli()
	return out, nil
}

func randomQRID() (string, error) {
	// 10 цифр, первая не ноль.
	n, err := rand.Int(rand.Reader, big.NewInt(9_000_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%d", n.Int64()+1_000_000_000), nil
}

// QRCode — одноразовый код QR для шага [step] (unix-время / 30 с).
func QRCode(secret []byte, step int64) string {
	var msg [8]byte
	binary.BigEndian.PutUint64(msg[:], uint64(step))
	m := hmac.New(sha256.New, secret)
	m.Write(msg[:])
	sum := m.Sum(nil)
	off := sum[len(sum)-1] & 0x0f
	bin := (uint32(sum[off])&0x7f)<<24 | uint32(sum[off+1])<<16 | uint32(sum[off+2])<<8 | uint32(sum[off+3])
	return fmt.Sprintf("%0*d", QRDigits, bin%100_000_000)
}

// QRPayload — содержимое QR в момент [at] (для тестов и примеров).
func QRPayload(qrID string, secret []byte, at time.Time) string {
	return QRPrefix + qrID + QRCode(secret, at.Unix()/int64(QRStep/time.Second))
}

// ParseQR разбирает скан: «99» + qr_id + код. Пробелы и переводы строк по
// краям сканер иногда добавляет — их убираем. ok=false — это не QR покупателя.
func ParseQR(raw string) (qrID, code string, ok bool) {
	s := strings.TrimSpace(raw)
	if len(s) != len(QRPrefix)+qrIDLen+QRDigits || !strings.HasPrefix(s, QRPrefix) {
		return "", "", false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return "", "", false
		}
	}
	return s[len(QRPrefix) : len(QRPrefix)+qrIDLen], s[len(QRPrefix)+qrIDLen:], true
}

var (
	errNotClientQR = apperr.New(http.StatusBadRequest, "not_client_qr", "это не QR покупателя Super Market").
			Uz("bu Super Market xaridorining QR kodi emas")
	errQRExpired = apperr.New(http.StatusBadRequest, "qr_expired",
		"QR устарел — похоже на фото или скриншот. Попросите покупателя открыть «Мой QR-код» в приложении заново").
		Uz("QR eskirgan — rasm yoki skrinshotga oʻxshaydi. Xaridordan ilovada «Mening QR kodim»ni qaytadan ochishini soʻrang")
)

// LookupQR — покупатель по QR из приложения: проверить код, завести
// покупателя в сети (номер подтверждён входом в приложение) и ответить как
// поиск по номеру.
func (s *Service) LookupQR(ctx context.Context, p *identity.Principal, raw string) (Lookup, error) {
	if err := p.RequireAny(identity.PermDebtsGive, identity.PermDebtsManage); err != nil {
		return Lookup{}, err
	}
	qrID, code, ok := ParseQR(raw)
	if !ok {
		return Lookup{}, errNotClientQR
	}
	var secret []byte
	var ph, name string
	err := s.pool.QueryRow(ctx, `
		SELECT q.secret, u.phone,
		       COALESCE(NULLIF(btrim(c.first_name || ' ' || c.last_name), ''), u.full_name)
		FROM client_qr q
		JOIN users u ON u.id = q.user_id
		JOIN customers c ON c.user_id = u.id AND c.deleted_at IS NULL
		WHERE q.qr_id = $1`, qrID).Scan(&secret, &ph, &name)
	if errors.Is(err, pgx.ErrNoRows) {
		return Lookup{}, errNotClientQR
	}
	if err != nil {
		return Lookup{}, err
	}
	if !validQRCode(secret, code, s.now()) {
		return Lookup{}, errQRExpired
	}
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		id, err := upsertDebtor(ctx, tx, p.NetworkID, ph, name)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE debtors SET verified_at = COALESCE(verified_at, now()) WHERE id = $1`, id)
		return err
	})
	if err != nil {
		return Lookup{}, err
	}
	out, err := s.Lookup(ctx, p, ph)
	out.QRID = qrID
	return out, err
}

func validQRCode(secret []byte, code string, now time.Time) bool {
	step := now.Unix() / int64(QRStep/time.Second)
	ok := false
	for d := -qrPastSteps; d <= qrFutureSteps; d++ {
		// Все шаги проверяем до конца — время ответа не подсказывает, какой подошёл.
		if hmac.Equal([]byte(QRCode(secret, step+int64(d))), []byte(code)) {
			ok = true
		}
	}
	return ok
}

// QRRecent — покупка в долг, которую касса только что записала по QR:
// экран «Мой QR-код» показывает «Записано в долг» (Figma Q3).
type QRRecent struct {
	Entry *QREntry `json:"entry"`
}

type QREntry struct {
	ID        int64     `json:"id"`
	StoreID   string    `json:"store_id"`
	StoreName string    `json:"store_name"`
	Number    *int64    `json:"number"`
	Amount    string    `json:"amount"`
	CreatedAt time.Time `json:"created_at"`
	// Долг в магазине после покупки и срок оплаты.
	Balance string  `json:"balance"`
	DueDate *string `json:"due_date"`
}

// ClientQRRecent — последняя покупка в долг покупателя после [since]
// (не раньше 10 минут назад).
func (s *Service) ClientQRRecent(ctx context.Context, p *identity.Principal, since time.Time) (QRRecent, error) {
	var out QRRecent
	ph, err := s.clientPhone(ctx, p)
	if err != nil {
		return out, err
	}
	if floor := s.now().Add(-10 * time.Minute); since.Before(floor) {
		since = floor
	}
	var e QREntry
	err = s.pool.QueryRow(ctx, `
		SELECT e.id, e.store_id, st.name, sl.number, e.amount::text, e.created_at
		FROM debt_entries e
		JOIN debtors d ON d.id = e.debtor_id
		JOIN stores st ON st.id = e.store_id
		LEFT JOIN sales sl ON sl.id = e.doc_id
		WHERE d.phone = $1 AND e.doc_type = 'sale' AND e.created_at > $2
		ORDER BY e.created_at DESC, e.id DESC LIMIT 1`, ph, since).
		Scan(&e.ID, &e.StoreID, &e.StoreName, &e.Number, &e.Amount, &e.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, nil
	}
	if err != nil {
		return out, err
	}
	e.Balance = e.Amount
	list, err := s.clientBalances(ctx, ph, &e.StoreID)
	if err != nil {
		return out, err
	}
	if len(list) > 0 {
		e.Balance, e.DueDate = list[0].Amount, list[0].DueDate
		if list[0].Name != "" {
			e.StoreName = list[0].Name
		}
	}
	out.Entry = &e
	return out, nil
}
