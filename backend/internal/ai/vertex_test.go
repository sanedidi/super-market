package ai

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func testServiceAccount(t *testing.T) string {
	t.Helper()
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(k)
	b, _ := json.MarshalIndent(map[string]string{
		"type": "service_account", "project_id": "sm-test", "private_key_id": "abc123ff",
		"private_key":  string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})),
		"client_email": "sm@sm-test.iam.gserviceaccount.com",
	}, "", "  ")
	return string(b)
}

func TestVertexURL(t *testing.T) {
	if g := VertexURL("p1", "global"); g != "https://aiplatform.googleapis.com/v1/projects/p1/locations/global" {
		t.Fatal(g)
	}
	if g := VertexURL("p1", "europe-west4"); g != "https://europe-west4-aiplatform.googleapis.com/v1/projects/p1/locations/europe-west4" {
		t.Fatal(g)
	}
}

func TestServiceAccountParse(t *testing.T) {
	key := testServiceAccount(t)
	if vertexProject(key) != "sm-test" || keyHint(key) != "23ff" {
		t.Fatalf("project=%q hint=%q", vertexProject(key), keyHint(key))
	}
	if _, err := parseServiceAccount(`{"type":"authorized_user"}`); err == nil {
		t.Fatal("not a service account must fail")
	}
	if keyHint("AIzaSyXXXX1234") != "1234" {
		t.Fatal("api key hint")
	}
}

func TestVertexGenerate(t *testing.T) {
	key := testServiceAccount(t)
	var tokenCalls int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/token":
			tokenCalls++
			body, _ := io.ReadAll(r.Body)
			f, _ := url.ParseQuery(string(body))
			parts := strings.Split(f.Get("assertion"), ".")
			if f.Get("grant_type") != "urn:ietf:params:oauth:grant-type:jwt-bearer" || len(parts) != 3 {
				w.WriteHeader(400)
				return
			}
			claims, _ := base64.RawURLEncoding.DecodeString(parts[1])
			if !strings.Contains(string(claims), "sm@sm-test.iam.gserviceaccount.com") {
				w.WriteHeader(400)
				return
			}
			_, _ = w.Write([]byte(`{"access_token":"tok-1","expires_in":3600}`))
		case r.URL.Path == "/v1/projects/sm-test/locations/global/publishers/google/models/gemini-2.5-flash:generateContent":
			if r.Header.Get("Authorization") != "Bearer tok-1" {
				w.WriteHeader(401)
				_, _ = w.Write([]byte(`{"error":{"code":401,"message":"bad token","status":"UNAUTHENTICATED"}}`))
				return
			}
			var in map[string]any
			_ = json.NewDecoder(r.Body).Decode(&in)
			parts := in["contents"].([]any)[0].(map[string]any)["parts"].([]any)
			if _, ok := parts[0].(map[string]any)["inlineData"]; !ok || in["systemInstruction"] == nil {
				w.WriteHeader(400)
				return
			}
			_, _ = w.Write([]byte(`{"candidates":[{"content":{"role":"model","parts":[{"text":"thinking","thought":true},{"text":"{\"name\":\"Coca-Cola\"}"}]},"finishReason":"STOP"}],
				"usageMetadata":{"promptTokenCount":1200,"candidatesTokenCount":35,"thoughtsTokenCount":15}}`))
		case strings.HasSuffix(r.URL.Path, "/publishers/google/models/gemini-2.5-pro:generateContent"):
			if r.Header.Get("x-goog-api-key") != "AIzaTEST" {
				w.WriteHeader(403)
				return
			}
			_, _ = w.Write([]byte(`{"promptFeedback":{"blockReason":"SAFETY"}}`))
		default:
			w.WriteHeader(404)
		}
	}))
	defer srv.Close()
	old := googleTokenURL
	googleTokenURL = srv.URL + "/token"
	defer func() { googleTokenURL = old }()

	c := Conn{Provider: ProviderVertex, BaseURL: srv.URL + "/v1/projects/sm-test/locations/global", Key: key, Model: "gemini-2.5-flash"}
	for i := 0; i < 2; i++ {
		text, u, err := c.Vision(context.Background(), "sys", "what is it?", []Image{{MIME: "image/jpeg", Data: []byte{1, 2, 3}}})
		if err != nil {
			t.Fatal(err)
		}
		if text != `{"name":"Coca-Cola"}` || u.Input != 1200 || u.Output != 50 {
			t.Fatalf("text=%q usage=%+v", text, u)
		}
	}
	if tokenCalls != 1 {
		t.Fatalf("token must be cached, calls=%d", tokenCalls)
	}

	models, err := c.Models(context.Background())
	if err != nil || len(models) == 0 || models[0].Vision == nil || !*models[0].Vision {
		t.Fatalf("models=%v err=%v", models, err)
	}

	api := Conn{Provider: ProviderVertex, BaseURL: srv.URL + "/v1", Key: "AIzaTEST", Model: "gemini-2.5-pro"}
	_, _, err = api.Vision(context.Background(), "sys", "x", nil)
	if se, ok := err.(*ErrService); !ok || !strings.Contains(se.Msg, "SAFETY") {
		t.Fatalf("err=%v", err)
	}
}
