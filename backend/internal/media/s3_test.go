package media

import (
	"net/http"
	"strings"
	"testing"
	"time"
)

// Пример «GET Object» из документации AWS Signature V4.
func TestSignAWSExample(t *testing.T) {
	req, _ := http.NewRequest(http.MethodGet, "https://examplebucket.s3.amazonaws.com/test.txt", nil)
	req.Header.Set("Range", "bytes=0-9")
	sign(req, nil, "AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "us-east-1",
		time.Date(2013, 5, 24, 0, 0, 0, 0, time.UTC))
	got := req.Header.Get("Authorization")
	want := "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " +
		"SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, " +
		"Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
	if got != want {
		t.Fatalf("authorization:\n got %s\nwant %s", got, want)
	}
}

func TestURIEncode(t *testing.T) {
	if got := uriEncode("a b/ф~.jpg", true); got != "a%20b/%D1%84~.jpg" {
		t.Fatal(got)
	}
	if strings.Contains(uriEncode("a/b", false), "/") {
		t.Fatal("slash kept")
	}
}
