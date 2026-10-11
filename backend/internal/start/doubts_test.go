package start

import "testing"

func TestMinorDoubts(t *testing.T) {
	cases := []struct {
		in   []string
		want bool
	}{
		{nil, false},
		{[]string{"size"}, true},
		{[]string{"size", "pack"}, true},
		{[]string{" Size "}, true},
		{[]string{"size", "brand"}, false},
		{[]string{"category"}, false},
		{[]string{"other"}, false},
	}
	for _, c := range cases {
		if got := minorDoubts(c.in); got != c.want {
			t.Errorf("minorDoubts(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestSizeOnlyNote(t *testing.T) {
	yes := []string{
		"Вес или объём на упаковке не виден. Рукописные надписи «400» и «40» на коробке, вероятно, это цена, а не вес; проверьте их перед внесением.",
		"Объём не указан на упаковке",
		"Вес товара не виден на фото",
		"Нет чистого веса или объёма упаковки, поэтому поле size пустое. На фото не указано явно, что прокладки ночные, поэтому в названии этого нет. Проверьте по штрихкоду 5900516306809.",
	}
	no := []string{
		"",
		"Super Market не уверен в карточке — проверьте название и категорию",
		"Вес не виден, бренд читается плохо",
		"Фото размыто, вес не читается",
		"Не уверен во вкусе; объём не виден",
		"Категория подобрана примерно",
		"Проверьте по штрихкоду 123. Название на упаковке читается плохо",
		"Вес не виден. Возможно, это другой товар",
		"На фото не видно, какой вкус",
	}
	for _, n := range yes {
		if !sizeOnlyNote(n) {
			t.Errorf("ждали true: %q", n)
		}
	}
	for _, n := range no {
		if sizeOnlyNote(n) {
			t.Errorf("ждали false: %q", n)
		}
	}
}
