package start

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/ai"
	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// Товара нет в центральной базе — магазин ищет его в каталоге ИКПУ
// (tasnif.soliq.uz). Сервер до tasnif не достаёт: поиск идёт из браузера или
// телефона, а сюда приходят найденные записи.
//
//   - Preview — названия по правилам каталога и отметки «уже есть в базе» /
//     «уже добавлен»; алкоголь и записи без ИКПУ отбрасываются.
//   - AddTasnif — добавить в «Мои товары». Товар с тем же штрихкодом уже есть
//     в базе — добавляется он. Иначе товар создаётся в общем каталоге:
//     категория — по коду ИКПУ (как у уже загруженных товаров), а если её не
//     определить — status = need_category и предложение Super Market
//     (подходящая категория из базы или новая); магазин подтверждает, и
//     запрос повторяется с category_id или new_category.

const maxTasnifPreview = 50

// TasnifPreviewInput — POST /store/start/tasnif/preview.
type TasnifPreviewInput struct {
	StoreID string               `json:"store_id"`
	Items   []catalog.TasnifItem `json:"items"`
}

// TasnifPreviewItem — вариант для показа. Index — номер записи в запросе.
type TasnifPreviewItem struct {
	Index     int     `json:"index"`
	Name      string  `json:"name"`
	Barcode   *string `json:"barcode"`
	Ikpu      string  `json:"ikpu"`
	UnitShort string  `json:"unit_short"`
	// ProductID — товар уже есть в центральной базе (по штрихкоду).
	ProductID *string `json:"product_id"`
	Image     *string `json:"image"`
	Added     bool    `json:"added"`
	InStore   bool    `json:"in_store"`
}

