package ai

// Инструменты (function calling): модель сама вызывает функции сервера —
// помощник в панели ходит в API магазина. Gemini (Vertex AI, Gemini API)
// и OpenAI-совместимые; Anthropic — пока нет.

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

// Tool — функция, которую модель может вызвать. Params — JSON-схема
// аргументов (type: object, properties, required).
type Tool struct {
	Name        string
	Description string
	Params      map[string]any
}

// ToolCall — модель просит вызвать функцию.
type ToolCall struct {
	ID   string
	Name string
	Args map[string]any
}

// ToolResult — что вернула функция (JSON или текст).
type ToolResult struct {
	ID      string
	Name    string
	Content string
}

// ChatMsg — реплика разговора: user (текст и вложения), model (текст или
// вызовы функций), tool (результаты вызовов).
type ChatMsg struct {
	Role    string
	Text    string
	Parts   []Part
	Calls   []ToolCall
	Results []ToolResult
}

// ChatReply — ответ модели: либо текст, либо вызовы функций (бывает и то и то).
type ChatReply struct {
	Text  string
	Calls []ToolCall
}

// Chat — ход разговора с инструментами.
func (c Conn) Chat(ctx context.Context, system string, msgs []ChatMsg, tools []Tool) (ChatReply, Usage, error) {
	if c.Model == "" {
		return ChatReply{}, Usage{}, &ErrService{Msg: "не выбрана модель", MsgUz: "model tanlanmagan"}
	}
	switch {
	case c.IsGoogle():
		return c.geminiChat(ctx, system, msgs, tools)
	case c.Provider == ProviderAnthropic:
		return ChatReply{}, Usage{}, &ErrService{Msg: "помощник с инструментами работает с Gemini (Vertex AI) или OpenAI", MsgUz: "asboblar bilan yordamchi Gemini (Vertex AI) yoki OpenAI bilan ishlaydi"}
	}
	return c.openaiChat(ctx, system, msgs, tools)
}

// ---------------------------------------------------------------- Gemini

func geminiSchema(v any) any {
	switch t := v.(type) {
	case map[string]any:
		out := map[string]any{}
		for k, x := range t {
			if k == "type" {
				if s, ok := x.(string); ok {
					out[k] = strings.ToUpper(s)
					continue
				}
			}
			out[k] = geminiSchema(x)
		}
		return out
	case []any:
		out := make([]any, len(t))
		for i, x := range t {
			out[i] = geminiSchema(x)
		}
		return out
	}
	return v
}

