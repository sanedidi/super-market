package ai

import (
	"context"
	"encoding/json"
	"strings"
)

// Автонормализация общего каталога: модель чистит названия товаров (ru и uz),
// выбирает подкатегорию и разбирает товар на линейку, вкус и вес — для групп
// вариаций. Вторым запросом подтверждает перенос товара в другой раздел, третьим
// — решает по товарам, которые предложили магазины. Расход пишется в ai_usage
// с kind = "catalog_norm".

const normSystem = `You clean up the shared product catalog of a grocery and retail platform in Uzbekistan (Super Market).
Many names were built from the national product classifier (MXIK) and start with an official product-type phrase
("Безалкогольные напитки Coca-Cola, …", "Не замороженные овощи Lay's, …", "Биологически активные добавки к пище …"),
contain packaging words ("Полиэтиленовый пакет", "алюминиевая банка") and messy weights ("150г", "62 гр", "1.0л").
Uzbek is always in the Latin alphabet with typographic apostrophes: oʻ, gʻ (U+02BB) and ʼ (U+02BC).
Answer with JSON only.`

// NormCategory — подкатегория для модели: короткий код и путь.
type NormCategory struct {
	Code string
	Path string // «Раздел / Подкатегория»
}

// NormProduct — товар для модели. ID — короткий код в запросе (p1, p2…).
type NormProduct struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Brand    string `json:"brand,omitempty"`
	Mxik     string `json:"mxik,omitempty"`     // название в классификаторе ИКПУ
	Category string `json:"category,omitempty"` // код текущей подкатегории
	// Food — еда или напиток по коду ИКПУ; nil — неизвестно, решает модель.
	Food *bool `json:"food,omitempty"`
}

// NormAsk — пачка товаров и дерево подкатегорий.
type NormAsk struct {
	Categories []NormCategory
	Products   []NormProduct
}

// NormItem — ответ модели по товару.
type NormItem struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	NameUz   string `json:"name_uz"`
	Category string `json:"category"`
	Food     bool   `json:"food"`
	Line     string `json:"line"`
	LineUz   string `json:"line_uz"`
	Flavor   string `json:"flavor"`
	FlavorUz string `json:"flavor_uz"`
	Weight   string `json:"weight"`
	WeightUz string `json:"weight_uz"`
}

type NormAnswer struct {
	Items []NormItem `json:"items"`
}

func normPrompt(in NormAsk) string {
	var b strings.Builder
	b.WriteString("Catalog subcategories (code | section / subcategory):\n")
	for _, c := range in.Categories {
		b.WriteString(c.Code + " | " + c.Path + "\n")
	}
	b.WriteString("\nProducts (JSON, \"category\" is the current subcategory code, \"food\" — food or drink by its MXIK code when known):\n")
	raw, _ := json.Marshal(in.Products)
	b.Write(raw)
	b.WriteString(normRules)
	return b.String()
}

