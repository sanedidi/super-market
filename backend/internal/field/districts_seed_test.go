package field

import (
	"encoding/json"
	"os"
	"regexp"
	"strconv"
	"testing"
)

// Миграция 0095 заполняет границы районов Ташкента — total_cells в ней должен
// совпадать с тем, что посчитал бы SetBoundary для той же границы.
func TestDistrictSeedCells(t *testing.T) {
	raw, err := os.ReadFile("../../db/migrations/0095_field_district_boundaries.sql")
	if err != nil {
		t.Fatal(err)
	}
	re := regexp.MustCompile(`SET boundary = '(\[[^']+\])'::jsonb, total_cells = (\d+)\s+WHERE name = '([^']+)'`)
	m := re.FindAllStringSubmatch(string(raw), -1)
	if len(m) != 12 {
		t.Fatalf("районов в миграции: %d, ждали 12", len(m))
	}
	for _, x := range m {
		var p Polygon
		if err := json.Unmarshal([]byte(x[1]), &p); err != nil {
			t.Fatalf("%s: %v", x[3], err)
		}
		if len(p) < 3 || len(p) > 500 {
			t.Errorf("%s: точек %d — SetBoundary принимает 3–500", x[3], len(p))
		}
		for _, v := range p {
			if v[0] < 40.5 || v[0] > 42 || v[1] < 68.5 || v[1] > 70.5 {
				t.Fatalf("%s: точка %v вне Ташкента (перепутаны широта и долгота?)", x[3], v)
			}
		}
		want, _ := strconv.Atoi(x[2])
		if got := p.cellCount(); got != want {
			t.Errorf("%s: total_cells %d, а cellCount() = %d", x[3], want, got)
		}
	}
}
