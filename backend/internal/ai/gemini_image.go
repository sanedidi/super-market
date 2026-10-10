package ai

// Картинки от Gemini («ИИ для фото», photo.go): generateContent с ответом IMAGE.
//
//	Gemini API: POST {base}/models/{model}:generateContent — ключ Google AI Studio в x-goog-api-key,
//	            base — https://generativelanguage.googleapis.com/v1beta
//	Vertex AI:  POST {base}/publishers/google/models/{model}:generateContent (vertex.go)
//
// Фото уходит частью inlineData, инструкция — текстом; в ответе картинка — тоже
// inlineData (последняя «не-мысль»: Gemini 3 присылает черновики с thought=true).

import (
	"context"
	"encoding/base64"
	"errors"
	"net/http"
	"net/url"
	"sort"
	"strings"
)

const (
	ProviderGemini   = "gemini"
	DefaultGeminiURL = "https://generativelanguage.googleapis.com/v1beta"
)

// imageModels — модели Gemini, которые рисуют картинки: список для Vertex AI
// (у него нет простого списка моделей проекта). Другую модель можно вписать вручную.
var imageModels = []string{
	"gemini-3-pro-image",
	"gemini-nano-banana-2.1",
	"gemini-3.1-flash-image",
	"gemini-3.1-flash-lite-image",
	"gemini-2.5-flash-image",
}

// imagePrices — прайс Google (Standard, USD за 1 млн токенов) для расхода.
// Совпадение по подстроке названия, по порядку: lite раньше flash-image.
var imagePrices = []struct {
	match   string
	in, out float64
}{
	{"3-pro-image", 2, 120},
	{"flash-lite-image", 0.25, 30},
	{"3.1-flash-image", 0.5, 60},
	{"nano-banana", 1.5, 30},
	{"2.5-flash-image", 0.3, 30},
}

// imageTokensGuess — сколько выходных токенов стоит одна картинка 1K, если
// сервис не прислал расход.
const imageTokensGuess = 1120

// ImageCostUSD — цена запроса по прайсу картинок Google.
func ImageCostUSD(model string, u Usage, ok bool) float64 {
	m := strings.ToLower(model)
	in, out := 0.5, 60.0 // незнакомая модель — как 3.1 Flash Image
	for _, p := range imagePrices {
		if strings.Contains(m, p.match) {
			in, out = p.in, p.out
			break
		}
	}
	o := u.Output
	if o == 0 && ok {
		o = imageTokensGuess
	}
	return (float64(max(u.Input, 0))*in + float64(max(o, 0))*out) / 1e6
}

// IsImageModel — по названию: модель Gemini, которая возвращает картинку.
func IsImageModel(id string) bool {
	s := strings.ToLower(id)
	return strings.Contains(s, "gemini") && (strings.Contains(s, "image") || strings.Contains(s, "nano-banana"))
}

// imageSearchOK — умеет ли модель искать в Google (у Lite и 2.5 Flash Image поиска нет).
func imageSearchOK(model string) bool {
	s := strings.ToLower(model)
	return !strings.Contains(s, "lite") && !strings.Contains(s, "2.5-flash-image")
}

// ImageAsk — что нарисовать: фото, инструкция, квадрат, размер, поиск в Google.
type ImageAsk struct {
	Prompt string
	Images []Image
	Aspect string // "1:1"
	Size   string // "" — по умолчанию (1K), "2K"
	Search bool
}

// ImageModels — модели ключа, которые рисуют картинки.
func (c Conn) ImageModels(ctx context.Context) ([]Model, error) {
	if c.Provider == ProviderVertex {
		if isJSONKey(c.Key) {
			if _, err := googleToken(ctx, c.Key); err != nil {
				return nil, err
			}
		}
		items := make([]Model, 0, len(imageModels))
		for _, id := range imageModels {
			items = append(items, Model{ID: id, Vision: boolp(true)})
		}
		return items, nil
	}
	items := []Model{}
	page := ""
	for i := 0; i < 5; i++ {
		var out struct {
			Models []struct {
				Name    string   `json:"name"`
				Methods []string `json:"supportedGenerationMethods"`
			} `json:"models"`
			Next string `json:"nextPageToken"`
		}
		path := "/models?pageSize=1000"
		if page != "" {
			path += "&pageToken=" + url.QueryEscape(page)
		}
		if err := c.do(ctx, http.MethodGet, path, nil, &out); err != nil {
			return nil, err
		}
		for _, m := range out.Models {
			id := strings.TrimPrefix(m.Name, "models/")
			gen := len(m.Methods) == 0
			for _, x := range m.Methods {
				gen = gen || x == "generateContent"
			}
			if id != "" && gen && IsImageModel(id) {
				items = append(items, Model{ID: id, Vision: boolp(true)})
			}
		}
		if page = out.Next; page == "" {
			break
		}
	}
	sort.SliceStable(items, func(i, j int) bool { return items[i].ID < items[j].ID })
	return items, nil
}

