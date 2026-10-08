// Package money — денежные суммы в сумах как десятичные строки ("15000.00").
// В JSON и в Go суммы хранятся строкой, чтобы не терять точность на float;
// считает PostgreSQL (numeric).
package money

import (
	"encoding/json"
	"regexp"
	"strings"

	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

var re = regexp.MustCompile(`^\d{1,12}(\.\d{1,2})?$`)

var ErrInvalid = i18n.NewError("ожидается неотрицательная сумма, например 15000 или 15000.50", "manfiy boʻlmagan summa kerak, masalan 15000 yoki 15000.50")

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

var qtyRe = regexp.MustCompile(`^\d{1,11}(\.\d{1,3})?$`)

// ErrInvalidQty — неверное количество.
var ErrInvalidQty = i18n.NewError("ожидается неотрицательное количество, до 3 знаков после точки", "manfiy boʻlmagan miqdor kerak, nuqtadan keyin 3 xonagacha")

// Qty — количество товара (шт, кг, л). В JSON — число или строка.
type Qty string

func (q *Qty) UnmarshalJSON(b []byte) error {
	s := strings.TrimSpace(string(b))
	if strings.HasPrefix(s, `"`) {
		if err := json.Unmarshal(b, &s); err != nil {
			return ErrInvalidQty
		}
	}
	if !qtyRe.MatchString(s) {
		return ErrInvalidQty
	}
	*q = Qty(s)
	return nil
}

func (q Qty) Valid() bool { return qtyRe.MatchString(string(q)) }

// Rate — курс (сумов за 1 USD), до 4 знаков.
type Rate string

var rateRe = regexp.MustCompile(`^\d{1,10}(\.\d{1,4})?$`)

func (r *Rate) UnmarshalJSON(b []byte) error {
	s := strings.TrimSpace(string(b))
	if strings.HasPrefix(s, `"`) {
		if err := json.Unmarshal(b, &s); err != nil {
			return i18n.NewError("неверный курс", "kurs notoʻgʻri")
		}
	}
	if !rateRe.MatchString(s) || strings.Trim(s, "0.") == "" {
		return i18n.NewError("курс должен быть положительным числом", "kurs musbat son boʻlishi kerak")
	}
	*r = Rate(s)
	return nil
}

// Price — цена или себестоимость за единицу: неотрицательная, до 4 знаков
// (себестоимость хранится с точностью 4 знака, цены в USD бывают дробными).
type Price string

var priceRe = regexp.MustCompile(`^\d{1,12}(\.\d{1,4})?$`)

func (p *Price) UnmarshalJSON(b []byte) error {
	s := strings.TrimSpace(string(b))
	if strings.HasPrefix(s, `"`) {
		if err := json.Unmarshal(b, &s); err != nil {
			return ErrInvalid
		}
	}
	if !priceRe.MatchString(s) {
		return i18n.NewError("ожидается неотрицательная цена, до 4 знаков после точки", "manfiy boʻlmagan narx kerak, nuqtadan keyin 4 xonagacha")
	}
	*p = Price(s)
	return nil
}

// Valid — цена задана и корректна.
func (p Price) Valid() bool { return priceRe.MatchString(string(p)) }
