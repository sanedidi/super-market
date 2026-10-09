package ai

import (
	"context"
	"encoding/json"
	"strings"
)

// Подбор категории Super Market для товара из каталога ИКПУ, если по коду
// ИКПУ её определить не удалось: модель выбирает подходящую из списка или
// предлагает новую подкатегорию (с названием на ru и uz). Заодно переводит
// название товара на узбекский. Расход пишется в ai_usage с kind = "category".

const categorySystem = `You help a grocery and retail platform in Uzbekistan (Super Market) put a product into its catalog tree.
The tree has two levels: sections and subcategories. A product always goes into a subcategory.
Uzbek is always in the Latin alphabet with typographic apostrophes: oʻ, gʻ (U+02BB) and ʼ (U+02BC).
Answer with JSON only.`

// CategoryOption — подкатегория (или раздел) из дерева для модели.
type CategoryOption struct {
	ID     string
	Path   string // «Раздел / Подкатегория» по-русски
	PathUz string
}

// CategoryAsk — товар и дерево категорий.
type CategoryAsk struct {
	Name     string
	IkpuPath string // группа / класс / позиция / субпозиция в классификаторе ИКПУ
	Sections []CategoryOption
	Leaves   []CategoryOption
	// Near — подкатегории, где лежат товары того же класса ИКПУ.
	Near []string
}

// CategoryAnswer — ответ модели.
type CategoryAnswer struct {
	Match        string   `json:"match"`
	Alternatives []string `json:"alternatives"`
	New          *struct {
		ParentID     string `json:"parent_id"`
		ParentName   string `json:"parent_name"`
		ParentNameUz string `json:"parent_name_uz"`
		Name         string `json:"name"`
		NameUz       string `json:"name_uz"`
	} `json:"new"`
	NameUz string `json:"name_uz"`
}

func categoryPrompt(in CategoryAsk) string {
	var b strings.Builder
	b.WriteString("Product (Russian name): " + in.Name + "\n")
	if in.IkpuPath != "" {
		b.WriteString("Its place in the national product classifier (MXIK): " + in.IkpuPath + "\n")
	}
	if len(in.Near) > 0 {
		b.WriteString("Products from the same MXIK class are already in subcategories: " + strings.Join(in.Near, ", ") + "\n")
	}
	b.WriteString("\nSections (id | name ru | name uz):\n")
	for _, s := range in.Sections {
		b.WriteString(s.ID + " | " + s.Path + " | " + s.PathUz + "\n")
	}
	b.WriteString("\nSubcategories (id | section / subcategory ru | uz):\n")
	for _, s := range in.Leaves {
		b.WriteString(s.ID + " | " + s.Path + " | " + s.PathUz + "\n")
	}
	b.WriteString(`
Pick the subcategory where a shopper would look for this product.
Return JSON:
{"match": "id of the best existing subcategory, or empty string if none of them really fits",
 "alternatives": ["up to 2 more ids of existing subcategories that could also fit"],
 "new": null or, only when "match" is empty, a new subcategory to create:
        {"parent_id": "id of an existing section, or empty if a new section is needed",
         "parent_name": "new section name in Russian (only when parent_id is empty)",
         "parent_name_uz": "the same in Uzbek",
         "name": "subcategory name in Russian, short, plural, like the existing ones",
         "name_uz": "the same in Uzbek"},
 "name_uz": "the product name translated into Uzbek (brands, numbers and units unchanged)"}
Prefer an existing subcategory when it fits well. Prefer a new subcategory inside an existing section over a new section.`)
	return b.String()
}

// SuggestCategory — спросить модель. Токены возвращаются и при ошибке разбора.
func (c Conn) SuggestCategory(ctx context.Context, in CategoryAsk) (CategoryAnswer, Usage, error) {
	text, u, err := c.Vision(ctx, categorySystem, categoryPrompt(in), nil)
	if err != nil {
		return CategoryAnswer{}, u, err
	}
	raw, err := ExtractJSON(text)
	var out CategoryAnswer
	if err == nil {
		err = json.Unmarshal(raw, &out)
	}
	if err != nil {
		return CategoryAnswer{}, u, &ErrService{Msg: "не удалось подобрать категорию", MsgUz: "kategoriyani tanlab boʻlmadi"}
	}
	return out, u, nil
}