const normRules = `

For every product return a clean card. Return JSON:
{"items": [{"id": "product id from the input",
  "name": "clean Russian name",
  "name_uz": "the same name in Uzbek (brand, model, numbers unchanged; units g, kg, ml, l, dona)",
  "category": "code of the subcategory where a shopper looks for this product; keep the current one when it fits",
  "food": true for food, drinks, baby food, dietary supplements; false for everything else (tobacco, cosmetics, household chemicals, clothes, appliances, pet food),
  "line": "brand + product line without flavor and size, e.g. \"Lay's\", \"Lay's MAXX\", \"Coca-Cola Zero\"; for non-food: short type + brand + model series, e.g. \"Телевизор Samsung UE55AU7100\"",
  "line_uz": "the same in Uzbek",
  "flavor": "flavor, color, scent or other variant in Russian, capitalized (\"С солью\", \"Сметана и лук\", \"Белый\"); empty if none",
  "flavor_uz": "the same in Uzbek",
  "weight": "package size as \"150 г\", \"1 кг\", \"0,5 л\", \"330 мл\", \"10 шт\", \"XL\"; empty if none",
  "weight_uz": "the same with Uzbek units: \"150 g\", \"1 kg\", \"0,5 l\", \"330 ml\", \"10 dona\""}]}
Rules for "name":
1. Food and drinks: NO product type and NO classifier phrase — start with the brand, then flavor or characteristics, size last:
   "Lay's, С солью, 150 г", "Coca-Cola, 0,15 л", "Hochland, плавленый сливочный 55%, 200 г", "Nestle Nan Optipro 1, 400 г".
2. Everything else: a short natural product type of 1–3 words (singular when it is one item), then brand and model:
   "Телевизор Samsung UE55AU7100, 55\"", "Шампунь Head & Shoulders, против перхоти, 400 мл", "Водонагреватель Ariston ABS VLS 80 л",
   "Батарейки Duracell AA, 4 шт", "Электронная сигарета Friobar, Tropical Rainbow Blast". Replace official long types with short ones
   ("Водные нагреватели" → "Водонагреватель", "Первичные батареи" → "Батарейки", "Сигареты электронные" → "Электронная сигарета").
3. Remove packaging words (polyethylene bag, aluminium can, PET bottle, glass bottle, cardboard box, Tetra Pak) and article/lot codes like "арт.перм70130брза".
4. Size goes last in the format of "weight" ("150 г", "0,5 л", "4 шт. по 100 г"); decimal comma; never "гр", "Л", "1.0л".
5. Normal letter case: no CAPS LOCK except brands and abbreviations. Brand spelled as given.
6. Never drop or change numbers, percentages, model codes, sizes, flavors or colors that are in the input name.
Return every product of the input exactly once.`

// Normalize — спросить модель. Токены возвращаются и при ошибке разбора.
func (c Conn) Normalize(ctx context.Context, in NormAsk) (NormAnswer, Usage, error) {
	text, u, err := c.Vision(ctx, normSystem, normPrompt(in), nil)
	if err != nil {
		return NormAnswer{}, u, err
	}
	raw, err := ExtractJSON(text)
	var out NormAnswer
	if err == nil {
		err = json.Unmarshal(raw, &out)
	}
	if err != nil {
		return NormAnswer{}, u, &ErrService{Msg: "не удалось разобрать товары", MsgUz: "mahsulotlarni tahlil qilib boʻlmadi"}
	}
	return out, u, nil
}

// ---------------------------------------------------------------- перенос в другой раздел

// MoveAsk — товар, который модель предлагает перенести в другой раздел:
// второе мнение перед переносом.
type MoveAsk struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Mxik string `json:"mxik,omitempty"`
	From string `json:"from"`
	To   string `json:"to"`
}

type MoveAnswer struct {
	Items []struct {
		ID   string `json:"id"`
		Move bool   `json:"move"`
	} `json:"items"`
}

const moveRules = `

Each product above is now in subcategory "from"; it is proposed to move it to "to".
Answer "move": true only when "to" is clearly the right place for this product in a grocery/retail app
and "from" is wrong (for example potato chips in "Frozen vegetables"). When both could fit or you are unsure — false.
Return JSON: {"items": [{"id": "product id", "move": true | false}]} for every product.`

// ConfirmMoves — второе мнение о переносе товаров между разделами.
func (c Conn) ConfirmMoves(ctx context.Context, items []MoveAsk) (MoveAnswer, Usage, error) {
	raw, _ := json.Marshal(items)
	text, u, err := c.Vision(ctx, normSystem, "Products (JSON):\n"+string(raw)+moveRules, nil)
	if err != nil {
		return MoveAnswer{}, u, err
	}
	js, err := ExtractJSON(text)
	var out MoveAnswer
	if err == nil {
		err = json.Unmarshal(js, &out)
	}
	if err != nil {
		return MoveAnswer{}, u, &ErrService{Msg: "не удалось проверить перенос", MsgUz: "koʻchirishni tekshirib boʻlmadi"}
	}
	return out, u, nil
}

// ---------------------------------------------------------------- модерация

// ModerationSimilar — похожий товар общего каталога.
type ModerationSimilar struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// ModerationAsk — товар, который магазин предложил в общий каталог.
type ModerationAsk struct {
	ID         string              `json:"id"`
	Name       string              `json:"name"`
	Brand      string              `json:"brand,omitempty"`
	Category   string              `json:"category"`
	HasPhoto   bool                `json:"has_photo"`
	HasBarcode bool                `json:"has_barcode"`
	Similar    []ModerationSimilar `json:"similar,omitempty"`
}

