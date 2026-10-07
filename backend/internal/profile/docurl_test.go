package profile

import "testing"

func TestDocURL(t *testing.T) {
	cases := []struct{ lang, in, want string }{
		{"uz", "https://super-market.uz/privacy", "https://super-market.uz/privacy"},
		{"ru", "https://super-market.uz/privacy", "https://super-market.uz/privacy/ru"},
		{"ru", "https://super-market.uz/privacy/uz", "https://super-market.uz/privacy/ru"},
		{"uz", "https://super-market.uz/offer/stores/ru", "https://super-market.uz/offer/stores"},
		{"ru", "https://super-market.uz/courier-terms/", "https://super-market.uz/courier-terms/ru"},
		{"ru", "https://example.com/privacy", "https://example.com/privacy"},
		{"ru", "https://super-market.uz/", "https://super-market.uz/"},
		{"ru", "", ""},
	}
	for _, c := range cases {
		if got := DocURL(c.lang, c.in); got != c.want {
			t.Errorf("DocURL(%s, %s) = %s, want %s", c.lang, c.in, got, c.want)
		}
	}
}
