package ai

import (
	"context"
	"encoding/json"
	"strings"
)

// Группы вариаций: товары одного бренда и раздела, которые отличаются только
// весом или вкусом («Чипсы Lay's» 90 г / 150 г × Сметана и лук / Сыр /
// Пицца Пепперони). Модель делит список на группы по линейке и для каждого
// товара называет вес и вкус. Расход пишется в ai_usage с kind = "variants".

const variantsSystem = `You help a grocery and retail platform in Uzbekistan (Super Market) merge product variations.
A variation group is one product line of one brand whose items differ ONLY by package weight/volume and/or flavor
(for example "Чипсы Lay's" in 90 g and 150 g, flavors "Сметана и лук", "Сыр", "Пицца Пепперони").
Different product lines of the same brand are different groups: Lay's and Lay's MAXX, Lay's and Lay's Stax,
ridged ("рифлёные") and smooth chips, regular and zero-sugar drinks, a different product type.
Uzbek is always in the Latin alphabet with typographic apostrophes: oʻ, gʻ (U+02BB) and ʼ (U+02BC).
Answer with JSON only.`

// VariantProduct — товар для модели.
type VariantProduct struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// VariantAsk — товары одного бренда и подкатегории.
type VariantAsk struct {
	Brand    string
	Category string
	Products []VariantProduct
}

// VariantAnswer — группы, которые предлагает модель.
type VariantAnswer struct {
	Groups []VariantGroup `json:"groups"`
}

type VariantGroup struct {
	Name       string        `json:"name"`
	NameUz     string        `json:"name_uz"`
	Confidence string        `json:"confidence"` // high | check
	Note       string        `json:"note"`
	Items      []VariantItem `json:"items"`
}

type VariantItem struct {
	ID       string `json:"id"`
	Weight   string `json:"weight"`
	WeightUz string `json:"weight_uz"`
	Flavor   string `json:"flavor"`
	FlavorUz string `json:"flavor_uz"`
}

func variantsPrompt(in VariantAsk) string {
	var b strings.Builder
	b.WriteString("Brand: " + in.Brand + "\nSubcategory: " + in.Category + "\nProducts (JSON):\n")
	raw, _ := json.Marshal(in.Products)
	b.Write(raw)
	b.WriteString(variantsRules)
	return b.String()
}

const variantsRules = `

Split the products into variation groups. Return JSON:
{"groups": [
  {"name": "group name in Russian: product type + brand + line, without weight and flavor, e.g. \"Чипсы Lay's\" or \"Чипсы Lay's MAXX\"",
   "name_uz": "the same in Uzbek",
   "confidence": "high when you are sure, \"check\" when flavors or lines are ambiguous",
   "note": "short note in Russian for the reviewer when confidence is \"check\", otherwise empty",
   "items": [{"id": "product id", "weight": "weight or volume as on the pack, Russian units: \"150 г\", \"1 кг\", \"0,5 л\", \"10 шт\"; empty if unknown",
              "weight_uz": "the same with Uzbek units: \"150 g\", \"1 kg\", \"0,5 l\", \"10 dona\"",
              "flavor": "flavor/taste/variant in Russian, capitalized, short, e.g. \"Сметана и лук\"",
              "flavor_uz": "the same in Uzbek"}]}
]}
Rules: only groups with at least 2 products; every product in at most one group; leave out products that have no siblings.
Inside a group no two items may have the same weight and flavor. Use the same spelling of a flavor for all weights.`

// GroupVariants — спросить модель. Токены возвращаются и при ошибке разбора.
func (c Conn) GroupVariants(ctx context.Context, in VariantAsk) (VariantAnswer, Usage, error) {
	text, u, err := c.Vision(ctx, variantsSystem, variantsPrompt(in), nil)
	if err != nil {
		return VariantAnswer{}, u, err
	}
	raw, err := ExtractJSON(text)
	var out VariantAnswer
	if err == nil {
		err = json.Unmarshal(raw, &out)
	}
	if err != nil {
		return VariantAnswer{}, u, &ErrService{Msg: "не удалось подобрать группы вариаций", MsgUz: "variantlar guruhini tanlab boʻlmadi"}
	}
	return out, u, nil
}
