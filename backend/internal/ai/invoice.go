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
	// Скидка поставщика на всю накладную, % (уже учтена в строках).
	Discount float64 `json:"discount"`
}

type InvoiceLine struct {
	Name    string  `json:"name"`
	Barcode string  `json:"barcode"`
	Unit    string  `json:"unit"`
	Qty     float64 `json:"qty"`
	Price   float64 `json:"price"`
	Sum     float64 `json:"sum"`
	// Скидка поставщика по строке, % (наценка — минус); price и sum — уже со
	// скидкой, т.е. то, что магазин реально платит.
	Discount float64 `json:"discount"`
	// Цена за единицу без скидки; 0 — скидки нет.
	ListPrice float64 `json:"list_price"`
	// В чём считано «Кол-во» по смыслу строки: pcs — штуки, pack — упаковки, "" — не понять.
	QtyIn string `json:"qty_in"`
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
В каждой строке верни "qty_unit" — в чём на самом деле считано «Кол-во»: "шт" (отдельные штуки: пачки, бутылки, куски мыла)
или "упак" (блоки, коробки, упаковки — даже если в колонке «Ед. изм.» написано «шт»); пусто, если не понять.
Подсказки: колонка веса строки (3 пачки по 20 г = 0,06 кг — штуки), цена за единицу (пачка чипсов 20 г стоит тысячи,
коробка из 48 — сотни тысяч; кусок мыла ~10 000, блок из 6 — ~60 000). «48*20гр» или «6*150g» в названии — сколько штук
в упаковке, по этому одному не решай.
Скидки поставщика: если у строки есть скидка или наценка (колонки «Цена без скидки», «Скидка %», «Сумма скидки»,
«Цена со скидкой» и т.п.) — добавь в строку "discount": скидка в процентах (наценка — отрицательным числом)
и "net_price": цена за единицу ПОСЛЕ скидки, как напечатана (нет такой колонки — null);
price — цена ДО скидки, sum — сумма строки как напечатана (до или после скидки — как в накладной).
Скидка 100% — товар бесплатно (бонус): так и верни "discount": 100, "net_price": 0.
Если скидка одна на всю накладную (строка «Скидка 5%» внизу, а в строках её нет) — верни её в "discount" верхнего уровня, в процентах.
total — именно «к оплате» (после всех скидок), а не «Итого» до скидки.
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
			Name     any `json:"name"`
			Barcode  any `json:"barcode"`
			Unit     any `json:"unit"`
			Qty      any `json:"qty"`
			Price    any `json:"price"`
			Sum      any `json:"sum"`
			Discount any `json:"discount"`
			NetPrice any `json:"net_price"`
			QtyUnit  any `json:"qty_unit"`
		} `json:"lines"`
		Discount any `json:"discount"`
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
		switch strings.ToLower(str(l.QtyUnit, 20)) {
		case "шт", "pcs":
			line.QtyIn = "pcs"
		case "упак", "pack":
			line.QtyIn = "pack"
		}
		line.Qty, _ = num(l.Qty)
		line.Price, _ = num(l.Price)
		line.Sum, _ = num(l.Sum)
		line.Discount, _ = num(l.Discount)
		netPrice, _ := num(l.NetPrice)
		if line.Name == "" {
			continue
		}
		// Нет цены — из суммы и количества.
		free := line.Discount >= 100
		if line.Price == 0 && line.Qty > 0 && line.Sum > 0 && !free {
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
		// Модель положила в price цену уже со скидкой — вернём цену до скидки.
		if netPrice > 0 && line.Discount > 0 && line.Discount < 100 && math.Abs(netPrice-line.Price) <= line.Price*0.001 {
			line.Price = netPrice / (1 - line.Discount/100)
		}
		line.Discount = discountRate(line.Price, netPrice, line.Discount)
		inv.Lines = append(inv.Lines, line)
		if len(inv.Lines) == 300 {
			break
		}
	}
	if d, ok := num(loose.Discount); ok && d > 0 && d < 100 {
		inv.Discount = d
	}
	applyDiscounts(&inv)
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

// discountRate — скидка строки в %: по цене после скидки (точнее) или по
// проценту; странное (≥ 100% или наценка больше 100%) — без скидки.
func discountRate(price, netPrice, pct float64) float64 {
	d := pct
	if price > 0 && netPrice > 0 && netPrice != price {
		d = (1 - netPrice/price) * 100
	}
	// 100% — бесплатно (бонус поставщика): цена и сумма 0.
	if d > 100 || d < -100 || math.Abs(d) < 0.001 {
		return 0
	}
	return math.Round(d*10000) / 10000
}

// applyDiscounts — цены и суммы строк со скидкой поставщика: магазин платит
// цену после скидки, она и есть цена закупки. Сумма строки в накладной бывает
// и до скидки (колонка «Сумма» = кол-во × цена без скидки, скидка — итогом
// внизу), и после — смотрим, на что она похожа.
func applyDiscounts(inv *Invoice) {
	// Скидка одна на всю накладную — тем строкам, где своей нет.
	if inv.Discount > 0 {
		for i := range inv.Lines {
			if inv.Lines[i].Discount == 0 {
				inv.Lines[i].Discount = inv.Discount
			}
		}
	}
	// Суммы строк в накладной уже со скидкой: их итог = «к оплате».
	var printed float64
	for _, l := range inv.Lines {
		printed += l.Sum
	}
	sumsNet := inv.Total != nil && *inv.Total > 0 && math.Abs(printed-*inv.Total) <= *inv.Total*0.005
	for i := range inv.Lines {
		l := &inv.Lines[i]
		if l.Discount == 0 {
			continue
		}
		f := 1 - l.Discount/100
		l.ListPrice = l.Price
		if l.Sum > 0 {
			gross := l.Qty * l.Price
			net := gross * f
			switch {
			case gross > 0 && math.Abs(l.Sum-net) <= net*0.005:
				// Уже со скидкой.
			case gross > 0 && math.Abs(l.Sum-gross) <= gross*0.005:
				l.Sum = math.Round(l.Sum*f*100) / 100
			case !sumsNet:
				// Кол-во × цена ≠ сумма (упаковки): решает итог накладной.
				l.Sum = math.Round(l.Sum*f*100) / 100
			}
		}
		l.Price = math.Round(l.Price*f*10000) / 10000
	}
}
