package ai

import (
	"strings"
	"testing"
)

// Лицевая сторона просится всегда: и со стандартной, и со своей инструкцией.
func TestPhotoPromptFrontSide(t *testing.T) {
	for _, o := range []photoOpts{{}, {Prompt: "my rules"}, {Outpaint: true}, {WebSearch: true}} {
		p := photoPrompt(o, "Plus 18 Energy Drink 450 ml, barcode 4780101734276")
		if !strings.Contains(p, frontSideRule) {
			t.Fatalf("нет правила лицевой стороны: %+v", o)
		}
		if !o.Outpaint && !strings.Contains(p, "except the front side") {
			t.Fatalf("запрет дорисовки мешает лицевой стороне: %+v", o)
		}
	}
	if p := photoPrompt(photoOpts{WebSearch: true}, "x"); !strings.Contains(p, "rebuild the front side") {
		t.Fatal("поиск не просит восстановить лицевую сторону")
	}
}
