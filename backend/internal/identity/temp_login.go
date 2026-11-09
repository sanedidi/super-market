package identity

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"unicode"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

// Логин и временный пароль, которые придумывает сервер: продажник выдаёт
// их владельцу нового магазина, «SM Магазин» — сотруднику.

// GenerateTempPassword — 8 случайных цифр: их легко продиктовать и набрать
// на телефоне. Пароль временный — при первом входе его меняют на свой.
func GenerateTempPassword() (string, error) {
	var b strings.Builder
	for range 8 {
		n, err := rand.Int(rand.Reader, big.NewInt(10))
		if err != nil {
			return "", err
		}
		b.WriteByte(byte('0' + n.Int64()))
	}
	return b.String(), nil
}

// translit — кириллица (русская и узбекская) латиницей, как пишут логины.
var translit = map[rune]string{
	'а': "a", 'б': "b", 'в': "v", 'г': "g", 'д': "d", 'е': "e", 'ё': "yo", 'ж': "j", 'з': "z",
	'и': "i", 'й': "y", 'к': "k", 'л': "l", 'м': "m", 'н': "n", 'о': "o", 'п': "p", 'р': "r",
	'с': "s", 'т': "t", 'у': "u", 'ф': "f", 'х': "x", 'ц': "ts", 'ч': "ch", 'ш': "sh", 'щ': "sh",
	'ъ': "", 'ы': "i", 'ь': "", 'э': "e", 'ю': "yu", 'я': "ya",
	'ў': "o", 'қ': "q", 'ғ': "g", 'ҳ': "h",
}

// LoginBase — основа логина из названия магазина или имени: «Baraka Market» →
// baraka.market, «Дилноза Юсупова» → dilnoza.yusupova. Берутся первые два
// слова; пусто — "".
func LoginBase(name string) string {
	var words []string
	var cur strings.Builder
	flush := func() {
		if cur.Len() > 0 {
			words = append(words, cur.String())
			cur.Reset()
		}
	}
	for _, r := range strings.ToLower(name) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			cur.WriteRune(r)
		case translit[r] != "" || r == 'ъ' || r == 'ь':
			cur.WriteString(translit[r])
		case r == '\'' || r == 'ʻ' || r == 'ʼ' || r == '`' || r == '‘' || r == '’':
			// o‘zbek → ozbek: апостроф внутри слова не разрывает его.
		case unicode.IsLetter(r) || unicode.IsDigit(r):
			// Прочие буквы (латиница с диакритикой и т.п.) пропускаем.
		default:
			flush()
		}
	}
	flush()
	if len(words) > 2 {
		words = words[:2]
	}
	base := strings.Join(words, ".")
	if len(base) > 28 {
		base = strings.TrimRight(base[:28], ".")
	}
	return base
}

// SuggestLogin — свободный логин по названию или имени: baraka.market, если
// занят — baraka.market2, baraka.market3 …
func SuggestLogin(ctx context.Context, q db.Querier, name string) (string, error) {
	base := LoginBase(name)
	if len(base) < 3 {
		base = "shop" + base
	}
	for i := 1; i < 100; i++ {
		login := base
		if i > 1 {
			login = fmt.Sprintf("%s%d", base, i)
		}
		if !loginRe.MatchString(login) {
			continue
		}
		var taken bool
		err := q.QueryRow(ctx, `SELECT true FROM employee_logins WHERE login = $1`, login).Scan(&taken)
		if errors.Is(err, pgx.ErrNoRows) {
			return login, nil
		}
		if err != nil {
			return "", err
		}
	}
	return "", apperr.Conflict("login_taken", "не удалось придумать свободный логин — введите свой").Uz("boʻsh login topilmadi — oʻzingiz kiriting")
}

// OwnerLogin — логин владельца сети и временный пароль, пока владелец ни
// разу не вошёл. LastLoginAt == nil — ещё не входил.
type OwnerLogin struct {
	Name         string  `json:"name"`
	Phone        string  `json:"phone"`
	Login        string  `json:"login"`
	TempPassword string  `json:"temp_password,omitempty"`
	MustChange   bool    `json:"must_change_password"`
	LastLoginAt  *string `json:"last_login_at"`
}

// GetOwnerLogin — вход владельца сети (для «SM Продажник»).
func GetOwnerLogin(ctx context.Context, q db.Querier, networkID string) (*OwnerLogin, error) {
	var o OwnerLogin
	err := q.QueryRow(ctx, `
		SELECT e.full_name, u.phone, el.login, COALESCE(CASE WHEN el.must_change_password THEN el.temp_password END, ''),
		       el.must_change_password, to_char(el.last_login_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
		FROM employees e
		JOIN roles r ON r.id = e.role_id AND r.is_owner
		JOIN employee_logins el ON el.employee_id = e.id
		JOIN users u ON u.id = e.user_id
		WHERE e.network_id = $1`, networkID).Scan(&o.Name, &o.Phone, &o.Login, &o.TempPassword, &o.MustChange, &o.LastLoginAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &o, nil
}
