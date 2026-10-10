package start

import "testing"

func TestBarcodeValid(t *testing.T) {
	for code, want := range map[string]bool{
		"8714100707890": true, "4870001573331": true, "4870001573744": true,
		"8712561015882": true, "4870001571795": true,
		"4870001571796": false, "036000291452": true, "036000291453": false,
		"96385074": true, "ABC-123": true, "12345": true,
	} {
		if got := BarcodeValid(code); got != want {
			t.Errorf("BarcodeValid(%q) = %v, want %v", code, got, want)
		}
	}
}

func TestBarcodeKey(t *testing.T) {
	if BarcodeKey("036000291452") != BarcodeKey("0036000291452") || BarcodeKey("0036000291452") != BarcodeKey("00036000291452") {
		t.Error("UPC-A, EAN-13 и GTIN-14 одного кода должны совпадать")
	}
	if BarcodeKey("4870001573331") == BarcodeKey("4870001573744") {
		t.Error("разные коды совпали")
	}
}

func TestSpecConflicts(t *testing.T) {
	cases := []struct {
		a, b     string
		conflict bool
	}{
		{"Чай Piala Gold черный кенийский классический, 10 пакетиков", "Чай Piala Gold черный кенийский классический, 25 пакетиков", true},
		{"Сок Bliss яблочный, 1 л", "Сок Bliss яблочный, 1000 мл", false},
		{"Sprite, 1 л", "Sprite, 1,5 л", true},
		{"Чай Piala Gold зелёный №110 высший сорт, 100 г", "Чай Piala Gold зелёный №95 высший сорт, 100 г", true},
		{"Средство чистящее Domestos Ультра белый, 500 мл", "Domestos Ультра белый", false},
		{"Печенье Юбилейное, 112 г", "Печенье Юбилейное, 112г", false},
		{"Вода, 6 x 1,5 л", "Вода, 1,5 л", false},
		{"Вода, 6 x 1,5 л", "Вода, 4 x 1,5 л", true},
		{"Гель Domestos 2 гель", "Гель Domestos", false},
	}
	for _, c := range cases {
		if got := ParseSpec(c.a).Conflicts(ParseSpec(c.b)); got != c.conflict {
			t.Errorf("%q vs %q: conflict = %v, want %v (%+v / %+v)", c.a, c.b, got, c.conflict, ParseSpec(c.a), ParseSpec(c.b))
		}
	}
}

func TestInternalBarcode(t *testing.T) {
	if !InternalBarcode("2000000012345") || InternalBarcode("4870001573331") {
		t.Error("InternalBarcode")
	}
}
