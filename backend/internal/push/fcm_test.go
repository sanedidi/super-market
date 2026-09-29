package push

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestFCM(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	tokenCalls := 0
	var sent map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/token":
			tokenCalls++
			_ = r.ParseForm()
			if r.Form.Get("grant_type") != "urn:ietf:params:oauth:grant-type:jwt-bearer" || strings.Count(r.Form.Get("assertion"), ".") != 2 {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			_, _ = w.Write([]byte(`{"access_token":"at-1","expires_in":3600}`))
		case "/send":
			if r.Header.Get("Authorization") != "Bearer at-1" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			_ = json.NewDecoder(r.Body).Decode(&sent)
			tok := sent["message"].(map[string]any)["token"]
			switch tok {
			case "gone":
				w.WriteHeader(http.StatusNotFound)
				_, _ = w.Write([]byte(`{"error":{"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}`))
			case "bad":
				w.WriteHeader(http.StatusBadRequest)
				_, _ = w.Write([]byte(`{"error":{"status":"INVALID_ARGUMENT","message":"bad token"}}`))
			case "busy":
				w.WriteHeader(http.StatusServiceUnavailable)
			default:
				_, _ = w.Write([]byte(`{"name":"projects/p/messages/1"}`))
			}
		}
	}))
	defer srv.Close()

	creds, _ := json.Marshal(map[string]string{
		"project_id": "p", "client_email": "sa@p.iam.gserviceaccount.com", "token_uri": srv.URL + "/token",
		"private_key": string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})),
	})
	// Ключ в base64 — как в .env.
	raw, err := LoadCredentials(base64.StdEncoding.EncodeToString(creds))
	if err != nil {
		t.Fatal(err)
	}
	f, err := NewFCM(raw)
	if err != nil {
		t.Fatal(err)
	}
	f.sendURL = srv.URL + "/send"
	ctx := context.Background()
	m := Message{Title: "T", Body: "B", Data: map[string]string{"order_id": "o1"}}

	if err := f.Send(ctx, "ok-token", m); err != nil {
		t.Fatal(err)
	}
	if err := f.Send(ctx, "ok-token", m); err != nil {
		t.Fatal(err)
	}
	if tokenCalls != 1 {
		t.Fatalf("access token must be cached, calls = %d", tokenCalls)
	}
	msg := sent["message"].(map[string]any)
	if msg["notification"].(map[string]any)["title"] != "T" || msg["data"].(map[string]any)["order_id"] != "o1" {
		t.Fatalf("payload = %v", sent)
	}
	if err := f.Send(ctx, "gone", m); !errors.Is(err, ErrUnregistered) {
		t.Fatalf("gone = %v", err)
	}
	if err := f.Send(ctx, "bad", m); !errors.Is(err, ErrPermanent) {
		t.Fatalf("bad = %v", err)
	}
	if err := f.Send(ctx, "busy", m); err == nil || errors.Is(err, ErrPermanent) || errors.Is(err, ErrUnregistered) {
		t.Fatalf("busy = %v", err)
	}
	if _, err := NewFCM([]byte(`{"project_id":"p"}`)); err == nil {
		t.Fatal("incomplete credentials accepted")
	}
}
