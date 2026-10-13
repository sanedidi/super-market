package start

// Нормализация фото для магазина (Figma «Нормализация фото для магазина»):
// Super Market сам делает чистое фото — после распознавания нового товара
// («Новые от Super Market» / «Требуют внимания») и после фото строки на
// «Инвентаризации», если у товара фото не было. Сами фото делает
// ai.PhotoService (очередь photo_jobs); здесь — когда ставить задание и куда
// класть готовое фото.
//
// Готовое фото встаёт первым, фото магазина остаются в товаре (их видит
// модератор). Если магазин успел поменять фото сам, готовое ложится вторым.

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/ai"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/media"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

const maxProductImages = 10

// NewItemPhoto — чистое фото карточки от Super Market (последнее задание).
//   - processing — Super Market делает фото;
//   - done — готово, Image — ключ фото (ссылку подставляет HTTP-слой);
//   - failed — не вышло, осталось фото магазина;
//   - limit — фото на этот месяц по тарифу закончились.
type NewItemPhoto struct {
	Status string  `json:"status"`
	Image  *string `json:"image"`
	Error  string  `json:"error"`
}

// newItemPhotoSQL — последнее задание карточки: {status, error, result}.
const newItemPhotoSQL = `(SELECT ARRAY[j.status, j.error, j.result] FROM photo_jobs j
	WHERE j.new_item_id = start_new_items.id ORDER BY j.created_at DESC LIMIT 1)`

func newItemPhoto(job []string) *NewItemPhoto {
	if len(job) != 3 {
		return nil
	}
	st := ai.JobState(job[0], job[1])
	if st == "" {
		return nil
	}
	ph := &NewItemPhoto{Status: st}
	switch st {
	case ai.JobDone:
		k := job[2]
		ph.Image = &k
	case ai.JobFailed:
		ph.Error = job[1]
	}
	return ph
}

// linePhotoSQL — фото строки инвентаризации: processing — Super Market
// делает, done — первым стоит его фото.
const linePhotoSQL = `(SELECT CASE WHEN j.status IN ('queued', 'processing') THEN 'processing'
	                            WHEN j.status = 'done' AND p.images[1] LIKE '%/' || j.result THEN 'done' ELSE '' END
	FROM photo_jobs j WHERE j.product_id = p.id ORDER BY j.created_at DESC LIMIT 1)`

// enqueuePhoto — поставить задание; Kick — после коммита (ok).
func (s *Service) enqueuePhoto(ctx context.Context, q db.Querier, j ai.StoreJob) (string, error) {
	if s.Photos == nil {
		return "", nil
	}
	return s.Photos.Enqueue(ctx, q, j)
}

func (s *Service) kickPhotos(status string) {
	if s.Photos != nil && status == ai.JobQueued {
		s.Photos.Kick()
	}
}

// photoNewItem — после распознавания: новый товар (не найден в базе) —
// Super Market делает его чистое фото из фото магазина.
func (s *Service) photoNewItem(ctx context.Context, id, networkID, storeID, employeeID string, keys []string) {
	var base string
	if err := s.pool.QueryRow(ctx, `SELECT media_base FROM start_new_items WHERE id = $1`, id).Scan(&base); err != nil {
		s.log.Error("фото нового товара", "id", id, "err", err)
		return
	}
	st, err := s.enqueuePhoto(ctx, s.pool, ai.StoreJob{NetworkID: networkID, StoreID: storeID, EmployeeID: employeeID,
		NewItemID: &id, Sources: keys, MediaBase: base})
	if err != nil {
		s.log.Error("фото нового товара", "id", id, "err", err)
		return
	}
	s.kickPhotos(st)
}

// RedoNewItemPhoto — «Переделать»: Super Market делает фото карточки ещё раз
// (это тоже фото по тарифу).
func (s *Service) RedoNewItemPhoto(ctx context.Context, p *identity.Principal, id string) (NewItem, error) {
	it, err := s.GetNewItem(ctx, p, id)
	if err != nil {
		return it, err
	}
	if err := require(p, it.StoreID); err != nil {
		return it, err
	}
	if it.Status == NewDone || it.Status == NewProcessing {
		return it, apperr.Conflict("not_ready", "карточка ещё распознаётся или уже добавлена").Uz("kartochka hali aniqlanmoqda yoki allaqachon qoʻshilgan")
	}
	if it.Photo != nil && it.Photo.Status == ai.JobProcessing {
		return it, nil
	}
	var st string
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var keys []string
		var base string
		if err := tx.QueryRow(ctx, `SELECT images, media_base FROM start_new_items WHERE id = $1 FOR UPDATE`, id).Scan(&keys, &base); err != nil {
			return err
		}
		if st, err = s.enqueuePhoto(ctx, tx, ai.StoreJob{NetworkID: p.NetworkID, StoreID: it.StoreID, EmployeeID: p.EmployeeID,
			NewItemID: &id, Sources: keys, MediaBase: base}); err != nil {
			return err
		}
		switch st {
		case "":
			return apperr.Conflict("photo_off", "Super Market сейчас не делает фото").Uz("Super Market hozir rasm tayyorlamaydi")
		case ai.JobSkipped:
			return apperr.Conflict("photo_limit", "Фото Super Market на этот месяц закончились").Uz("Bu oy uchun Super Market rasmlari tugadi")
		}
		return nil
	})
	if err != nil {
		return it, err
	}
	s.kickPhotos(st)
	return s.GetNewItem(ctx, p, id)
}

