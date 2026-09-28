// Package phone приводит номера телефонов к формату E.164 (+998901234567).
package phone

import (
	"errors"
	"strings"
)

var ErrInvalid = errors.New("неверный номер телефона")

// Normalize принимает номер в любом привычном виде:
// "+998 90 123-45-67", "998901234567", "901234567" (без кода — считаем Узбекистаном).
func Normalize(raw string) (string, error) {
	var b strings.Builder
	for i, r := range strings.TrimSpace(raw) {
		switch {
		case r >= '0' && r <= '9':
			b.WriteRune(r)
		case r == '+' && i == 0:
		case r == ' ' || r == '-' || r == '(' || r == ')':
		default:
			return "", ErrInvalid
		}
	}
	digits := b.String()

	if len(digits) == 9 {
		digits = "998" + digits
	}
	if len(digits) < 10 || len(digits) > 15 || digits[0] == '0' {
		return "", ErrInvalid
	}
	if strings.HasPrefix(digits, "998") && len(digits) != 12 {
		return "", ErrInvalid
	}
	return "+" + digits, nil
}
