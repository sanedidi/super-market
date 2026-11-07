package field

import "math"

// Сетка обхода: город поделён на клетки примерно 100×100 м. Номер клетки —
// (cx, cy): cy — полоса по широте, cx — по долготе. Ширина клетки по долготе
// посчитана для широты Ташкента (refLat) — для одного города этого хватает.
// Клиенту отдаём размеры клетки в градусах (Grid), границы клетки он
// считает сам: юг = cy·Lat, запад = cx·Lng.

const (
	// CellM — сторона клетки, м.
	CellM = 100.0
	// refLat — широта, для которой считаем ширину клетки по долготе.
	refLat     = 41.3
	mPerDegLat = 111320.0
	// coverM — путь покрывает клетки по обе стороны улицы: всё, что ближе
	// этого к точке пути.
	coverM = 30.0
	// stepM — шаг, с которым отрезок пути между двумя точками проходит по клеткам.
	stepM = 20.0
	// maxStepM — отрезок длиннее (разрыв в точках) клетки по пути не закрашивает.
	maxStepM = 300.0
)

var (
	cellLat = CellM / mPerDegLat
	cellLng = CellM / (mPerDegLat * math.Cos(refLat*math.Pi/180))
)

// Grid — размер клетки в градусах (для клиента).
type Grid struct {
	Lat float64 `json:"lat"`
	Lng float64 `json:"lng"`
	M   float64 `json:"m"`
}

func grid() Grid { return Grid{Lat: cellLat, Lng: cellLng, M: CellM} }

type cell struct{ x, y int }

func cellOf(lat, lng float64) cell {
	return cell{int(math.Floor(lng / cellLng)), int(math.Floor(lat / cellLat))}
}

// center — середина клетки (lat, lng).
func (c cell) center() (float64, float64) {
	return (float64(c.y) + 0.5) * cellLat, (float64(c.x) + 0.5) * cellLng
}

// cellsAround — клетки, которые задевает квадрат ±coverM вокруг точки (до 4).
func cellsAround(lat, lng float64, add func(cell)) {
	dLat := coverM / mPerDegLat
	dLng := coverM / (mPerDegLat * math.Cos(lat*math.Pi/180))
	a := cellOf(lat-dLat, lng-dLng)
	b := cellOf(lat+dLat, lng+dLng)
	for x := a.x; x <= b.x; x++ {
		for y := a.y; y <= b.y; y++ {
			add(cell{x, y})
		}
	}
}

// cellsAlong — клетки по отрезку пути (шаг stepM; длинный отрезок — только концы).
func cellsAlong(lat1, lng1, lat2, lng2 float64, add func(cell)) {
	d := distM(lat1, lng1, lat2, lng2)
	if d > maxStepM {
		cellsAround(lat2, lng2, add)
		return
	}
	n := int(math.Ceil(d / stepM))
	if n < 1 {
		n = 1
	}
	for i := 1; i <= n; i++ {
		t := float64(i) / float64(n)
		cellsAround(lat1+(lat2-lat1)*t, lng1+(lng2-lng1)*t, add)
	}
}

// distM — расстояние между точками, м (гаверсинус).
func distM(lat1, lng1, lat2, lng2 float64) float64 {
	const r = 6371000.0
	p1, p2 := lat1*math.Pi/180, lat2*math.Pi/180
	dp := (lat2 - lat1) * math.Pi / 180
	dl := (lng2 - lng1) * math.Pi / 180
	a := math.Sin(dp/2)*math.Sin(dp/2) + math.Cos(p1)*math.Cos(p2)*math.Sin(dl/2)*math.Sin(dl/2)
	return 2 * r * math.Asin(math.Min(1, math.Sqrt(a)))
}

// bearing — направление от точки 1 к точке 2: n, ne, e, se, s, sw, w, nw.
func bearing(lat1, lng1, lat2, lng2 float64) string {
	y := math.Sin((lng2-lng1)*math.Pi/180) * math.Cos(lat2*math.Pi/180)
	x := math.Cos(lat1*math.Pi/180)*math.Sin(lat2*math.Pi/180) -
		math.Sin(lat1*math.Pi/180)*math.Cos(lat2*math.Pi/180)*math.Cos((lng2-lng1)*math.Pi/180)
	deg := math.Mod(math.Atan2(y, x)*180/math.Pi+360, 360)
	dirs := []string{"n", "ne", "e", "se", "s", "sw", "w", "nw"}
	return dirs[int(math.Floor((deg+22.5)/45))%8]
}

// Polygon — граница района: [[lat, lng], ...].
type Polygon [][2]float64

// contains — точка внутри многоугольника (луч).
func (p Polygon) contains(lat, lng float64) bool {
	in := false
	for i, j := 0, len(p)-1; i < len(p); j, i = i, i+1 {
		yi, xi := p[i][0], p[i][1]
		yj, xj := p[j][0], p[j][1]
		if (yi > lat) != (yj > lat) && lng < (xj-xi)*(lat-yi)/(yj-yi)+xi {
			in = !in
		}
	}
	return in
}

// bounds — клетки углов прямоугольника вокруг многоугольника.
func (p Polygon) bounds() (cell, cell) {
	minLat, minLng, maxLat, maxLng := math.Inf(1), math.Inf(1), math.Inf(-1), math.Inf(-1)
	for _, v := range p {
		minLat, maxLat = math.Min(minLat, v[0]), math.Max(maxLat, v[0])
		minLng, maxLng = math.Min(minLng, v[1]), math.Max(maxLng, v[1])
	}
	return cellOf(minLat, minLng), cellOf(maxLat, maxLng)
}

// hasCell — середина клетки внутри района.
func (p Polygon) hasCell(c cell) bool {
	lat, lng := c.center()
	return p.contains(lat, lng)
}

// cellCount — сколько клеток района (середина внутри границы).
func (p Polygon) cellCount() int {
	if len(p) < 3 {
		return 0
	}
	a, b := p.bounds()
	n := 0
	for x := a.x; x <= b.x; x++ {
		for y := a.y; y <= b.y; y++ {
			if p.hasCell(cell{x, y}) {
				n++
			}
		}
	}
	return n
}
