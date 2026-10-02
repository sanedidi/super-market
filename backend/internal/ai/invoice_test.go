package ai

import "testing"

func TestParseInvoice(t *testing.T) {
	inv, err := ParseInvoice("Вот данные:\n```json\n" + `{"supplier_name":" ООО  «Савдо» ","supplier_inn":"301 245 778","number":12,"date":"02.10.2026","currency":"usd","total":"12 500,50",
	 "lines":[{"name":"Чай","qty":"2","price":"","sum":"100,50"},{"name":"","qty":1,"price":1},{"name":"Сахар","qty":0,"price":5,"sum":25,"barcode":"123"}]}` + "\n```")
	if err != nil {
		t.Fatal(err)
	}
	if inv.SupplierName != "ООО «Савдо»" || inv.SupplierINN != "301245778" || inv.Number != "12" || inv.Date != "2026-10-02" ||
		inv.Currency != "USD" || inv.Total == nil || *inv.Total != 12500.5 {
		t.Fatalf("header = %+v", inv)
	}
	if len(inv.Lines) != 2 || inv.Lines[0].Price != 50.25 || inv.Lines[1].Qty != 5 || inv.Lines[1].Barcode != "" {
		t.Fatalf("lines = %+v", inv.Lines)
	}
	if _, err := ParseInvoice(`{"lines":[]}`); err == nil {
		t.Fatal("empty lines must fail")
	}
	if _, err := ParseInvoice(`нет данных`); err == nil {
		t.Fatal("no json must fail")
	}
}

func TestVisionGuess(t *testing.T) {
	for id, want := range map[string]bool{"gpt-4o-mini": true, "gpt-3.5-turbo": false, "text-embedding-3-small": false, "qwen2.5-vl-72b": true} {
		if g := visionGuess(ProviderOpenAI, id); g == nil || *g != want {
			t.Fatalf("%s = %v", id, g)
		}
	}
	if visionGuess(ProviderOpenAI, "deepseek-chat") != nil {
		t.Fatal("unknown must be nil")
	}
}
