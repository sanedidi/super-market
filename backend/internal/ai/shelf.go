package ai

import (
	"context"
	"encoding/json"
	"math"
	"strings"
)

// ShelfItem — товар, который модель увидела на фото полки или товара.
type ShelfItem struct {
	Name    string  `json:"name"`
	Brand   string  `json:"brand"`
	Barcode string  `json:"barcode"`
	Qty     float64 `json:"qty"`
}

const shelfSystem = `Ты помогаешь магазину Узбекистана завести товары, которые стоят у него на полках.
По фото определяешь товары и считаешь штуки. Отвечай только JSON без пояснений.`

const shelfPrompt = `На фото — полка магазина или отдельные товары (фото могут быть одной полки с разных сторон).
Верни JSON:
{"items": [{"name": "название товара по-русски, как в каталоге магазина: вид товара, бренд, вкус/вариант, объём или вес — например «Напиток Coca-Cola 1,5 л», «Молоко Musaffo 3,2%, 1 л»",
            "brand": "бренд как на упаковке",
            "barcode": "штрихкод, если цифры видны, иначе пусто",
            "qty": сколько штук этого товара видно на всех фото}]}
Правила: одинаковые товары (тот же бренд, вкус и объём) — одна строка, штуки складываются; разный объём или вкус — разные строки.
Не придумывай товары, которых не видно. Ценники, полки и оборудование — не товары. Если товар не удаётся опознать, пропусти его.`

// RecognizeShelf — найти на фото товары. Токены возвращаются и при ошибке
// разбора: за них уже заплачено.
func (c Conn) RecognizeShelf(ctx context.Context, images []Image) ([]ShelfItem, Usage, error) {
	text, u, err := c.Vision(ctx, shelfSystem, shelfPrompt, images)
	if err != nil {
		return nil, u, err
	}
	items, err := ParseShelf(text)
	return items, u, err
}

// ParseShelf — разбор ответа модели; количество принимает и строкой.
func ParseShelf(text string) ([]ShelfItem, error) {
	raw, err := ExtractJSON(text)
	if err != nil {
		return nil, &ErrService{Msg: "не удалось разобрать товары на фото"}
	}
	var loose struct {
		Items []struct {
			Name    any `json:"name"`
			Brand   any `json:"brand"`
			Barcode any `json:"barcode"`
			Qty     any `json:"qty"`
		} `json:"items"`
	}
	if err := json.Unmarshal(raw, &loose); err != nil {
		return nil, &ErrService{Msg: "не удалось разобрать товары на фото"}
	}
	var out []ShelfItem
	seen := map[string]int{}
	for _, it := range loose.Items {
		item := ShelfItem{Name: str(it.Name, 200), Brand: str(it.Brand, 80), Barcode: digits(str(it.Barcode, 40))}
		if item.Name == "" {
			continue
		}
		q, _ := num(it.Qty)
		q = math.Round(q)
		if q < 1 {
			q = 1
		}
		item.Qty = math.Min(q, 9999)
		if len(item.Barcode) < 8 || len(item.Barcode) > 14 {
			item.Barcode = ""
		}
		// Модель иногда повторяет товар — складываем штуки.
		key := strings.ToLower(item.Name)
		if i, ok := seen[key]; ok {
			out[i].Qty = math.Min(out[i].Qty+item.Qty, 9999)
			continue
		}
		seen[key] = len(out)
		out = append(out, item)
		if len(out) == 100 {
			break
		}
	}
	if len(out) == 0 {
		return nil, &ErrService{Msg: "на фото не найдено товаров — снимите полку ближе и при хорошем свете"}
	}
	return out, nil
}
