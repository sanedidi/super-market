package start

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
)

// «Провести все» (Figma «Требуют внимания — кнопка «Провести все»», В1–В3):
// карточки, которые Super Market заполнил, магазин одной кнопкой ставит в
// «Мои товары» как есть — без открытия каждой. Проводятся:
//   - тот же штрихкод уже в базе — добавляется товар базы;
//   - остальное — новым товаром (свой, draft; на модерацию — при «Записать и
//     закрыть»), в том числе «Тот же товар, другой штрихкод?» и «Есть сомнения».
// Остаются в «Требуют внимания» для ручной проверки: нет категории из дерева
// (иначе Super Market разом насоздаёт категорий), похоже на дубль более
// ранней карточки в очереди (в том числе уже добавленной — иначе вторая
// карточка того же товара после первой создала бы второй товар), штрихкод с
// опечаткой, распознаётся и не удалось.

// NewItemsBulkInput — POST /store/start/new-items/confirm-all. DryRun —
// только посчитать (окно подтверждения). Limit — сколько провести за вызов
// (запрос живёт 30 секунд): клиент вызывает, пока Remaining > 0.
type NewItemsBulkInput struct {
	StoreID string `json:"store_id"`
	DryRun  bool   `json:"dry_run"`
	Limit   int    `json:"limit"`
}

// NewItemsLeft — что останется в «Требуют внимания» и почему.
type NewItemsLeft struct {
	NoCategory int `json:"no_category"`
	Duplicate  int `json:"duplicate"`
	Barcode    int `json:"barcode"`
	Processing int `json:"processing"`
	Failed     int `json:"failed"`
	Other      int `json:"other"`
}

type NewItemsBulk struct {
	// Ready — сколько можно провести (до этого вызова); Existing из них —
	// товар базы с тем же штрихкодом, остальные — новые товары.
	Ready    int `json:"ready"`
	Existing int `json:"existing"`
	// Added — проведено этим вызовом; Remaining — можно провести ещё.
	Added     int          `json:"added"`
	Remaining int          `json:"remaining"`
	Left      NewItemsLeft `json:"left"`
}

const (
	bulkLimit    = 100
	bulkExisting = "existing"
	bulkCreate   = "create"
)

type bulkCard struct {
	id, code string
	keys     []string
	res      NewItemResult
	action   string
	// dup — более ранняя карточка того же товара (для action пусто).
	dup string
}

// bulkDupQuery — как dupQuery, но более ранняя карточка может быть уже
// добавленной: её товар уже в «Моих товарах».
var bulkDupQuery = strings.Replace(dupQuery, "AND o.id <> x.id AND o.status <> 'done'", "AND o.id <> x.id", 1)

// bulkPlan — карточки «ready» магазина по порядку создания: что с каждой
// сделает «Провести все» (action пусто — останется) и итоги.
func (s *Service) bulkPlan(ctx context.Context, networkID, storeID string) ([]bulkCard, NewItemsBulk, error) {
	var out NewItemsBulk
	cnt, err := s.pool.Query(ctx, `
		SELECT CASE WHEN status = 'processing' AND updated_at < now() - $3::interval THEN 'failed' ELSE status END, count(*)
		FROM start_new_items WHERE store_id = $1 AND network_id = $2 AND status IN ('processing', 'failed')
		GROUP BY 1`, storeID, networkID, newStale.String())
	if err != nil {
		return nil, out, err
	}
	var status string
	var n int
	if _, err := pgx.ForEachRow(cnt, []any{&status, &n}, func() error {
		if status == NewProcessing {
			out.Left.Processing += n
		} else {
			out.Left.Failed += n
		}
		return nil
	}); err != nil {
		return nil, out, err
	}

	rows, err := s.pool.Query(ctx, `SELECT id, barcode, images, result FROM start_new_items
		WHERE store_id = $1 AND network_id = $2 AND status = 'ready' ORDER BY created_at, id`, storeID, networkID)
	if err != nil {
		return nil, out, err
	}
	var cards []bulkCard
	var ids []string
	var raw []byte
	var c bulkCard
	if _, err := pgx.ForEachRow(rows, []any{&c.id, &c.code, &c.keys, &raw}, func() error {
		x := bulkCard{id: c.id, code: c.code, keys: append([]string(nil), c.keys...)}
		if len(raw) > 2 {
			_ = json.Unmarshal(raw, &x.res)
		}
		cards = append(cards, x)
		ids = append(ids, x.id)
		return nil
	}); err != nil {
		return nil, out, err
	}
	dups, err := s.dupsBy(ctx, s.pool, bulkDupQuery, ids)
	if err != nil {
		return nil, out, err
	}
	for i := range cards {
		x := &cards[i]
		r := x.res
		d, dup := dups[x.id]
		switch {
		case r.Match != nil && r.Match.SameBarcode:
			x.action = bulkExisting
			out.Existing++
		case x.code != "" && !BarcodeValid(x.code):
			out.Left.Barcode++
		case dup:
			x.dup = d.ID
			out.Left.Duplicate++
		case r.Suggestion == nil || r.Suggestion.Category == nil:
			out.Left.NoCategory++
		case strings.TrimSpace(r.Name) == "" || r.UnitID == "":
			out.Left.Other++
		default:
			x.action = bulkCreate
		}
		if x.action != "" {
			out.Ready++
		}
	}
	out.Remaining = out.Ready
	return cards, out, nil
}

