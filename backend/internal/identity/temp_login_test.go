package identity

import "testing"

func TestLoginBase(t *testing.T) {
	for in, want := range map[string]string{
		"Baraka Market":          "baraka.market",
		"Дилноза Юсупова":        "dilnoza.yusupova",
		"«Ўзбегим» Шоҳ маркет 2": "ozbegim.shoh",
		"Oʻzbekiston-24":         "ozbekiston.24",
		"Магазин":                "magazin",
		"  ":                     "",
		"Ёқут":                   "yoqut",
	} {
		if got := LoginBase(in); got != want {
			t.Errorf("LoginBase(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestGenerateTempPassword(t *testing.T) {
	p, err := GenerateTempPassword()
	if err != nil || len(p) != 8 || validTempPassword(p) != nil {
		t.Fatalf("password = %q, %v", p, err)
	}
	for _, r := range p {
		if r < '0' || r > '9' {
			t.Fatalf("not digits: %q", p)
		}
	}
}
