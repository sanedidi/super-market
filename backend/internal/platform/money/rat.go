package money

import (
	"fmt"
	"math/big"
)

// Dec — точная десятичная арифметика на big.Rat для расчётов в Go
// (строки чека, возвраты). Хранение и итоговые суммы — numeric в PostgreSQL.
type Dec struct{ r big.Rat }

// D разбирает десятичную строку. Пустая строка — ноль.
func D(s string) Dec {
	var d Dec
	if s == "" {
		return d
	}
	if _, ok := d.r.SetString(s); !ok {
		panic(fmt.Sprintf("money.D: неверное число %q", s))
	}
	return d
}

func (a Dec) Add(b Dec) Dec { var c Dec; c.r.Add(&a.r, &b.r); return c }
func (a Dec) Sub(b Dec) Dec { var c Dec; c.r.Sub(&a.r, &b.r); return c }
func (a Dec) Mul(b Dec) Dec { var c Dec; c.r.Mul(&a.r, &b.r); return c }

// Div — деление; деление на ноль даёт ноль.
func (a Dec) Div(b Dec) Dec {
	var c Dec
	if b.r.Sign() == 0 {
		return c
	}
	c.r.Quo(&a.r, &b.r)
	return c
}

func (a Dec) Cmp(b Dec) int { return a.r.Cmp(&b.r) }
func (a Dec) Sign() int     { return a.r.Sign() }
func (a Dec) IsZero() bool  { return a.r.Sign() == 0 }
func (a Dec) Min(b Dec) Dec {
	if a.Cmp(b) <= 0 {
		return a
	}
	return b
}

// Fixed — строка с n знаками после точки (округление половин от нуля).
func (a Dec) Fixed(n int) string { return a.r.FloatString(n) }

// Money — сумма, округлённая до тийинов.
func (a Dec) Money() string { return a.Fixed(2) }

// Round2 — значение, округлённое до 2 знаков.
func (a Dec) Round2() Dec { return D(a.Money()) }
