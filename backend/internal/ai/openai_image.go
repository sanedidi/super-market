package ai

// Картинки от OpenAI («ИИ для фото», способ openai): модели GPT Image.
//
//	POST {base}/images/edits — multipart: model, image[] (фото товара), prompt,
//	     size, quality (low | medium | high), output_format = png;
//	     ответ — data[0].b64_json и usage (input_tokens, output_tokens).
//	GET  {base}/models — модели ключа; рисуют те, в названии которых «image».
//
// Поиска в интернете при рисовании у OpenAI нет — ImageAsk.Search не
// учитывается. Проверка «Фото из сети» идёт текстовой моделью GPT-…-mini
// того же ключа через chat/completions (Conn.Vision).

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Качество картинки OpenAI (настройка «Качество»; у Gemini не используется).
const (
	QualityLow    = "low"
	QualityMedium = "medium"
	QualityHigh   = "high"
)

// isOpenAIImageModel — модель OpenAI, которая рисует картинки.
func isOpenAIImageModel(id string) bool {
	s := strings.ToLower(id)
	return strings.Contains(s, "gpt-image") || strings.Contains(s, "chatgpt-image")
}

// openaiImagePrices — прайс OpenAI для GPT Image (USD за 1 млн токенов):
// вход — по цене картинок (фото товара — основная часть входа), выход — картинка.
var openaiImagePrices = []struct {
	match   string
	in, out float64
}{
	{"mini", 2.5, 8},
	{"gpt-image-1.5", 8, 32},
	{"gpt-image-1", 10, 40},
	{"gpt-image", 8, 32},
	{"chatgpt-image", 8, 32},
}

// openaiTokensGuess — выходные токены квадрата 1024 по качеству, если сервис
// не прислал расход.
var openaiTokensGuess = map[string]int{QualityLow: 272, QualityMedium: 1056, QualityHigh: 4160}

func openaiImageCostUSD(model string, u Usage, ok bool) float64 {
	m := strings.ToLower(model)
	in, out := 8.0, 32.0
	for _, p := range openaiImagePrices {
		if strings.Contains(m, p.match) {
			in, out = p.in, p.out
			break
		}
	}
	o := u.Output
	if o == 0 && ok {
		o = openaiTokensGuess[QualityMedium]
	}
	return (float64(max(u.Input, 0))*in + float64(max(o, 0))*out) / 1e6
}

// openaiModelIDs — все модели ключа OpenAI.
func (c Conn) openaiModelIDs(ctx context.Context) ([]string, error) {
	var out struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := c.do(ctx, http.MethodGet, "/models", nil, &out); err != nil {
		return nil, err
	}
	ids := make([]string, 0, len(out.Data))
	for _, m := range out.Data {
		if m.ID != "" {
			ids = append(ids, m.ID)
		}
	}
	return ids, nil
}

// openaiImageModels — модели ключа, которые рисуют картинки (новые сверху).
func (c Conn) openaiImageModels(ctx context.Context) ([]Model, error) {
	ids, err := c.openaiModelIDs(ctx)
	if err != nil {
		return nil, err
	}
	items := []Model{}
	for _, id := range ids {
		if isOpenAIImageModel(id) {
			items = append(items, Model{ID: id, Vision: boolp(true)})
		}
	}
	sort.SliceStable(items, func(i, j int) bool { return items[i].ID > items[j].ID })
	return items, nil
}

var openaiMiniRe = regexp.MustCompile(`^gpt-(\d+(?:\.\d+)?)(?:o)?-mini$`)

// pickOpenAICheckModel — самая новая GPT-…-mini для проверки фото (дешевле картинок).
func pickOpenAICheckModel(ids []string) string {
	best, bestV := "", -1.0
	for _, id := range ids {
		m := openaiMiniRe.FindStringSubmatch(strings.ToLower(id))
		if m == nil {
			continue
		}
		v, _ := strconv.ParseFloat(m[1], 64)
		if v > bestV {
			best, bestV = id, v
		}
	}
	return best
}

// openaiSize — сторона квадрата для OpenAI: дальше сервер сам доводит до размера из настроек.
func openaiSize(size string) string {
	if size == "2K" {
		return "2048x2048"
	}
	return "1024x1024"
}