// confirmPhoto — карточку подтвердили (в транзакции ConfirmNewItem).
//   - «Это он» (товар базы) или магазин выбрал своё фото — недоделанные
//     задания отменяются;
//   - создан новый товар — задания карточки теперь его; готовое фото
//     встаёт первым.
func (s *Service) confirmPhoto(ctx context.Context, tx pgx.Tx, id, productID string, created, keepOwn bool) error {
	if !created || keepOwn {
		_, err := tx.Exec(ctx, `UPDATE photo_jobs SET status = 'skipped', error = $2 WHERE new_item_id = $1 AND status IN ('queued', 'processing')`,
			id, ai.SkipCancelled)
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE photo_jobs SET product_id = $2 WHERE new_item_id = $1`, id, productID); err != nil {
		return err
	}
	var result, base string
	var sources []string
	err := tx.QueryRow(ctx, `SELECT result, sources, media_base FROM photo_jobs WHERE new_item_id = $1 AND status = 'done' ORDER BY created_at DESC LIMIT 1`, id).
		Scan(&result, &sources, &base)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	return s.putClean(ctx, tx, productID, sources, s.media.URLWithBase(base, result))
}

// ApplyStorePhoto — готовое фото задания (ai.PhotoService.OnStoreDone):
// отметить задание и положить фото. Карточка ещё не подтверждена — фото
// ждёт в ней (магазин видит «до / после»); подтверждена — встаёт в товар.
func (s *Service) ApplyStorePhoto(ctx context.Context, d ai.StoreDone) error {
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		productID := d.ProductID
		if d.NewItemID != nil {
			// Карточка — первой: ConfirmNewItem блокирует её же, потом задания.
			var status string
			var pid *string
			err := tx.QueryRow(ctx, `SELECT status, product_id FROM start_new_items WHERE id = $1 FOR UPDATE`, *d.NewItemID).Scan(&status, &pid)
			if errors.Is(err, pgx.ErrNoRows) {
				return nil
			}
			if err != nil {
				return err
			}
			productID = nil
			if status == NewDone {
				productID = pid
			}
		}
		tag, err := tx.Exec(ctx, `UPDATE photo_jobs SET status = 'done', result = $2, error = '' WHERE id = $1 AND status = 'processing'`, d.ID, d.Result)
		if err != nil || tag.RowsAffected() == 0 || productID == nil {
			return err
		}
		return s.putClean(ctx, tx, *productID, d.Sources, s.media.URLWithBase(d.MediaBase, d.Result))
	})
}

// putClean — чистое фото в товар: первым, если первым стоит фото магазина
// из задания (или фото нет); иначе — вторым (магазин успел поменять фото).
func (s *Service) putClean(ctx context.Context, tx pgx.Tx, productID string, sources []string, url string) error {
	key, ok := media.KeyFromURL(url)
	if url == "" || !ok {
		s.log.Warn("фото магазина: нет ссылки на готовое фото (MEDIA_BASE_URL)", "product", productID)
		return nil
	}
	var imgs []string
	err := tx.QueryRow(ctx, `SELECT COALESCE(images, '{}') FROM products WHERE id = $1 FOR UPDATE`, productID).Scan(&imgs)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, u := range imgs {
		if k, _ := media.KeyFromURL(u); k == key {
			return nil
		}
	}
	first := ""
	if len(imgs) > 0 {
		first, _ = media.KeyFromURL(imgs[0])
	}
	switch {
	case len(imgs) == 0 || (len(sources) > 0 && first == sources[0]):
		imgs = append([]string{url}, imgs...)
	default:
		imgs = append(imgs[:1], append([]string{url}, imgs[1:]...)...)
	}
	if len(imgs) > maxProductImages {
		imgs = imgs[:maxProductImages]
	}
	_, err = tx.Exec(ctx, `UPDATE products SET images = $2 WHERE id = $1`, productID, imgs)
	return err
}

// PhotoQuota — фото Super Market в этом месяце (плашка «закончились», «Тариф»).
func (s *Service) PhotoQuota(ctx context.Context, p *identity.Principal, storeID string) (ai.StoreQuota, error) {
	if _, err := s.store(ctx, s.pool, p, storeID); err != nil {
		return ai.StoreQuota{}, err
	}
	if s.Photos == nil {
		return ai.StoreQuota{}, nil
	}
	return s.Photos.Quota(ctx, p.NetworkID)
}

// photoSources — ключи фото для задания строки инвентаризации.
func photoSources(images []string) (keys []string, base string) {
	for _, u := range images {
		if k, ok := media.KeyFromURL(u); ok {
			keys = append(keys, k)
		}
	}
	if len(images) > 0 {
		base = media.BaseOf(images[0])
	}
	return keys, base
}
