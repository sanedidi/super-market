package field

import (
	"math"
	"testing"
)

func TestGrid(t *testing.T) {
	// Клетка ≈ 100 × 100 м в Ташкенте.
	c := cellOf(41.311, 69.279)
	lat, lng := c.center()
	if d := distM(lat-cellLat/2, lng, lat+cellLat/2, lng); math.Abs(d-100) > 1 {
		t.Fatalf("cell height = %v m", d)
	}
	if d := distM(lat, lng-cellLng/2, lat, lng+cellLng/2); math.Abs(d-100) > 2 {
		t.Fatalf("cell width = %v m", d)
	}
	if cellOf(lat, lng) != c {
		t.Fatalf("center is in another cell")
	}

	// Точка у края клетки задевает соседнюю (обе стороны улицы).
	got := map[cell]bool{}
	cellsAround(lat, float64(c.x+1)*cellLng-0.00001, func(x cell) { got[x] = true })
	if !got[c] || !got[cell{c.x + 1, c.y}] {
		t.Fatalf("cellsAround = %v", got)
	}

	// Отрезок 200 м по клеткам: 2–3 клетки в длину.
	got = map[cell]bool{}
	cellsAlong(41.3600, 69.28, 41.3618, 69.28, func(x cell) { got[x] = true })
	ys := map[int]bool{}
	for x := range got {
		ys[x.y] = true
	}
	if len(ys) < 2 || len(ys) > 4 {
		t.Fatalf("cellsAlong rows = %v", ys)
	}

	if b := bearing(41.36, 69.28, 41.37, 69.28); b != "n" {
		t.Fatalf("bearing north = %s", b)
	}
	if b := bearing(41.36, 69.28, 41.36, 69.29); b != "e" {
		t.Fatalf("bearing east = %s", b)
	}

	sq := Polygon{{41.36, 69.275}, {41.37, 69.275}, {41.37, 69.285}, {41.36, 69.285}}
	if !sq.contains(41.365, 69.28) || sq.contains(41.375, 69.28) {
		t.Fatal("contains")
	}
	// ≈ 1,11 × 0,84 км → около 93 клеток.
	if n := sq.cellCount(); n < 80 || n > 105 {
		t.Fatalf("cellCount = %d", n)
	}
	if Polygon(nil).cellCount() != 0 {
		t.Fatal("empty polygon")
	}
}
