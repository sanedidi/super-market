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

var qtyRe = regexp.MustCompile(`^\d{1,11}(\.\d{1,3})?$`)

// ErrInvalidQty — неверное количество.
var ErrInvalidQty = errors.New("ожидается неотрицательное количество, до 3 знаков после точки")

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
			return errors.New("неверный курс")
		}
	}
	if !rateRe.MatchString(s) || strings.Trim(s, "0.") == "" {
		return errors.New("курс должен быть положительным числом")
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
		return errors.New("ожидается неотрицательная цена, до 4 знаков после точки")
	}
	*p = Price(s)
	return nil
}

// Valid — цена задана и корректна.
func (p Price) Valid() bool { return priceRe.MatchString(string(p)) }