type ModerationItem struct {
	ID       string `json:"id"`
	Decision string `json:"decision"` // approve | duplicate | reject
	DupOf    string `json:"duplicate_of"`
	Reason   string `json:"reason"`
	ReasonUz string `json:"reason_uz"`
}

type ModerationAnswer struct {
	Items []ModerationItem `json:"items"`
}

const moderationRules = `

These products were added by shops and wait for moderation before they join the shared catalog.
"similar" are existing products of the shared catalog with similar names.
For every product decide:
- "duplicate" when one of "similar" is the same product (same brand, type, flavor/variant and size) — put its id into "duplicate_of";
- "reject" only when the card is clearly unusable: meaningless or test name, not a product, alcohol (forbidden in the catalog),
  or no photo and no barcode at all;
- "approve" otherwise (a normal real product, even if the name could be nicer).
Return JSON: {"items": [{"id": "product id", "decision": "approve" | "duplicate" | "reject", "duplicate_of": "id or empty",
 "reason": "for reject and duplicate: short reason in Russian for the shop", "reason_uz": "the same in Uzbek"}]}`

// Moderate — решения по товарам магазинов.
func (c Conn) Moderate(ctx context.Context, items []ModerationAsk) (ModerationAnswer, Usage, error) {
	raw, _ := json.Marshal(items)
	text, u, err := c.Vision(ctx, normSystem, "Products (JSON):\n"+string(raw)+moderationRules, nil)
	if err != nil {
		return ModerationAnswer{}, u, err
	}
	js, err := ExtractJSON(text)
	var out ModerationAnswer
	if err == nil {
		err = json.Unmarshal(js, &out)
	}
	if err != nil {
		return ModerationAnswer{}, u, &ErrService{Msg: "не удалось проверить товары", MsgUz: "mahsulotlarni tekshirib boʻlmadi"}
	}
	return out, u, nil
}

// ---------------------------------------------------------------- исправления от магазинов

// SuggestionAsk — исправление карточки общего каталога, которое прислал
// магазин: только изменённые поля («было» → «стало»).
type SuggestionAsk struct {
	ID      string            `json:"id"`
	Product string            `json:"product"`
	Changes map[string][2]any `json:"changes"` // поле → [было, стало]
}

type SuggestionItem struct {
	ID       string `json:"id"`
	Approve  bool   `json:"approve"`
	Reason   string `json:"reason"`
	ReasonUz string `json:"reason_uz"`
}

type SuggestionAnswer struct {
	Items []SuggestionItem `json:"items"`
}

const suggestionRules = `

Shops sent corrections of shared catalog product cards ("changes": field → [current value, proposed value]).
The shared card is used by all shops. Approve a correction when it describes the SAME product and makes the card more correct:
fixes a typo or the name, adds a missing flavor/size, a better photo (photos are counted), an added barcode, a more fitting category or unit.
Reject when it turns the card into a different product, makes the name worse or meaningless, removes useful information,
adds alcohol, or looks like a mistake. Do not reject only because the style differs slightly.
Return JSON: {"items": [{"id": "correction id", "approve": true | false,
 "reason": "for rejection: short reason in Russian for the shop", "reason_uz": "the same in Uzbek"}]}`

// ReviewSuggestions — решения по исправлениям от магазинов.
func (c Conn) ReviewSuggestions(ctx context.Context, items []SuggestionAsk) (SuggestionAnswer, Usage, error) {
	raw, _ := json.Marshal(items)
	text, u, err := c.Vision(ctx, normSystem, "Corrections (JSON):\n"+string(raw)+suggestionRules, nil)
	if err != nil {
		return SuggestionAnswer{}, u, err
	}
	js, err := ExtractJSON(text)
	var out SuggestionAnswer
	if err == nil {
		err = json.Unmarshal(js, &out)
	}
	if err != nil {
		return SuggestionAnswer{}, u, &ErrService{Msg: "не удалось проверить исправления", MsgUz: "tuzatishlarni tekshirib boʻlmadi"}
	}
	return out, u, nil
}
