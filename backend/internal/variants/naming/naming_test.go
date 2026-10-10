package naming

import "testing"

func TestWeight(t *testing.T) {
	cases := []struct{ in, rest, w, uz string }{
		{"Чипсы Lay's Пицца Пепперони, 150 г", "Чипсы Lay's Пицца Пепперони", "150 г", "150 g"},
		{"Coca-Cola 1,5 л", "Coca-Cola", "1,5 л", "1,5 l"},
		{"Сок Rich 0.2L", "Сок Rich", "0,2 л", "0,2 l"},
		{"Хлеб «Бородинский»", "Хлеб «Бородинский»", "", ""},
		{"Яйца С1, 10 шт", "Яйца С1", "10 шт", "10 dona"},
	}
	for _, c := range cases {
		rest, w, uz, _ := Weight(c.in)
		if rest != c.rest || w != c.w || uz != c.uz {
			t.Errorf("Weight(%q) = %q %q %q", c.in, rest, w, uz)
		}
	}
	if WeightSort("1 кг") <= WeightSort("150 г") || WeightSort("0,5 л") != 500 {
		t.Errorf("WeightSort: 1 кг=%v 150 г=%v 0,5 л=%v", WeightSort("1 кг"), WeightSort("150 г"), WeightSort("0,5 л"))
	}
}

func TestSuggest(t *testing.T) {
	items := []Item{
		{"1", "Чипсы Lay's Пицца Пепперони, 150 г", "Lay's"},
		{"2", "Чипсы Lay's сметана и лук, 150 г", "Lay's"},
		{"3", "Чипсы Lay’s сметана и лук, 90 г", "Lay's"},
		{"4", "Чипсы Lay's сметана и лук, 150 г", "Lay's"},
		{"5", "Картофельные чипсы Lay's со вкусом сыра, 50 г", "Lay's"},
	}
	gs := Suggest(items)
	if len(gs) != 1 {
		t.Fatalf("groups = %+v", gs)
	}
	g := gs[0]
	if g.Name != "Чипсы Lay's" || len(g.Items) != 4 {
		t.Fatalf("group = %+v", g)
	}
	// 90 г первым, дубль «сметана и лук, 150 г» не входит.
	if g.Items[0].ID != "3" || g.Items[0].Flavor != "Сметана и лук" || g.Items[0].Weight != "90 г" {
		t.Errorf("first = %+v", g.Items[0])
	}
	excluded := 0
	for _, it := range g.Items {
		if !it.Included {
			excluded++
		}
	}
	if excluded != 1 {
		t.Errorf("excluded = %d, items = %+v", excluded, g.Items)
	}
	if f := Flavor("Чипсы Lay's Краб, 150 г", "Чипсы Lay's"); f != "Краб" {
		t.Errorf("Flavor = %q", f)
	}
}
