package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"strings"
)

// Invoice — то, что модель прочитала с фото накладной.
type Invoice struct {
	SupplierName string        `json:"supplier_name"`
	SupplierINN  string        `json:"supplier_inn"`
	Number       string        `json:"number"`
	Date         string        `json:"date"` // YYYY-MM-DD или ""
	Currency     string        `json:"currency"`
	Total        *float64      `json:"total"`
	Lines        []InvoiceLine `json:"lines"`
}

type InvoiceLine struct {
	Name    string  `json:"name"`
	Barcode string  `json:"barcode"`
	Unit    string  `json:"unit"`
	Qty     float64 `json:"qty"`
	Price   float64 `json:"price"`
	Sum     float64 `json:"sum"`
}

const invoiceSystem = `Ты читаешь товарные накладные (счёт-фактуры) магазинов Узбекистана на русском, узбекском или английском.
Отвечай только JSON без пояснений.`

const invoicePrompt = `На фото — одна накладная (страницы по порядку). Верни JSON:
{"supplier_name": "поставщик (продавец), как написано",
 "supplier_inn": "ИНН/СТИР поставщика, только цифры, или пусто",
 "number": "номер накладной", "date": "YYYY-MM-DD или пусто",
 "currency": "UZS или USD",
 "total": итоговая сумма к оплате числом или null,
 "lines": [{"name": "наименование как в накладной", "barcode": "штрихкод, если напечатан, иначе пусто",
            "unit": "ед. изм.", "qty": количество, "price": цена за единицу, "sum": сумма строки}]}
Правила: числа без пробелов и валюты, десятичная точка. Если цена указана с НДС и без — бери с НДС.
qty, price и sum — ровно как напечатано в колонках «Кол-во», «Цена», «Сумма», ничего не пересчитывай:
даже если qty × price ≠ sum (например, в наименовании «12 кг», qty 1, цена за кг) — так и верни, по сумме разберёмся сами.
unit — как в колонке «Ед. изм.» (шт, кг, блок, кор, уп…), пусто, если колонки нет.
Не придумывай строки, которых нет. Строки итогов, НДС и подписи — не товары.`

// ReadInvoice — распознать накладную. Токены возвращаются и при ошибке разбора:
// за них уже заплачено.
func (c Conn) ReadInvoice(ctx context.Context, images []Image) (Invoice, Usage, error) {
	text, u, err := c.Vision(ctx, invoiceSystem, invoicePrompt, images)
	if err != nil {
		return Invoice{}, u, err
	}
	inv, err := ParseInvoice(text)
	return inv, u, err
}

// ParseInvoice — разбор ответа модели; числа принимает и строками («12 500,50»).
func ParseInvoice(text string) (Invoice, error) {
	raw, err := ExtractJSON(text)
	if err != nil {
		return Invoice{}, &ErrService{Msg: "модель не вернула данные накладной", MsgUz: "model yuk xati maʼlumotlarini qaytarmadi"}
	}
	var loose struct {
		SupplierName any `json:"supplier_name"`
		SupplierINN  any `json:"supplier_inn"`
		Number       any `json:"number"`
		Date         any `json:"date"`
		Currency     any `json:"currency"`
		Total        any `json:"total"`
		Lines        []struct {
			Name    any `json:"name"`
			Barcode any `json:"barcode"`
			Unit    any `json:"unit"`
			Qty     any `json:"qty"`
			Price   any `json:"price"`
			Sum     any `json:"sum"`
		} `json:"lines"`
	}
	if err := json.Unmarshal(raw, &loose); err != nil {
		return Invoice{}, &ErrService{Msg: "модель вернула данные накладной в неверном виде", MsgUz: "model yuk xati maʼlumotlarini notoʻgʻri koʻrinishda qaytardi"}
	}
	inv := Invoice{
		SupplierName: str(loose.SupplierName, 200),
		SupplierINN:  digits(str(loose.SupplierINN, 40)),
		Number:       str(loose.Number, 60),
		Date:         normDate(str(loose.Date, 20)),
		Currency:     strings.ToUpper(str(loose.Currency, 10)),
	}
	if inv.Currency != "USD" {
		inv.Currency = "UZS"
	}
	if t, ok := num(loose.Total); ok {
		inv.Total = &t
	}
	for _, l := range loose.Lines {
		line := InvoiceLine{Name: str(l.Name, 300), Barcode: digits(str(l.Barcode, 40)), Unit: str(l.Unit, 20)}
		line.Qty, _ = num(l.Qty)
		line.Price, _ = num(l.Price)
		line.Sum, _ = num(l.Sum)
		if line.Name == "" {
			continue
		}
		// Нет цены — из суммы и количества.
		if line.Price == 0 && line.Qty > 0 && line.Sum > 0 {
			line.Price = math.Round(line.Sum/line.Qty*100) / 100
		}
		if line.Qty <= 0 && line.Price > 0 && line.Sum > 0 {
			line.Qty = math.Round(line.Sum/line.Price*1000) / 1000
		}
		if line.Qty < 0 || line.Price < 0 {
			continue
		}
		if len(line.Barcode) < 8 || len(line.Barcode) > 14 {
			line.Barcode = ""
		}
		inv.Lines = append(inv.Lines, line)
		if len(inv.Lines) == 300 {
			break
		}
	}
	if len(inv.Lines) == 0 {
		return inv, &ErrService{Msg: "на фото не найдено строк с товарами — переснимите накладную ровнее", MsgUz: "rasmda mahsulotli qatorlar topilmadi — yuk xatini tekisroq qilib qayta suratga oling"}
	}
	return inv, nil
}

func str(v any, max int) string {
	var s string
	switch t := v.(type) {
	case string:
		s = t
	case float64:
		s = strconv.FormatFloat(t, 'f', -1, 64)
	case nil:
		return ""
	default:
		s = fmt.Sprint(t)
	}
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > max {
		s = string(r[:max])
	}
	return s
}

func digits(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func num(v any) (float64, bool) {
	switch t := v.(type) {
	case float64:
		return t, !math.IsNaN(t) && !math.IsInf(t, 0)
	case string:
		s := strings.NewReplacer(" ", "", " ", "", " ", "", "'", "").Replace(t)
		s = strings.TrimSuffix(strings.TrimSuffix(strings.ToLower(s), "сум"), "uzs")
		// «12 500,50» → 12500.50; «12,500.50» → 12500.50.
		if strings.Contains(s, ",") && strings.Contains(s, ".") {
			s = strings.ReplaceAll(s, ",", "")
		} else {
			s = strings.ReplaceAll(s, ",", ".")
		}
		f, err := strconv.ParseFloat(s, 64)
		return f, err == nil
	}
	return 0, false
}

// normDate — YYYY-MM-DD; «02.10.2026» тоже понимаем.
func normDate(s string) string {
	if len(s) == 10 && s[4] == '-' && s[7] == '-' {
		return s
	}
	if len(s) == 10 && (s[2] == '.' || s[2] == '/') {
		return s[6:10] + "-" + s[3:5] + "-" + s[0:2]
	}
	return ""
}
