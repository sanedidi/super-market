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
