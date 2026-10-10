package ai

import (
	"context"
	"encoding/json"
	"strings"
)

// Группы вариаций: товары одного бренда и раздела, которые отличаются только
// двумя признаками — размером упаковки (вес, объём, количество, размер) и
// вариантом (вкус, цвет, аромат…): «Чипсы Lay's» 90 г / 150 г × Сыр / Краб,
// ваза × Белый / Чёрный. Модель делит список на группы по линейке, называет
// оба переключателя группы и значения у каждого товара. Расход пишется в
// ai_usage с kind = "variants".

const variantsSystem = `You help a grocery and retail platform in Uzbekistan (Super Market) merge product variations.
A variation group is one product line of one brand whose items differ ONLY by two attributes:
1) package size — weight, volume, count or clothing/shoe size, and/or
2) variant — flavor for food, color for dishes/clothes/goods, scent for cosmetics, model, etc.
(for example "Чипсы Lay's" in 90 g and 150 g with flavors "Сметана и лук", "Сыр"; a vase in colors "Белый", "Чёрный").
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
	Name   string `json:"name"`
	NameUz string `json:"name_uz"`
	// Названия переключателей: «Вес»/«Объём»/«Размер», «Вкус»/«Цвет»/«Аромат».
	WeightLabel   string        `json:"weight_label"`
	WeightLabelUz string        `json:"weight_label_uz"`
	FlavorLabel   string        `json:"flavor_label"`
	FlavorLabelUz string        `json:"flavor_label_uz"`
	Confidence    string        `json:"confidence"` // high | check
	Note          string        `json:"note"`
	Items         []VariantItem `json:"items"`
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
  {"name": "group name in Russian: product type + brand + line, without size and variant, e.g. \"Чипсы Lay's\" or \"Чипсы Lay's MAXX\"",
   "name_uz": "the same in Uzbek",
   "weight_label": "name of the size switch in Russian, one word: \"Вес\" (г, кг), \"Объём\" (мл, л), \"Количество\" (шт), \"Размер\" (clothes, shoes, diapers)",
   "weight_label_uz": "the same in Uzbek: \"Vazn\", \"Hajm\", \"Soni\", \"Oʻlcham\"",
   "flavor_label": "name of the variant switch in Russian, one word that fits these products: \"Вкус\" (food, drinks), \"Цвет\", \"Аромат\", \"Модель\", \"Вид\"",
   "flavor_label_uz": "the same in Uzbek: \"Taʼm\", \"Rang\", \"Hid\", \"Model\", \"Tur\"",
   "confidence": "high when you are sure, \"check\" when flavors or lines are ambiguous",
   "note": "short note in Russian for the reviewer when confidence is \"check\", otherwise empty",
   "items": [{"id": "product id", "weight": "size as on the pack, Russian units: \"150 г\", \"1 кг\", \"0,5 л\", \"10 шт\", \"XL\"; empty if the group has no size switch",
              "weight_uz": "the same with Uzbek units: \"150 g\", \"1 kg\", \"0,5 l\", \"10 dona\"",
              "flavor": "value of the variant switch in Russian, capitalized, short, e.g. \"Сметана и лук\" or \"Белый\"; empty if the group has no variant switch",
              "flavor_uz": "the same in Uzbek"}]}
]}
Rules: only groups with at least 2 products; every product in at most one group; leave out products that have no siblings.
Inside a group no two items may have the same size and variant. Use the same spelling of a variant for all sizes.
Do not merge products that differ by anything else than these two attributes (another model number, product type or line).`

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
