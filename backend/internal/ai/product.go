package ai

import (
	"context"
	"encoding/json"
	"strings"
)

// Новый товар по фото («Начало работы»): товара нет ни в базе, ни в каталоге
// ИКПУ — магазин фотографирует его, модель заполняет карточку (название ru/uz,
// бренд, единица, категория из дерева или новая). Расход — ai_usage.kind = product.

const productSystem = `You help a grocery and retail store in Uzbekistan add a product to the Super Market catalog from photos of the package.
The catalog tree has two levels: sections and subcategories. A product always goes into a subcategory.
Uzbek is always in the Latin alphabet with typographic apostrophes: oʻ, gʻ (U+02BB) and ʼ (U+02BC).
Never invent what is not visible on the package. Answer with JSON only.`

// ProductAsk — фото и дерево категорий.
type ProductAsk struct {
	Images   []Image
	Barcode  string
	Sections []CategoryOption
	Leaves   []CategoryOption
}

// ProductAnswer — карточка, которую заполнила модель.
type ProductAnswer struct {
	// Product — на фото виден товар в упаковке (иначе Problem — почему нет).
	Product     bool   `json:"product"`
	Problem     string `json:"problem"`
	Name        string `json:"name"`
	NameUz      string `json:"name_uz"`
	Brand       string `json:"brand"`
	Unit        string `json:"unit"`
	Description string `json:"description"`
	// Confidence — high: сомнений нет; check: что-то пришлось домысливать
	// (тогда Note — что именно). От этого зависит, попадёт ли карточка к
	// магазину на проверку или встанет в «Мои товары» сама.
	Confidence string `json:"confidence"`
	Note       string `json:"note"`
	CategoryAnswer
}

func productPrompt(in ProductAsk) string {
	var b strings.Builder
	b.WriteString("The photos show one product: the front of the package and possibly the label with composition and weight.\n")
	if in.Barcode != "" {
		b.WriteString("Its barcode: " + in.Barcode + "\n")
	}
	writeTree(&b, in.Sections, in.Leaves)
	b.WriteString(`
Return JSON:
{"product": true if a packaged product is clearly visible, otherwise false,
 "problem": "only when product is false: short reason in Russian, e.g. «на фото не видно товара», «фото размыто»",
 "name": "name in Russian as on a shop shelf: product type, brand, flavour or variant, volume or weight — e.g. «Сок Bliss яблочный, 1 л», «Печенье Юбилейное традиционное, 112 г»",
 "name_uz": "the same name in Uzbek (brand, numbers and units unchanged)",
 "brand": "brand as written on the package, or empty",
 "unit": "шт for packaged goods, кг only for loose goods sold by weight",
 "description": "one short sentence in Russian from the label (composition or key facts), or empty",
 "confidence": "high only when the package is sharp and readable and you are sure of the name, brand, volume and category; \"check\" whenever anything had to be guessed",
 "note": "short note in Russian for the shop when confidence is \"check\" — what exactly is unclear; otherwise empty",
 "match": "id of the subcategory where a shopper would look for it, or empty if none really fits",
 "alternatives": ["up to 2 more subcategory ids that could also fit"],
 "new": null or, only when "match" is empty, a new subcategory:
        {"parent_id": "id of an existing section, or empty if a new section is needed",
         "parent_name": "new section name in Russian (only when parent_id is empty)",
         "parent_name_uz": "the same in Uzbek",
         "name": "subcategory name in Russian, short, plural, like the existing ones",
         "name_uz": "the same in Uzbek"}}
Prefer an existing subcategory when it fits well. Prefer a new subcategory inside an existing section over a new section.`)
	return b.String()
}

// RecognizeProduct — заполнить карточку по фото. Токены возвращаются и при
// ошибке разбора: за них уже заплачено.
func (c Conn) RecognizeProduct(ctx context.Context, in ProductAsk) (ProductAnswer, Usage, error) {
	text, u, err := c.Vision(ctx, productSystem, productPrompt(in), in.Images)
	if err != nil {
		return ProductAnswer{}, u, err
	}
	raw, err := ExtractJSON(text)
	var out ProductAnswer
	if err == nil {
		err = json.Unmarshal(raw, &out)
	}
	if err != nil {
		return ProductAnswer{}, u, &ErrService{Msg: "не удалось разобрать фото товара", MsgUz: "mahsulot rasmini aniqlab boʻlmadi"}
	}
	out.Name, out.NameUz, out.Brand = strings.TrimSpace(out.Name), strings.TrimSpace(out.NameUz), strings.TrimSpace(out.Brand)
	if out.Product && out.Name == "" {
		out.Product = false
	}
	return out, u, nil
}
