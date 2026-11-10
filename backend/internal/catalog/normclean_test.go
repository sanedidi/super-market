package catalog

import "testing"

func TestCleanName(t *testing.T) {
	cases := []struct {
		name, brand string
		food        bool
		want        string
	}{
		{"Не замороженные овощи Lay's, С солью 150г", "Lay's", true, "Lay's, С солью, 150 г"},
		{"Не замороженные овощи Lay's, stix кетчуп 65г", "Lay's", true, "Lay's, stix кетчуп, 65 г"},
		{"Безалкогольные напитки Coca-Cola, 0.15 л", "Coca-Cola", true, "Coca-Cola, 0,15 л"},
		{"Безалкогольные напитки Dream Cola, апельсиновый алюминиевая банка 0,25 л", "Dream Cola", true, "Dream Cola, апельсиновый, 0,25 л"},
		{"Полуфабрикаты мучных изделий Salmur, булочка с джемом, Полиэтиленовый пакет 4 шт. по 100 г", "Salmur", true,
			"Salmur, булочка с джемом, 4 шт. по 100 г"},
		{"Мороженое упакованное Milka, ваниль в шоколаде 62 гр", "Milka", true, "Milka, ваниль в шоколаде, 62 г"},
		{"Сок Rich, 1.0л", "Rich", true, "Rich, 1 л"},
		// Непищевое: тип остаётся.
		{"Телевизор Samsung, UE55AU7100 55\"", "Samsung", false, "Телевизор Samsung, UE55AU7100 55\""},
		{"Шампунь Head&Shoulders, против перхоти 400мл", "Head&Shoulders", false, "Шампунь Head&Shoulders, против перхоти, 400 мл"},
		// Бренд — часть слова или в начале: ничего не снимаем.
		{"Lay's, С солью 150 г", "Lay's", true, "Lay's, С солью, 150 г"},
		{"Чипсы Layser, 90 г", "Lay", true, "Чипсы Layser, 90 г"},
		{"Хлеб пшеничный", "", true, "Хлеб пшеничный"},
	}
	for _, c := range cases {
		if got := CleanName(c.name, c.brand, c.food); got != c.want {
			t.Errorf("CleanName(%q) = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestFoodIkpu(t *testing.T) {
	for code, want := range map[string]bool{"02202002001010021": true, "02004001001000000": true, "08528001001000000": false, "02403002001000000": false} {
		if got, known := FoodIkpu(code); !known || got != want {
			t.Errorf("FoodIkpu(%s) = %v %v", code, got, known)
		}
	}
	if _, known := FoodIkpu("123"); known {
		t.Error("short code")
	}
}

func TestSplitTypePrefix(t *testing.T) {
	p, rest := SplitTypePrefix("Биологически активные добавки к пище Project V, A-Antiox", "Project V")
	if p != "Биологически активные добавки к пище" || rest != "Project V, A-Antiox" {
		t.Errorf("got %q | %q", p, rest)
	}
	if p, _ := SplitTypePrefix("Coca-Cola, 0,5 л", "Coca-Cola"); p != "" {
		t.Errorf("no prefix expected, got %q", p)
	}
}
