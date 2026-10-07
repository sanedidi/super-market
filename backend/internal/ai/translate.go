package ai

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// Перевод полей uz ↔ ru — кнопка «Перевести автоматически» у двуязычных
// полей (название товара, категории, описание…). Идёт через тот же
// ИИ-сервис, что и распознавание накладных; расход пишется в ai_usage
// с kind = "translate".

const (
	maxTranslateTexts = 50
	maxTranslateChars = 4000
)

const translateSystem = `You translate short texts for a grocery and retail platform in Uzbekistan
(product names, categories, descriptions, store texts) between Russian and Uzbek.
Uzbek is always in the Latin alphabet with typographic apostrophes: oʻ, gʻ (U+02BB) and ʼ (U+02BC).
Keep brand names, numbers, units, sizes and percentages unchanged. Keep it short and natural, as on a shop shelf.
Answer with JSON only: {"texts": ["...", ...]} — the same number of items, in the same order.`

// TranslateInput — POST /translate.
type TranslateInput struct {
	Texts []string `json:"texts"`
	// To — язык результата: "uz" или "ru".
	To string `json:"to"`
}

type TranslateResult struct {
	Texts []string `json:"texts"`
}

// Translate — перевести тексты моделью. Пустые строки остаются пустыми.
func (c Conn) Translate(ctx context.Context, texts []string, to string) ([]string, Usage, error) {
	target := "Uzbek (Latin script)"
	if to == i18n.RU {
		target = "Russian"
	}
	in, _ := json.Marshal(map[string]any{"to": target, "texts": texts})
	text, u, err := c.Vision(ctx, translateSystem, "Translate every item of \"texts\" into "+target+":\n"+string(in), nil)
	if err != nil {
		return nil, u, err
	}
	raw, err := ExtractJSON(text)
	if err != nil {
		return nil, u, &ErrService{Msg: "модель вернула перевод в неверном виде", MsgUz: "model tarjimani notoʻgʻri koʻrinishda qaytardi"}
	}
	var out TranslateResult
	if err := json.Unmarshal(raw, &out); err != nil || len(out.Texts) != len(texts) {
		return nil, u, &ErrService{Msg: "модель вернула перевод в неверном виде", MsgUz: "model tarjimani notoʻgʻri koʻrinishda qaytardi"}
	}
	for i := range out.Texts {
		if strings.TrimSpace(texts[i]) == "" {
			out.Texts[i] = ""
		} else {
			out.Texts[i] = strings.TrimSpace(out.Texts[i])
		}
	}
	return out.Texts, u, nil
}

// Translate — перевод для сотрудника магазина или супер-админа с учётом расхода.
func (s *Service) Translate(ctx context.Context, p *identity.Principal, in TranslateInput) (TranslateResult, error) {
	to := strings.ToLower(strings.TrimSpace(in.To))
	if to != i18n.UZ && to != i18n.RU {
		return TranslateResult{}, apperr.Validation("язык перевода: uz или ru").Uz("tarjima tili: uz yoki ru")
	}
	if len(in.Texts) == 0 {
		return TranslateResult{}, apperr.Validation("нет текста для перевода").Uz("tarjima uchun matn yoʻq")
	}
	if len(in.Texts) > maxTranslateTexts {
		return TranslateResult{}, apperr.Validation("слишком много строк за раз").Uz("bir martada juda koʻp qator")
	}
	total, empty := 0, true
	for _, t := range in.Texts {
		total += len([]rune(t))
		if strings.TrimSpace(t) != "" {
			empty = false
		}
	}
	if empty {
		return TranslateResult{}, apperr.Validation("нет текста для перевода").Uz("tarjima uchun matn yoʻq")
	}
	if total > maxTranslateChars {
		return TranslateResult{}, apperr.Validation("текст слишком длинный для перевода").Uz("matn tarjima uchun juda uzun")
	}
	conn, err := s.Conn(ctx)
	if err != nil {
		return TranslateResult{}, err
	}
	ctx2, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	texts, usage, err := conn.Translate(ctx2, in.Texts, to)
	if usage.Input+usage.Output > 0 || err == nil {
		rec := UsageRecord{Kind: "translate", Provider: conn.Provider, Model: conn.Model, Usage: usage, OK: err == nil}
		if p != nil && p.NetworkID != "" {
			rec.NetworkID = &p.NetworkID
		}
		if p != nil && p.EmployeeID != "" {
			rec.EmployeeID = &p.EmployeeID
		}
		_ = s.Record(context.WithoutCancel(ctx), rec)
	}
	if err != nil {
		return TranslateResult{}, AsAppErr(err)
	}
	return TranslateResult{Texts: texts}, nil
}

func (m *Module) translate(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in TranslateInput) (TranslateResult, error) {
		return m.svc.Translate(r.Context(), identity.FromContext(r.Context()), in)
	})
}