// GenerateImage — картинка от Gemini. Поиск в Google, если модель его не
// принимает, отключается и запрос повторяется.
func (c Conn) GenerateImage(ctx context.Context, ask ImageAsk) (Image, Usage, error) {
	if c.Model == "" {
		return Image{}, Usage{}, &ErrService{Msg: "не выбрана модель", MsgUz: "model tanlanmagan"}
	}
	search := ask.Search && imageSearchOK(c.Model)
	img, u, err := c.generateImage(ctx, ask, search)
	var se *ErrService
	if search && errors.As(err, &se) && se.Status == http.StatusBadRequest {
		var u2 Usage
		img, u2, err = c.generateImage(ctx, ask, false)
		u.Input += u2.Input
		u.Output += u2.Output
	}
	return img, u, err
}

func (c Conn) generateImage(ctx context.Context, ask ImageAsk, search bool) (Image, Usage, error) {
	parts := []map[string]any{}
	for _, im := range ask.Images {
		parts = append(parts, map[string]any{"inlineData": map[string]any{
			"mimeType": im.MIME, "data": base64.StdEncoding.EncodeToString(im.Data)}})
	}
	parts = append(parts, map[string]any{"text": ask.Prompt})
	imgCfg := map[string]any{}
	if ask.Aspect != "" {
		imgCfg["aspectRatio"] = ask.Aspect
	}
	if ask.Size != "" {
		imgCfg["imageSize"] = ask.Size
	}
	gen := map[string]any{"responseModalities": []string{"TEXT", "IMAGE"}}
	if len(imgCfg) > 0 {
		gen["imageConfig"] = imgCfg
	}
	body := map[string]any{
		"contents":         []map[string]any{{"role": "user", "parts": parts}},
		"generationConfig": gen,
	}
	if search {
		body["tools"] = []map[string]any{{"googleSearch": map[string]any{}}}
	}
	var out struct {
		Candidates []struct {
			Content struct {
				Parts []struct {
					Text       string `json:"text"`
					Thought    bool   `json:"thought"`
					InlineData *struct {
						MimeType string `json:"mimeType"`
						Data     string `json:"data"`
					} `json:"inlineData"`
				} `json:"parts"`
			} `json:"content"`
			FinishReason string `json:"finishReason"`
		} `json:"candidates"`
		PromptFeedback struct {
			BlockReason string `json:"blockReason"`
		} `json:"promptFeedback"`
		UsageMetadata struct {
			Prompt     int `json:"promptTokenCount"`
			Candidates int `json:"candidatesTokenCount"`
			Thoughts   int `json:"thoughtsTokenCount"`
		} `json:"usageMetadata"`
	}
	path := "/models/" + url.PathEscape(c.Model) + ":generateContent"
	if c.Provider == ProviderVertex {
		path = "/publishers/google/models/" + url.PathEscape(c.Model) + ":generateContent"
	}
	if err := c.do(ctx, http.MethodPost, path, body, &out); err != nil {
		return Image{}, Usage{}, err
	}
	u := Usage{Input: out.UsageMetadata.Prompt, Output: out.UsageMetadata.Candidates + out.UsageMetadata.Thoughts}
	if out.PromptFeedback.BlockReason != "" {
		return Image{}, u, &ErrService{Msg: "Gemini отказался обрабатывать фото (" + out.PromptFeedback.BlockReason + ")",
			MsgUz: "Gemini rasmni qayta ishlashdan bosh tortdi (" + out.PromptFeedback.BlockReason + ")"}
	}
	if len(out.Candidates) == 0 {
		return Image{}, u, &ErrService{Msg: "Gemini вернул пустой ответ", MsgUz: "Gemini boʻsh javob qaytardi"}
	}
	cand := out.Candidates[0]
	var img Image
	var text strings.Builder
	for _, p := range cand.Content.Parts {
		if p.Thought {
			continue
		}
		if p.InlineData != nil && p.InlineData.Data != "" {
			data, err := base64.StdEncoding.DecodeString(p.InlineData.Data)
			if err != nil {
				return Image{}, u, &ErrService{Msg: "Gemini прислал повреждённую картинку", MsgUz: "Gemini buzilgan rasm yubordi"}
			}
			img = Image{MIME: p.InlineData.MimeType, Data: data}
			continue
		}
		text.WriteString(p.Text)
	}
	if len(img.Data) > 0 {
		return img, u, nil
	}
	if t := strings.TrimSpace(text.String()); t != "" {
		if r := []rune(t); len(r) > 200 {
			t = string(r[:200]) + "…"
		}
		return Image{}, u, &ErrService{Msg: "Gemini не нарисовал фото: " + t, MsgUz: "Gemini rasm chizmadi: " + t}
	}
	switch cand.FinishReason {
	case "", "STOP":
		return Image{}, u, &ErrService{Msg: "Gemini не вернул фото — выбрана модель, которая не рисует картинки?",
			MsgUz: "Gemini rasm qaytarmadi — rasm chizmaydigan model tanlanganmi?"}
	default:
		return Image{}, u, &ErrService{Msg: "Gemini не нарисовал фото (" + cand.FinishReason + ")",
			MsgUz: "Gemini rasm chizmadi (" + cand.FinishReason + ")"}
	}
}