// openaiGenerateImage — фото товара через images/edits.
func (c Conn) openaiGenerateImage(ctx context.Context, ask ImageAsk) (Image, Usage, error) {
	quality := ask.Quality
	if quality != QualityLow && quality != QualityHigh {
		quality = QualityMedium
	}
	img, u, err := c.openaiEdit(ctx, ask, quality, openaiSize(ask.Size))
	// Модель не умеет 2048 — повторяем в 1024 (сервер увеличит сам).
	var se *ErrService
	if err != nil && ask.Size == "2K" && asErr(err, &se) && se.Status == http.StatusBadRequest {
		var u2 Usage
		img, u2, err = c.openaiEdit(ctx, ask, quality, "1024x1024")
		u.Input += u2.Input
		u.Output += u2.Output
	}
	return img, u, err
}

func asErr(err error, se **ErrService) bool {
	e, ok := err.(*ErrService)
	if ok {
		*se = e
	}
	return ok
}

func (c Conn) openaiEdit(ctx context.Context, ask ImageAsk, quality, size string) (Image, Usage, error) {
	var body bytes.Buffer
	w := multipart.NewWriter(&body)
	_ = w.WriteField("model", c.Model)
	_ = w.WriteField("prompt", ask.Prompt)
	_ = w.WriteField("n", "1")
	_ = w.WriteField("size", size)
	_ = w.WriteField("quality", quality)
	_ = w.WriteField("output_format", "png")
	for i, im := range ask.Images {
		ext := "jpg"
		switch im.MIME {
		case "image/png":
			ext = "png"
		case "image/webp":
			ext = "webp"
		}
		h := textproto.MIMEHeader{}
		h.Set("Content-Disposition", fmt.Sprintf(`form-data; name="image[]"; filename="photo%d.%s"`, i+1, ext))
		h.Set("Content-Type", im.MIME)
		pw, err := w.CreatePart(h)
		if err != nil {
			return Image{}, Usage{}, err
		}
		if _, err := pw.Write(im.Data); err != nil {
			return Image{}, Usage{}, err
		}
	}
	if err := w.Close(); err != nil {
		return Image{}, Usage{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.base()+"/images/edits", &body)
	if err != nil {
		return Image{}, Usage{}, &ErrService{Msg: "неверный адрес сервиса", MsgUz: "xizmat manzili notoʻgʻri"}
	}
	req.Header.Set("Content-Type", w.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+c.Key)
	resp, err := client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return Image{}, Usage{}, &ErrService{Msg: "OpenAI не ответил вовремя", MsgUz: "OpenAI oʻz vaqtida javob bermadi", Temporary: true}
		}
		return Image{}, Usage{}, &ErrService{Msg: "не удалось подключиться к OpenAI: проверьте адрес", MsgUz: "OpenAIga ulanib boʻlmadi: manzilni tekshiring", Temporary: true}
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 60<<20))
	if resp.StatusCode/100 != 2 {
		msg := serviceError(resp.StatusCode, raw)
		return Image{}, Usage{}, &ErrService{Status: resp.StatusCode, Msg: msg.RU, MsgUz: msg.UZ, Temporary: resp.StatusCode >= 500 || resp.StatusCode == 429}
	}
	var out struct {
		Data []struct {
			B64 string `json:"b64_json"`
		} `json:"data"`
		Usage struct {
			Input  int `json:"input_tokens"`
			Output int `json:"output_tokens"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return Image{}, Usage{}, &ErrService{Msg: "OpenAI вернул непонятный ответ", MsgUz: "OpenAI tushunarsiz javob qaytardi"}
	}
	u := Usage{Input: out.Usage.Input, Output: out.Usage.Output}
	if len(out.Data) == 0 || out.Data[0].B64 == "" {
		return Image{}, u, &ErrService{Msg: "OpenAI не вернул фото — выбрана модель, которая не рисует картинки?",
			MsgUz: "OpenAI rasm qaytarmadi — rasm chizmaydigan model tanlanganmi?"}
	}
	data, err := base64.StdEncoding.DecodeString(out.Data[0].B64)
	if err != nil {
		return Image{}, u, &ErrService{Msg: "OpenAI прислал повреждённую картинку", MsgUz: "OpenAI buzilgan rasm yubordi"}
	}
	return Image{MIME: "image/png", Data: data}, u, nil
}

// ServiceName — как называть сервис фото в сообщениях.
func ServiceName(provider string) string {
	if provider == ProviderOpenAI {
		return "OpenAI"
	}
	return "Gemini"
}
