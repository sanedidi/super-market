package pos

import "testing"

func TestOffName(t *testing.T) {
	for _, c := range []struct {
		in   OFFItem
		want string
	}{
		{OFFItem{ProductName: "Nutella", Brands: "Nutella, Ferrero", Quantity: "350 g"}, "Nutella 350 г"},
		{OFFItem{ProductName: "Snickers", Brands: "Mars Wrigley Confectionery UK Limited, Snickers", Quantity: "50g"}, "Snickers 50 г"},
		{OFFItem{ProductName: "Red Bull", Brands: "Red Bull GmbH", Quantity: "250 ml"}, "Red Bull 250 мл"},
		{OFFItem{ProductName: "coca cola 0.25 l", Brands: "Coca-Cola", Quantity: "0.25 l"}, "Coca cola 0.25 l"},
		{OFFItem{ProductName: "Original", Brands: "Coca-Cola", Quantity: "33 cl"}, "Coca-Cola Original 330 мл"},
		{OFFItem{ProductName: "  ", Brands: "X"}, ""},
		{OFFItem{ProductName: "Original", Brands: "Mars Wrigley Confectionery UK Limited"}, "Original"},
		{OFFItem{ProductName: "Coca-Cola Original", Brands: "COCA-COLA SERVICES SA/NV"}, "Coca-Cola Original"},
		{OFFItem{ProductName: "Chips paprika", Brands: "Lay's", Quantity: "about 150g pack"}, "Lay's Chips paprika"},
	} {
		if got := OffName(c.in); got != c.want {
			t.Errorf("OffName(%+v) = %q, want %q", c.in, got, c.want)
		}
	}
}