// existingProduct — товар базы, видимый сети, для записи ИКПУ: по штрихкоду,
// а без штрихкода — товар общего каталога с тем же кодом ИКПУ.
func existingProduct(ctx context.Context, q db.Querier, networkID string, it catalog.TasnifItem) (string, error) {
	var id string
	var err error
	if code := it.Barcode(); code != "" {
		err = q.QueryRow(ctx, `
			SELECT p.id FROM product_barcodes pb JOIN products p ON p.id = pb.product_id
			WHERE pb.barcode = $1 AND (p.network_id IS NULL OR p.network_id = $2)`, code, networkID).Scan(&id)
	} else {
		err = q.QueryRow(ctx, `
			SELECT id FROM products WHERE network_id IS NULL AND attributes ? 'ikpu' AND attributes ->> 'ikpu' = $1
			ORDER BY is_active DESC, created_at LIMIT 1`, it.Ikpu()).Scan(&id)
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return id, err
}

func (s *Service) Preview(ctx context.Context, p *identity.Principal, in TasnifPreviewInput) ([]TasnifPreviewItem, error) {
	st, err := s.store(ctx, s.pool, p, in.StoreID)
	if err != nil {
		return nil, err
	}
	if len(in.Items) > maxTasnifPreview {
		return nil, apperr.Validation("items: не больше 50").Uz("items: koʻpi bilan 50 ta")
	}
	draft, err := s.draftID(ctx, s.pool, st)
	if err != nil {
		return nil, err
	}
	out := []TasnifPreviewItem{}
	seen := map[string]bool{}
	for i, it := range in.Items {
		if it.Validate() != nil {
			continue
		}
		key := it.Ikpu() + "/" + it.Barcode()
		if seen[key] {
			continue
		}
		seen[key] = true
		x := TasnifPreviewItem{Index: i, Name: it.Name(), Ikpu: it.Ikpu(), UnitShort: it.Unit()}
		if code := it.Barcode(); code != "" {
			x.Barcode = &code
		}
		id, err := existingProduct(ctx, s.pool, p.NetworkID, it)
		if err != nil {
			return nil, err
		}
		if id != "" {
			x.ProductID = &id
			if err := s.pool.QueryRow(ctx, `
				SELECT loc(p.name, p.name_uz), p.images[1],
				       EXISTS (SELECT 1 FROM start_lines l WHERE l.draft_id::text = $2 AND l.product_id = p.id),
				       EXISTS (SELECT 1 FROM store_products a WHERE a.store_id = $3 AND a.product_id = p.id)
				FROM products p WHERE p.id = $1`, id, draft, st.ID).Scan(&x.Name, &x.Image, &x.Added, &x.InStore); err != nil {
				return nil, err
			}
			x.Added = x.Added || x.InStore
			x.InStore = x.InStore && !x.Added
		}
		out = append(out, x)
	}
	return out, nil
}

// TasnifAddInput — POST /store/start/tasnif.
type TasnifAddInput struct {
	StoreID string             `json:"store_id"`
	Item    catalog.TasnifItem `json:"item"`
	// Image — фото товара из tasnif, уже загруженное в /store/uploads.
	Image string `json:"image"`
	// CategoryID или NewCategory — категория, подтверждённая магазином
	// (после status = need_category).
	CategoryID  string               `json:"category_id"`
	NewCategory *catalog.NewCategory `json:"new_category"`
	// NameUz — название по-узбекски из предложения Super Market.
	NameUz string `json:"name_uz"`
	// UnitID — единица нового товара (по умолчанию шт, весовые — кг).
	UnitID         string `json:"unit_id"`
	ConfirmSimilar bool   `json:"confirm_similar"`
}

// CategoryRef — подкатегория: раздел и название на обоих языках.
type CategoryRef struct {
	ID        string `json:"id"`
	Section   string `json:"section"`
	SectionUz string `json:"section_uz"`
	Name      string `json:"name"`
	NameUz    string `json:"name_uz"`
}

// CategorySuggestion — предложение Super Market: подходящая категория из базы
// (Category, ещё варианты — Alternatives) или новая (New).
type CategorySuggestion struct {
	Category     *CategoryRef         `json:"category"`
	Alternatives []CategoryRef        `json:"alternatives"`
	New          *catalog.NewCategory `json:"new"`
	NameUz       string               `json:"name_uz"`
}

type TasnifAddResult struct {
	// Status — added или need_category.
	Status    string  `json:"status"`
	ProductID string  `json:"product_id,omitempty"`
	Created   bool    `json:"created"`
	Line      *Line   `json:"line,omitempty"`
	Totals    *Totals `json:"totals,omitempty"`
	// Name — название товара (для окна выбора категории).
	Name       string              `json:"name"`
	UnitShort  string              `json:"unit_short"`
	Suggestion *CategorySuggestion `json:"suggestion"`
}

func (s *Service) AddTasnif(ctx context.Context, p *identity.Principal, in TasnifAddInput) (TasnifAddResult, error) {
	it := in.Item
	out := TasnifAddResult{Name: it.Name(), UnitShort: it.Unit()}
	if err := it.Validate(); err != nil {
		return out, err
	}
	img := strings.TrimSpace(in.Image)
	if img != "" && !strings.HasPrefix(img, "https://") && !strings.HasPrefix(img, "http://") {
		return out, apperr.Validation("image: ожидается ссылка http(s)").Uz("image: http(s) havola boʻlishi kerak")
	}
	nameUz := strings.TrimSpace(in.NameUz)
	needCategory := false
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		st, err := s.store(ctx, tx, p, in.StoreID)
		if err != nil {
			return err
		}
		// Две вкладки или два магазина добавляют один товар одновременно.
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('tasnif:' || $1))`, it.Ikpu()+"/"+it.Barcode()); err != nil {
			return err
		}
		pid, err := existingProduct(ctx, tx, p.NetworkID, it)
		if err != nil {
			return err
		}
		if pid == "" && it.Barcode() != "" {
			// Штрихкод занят своим товаром другой сети.
			if other, err := catalog.ProductByBarcode(ctx, tx, it.Barcode()); err != nil {
				return err
			} else if other != "" {
				return apperr.Conflict("barcode_exists", "штрихкод "+it.Barcode()+" уже есть у другого товара").Uz(it.Barcode() + " shtrix-kodi boshqa mahsulotda allaqachon bor")
			}
		}
		if pid != "" {
			// Товар уже в базе: фото из tasnif — если у товара общего каталога его нет.
			if img != "" {
				if _, err := tx.Exec(ctx, `UPDATE products SET images = ARRAY[$2] WHERE id = $1 AND network_id IS NULL AND cardinality(images) = 0`, pid, img); err != nil {
					return err
				}
			}
		} else {
			if err := p.Require(identity.PermCatalogManage); err != nil {
				return err
			}
			catID := strings.TrimSpace(in.CategoryID)
			switch {
			case in.NewCategory != nil:
				if catID, err = catalog.EnsureCategory(ctx, tx, *in.NewCategory); err != nil {
					return err
				}
			case catID == "":
				id, ok, err := catalog.CategoryByIkpu(ctx, tx, it.Ikpu())
				if err != nil {
					return err
				}
				if !ok {
					needCategory = true
					return nil
				}
				catID = id
			}
			if pid, err = catalog.CreateTasnifProduct(ctx, tx, catalog.TasnifProduct{Item: it, CategoryID: catID, NameUz: nameUz, Image: img, StoreID: st.ID, UnitID: in.UnitID}); err != nil {
				return err
			}
			out.Created = true
		}
		out.ProductID = pid
		draft, err := s.ensureDraft(ctx, tx, p, st)
		if err != nil {
			return err
		}
		src := "tasnif"
		if _, err := s.setLine(ctx, tx, p, st, draft, LineInput{ProductID: pid, Add: true, ConfirmSimilar: in.ConfirmSimilar, Source: &src}, true); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, lineSelect+` WHERE l.draft_id = $1 AND l.product_id = $4`, draft, st.PriceTypeID, st.ID, pid)
		if err != nil {
			return err
		}
		line, err := pgx.CollectExactlyOneRow(rows, scanLine)
		if err != nil {
			return err
		}
		t, err := s.totals(ctx, tx, draft, st)
		if err != nil {
			return err
		}
		out.Status, out.Line, out.Totals, out.Name = "added", &line, &t, line.Name
		return nil
	})
	if err != nil {
		return out, err
	}
	if needCategory {
		out.Status = "need_category"
		out.Suggestion = s.suggestCategory(ctx, p, in.StoreID, it)
		return out, nil
	}
	if out.Created && nameUz == "" {
		s.translateName(p, in.StoreID, out.ProductID, it.Name())
	}
	return out, nil
}

func (s *Service) usage(p *identity.Principal, storeID string, kind string, conn ai.Conn, u ai.Usage, ok bool) {
	rec := ai.UsageRecord{Kind: kind, Provider: conn.Provider, Model: conn.Model, Usage: u, OK: ok}
	if p.NetworkID != "" {
		rec.NetworkID = &p.NetworkID
	}
	if storeID != "" {
		rec.StoreID = &storeID
	}
	if p.EmployeeID != "" {
		rec.EmployeeID = &p.EmployeeID
	}
	if err := s.ai.Record(context.Background(), rec); err != nil {
		s.log.Error("ai usage", "kind", kind, "err", err)
	}
}

// translateName — название нового товара по-узбекски, в фоне.
func (s *Service) translateName(p *identity.Principal, storeID, productID, name string) {
	pp := *p
	s.run(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()
		conn, err := s.ai.Conn(ctx)
		if err != nil {
			return
		}
		texts, u, err := conn.Translate(ctx, []string{name}, i18n.UZ)
		if u.Input+u.Output > 0 || err == nil {
			s.usage(&pp, storeID, "translate", conn, u, err == nil)
		}
		if err != nil || len(texts) != 1 || texts[0] == "" {
			return
		}
		if _, err := s.pool.Exec(ctx, `UPDATE products SET name_uz = $2 WHERE id = $1 AND name_uz = ''`, productID, texts[0]); err != nil {
			s.log.Error("tasnif name_uz", "product", productID, "err", err)
		}
	})
}

// suggestCategory — предложение Super Market; nil — ИИ не подключён или не
// ответил (тогда магазин выбирает категорию сам).
func (s *Service) suggestCategory(ctx context.Context, p *identity.Principal, storeID string, it catalog.TasnifItem) *CategorySuggestion {
	conn, err := s.ai.Conn(ctx)
	if err != nil {
		return nil
	}
	tree, err := loadTree(ctx, s.pool)
	if err != nil {
		s.log.Error("tasnif categories", "err", err)
		return nil
	}
	ask := ai.CategoryAsk{Name: it.Name(), IkpuPath: it.IkpuPath(), Sections: tree.sections(), Leaves: tree.leaves()}
	if near, err := catalog.CategoriesNearIkpu(ctx, s.pool, it.Ikpu(), 5); err == nil {
		ask.Near = tree.paths(near)
	}
	ctx2, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	ans, u, err := conn.SuggestCategory(ctx2, ask)
	if u.Input+u.Output > 0 || err == nil {
		s.usage(p, storeID, "category", conn, u, err == nil)
	}
	if err != nil {
		s.log.Warn("tasnif category", "err", err)
		return nil
	}
	out := tree.suggestion(ans.Match, ans.Alternatives, ans.New)
	out.NameUz = strings.TrimSpace(ans.NameUz)
	return out
}
