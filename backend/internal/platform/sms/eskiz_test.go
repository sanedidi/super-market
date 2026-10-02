package sms

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestEskizSendRelogin(t *testing.T) {
	logins, sends := 0, 0
	var gotPhone, gotFrom string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		switch r.URL.Path {
		case "/api/auth/login":
			logins++
			if r.Form.Get("email") != "a@b.uz" {
				w.WriteHeader(401)
				return
			}
			_, _ = w.Write([]byte(`{"data":{"token":"t` + string(rune('0'+logins)) + `"}}`))
		case "/api/message/sms/send":
			sends++
			if r.Header.Get("Authorization") == "Bearer t1" {
				w.WriteHeader(401) // старый токен истёк
				return
			}
			gotPhone, gotFrom = r.Form.Get("mobile_phone"), r.Form.Get("from")
			_, _ = w.Write([]byte(`{"id":"1","status":"waiting"}`))
		}
	}))
	defer srv.Close()
	e := NewEskiz(srv.URL+"/api", "a@b.uz", "p", "")
	if err := e.Send(context.Background(), "+998901234567", "kod 123456"); err != nil {
		t.Fatal(err)
	}
	if logins != 2 || sends != 2 || gotPhone != "998901234567" || gotFrom != "4546" {
		t.Fatalf("logins=%d sends=%d phone=%s from=%s", logins, sends, gotPhone, gotFrom)
	}
}
