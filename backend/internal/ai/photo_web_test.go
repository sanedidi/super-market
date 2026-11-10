package ai

import "testing"

// Модель для проверки фото: самая новая стабильная Flash, без картинок, Lite и голоса.
func TestPickCheckModel(t *testing.T) {
	cases := []struct {
		ids  []string
		want string
	}{
		{[]string{"gemini-3-pro-image", "gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.5-flash-image", "gemini-3-flash-preview"}, "gemini-2.5-flash"},
		{[]string{"gemini-2.5-flash", "gemini-3-flash", "gemini-3-flash-preview", "gemini-3.1-flash-image"}, "gemini-3-flash"},
		{[]string{"gemini-2.5-flash-preview-tts", "gemini-live-2.5-flash", "imagen-4"}, ""},
		{nil, ""},
	}
	for _, c := range cases {
		if got := pickCheckModel(c.ids); got != c.want {
			t.Errorf("pickCheckModel(%v) = %q, want %q", c.ids, got, c.want)
		}
	}
}

func TestWebQueryAndCost(t *testing.T) {
	if q := webQuery(webProduct{Name: "Juice 1 l", Brand: "Rich"}); q != "Rich Juice 1 l" {
		t.Fatalf("query = %q", q)
	}
	if q := webQuery(webProduct{Name: "Rich Juice", Brand: "rich"}); q != "Rich Juice" {
		t.Fatalf("query = %q", q)
	}
	if c := textCostUSD("gemini-2.5-flash", Usage{Input: 1e6, Output: 1e6}); c != 2.8 {
		t.Fatalf("cost = %v", c)
	}
}

func TestPickOpenAICheckModel(t *testing.T) {
	if got := pickOpenAICheckModel([]string{"gpt-image-2", "gpt-4o-mini", "gpt-5-mini", "gpt-5", "gpt-4.1-mini", "gpt-5-mini-2025-08-07"}); got != "gpt-5-mini" {
		t.Errorf("pick = %q", got)
	}
	if got := pickOpenAICheckModel([]string{"gpt-image-2"}); got != "" {
		t.Errorf("no mini = %q", got)
	}
	if !IsImageModel("gpt-image-2") || IsImageModel("gpt-5-mini") {
		t.Error("IsImageModel")
	}
}
