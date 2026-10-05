package catalog

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/draw"
	_ "image/gif" // декодеры фото источника
	"image/jpeg"
	_ "image/png"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Фото для импортированных товаров: воркер берёт задачи из product_photo_jobs,
// спрашивает у tasnif.soliq.uz имена фото по ИКПУ, скачивает, уменьшает до
// 1000 px по большей стороне и кладёт в хранилище. Фото ставятся товару,
// только если у него ещё нет своих.

// Uploader — хранилище фото (media.Service).
type Uploader interface {
	Upload(ctx context.Context, data []byte) (string, error)
}

type PhotoFetcher struct {
	pool       *pgxpool.Pool
	store      Uploader
	mediaBase  string // https://api.super-market.uz → ссылки …/api/v1/media/<ключ>
	tasnif     string // https://tasnif.soliq.uz
	client     *http.Client
	perProduct int
	parallel   int
	log        *slog.Logger
}

const (
	photoMaxSide     = 1000
	photoMaxAttempts = 5
	photoMaxDownload = 20 << 20
)

func NewPhotoFetcher(pool *pgxpool.Pool, store Uploader, mediaBase, tasnif string, perProduct int, log *slog.Logger) *PhotoFetcher {
	if tasnif == "" {
		tasnif = "https://tasnif.soliq.uz"
	}
	if perProduct <= 0 {
		perProduct = 1
	}
	return &PhotoFetcher{
		pool: pool, store: store, mediaBase: strings.TrimRight(mediaBase, "/"), tasnif: strings.TrimRight(tasnif, "/"),
		client: &http.Client{Timeout: 60 * time.Second}, perProduct: perProduct, parallel: 4, log: log,
	}
}

// Run — обрабатывает очередь, пока не отменён контекст. Пустая очередь — пауза idle.
func (f *PhotoFetcher) Run(ctx context.Context, idle time.Duration) {
	// Задачи, взятые до перезапуска, возвращаем в очередь.
	if _, err := f.pool.Exec(ctx, `UPDATE product_photo_jobs SET status = 'pending' WHERE status = 'working'`); err != nil {
		f.log.Error("фото: сброс задач", "err", err)
	}
	for {
		n, err := f.Batch(ctx, 20)
		if err != nil && ctx.Err() == nil {
			f.log.Error("фото товаров", "err", err)
		}
		wait := time.Duration(0)
		if n == 0 || err != nil {
			wait = idle
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
	}
}

type photoJob struct {
	productID string
	ref       string
	attempts  int
}

// Batch — взять до limit задач и обработать. Возвращает, сколько взято.
func (f *PhotoFetcher) Batch(ctx context.Context, limit int) (int, error) {
	rows, err := f.pool.Query(ctx, `
		UPDATE product_photo_jobs j SET status = 'working', attempts = j.attempts + 1, updated_at = now()
		WHERE j.product_id IN (
			SELECT product_id FROM product_photo_jobs
			WHERE status = 'pending' AND next_at <= now()
			ORDER BY next_at LIMIT $1 FOR UPDATE SKIP LOCKED)
		RETURNING j.product_id, j.ref, j.attempts`, limit)
	if err != nil {
		return 0, err
	}
	jobs, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (photoJob, error) {
		var j photoJob
		err := r.Scan(&j.productID, &j.ref, &j.attempts)
		return j, err
	})
	if err != nil {
		return 0, err
	}
	ch := make(chan photoJob)
	var wg sync.WaitGroup
	for i := 0; i < f.parallel; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range ch {
				f.process(ctx, j)
			}
		}()
	}
	for _, j := range jobs {
		ch <- j
	}
	close(ch)
	wg.Wait()
	return len(jobs), nil
}

func (f *PhotoFetcher) process(ctx context.Context, j photoJob) {
	urls, err := f.fetch(ctx, j.ref)
	switch {
	case err != nil:
		status, next := "pending", time.Now().Add(time.Duration(j.attempts)*10*time.Minute)
		if j.attempts >= photoMaxAttempts {
			status = "failed"
		}
		msg := err.Error()
		if len(msg) > 500 {
			msg = msg[:500]
		}
		if _, dbErr := f.pool.Exec(context.WithoutCancel(ctx), `
			UPDATE product_photo_jobs SET status = $2, error = $3, next_at = $4, updated_at = now() WHERE product_id = $1`,
			j.productID, status, msg, next); dbErr != nil {
			f.log.Error("фото: запись ошибки", "err", dbErr)
		}
	case len(urls) == 0:
		if _, dbErr := f.pool.Exec(ctx, `
			UPDATE product_photo_jobs SET status = 'none', error = '', updated_at = now() WHERE product_id = $1`, j.productID); dbErr != nil {
			f.log.Error("фото: запись", "err", dbErr)
		}
	default:
		err := pgx.BeginFunc(ctx, f.pool, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `UPDATE products SET images = $2 WHERE id = $1 AND cardinality(images) = 0`, j.productID, urls); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `
				UPDATE product_photo_jobs SET status = 'done', photos = $2, error = '', updated_at = now() WHERE product_id = $1`,
				j.productID, len(urls))
			return err
		})
		if err != nil {
			f.log.Error("фото: сохранение", "err", err)
		}
	}
}

