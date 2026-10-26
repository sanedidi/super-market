package ai

import (
	"context"
	"strings"
)

// Part — вложение к запросу: фото, голосовое (audio/webm, audio/mp4, audio/ogg)
// или PDF. Gemini (Vertex AI и Gemini API) понимает всё; OpenAI и Anthropic
// через этот код — только фото.
type Part struct {
	MIME string
	Data []byte
}

// IsGoogle — подключение к Gemini (там работают аудио и PDF).
func (c Conn) IsGoogle() bool { return c.Provider == ProviderVertex || c.Provider == ProviderGemini }

// Generate — ответ модели (JSON) на инструкцию, вопрос и вложения.
func (c Conn) Generate(ctx context.Context, system, prompt string, parts []Part) (string, Usage, error) {
	if c.Model == "" {
		return "", Usage{}, &ErrService{Msg: "не выбрана модель", MsgUz: "model tanlanmagan"}
	}
	if c.IsGoogle() {
		return c.geminiGenerate(ctx, system, prompt, parts)
	}
	images := make([]Image, 0, len(parts))
	for _, p := range parts {
		if !strings.HasPrefix(p.MIME, "image/") {
			return "", Usage{}, &ErrService{
				Msg:   "голосовые и файлы понимает только Gemini — выберите Vertex AI в «ИИ-сервисе»",
				MsgUz: "ovozli xabar va fayllarni faqat Gemini tushunadi — «SI xizmati»da Vertex AI ni tanlang"}
		}
		images = append(images, Image{MIME: p.MIME, Data: p.Data})
	}
	return c.Vision(ctx, system, prompt, images)
}
