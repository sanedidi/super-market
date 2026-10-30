package invoices

import "testing"

func TestNamePack(t *testing.T) {
	for name, want := range map[string]int{
		"Кола 1.5 ПЭТ 12":        12,
		"Фанта 0,5 x12":          12,
		"Pepsi 6×1,5 л":          6,
		"Сок Rich 1л (12 шт)":    12,
		"Вода 0.5л 24шт":         24,
		"Окорочка с/з 12 кг мар": 0,
		"Молоко 1 л":             0,
		"Хлеб белый":             0,
	} {
		if got := NamePack(name); got != want {
			t.Errorf("NamePack(%q) = %d, want %d", name, got, want)
		}
	}
}

func TestGuessPack(t *testing.T) {
	f := func(v float64) *float64 { return &v }
	cases := []struct {
		name string
		in   PackIn
		pack float64
		src  string
	}{
		// 1 коробка × 30 450 за кг, сумма 365 400 → 12 кг.
		{"weight by sum", PackIn{Qty: 1, Price: 30450, ReadSum: 365400, Fractional: true, Name: "Окорочка с/з 12 кг мар"}, 12, PackSum},
		{"weight by sum, product unknown", PackIn{Qty: 1, Price: 30450, ReadSum: 365400, Name: "Окорочка с/з 12 кг мар"}, 12, PackSum},
		{"sum matches", PackIn{Qty: 24, Price: 11200, ReadSum: 268800}, 1, PackNone},
		// Прошлая закупка 14 000 за шт, в накладной 84 000 → блок по 6, спросить.
		{"by last price", PackIn{Qty: 12, Price: 84000, ReadSum: 1008000, LastCost: 14000, Name: "Кола 1.5 ПЭТ 12"}, 6, PackGuess},
		{"by last price = net pack", PackIn{Qty: 12, Price: 84000, LastCost: 14000, NetPack: 6}, 6, PackProduct},
		{"same price as last", PackIn{Qty: 12, Price: 14500, LastCost: 14000, Name: "Кола 1.5 ПЭТ 12", NetPack: 6}, 1, PackNone},
		{"remembered", PackIn{Qty: 12, Price: 84000, Remembered: f(6), LastCost: 14000}, 6, PackRemembered},
		{"name only", PackIn{Qty: 2, Price: 60000, Name: "Фанта 0,5 x12"}, 12, PackGuess},
		{"unit block, size unknown", PackIn{Qty: 3, Price: 50000, Unit: "блок", Name: "Сок"}, 1, PackGuess},
		{"unit block, net pack", PackIn{Qty: 3, Price: 50000, Unit: "бл", NetPack: 12}, 12, PackProduct},
		{"weight, no sum", PackIn{Qty: 5.2, Price: 30000, Fractional: true, Name: "Сыр 12"}, 1, PackNone},
		{"plain", PackIn{Qty: 10, Price: 4000, ReadSum: 40000, Name: "Вода питьевая 1,5 л"}, 1, PackNone},
		// УТММ-878576: «Lay's 48*20гр», 3 шт × 4 200 — штуки, а не 3 коробки по 48.
		{"pieces unit beats name", PackIn{Qty: 3, Price: 4200, ReadSum: 12600, Unit: "шт", Name: "Lay's - Сметана зелень 48*20гр"}, 1, PackNone},
		{"no unit, name pack", PackIn{Qty: 3, Price: 4200, ReadSum: 12600, Name: "Lay's - Сметана зелень 48*20гр"}, 48, PackGuess},
	}
	for _, c := range cases {
		p, s := GuessPack(c.in)
		if p != c.pack || s != c.src {
			t.Errorf("%s: got %v %q, want %v %q", c.name, p, s, c.pack, c.src)
		}
	}
	if c := lineCost(12, 84000, 1008000, 6); c != 14000 {
		t.Errorf("cost = %v", c)
	}
	if c := lineCost(1, 30450, 365400, 12); c != 30450 {
		t.Errorf("cost kg = %v", c)
	}
	if c := lineCost(12, 84000, 0, 6); c != 14000 {
		t.Errorf("cost without sum = %v", c)
	}
}

func TestSizeOf(t *testing.T) {
	for name, want := range map[string]float64{
		"Lay's - Сметана зелень 48*20гр":      20,
		"Чипсы Lay's сметана и зелень, 225 г": 225,
		"Кола 1,5 л":     1500,
		"Fruzo, 120 g":   120,
		"Окорочка 12 кг": 12000,
	} {
		if got, ok := SizeOf(name); !ok || got.V != want {
			t.Errorf("SizeOf(%q) = %v %v, want %v", name, got, ok, want)
		}
	}
	if _, ok := SizeOf("Хлеб белый"); ok {
		t.Error("no size expected")
	}
	a, _ := SizeOf("Lay's 48*20гр")
	b, _ := SizeOf("Lay's 225 г")
	if sameSize(a, b) {
		t.Error("20 г ≠ 225 г")
	}
}
