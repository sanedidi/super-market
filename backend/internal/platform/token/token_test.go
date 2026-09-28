package token

import (
	"errors"
	"strings"
	"testing"
	"time"
)

func TestSignVerify(t *testing.T) {
	s := NewSigner("secret")
	tok, err := s.Sign(Claims{UserID: "u1", SessionID: "s1", App: "store"}, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	c, err := s.Verify(tok)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if c.UserID != "u1" || c.SessionID != "s1" || c.App != "store" {
		t.Errorf("claims = %+v", c)
	}
}

func TestVerifyRejects(t *testing.T) {
	s := NewSigner("secret")
	tok, _ := s.Sign(Claims{UserID: "u1"}, time.Minute)

	if _, err := NewSigner("other").Verify(tok); !errors.Is(err, ErrSignature) {
		t.Errorf("other secret: err = %v, want ErrSignature", err)
	}

	parts := strings.Split(tok, ".")
	forged := parts[0] + "." + parts[1] + "x." + parts[2]
	if _, err := s.Verify(forged); err == nil {
		t.Error("tampered payload accepted")
	}

	none := "eyJhbGciOiJub25lIn0." + parts[1] + "."
	if _, err := s.Verify(none); !errors.Is(err, ErrMalformed) {
		t.Errorf("alg=none: err = %v, want ErrMalformed", err)
	}

	s.now = func() time.Time { return time.Now().Add(2 * time.Minute) }
	if _, err := s.Verify(tok); !errors.Is(err, ErrExpired) {
		t.Errorf("expired: err = %v, want ErrExpired", err)
	}
}
