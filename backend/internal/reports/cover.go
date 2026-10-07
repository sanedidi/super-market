package reports

import "math"

// «На сколько дней хватит остатка» — одно правило для всех отчётов:
// остаток делится на средние продажи в день за последние CoverWindowDays дней.
// Им пользуются ABC/XYZ (days_cover) и «Итоги дня» (алерт «товары заканчиваются»).
const (
	CoverWindowDays = 14
	// CoverMinSold — меньше продаж за окно: товар не ходовой, в алерты не попадает.
	CoverMinSold = 3
	// CoverAttentionDays — на главной «заканчиваются» товары A, которых хватит меньше чем на столько дней.
	CoverAttentionDays = 7
	coverAttentionMax  = 5
)

// DaysCover — на сколько полных дней хватит остатка stock, если за окно
// продано sold. Нет остатка — 0; за окно не продавался — nil (спроса нет).
func DaysCover(stock, sold float64) *float64 {
	var d float64
	switch {
	case stock <= 0:
	case sold <= 0:
		return nil
	default:
		d = math.Floor(stock / (sold / CoverWindowDays))
	}
	return &d
}
