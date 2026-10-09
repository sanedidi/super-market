package productsearch

import (
	"reflect"
	"testing"
)

func TestFold(t *testing.T) {
	for in, want := range map[string]string{
		"Молоко «Lactel» 3,2%":  "молоко lactel 3 2",
		"  ЁЖИК  ":              "ежик",
		"Oʻzbek gʻalla":         "ozbek galla",
		"O'ZBEK  o‘zbek o`zbek": "ozbek ozbek ozbek",
		"ҚАТИҚ ўрик ғишт ҳалол": "катик урик гишт халол",
		"Coca-Cola_Zero":        "coca cola zero",
		"%_\\":                  "",
	} {
		if got := Fold(in); got != want {
			t.Errorf("Fold(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSwapLayout(t *testing.T) {
	for in, want := range map[string]string{
		"vjkjrj":  "молоко",
		"Vjkjrj":  "молоко",
		"rtabh 1": "кефир 1",
		"сщсф":    "coca",
		"[kt,":    "хлеб",
	} {
		if got, ok := SwapLayout(in); !ok || got != want {
			t.Errorf("SwapLayout(%q) = %q, %v; want %q", in, got, ok, want)
		}
	}
	for _, in := range []string{"молоко milk", "123", ""} {
		if got, ok := SwapLayout(in); ok {
			t.Errorf("SwapLayout(%q) = %q, want no swap", in, got)
		}
	}
}

func TestLooksLikeBarcode(t *testing.T) {
	for in, want := range map[string]bool{
		"4780069000239": true, "5449000000996": true, "ABC-12": true, "1234": true,
		"123": false, "молоко": false, "coca": false, "12 34": false, "1234567890123456789012345678901234": false,
	} {
		if got := LooksLikeBarcode(in); got != want {
			t.Errorf("LooksLikeBarcode(%q) = %v", in, got)
		}
	}
}

func TestWhere(t *testing.T) {
	args := []any{"x"}
	got := Text("Кока-кола 1 л").Where("s", &args)
	want := "(s.text LIKE $2 AND s.text LIKE $3 AND strpos(s.text, $4) > 0 AND strpos(s.text, $5) > 0)"
	if got != want || !reflect.DeepEqual(args, []any{"x", "%кока%", "%кола%", "1", "л"}) {
		t.Fatalf("Where = %s %v", got, args)
	}
	// Только короткие слова — по началу названия.
	args = nil
	got = Text("мо").Where("s", &args)
	if got != "((s.name LIKE $1 OR s.name_uz LIKE $1))" || args[0] != "мо%" {
		t.Fatalf("short = %s %v", got, args)
	}
	// Несколько коротких — фраза целиком подстрокой.
	args = nil
	got = Text("0,5").Where("s", &args)
	if got != "(s.text LIKE $1)" || args[0] != "%0 5%" {
		t.Fatalf("short phrase = %s %v", got, args)
	}
	if got := Text(" ,. ").Where("s", &args); got != "false" {
		t.Fatalf("empty = %s", got)
	}
}
