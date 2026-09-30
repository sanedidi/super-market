// Package media — загрузка фото (товары, логотипы, баннеры) в MinIO (S3) и
// раздача их по ссылке /api/v1/media/<ключ>.
//
// S3-клиент минимальный и без зависимостей: подпись AWS Signature V4,
// path-style адреса (http://minio:9000/<bucket>/<key>) — так работает MinIO.
package media

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

// S3 — клиент одного бакета.
type S3 struct {
	Endpoint  string // http://minio:9000
	AccessKey string
	SecretKey string
	Bucket    string
	Region    string // MinIO по умолчанию us-east-1
	HTTP      *http.Client
	now       func() time.Time
}

// ErrNotFound — объекта нет в бакете.
var ErrNotFound = errors.New("media: объект не найден")

func (c *S3) client() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return http.DefaultClient
}

func (c *S3) region() string {
	if c.Region == "" {
		return "us-east-1"
	}
	return c.Region
}

// objectURL — адрес объекта; key уже безопасный (буквы, цифры, / . - _).
func (c *S3) objectURL(key string) string {
	u := strings.TrimRight(c.Endpoint, "/") + "/" + c.Bucket
	if key != "" {
		u += "/" + key
	}
	return u
}

func (c *S3) do(ctx context.Context, method, rawURL string, body []byte, contentType string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, method, rawURL, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	if body == nil {
		req.Body = http.NoBody
	}
	req.ContentLength = int64(len(body))
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	now := time.Now
	if c.now != nil {
		now = c.now
	}
	sign(req, body, c.AccessKey, c.SecretKey, c.region(), now().UTC())
	return c.client().Do(req)
}

// EnsureBucket создаёт бакет, если его нет.
func (c *S3) EnsureBucket(ctx context.Context) error {
	res, err := c.do(ctx, http.MethodHead, c.objectURL(""), nil, "")
	if err != nil {
		return err
	}
	res.Body.Close()
	if res.StatusCode == http.StatusOK {
		return nil
	}
	if res.StatusCode != http.StatusNotFound {
		return fmt.Errorf("media: проверка бакета %s: HTTP %d", c.Bucket, res.StatusCode)
	}
	res, err = c.do(ctx, http.MethodPut, c.objectURL(""), nil, "")
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK && res.StatusCode != http.StatusConflict {
		b, _ := io.ReadAll(io.LimitReader(res.Body, 512))
		return fmt.Errorf("media: создание бакета %s: HTTP %d %s", c.Bucket, res.StatusCode, b)
	}
	return nil
}

// Put кладёт объект.
func (c *S3) Put(ctx context.Context, key, contentType string, body []byte) error {
	res, err := c.do(ctx, http.MethodPut, c.objectURL(key), body, contentType)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(res.Body, 512))
		return fmt.Errorf("media: загрузка %s: HTTP %d %s", key, res.StatusCode, b)
	}
	return nil
}

// Get открывает объект; вызывающий закрывает Body.
func (c *S3) Get(ctx context.Context, key string) (*http.Response, error) {
	res, err := c.do(ctx, http.MethodGet, c.objectURL(key), nil, "")
	if err != nil {
		return nil, err
	}
	if res.StatusCode == http.StatusNotFound {
		res.Body.Close()
		return nil, ErrNotFound
	}
	if res.StatusCode != http.StatusOK {
		res.Body.Close()
		return nil, fmt.Errorf("media: чтение %s: HTTP %d", key, res.StatusCode)
	}
	return res, nil
}

// ------------------------------------------------------------ Signature V4

func sha256Hex(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

func hmacSHA256(key []byte, data string) []byte {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(data))
	return m.Sum(nil)
}

// uriEncode — кодирование по правилам S3 (RFC 3986, «/» в пути сохраняется).
func uriEncode(s string, keepSlash bool) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '-', c == '_', c == '.', c == '~':
			b.WriteByte(c)
		case c == '/' && keepSlash:
			b.WriteByte(c)
		default:
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

// sign подписывает запрос заголовком Authorization (AWS4-HMAC-SHA256).
func sign(req *http.Request, body []byte, accessKey, secretKey, region string, t time.Time) {
	amzDate := t.Format("20060102T150405Z")
	day := t.Format("20060102")
	payloadHash := sha256Hex(body)
	req.Header.Set("X-Amz-Date", amzDate)
	req.Header.Set("X-Amz-Content-Sha256", payloadHash)

	host := req.URL.Host
	headers := map[string]string{"host": host}
	for k, v := range req.Header {
		lk := strings.ToLower(k)
		if lk == "content-type" || lk == "range" || strings.HasPrefix(lk, "x-amz-") {
			headers[lk] = strings.TrimSpace(strings.Join(v, ","))
		}
	}
	names := make([]string, 0, len(headers))
	for k := range headers {
		names = append(names, k)
	}
	sort.Strings(names)
	var canonHeaders strings.Builder
	for _, k := range names {
		canonHeaders.WriteString(k + ":" + headers[k] + "\n")
	}
	signed := strings.Join(names, ";")

	path := req.URL.EscapedPath()
	if u, err := url.PathUnescape(path); err == nil {
		path = uriEncode(u, true)
	}
	if path == "" {
		path = "/"
	}
	q := req.URL.Query()
	keys := make([]string, 0, len(q))
	for k := range q {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		vs := append([]string{}, q[k]...)
		sort.Strings(vs)
		for _, v := range vs {
			parts = append(parts, uriEncode(k, false)+"="+uriEncode(v, false))
		}
	}

	canonical := strings.Join([]string{req.Method, path, strings.Join(parts, "&"), canonHeaders.String(), signed, payloadHash}, "\n")
	scope := day + "/" + region + "/s3/aws4_request"
	toSign := "AWS4-HMAC-SHA256\n" + amzDate + "\n" + scope + "\n" + sha256Hex([]byte(canonical))

	k := hmacSHA256([]byte("AWS4"+secretKey), day)
	k = hmacSHA256(k, region)
	k = hmacSHA256(k, "s3")
	k = hmacSHA256(k, "aws4_request")
	sig := hex.EncodeToString(hmacSHA256(k, toSign))
	req.Header.Set("Authorization", fmt.Sprintf("AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s", accessKey, scope, signed, sig))
}
