// Package money — денежные суммы в сумах как десятичные строки ("15000.00").
// В JSON и в Go суммы хранятся строкой, чтобы не терять точность на float;
// считает PostgreSQL (numeric).
package money

import (
	"encoding/json"
	"errors"
	"regexp"
	"strings"
)

var re = regexp.MustCompile(`^\d{1,12}(\.\d{1,2})?$`)

var ErrInvalid = errors.New("ожидается неотрицательная сумма, например 15000 или 15000.50")

// Amount — сумма. В JSON принимается и числом (15000), и строкой ("15000.50").
type Amount string

func (a *Amount) UnmarshalJSON(b []byte) error {
	s := strings.TrimSpace(string(b))
	if strings.HasPrefix(s, `"`) {
		if err := json.Unmarshal(b, &s); err != nil {
			return ErrInvalid
		}
	}
	if !re.MatchString(s) {
		return ErrInvalid
	}
	*a = Amount(s)
	return nil
}

// Valid — сумма задана и корректна.
func (a Amount) Valid() bool { return re.MatchString(string(a)) }