// bulkReady — сколько карточек можно провести (для полосы над списком).
func (s *Service) bulkReady(ctx context.Context, networkID, storeID string) (int, error) {
	_, b, err := s.bulkPlan(ctx, networkID, storeID)
	return b.Ready, err
}

// ConfirmAllNewItems — «Провести все»: до Limit карточек за вызов.
func (s *Service) ConfirmAllNewItems(ctx context.Context, p *identity.Principal, in NewItemsBulkInput) (NewItemsBulk, error) {
	st, err := s.store(ctx, s.pool, p, in.StoreID)
	if err != nil {
		return NewItemsBulk{}, err
	}
	cards, out, err := s.bulkPlan(ctx, p.NetworkID, st.ID)
	if err != nil || in.DryRun || out.Ready == 0 {
		return out, err
	}
	if out.Ready > out.Existing {
		// Новые товары создаёт только тот, кому можно вести каталог.
		if err := p.Require(identity.PermCatalogManage); err != nil {
			return out, err
		}
	}
	limit := in.Limit
	if limit <= 0 || limit > bulkLimit {
		limit = bulkLimit
	}
	tried := 0
	added := map[string]bool{}
	for _, c := range cards {
		if c.action == "" {
			continue
		}
		if tried >= limit || ctx.Err() != nil {
			break
		}
		tried++
		var cin NewItemConfirm
		if c.action == bulkExisting {
			cin = NewItemConfirm{StoreID: st.ID, ProductID: c.res.Match.ProductID}
		} else {
			images := make([]string, 0, len(c.keys))
			for _, k := range c.keys {
				if u := s.media.PublicURL(k); u != "" {
					images = append(images, u)
				}
			}
			cin = NewItemConfirm{StoreID: st.ID, Name: c.res.Name, NameUz: c.res.NameUz, Description: c.res.Description,
				CategoryID: c.res.Suggestion.Category.ID, UnitID: c.res.UnitID, Images: images}
			if c.res.BrandID != nil {
				cin.BrandID = *c.res.BrandID
			} else {
				cin.BrandName = c.res.Brand
			}
		}
		if _, err := s.ConfirmNewItem(ctx, p, c.id, cin); err != nil {
			if e, ok := apperr.As(err); ok && e.Code == "already_added" && c.action == bulkExisting {
				// Товар базы уже в «Моих товарах» — карточке больше нечего ждать.
				if _, err := s.pool.Exec(ctx, `UPDATE start_new_items SET status = 'done', product_id = $2 WHERE id = $1 AND status = 'ready'`,
					c.id, c.res.Match.ProductID); err != nil {
					return out, err
				}
				out.Added++
				added[c.id] = true
				continue
			}
			s.log.Info("провести все: карточка осталась", "id", c.id, "err", err)
			continue
		}
		out.Added++
		added[c.id] = true
	}
	// Дубль только что добавленной карточки: её товар теперь в базе — показать
	// его в карточке («Тот же товар, другой штрихкод?» → «Это он»).
	for _, c := range cards {
		if c.dup != "" && added[c.dup] {
			if err := s.refreshMatch(ctx, c.id, p.NetworkID, c.code, &c.res); err != nil {
				s.log.Error("провести все: тот же товар", "id", c.id, "err", err)
			}
		}
	}
	if out.Added > 0 && s.OnOwnAdded != nil {
		s.OnOwnAdded(p.NetworkID)
	}
	out.Remaining = out.Ready - out.Added
	if tried < limit {
		// Прошли все — что не провелось, остаётся магазину.
		out.Left.Other += out.Remaining
		out.Remaining = 0
	}
	return out, nil
}
