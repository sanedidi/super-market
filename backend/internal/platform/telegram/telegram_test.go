package telegram

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestClient(t *testing.T) {
	var gotPath string
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		switch {
		case strings.HasSuffix(r.URL.Path, "/getUpdates"):
			_, _ = w.Write([]byte(`{"ok":true,"result":[{"update_id":7,"message":{"message_id":1,
				"from":{"id":5},"chat":{"id":5,"type":"private"},"contact":{"phone_number":"998901112233","user_id":5}}}]}`))
		case strings.HasSuffix(r.URL.Path, "/getMe"):
			_, _ = w.Write([]byte(`{"ok":true,"result":{"id":1,"username":"market_bot"}}`))
		case strings.HasSuffix(r.URL.Path, "/sendMessage"):
			if gotBody["chat_id"] == float64(0) {
				_, _ = w.Write([]byte(`{"ok":false,"description":"Bad Request: chat not found"}`))
				return
			}
			_, _ = w.Write([]byte(`{"ok":true,"result":{}}`))
		}
	}))
	defer srv.Close()
	c := New("TOKEN", srv.URL)
	ctx := context.Background()

	if err := c.SendMessage(ctx, 42, "hi", &ReplyMarkup{RemoveKeyboard: true}); err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	if gotPath != "/botTOKEN/sendMessage" || gotBody["text"] != "hi" || gotBody["reply_markup"] == nil {
		t.Errorf("request path %q body %v", gotPath, gotBody)
	}
	if err := c.SendMessage(ctx, 0, "x", nil); err == nil || !strings.Contains(err.Error(), "chat not found") {
		t.Errorf("api error not surfaced: %v", err)
	}

	ups, err := c.GetUpdates(ctx, 3, 10*time.Second)
	if err != nil || len(ups) != 1 || ups[0].Message.Contact.PhoneNumber != "998901112233" {
		t.Fatalf("GetUpdates = %+v, %v", ups, err)
	}
	if gotBody["offset"] != float64(3) || gotBody["timeout"] != float64(10) {
		t.Errorf("getUpdates body %v", gotBody)
	}

	me, err := c.GetMe(ctx)
	if err != nil || me.Username != "market_bot" {
		t.Fatalf("GetMe = %+v, %v", me, err)
	}
}
