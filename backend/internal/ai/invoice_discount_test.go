package ai

import (
	"math"
	"testing"
)

// Накладная SAYONAR (30.10.2026): «Сумма» строк — до скидки, итог «к оплате» — после.
func TestParseInvoiceDiscount(t *testing.T) {
	inv, err := ParseInvoice(`{"supplier_name":"SAYONAR","total":391784.36,"lines":[
	 {"name":"BS PO Nat Chamomile 6*150g","unit":"шт","qty":1,"price":63601,"discount":6,"net_price":59784.94,"sum":63601},
	 {"name":"BS PO Nat Olive 6*150g","unit":"шт","qty":1,"price":59784.94,"discount":6,"net_price":59784.94,"sum":63601},
	 {"name":"TP Triple Action 50ml","unit":"шт","qty":12,"price":7505,"discount":5,"net_price":7129.75,"sum":90060},
	 {"name":"TP Triple Action 125ml","unit":"шт","qty":6,"price":13607,"discount":6,"sum":81642},
	 {"name":"TP Triple Action 150ml","unit":"шт","qty":6,"price":18319,"sum":109914}]}`)
	if err != nil {
		t.Fatal(err)
	}
	var total float64
	for _, l := range inv.Lines {
		total += l.Sum
	}
	if math.Abs(total-391784.36) > 0.05 {
		t.Fatalf("сумма строк %.2f, нужно 391 784,36: %+v", total, inv.Lines)
	}
	for i, want := range []float64{59784.94, 59784.94, 7129.75, 12790.58, 18319} {
		if math.Abs(inv.Lines[i].Price-want) > 0.01 {
			t.Fatalf("строка %d: цена %.4f, нужно %.2f", i+1, inv.Lines[i].Price, want)
		}
	}

	// Суммы строк уже со скидкой — второй раз не вычитаем.
	inv, err = ParseInvoice(`{"total":94000,"lines":[{"name":"Кола","qty":10,"price":10000,"discount":6,"sum":94000}]}`)
	if err != nil || inv.Lines[0].Sum != 94000 || inv.Lines[0].Price != 9400 {
		t.Fatalf("net sum: %+v %v", inv.Lines, err)
	}

	// Скидка на всю накладную.
	inv, err = ParseInvoice(`{"total":95000,"discount":5,"lines":[{"name":"Чай","qty":10,"price":10000,"sum":100000}]}`)
	if err != nil || inv.Lines[0].Sum != 95000 || inv.Lines[0].Price != 9500 {
		t.Fatalf("invoice discount: %+v %v", inv.Lines, err)
	}

	// Упаковка (1 кор × цена за кг): сумма до скидки — решает итог.
	inv, err = ParseInvoice(`{"total":343476,"lines":[{"name":"Окорочка 12 кг","qty":1,"price":30450,"discount":6,"sum":365400}]}`)
	if err != nil || inv.Lines[0].Sum != 343476 {
		t.Fatalf("pack: %+v %v", inv.Lines, err)
	}
}