func (c Conn) geminiChat(ctx context.Context, system string, msgs []ChatMsg, tools []Tool) (ChatReply, Usage, error) {
	contents := []map[string]any{}
	for _, m := range msgs {
		parts := []map[string]any{}
		role := "user"
		switch m.Role {
		case "model":
			role = "model"
			if m.Text != "" {
				parts = append(parts, map[string]any{"text": m.Text})
			}
			for _, call := range m.Calls {
				parts = append(parts, map[string]any{"functionCall": map[string]any{"name": call.Name, "args": orEmpty(call.Args)}})
			}
		case "tool":
			for _, r := range m.Results {
				var resp any
				if json.Unmarshal([]byte(r.Content), &resp) != nil || resp == nil {
					resp = map[string]any{"result": r.Content}
				}
				if _, ok := resp.(map[string]any); !ok {
					resp = map[string]any{"result": resp}
				}
				parts = append(parts, map[string]any{"functionResponse": map[string]any{"name": r.Name, "response": resp}})
			}
		default:
			for _, p := range m.Parts {
				parts = append(parts, map[string]any{"inlineData": map[string]any{"mimeType": p.MIME, "data": base64.StdEncoding.EncodeToString(p.Data)}})
			}
			if m.Text != "" || len(parts) == 0 {
				parts = append(parts, map[string]any{"text": m.Text})
			}
		}
		contents = append(contents, map[string]any{"role": role, "parts": parts})
	}
	gen := map[string]any{"maxOutputTokens": vertexMaxOut}
	if !strings.HasPrefix(strings.ToLower(c.Model), "gemini-3") {
		gen["temperature"] = 0.2
	}
	body := map[string]any{"contents": contents, "generationConfig": gen}
	if system != "" {
		body["systemInstruction"] = map[string]any{"parts": []map[string]any{{"text": system}}}
	}
	if len(tools) > 0 {
		decls := []map[string]any{}
		for _, t := range tools {
			decls = append(decls, map[string]any{"name": t.Name, "description": t.Description, "parameters": geminiSchema(t.Params)})
		}
		body["tools"] = []map[string]any{{"functionDeclarations": decls}}
	}
	var out struct {
		Candidates []struct {
			Content struct {
				Parts []struct {
					Text         string `json:"text"`
					Thought      bool   `json:"thought"`
					FunctionCall *struct {
						Name string         `json:"name"`
						Args map[string]any `json:"args"`
					} `json:"functionCall"`
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
	path := "/publishers/google/models/" + url.PathEscape(c.Model) + ":generateContent"
	if c.Provider == ProviderGemini {
		path = "/models/" + url.PathEscape(c.Model) + ":generateContent"
	}
	if err := c.do(ctx, http.MethodPost, path, body, &out); err != nil {
		return ChatReply{}, Usage{}, err
	}
	u := Usage{Input: out.UsageMetadata.Prompt, Output: out.UsageMetadata.Candidates + out.UsageMetadata.Thoughts}
	if out.PromptFeedback.BlockReason != "" {
		return ChatReply{}, u, &ErrService{Msg: "Gemini отказался обрабатывать запрос (" + out.PromptFeedback.BlockReason + ")",
			MsgUz: "Gemini soʻrovni qayta ishlashdan bosh tortdi (" + out.PromptFeedback.BlockReason + ")"}
	}
	if len(out.Candidates) == 0 {
		return ChatReply{}, u, &ErrService{Msg: "модель вернула пустой ответ", MsgUz: "model boʻsh javob qaytardi"}
	}
	var rep ChatReply
	var b strings.Builder
	for i, p := range out.Candidates[0].Content.Parts {
		if p.FunctionCall != nil {
			rep.Calls = append(rep.Calls, ToolCall{ID: "call_" + itoa(i), Name: p.FunctionCall.Name, Args: p.FunctionCall.Args})
			continue
		}
		if !p.Thought {
			b.WriteString(p.Text)
		}
	}
	rep.Text = b.String()
	if rep.Text == "" && len(rep.Calls) == 0 {
		if out.Candidates[0].FinishReason == "MAX_TOKENS" {
			return rep, u, &ErrService{Msg: "модель не уложилась в лимит ответа", MsgUz: "model javob limitiga sigʻmadi"}
		}
		return rep, u, &ErrService{Msg: "модель вернула пустой ответ", MsgUz: "model boʻsh javob qaytardi"}
	}
	return rep, u, nil
}

func orEmpty(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	return m
}

func itoa(i int) string { return strconv.Itoa(i) }

// ---------------------------------------------------------------- OpenAI

func (c Conn) openaiChat(ctx context.Context, system string, msgs []ChatMsg, tools []Tool) (ChatReply, Usage, error) {
	messages := []map[string]any{{"role": "system", "content": system}}
	for _, m := range msgs {
		switch m.Role {
		case "model":
			am := map[string]any{"role": "assistant", "content": m.Text}
			if len(m.Calls) > 0 {
				calls := []map[string]any{}
				for _, call := range m.Calls {
					args, _ := json.Marshal(orEmpty(call.Args))
					calls = append(calls, map[string]any{"id": call.ID, "type": "function", "function": map[string]any{"name": call.Name, "arguments": string(args)}})
				}
				am["tool_calls"] = calls
			}
			messages = append(messages, am)
		case "tool":
			for _, r := range m.Results {
				messages = append(messages, map[string]any{"role": "tool", "tool_call_id": r.ID, "content": r.Content})
			}
		default:
			content := []map[string]any{{"type": "text", "text": m.Text}}
			for _, p := range m.Parts {
				if !strings.HasPrefix(p.MIME, "image/") {
					return ChatReply{}, Usage{}, &ErrService{
						Msg:   "голосовые понимает только Gemini — выберите Vertex AI в «ИИ-сервисе»",
						MsgUz: "ovozli xabarlarni faqat Gemini tushunadi — «SI xizmati»da Vertex AI ni tanlang"}
				}
				content = append(content, map[string]any{"type": "image_url", "image_url": map[string]any{
					"url": "data:" + p.MIME + ";base64," + base64.StdEncoding.EncodeToString(p.Data)}})
			}
			messages = append(messages, map[string]any{"role": "user", "content": content})
		}
	}
	body := map[string]any{"model": c.Model, "messages": messages}
	if len(tools) > 0 {
		list := []map[string]any{}
		for _, t := range tools {
			list = append(list, map[string]any{"type": "function", "function": map[string]any{"name": t.Name, "description": t.Description, "parameters": t.Params}})
		}
		body["tools"] = list
	}
	var out struct {
		Choices []struct {
			Message struct {
				Content   string `json:"content"`
				ToolCalls []struct {
					ID       string `json:"id"`
					Function struct {
						Name      string `json:"name"`
						Arguments string `json:"arguments"`
					} `json:"function"`
				} `json:"tool_calls"`
			} `json:"message"`
		} `json:"choices"`
		Usage struct {
			Prompt     int `json:"prompt_tokens"`
			Completion int `json:"completion_tokens"`
		} `json:"usage"`
	}
	if err := c.do(ctx, http.MethodPost, "/chat/completions", body, &out); err != nil {
		return ChatReply{}, Usage{}, err
	}
	u := Usage{Input: out.Usage.Prompt, Output: out.Usage.Completion}
	if len(out.Choices) == 0 {
		return ChatReply{}, u, &ErrService{Msg: "модель вернула пустой ответ", MsgUz: "model boʻsh javob qaytardi"}
	}
	msg := out.Choices[0].Message
	rep := ChatReply{Text: msg.Content}
	for i, tc := range msg.ToolCalls {
		args := map[string]any{}
		_ = json.Unmarshal([]byte(tc.Function.Arguments), &args)
		id := tc.ID
		if id == "" {
			id = "call_" + itoa(i)
		}
		rep.Calls = append(rep.Calls, ToolCall{ID: id, Name: tc.Function.Name, Args: args})
	}
	if rep.Text == "" && len(rep.Calls) == 0 {
		return rep, u, &ErrService{Msg: "модель вернула пустой ответ", MsgUz: "model boʻsh javob qaytardi"}
	}
	return rep, u, nil
}
