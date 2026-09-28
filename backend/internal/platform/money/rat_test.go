package money

import "testing"

func TestDec(t *testing.T) {
	if got := D("15000").Mul(D("2.5")).Sub(D("500")).Money(); got != "37000.00" {
		t.Errorf("15000*2.5-500 = %s", got)
	}
	if got := D("100").Div(D("3")).Money(); got != "33.33" {
		t.Errorf("100/3 = %s", got)
	}
	if got := D("0.005").Money(); got != "0.01" {
		t.Errorf("round half away from zero: %s", got)
	}
	if !D("1").Div(D("0")).IsZero() {
		t.Error("division by zero must be zero")
	}
	if D("2").Min(D("1.5")).Fixed(3) != "1.500" {
		t.Error("min")
	}
}
