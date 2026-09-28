package phone

import "testing"

func TestNormalize(t *testing.T) {
	ok := map[string]string{
		"+998901234567":       "+998901234567",
		"998901234567":        "+998901234567",
		"+998 (90) 123-45-67": "+998901234567",
		"901234567":           "+998901234567",
		"+79161234567":        "+79161234567",
	}
	for in, want := range ok {
		got, err := Normalize(in)
		if err != nil || got != want {
			t.Errorf("Normalize(%q) = %q, %v; want %q", in, got, err, want)
		}
	}

	for _, in := range []string{"", "12345", "+99890123456", "90123456a", "0901234567", "++998901234567", "+998 90 123 45 67 8"} {
		if got, err := Normalize(in); err == nil {
			t.Errorf("Normalize(%q) = %q, want error", in, got)
		}
	}
}
