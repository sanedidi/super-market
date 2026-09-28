package money

import (
	"encoding/json"
	"testing"
)

func TestAmountJSON(t *testing.T) {
	ok := map[string]Amount{`15000`: "15000", `"15000.5"`: "15000.5", `"0.99"`: "0.99", `0`: "0"}
	for in, want := range ok {
		var a Amount
		if err := json.Unmarshal([]byte(in), &a); err != nil || a != want {
			t.Errorf("%s -> %q, %v", in, a, err)
		}
	}
	for _, in := range []string{`-1`, `"1e5"`, `1.234`, `"abc"`, `null`, `"1234567890123"`} {
		var a Amount
		if err := json.Unmarshal([]byte(in), &a); err == nil {
			t.Errorf("%s accepted as %q", in, a)
		}
	}
}