// fetch — скачать, уменьшить и сохранить фото товара. Пустой список — фото нет.
func (f *PhotoFetcher) fetch(ctx context.Context, ikpu string) ([]string, error) {
	q := url.Values{"lang": {"ru"}, "mxik_code": {ikpu}}
	body, err := f.get(ctx, f.tasnif+"/api/cls-api/integration-mxik/references/get/mxik/picture-names?"+q.Encode())
	if err != nil {
		return nil, fmt.Errorf("список фото: %w", err)
	}
	var names []string
	if err := json.Unmarshal(body, &names); err != nil {
		return nil, fmt.Errorf("список фото: %w", err)
	}
	out := []string{}
	for _, name := range names {
		if len(out) >= f.perProduct {
			break
		}
		if name == "" || strings.ContainsAny(name, "/\\?#") {
			continue
		}
		raw, err := f.get(ctx, f.tasnif+"/api/cls-api/integration-mxik/references/get/file/"+url.PathEscape(name))
		if err != nil {
			return nil, fmt.Errorf("фото %s: %w", name, err)
		}
		img, err := shrinkPhoto(raw)
		if err != nil {
			f.log.Warn("фото: не картинка", "file", name, "err", err)
			continue
		}
		key, err := f.store.Upload(ctx, img)
		if err != nil {
			return nil, fmt.Errorf("хранилище: %w", err)
		}
		out = append(out, f.mediaBase+"/api/v1/media/"+key)
	}
	return out, nil
}

func (f *PhotoFetcher) get(ctx context.Context, u string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "SuperMarket/1.0 (+https://super-market.uz)")
	resp, err := f.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, photoMaxDownload+1))
	if err != nil {
		return nil, err
	}
	if len(data) > photoMaxDownload {
		return nil, errors.New("файл больше 20 МБ")
	}
	return data, nil
}

// shrinkPhoto — JPEG не больше photoMaxSide по большей стороне, белый фон
// вместо прозрачного.
func shrinkPhoto(raw []byte) ([]byte, error) {
	src, _, err := image.Decode(bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	if w == 0 || h == 0 {
		return nil, errors.New("пустая картинка")
	}
	rgba := image.NewRGBA(image.Rect(0, 0, w, h))
	draw.Draw(rgba, rgba.Bounds(), image.White, image.Point{}, draw.Src)
	draw.Draw(rgba, rgba.Bounds(), src, b.Min, draw.Over)
	dst := rgba
	if w > photoMaxSide || h > photoMaxSide {
		nw, nh := photoMaxSide, h*photoMaxSide/w
		if h > w {
			nw, nh = w*photoMaxSide/h, photoMaxSide
		}
		dst = boxResize(rgba, max(nw, 1), max(nh, 1))
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, dst, &jpeg.Options{Quality: 85}); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// boxResize — уменьшение усреднением пикселей (без внешних библиотек).
func boxResize(src *image.RGBA, nw, nh int) *image.RGBA {
	w, h := src.Bounds().Dx(), src.Bounds().Dy()
	dst := image.NewRGBA(image.Rect(0, 0, nw, nh))
	for y := 0; y < nh; y++ {
		y0, y1 := y*h/nh, (y+1)*h/nh
		if y1 <= y0 {
			y1 = y0 + 1
		}
		for x := 0; x < nw; x++ {
			x0, x1 := x*w/nw, (x+1)*w/nw
			if x1 <= x0 {
				x1 = x0 + 1
			}
			var r, g, bl, a, n uint64
			for yy := y0; yy < y1; yy++ {
				off := yy*src.Stride + x0*4
				for xx := x0; xx < x1; xx++ {
					p := src.Pix[off : off+4 : off+4]
					r += uint64(p[0])
					g += uint64(p[1])
					bl += uint64(p[2])
					a += uint64(p[3])
					n++
					off += 4
				}
			}
			d := dst.PixOffset(x, y)
			dst.Pix[d] = uint8(r / n)
			dst.Pix[d+1] = uint8(g / n)
			dst.Pix[d+2] = uint8(bl / n)
			dst.Pix[d+3] = uint8(a / n)
		}
	}
	return dst
}
