package assistant

import (
	"os"
	"strings"
	"testing"
)

// TestAssistantDocsCopy — api.md в пакете (встроен в бинарник для модели) —
// копия docs/api.md; разошлись — обновите копию: cp docs/api.md backend/internal/assistant/api.md.
func TestAssistantDocsCopy(t *testing.T) {
	orig, err := os.ReadFile("../../../docs/api.md")
	if err != nil {
		t.Skip("docs/api.md рядом нет")
	}
	if string(orig) != apiDocs {
		t.Fatal("backend/internal/assistant/api.md отстаёт от docs/api.md — скопируйте заново")
	}
}

func TestSearchDocs(t *testing.T) {
	out := searchDocs("остатки склад", 6000)
	if !strings.HasPrefix(out, "## ") || len(out) > 6200 {
		t.Fatalf("searchDocs = %q", out[:min(len(out), 200)])
	}
	if got := searchDocs("", 1000); !strings.Contains(got, "уточните") {
		t.Fatalf("empty query = %q", got)
	}
	if !isDangerous("DELETE", "/store/products/1", nil) || !isDangerous("POST", "/store/inventory/documents/1/post", nil) ||
		!isDangerous("POST", "/store/invoice-scans/1/document", map[string]any{"post": true}) ||
		isDangerous("POST", "/store/finance/counterparties", nil) || isDangerous("GET", "/store/finance/operations", nil) {
		t.Fatal("isDangerous")
	}
}

func TestSectionLink(t *testing.T) {
	l := sectionLink("uz", "Kassadan sotish uchun «Sotuvlar» boʻlimiga oʻting. Men bu yerdan sotuvni amalga oshira olmayman.")
	if l == nil || l["href"] != "/sales/pos" || l["label"] != "Sotuvlarni ochish" {
		t.Fatalf("uz = %v", l)
	}
	if l := sectionLink("ru", "Долги смотрите в разделе «Долги»."); l == nil || l["href"] != "/debts" {
		t.Fatalf("ru = %v", l)
	}
	if l := sectionLink("ru", "Остаток колы — 34 шт."); l != nil {
		t.Fatalf("no go-words, but link = %v", l)
	}
}

func TestParseLoose(t *testing.T) {
	text := `transcript: 1.5 litrlik koladan 20 ta blok keldi. Prikhod qilib qo'yish kerak.
reply: Напиток Coca-Cola Classic, 1,5 л товарining bir blokdagi donasi 6 qilib belgilandi.
Sotib olish narxi qancha?
Yetkazib beruvchi kim?
buttons:
- label: 12 000 — avvalgidek
  send: 12000
- label: SAYONAR — avvalgidek
  send: SAYONAR
links: []`
	out, ok := parseLoose(text)
	if !ok || out.Transcript != "1.5 litrlik koladan 20 ta blok keldi. Prikhod qilib qo'yish kerak." {
		t.Fatalf("loose = %+v", out)
	}
	if !strings.HasSuffix(out.Reply, "Yetkazib beruvchi kim?") || strings.Contains(out.Reply, "buttons") {
		t.Fatalf("reply = %q", out.Reply)
	}
	if len(out.Buttons) != 2 || out.Buttons[1].Label != "SAYONAR — avvalgidek" || out.Buttons[0].Send != "12000" || len(out.Links) != 0 {
		t.Fatalf("buttons = %+v links = %+v", out.Buttons, out.Links)
	}
	if _, ok := parseLoose("Просто текст без полей."); ok {
		t.Fatal("plain text parsed as loose")
	}
}
