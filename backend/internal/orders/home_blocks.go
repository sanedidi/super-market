package orders

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/showcase"
)

// Главная приложения из блоков: полка товаров, баннеры, промо-полоска,
// иконки разделов, каталог по разделам. Шапка и статус заказа в блоки не
// входят — они в приложении всегда.

// Типы блоков. Приложение пропускает незнакомый тип, поэтому новые типы
// можно добавлять без выпуска приложения.
const (
	BlockShelf           = "shelf"
	BlockBanners         = "banners"
	BlockPromo           = "promo"
	BlockCategoryIcons   = "category_icons"
	BlockCatalogSections = "catalog_sections"
)

// HomeBlock — блок витрины: общие поля, настройки своего типа и (в ответе
// приложению) данные — товары полки или баннеры.
type HomeBlock struct {
	ID       string `json:"id"`
	Type     string `json:"type"`
	Disabled bool   `json:"disabled,omitempty"`
	// Закреплён платформой: магазин не может убрать или выключить блок.
	Pinned   bool       `json:"pinned,omitempty"`
	StartsAt *time.Time `json:"starts_at,omitempty"`
	EndsAt   *time.Time `json:"ends_at,omitempty"`

	// Полка товаров.
	Title      string   `json:"title,omitempty"`
	Source     string   `json:"source,omitempty"` // hits | discount | new | category | manual
	CategoryID string   `json:"category_id,omitempty"`
	ProductIDs []string `json:"product_ids,omitempty"`
	Limit      int      `json:"limit,omitempty"`
	View       string   `json:"view,omitempty"` // полка: row | grid2 | grid3; каталог: tiles3 | tiles2 | list
	ShowAll    *bool    `json:"show_all,omitempty"`
	ShowEmpty  bool     `json:"show_empty,omitempty"` // по умолчанию пустой блок скрыт

	// Баннеры.
	Size      string   `json:"size,omitempty"` // big | strip
	BannerIDs []string `json:"banner_ids,omitempty"`
	Autoplay  *bool    `json:"autoplay,omitempty"`

	// Промо-полоска.
	Kind     string     `json:"kind,omitempty"` // custom | free_delivery
	Subtitle string     `json:"subtitle,omitempty"`
	Icon     string     `json:"icon,omitempty"`
	Color    string     `json:"color,omitempty"` // yellow | red | green | dark
	Link     *BlockLink `json:"link,omitempty"`

	// Иконки разделов и каталог по разделам.
	Mode        string   `json:"mode,omitempty"` // auto | manual (иконки); all | selected (каталог)
	CategoryIDs []string `json:"category_ids,omitempty"`
	Shape       string   `json:"shape,omitempty"` // circle | square | tiles
	ShowDeals   *bool    `json:"show_deals,omitempty"`
	ShowImages  *bool    `json:"show_images,omitempty"`
	ShowCounts  bool     `json:"show_counts,omitempty"`

	// Данные для приложения.
	Products []CatalogProduct `json:"products,omitempty"`
	Banners  []catalog.Banner `json:"banners,omitempty"`
}

// BlockLink — куда ведёт нажатие на промо-полоску.
type BlockLink struct {
	Type string `json:"type"` // none | deals | category | product | delivery_terms | url
	ID   string `json:"id,omitempty"`
	URL  string `json:"url,omitempty"`
}

// StoreHome — готовая главная магазина для приложения.
type StoreHome struct {
	Version int         `json:"version"`
	Blocks  []HomeBlock `json:"blocks"`
}

func oneOf(v string, allowed ...string) bool {
	for _, a := range allowed {
		if v == a {
			return true
		}
	}
	return false
}

// ValidateBlocks проверяет блоки витрины перед сохранением. Возвращает
// ошибку с номером блока, чтобы редактор подсветил нужный.
func ValidateBlocks(blocks []HomeBlock) error {
	if len(blocks) > 30 {
		return apperr.Validation("не больше 30 блоков на главной")
	}
	seen := map[string]bool{}
	for i, b := range blocks {
		bad := func(msg string) error { return apperr.Validation(fmt.Sprintf("блок %d: %s", i+1, msg)) }
		if !httpx.IsUUID(b.ID) || seen[b.ID] {
			return bad("нужен уникальный id")
		}
		seen[b.ID] = true
		if b.StartsAt != nil && b.EndsAt != nil && !b.EndsAt.After(*b.StartsAt) {
			return bad("дата окончания раньше начала")
		}
		uuids := func(ids []string, max int, what string) error {
			if len(ids) > max {
				return bad(fmt.Sprintf("%s: не больше %d", what, max))
			}
			for _, id := range ids {
				if !httpx.IsUUID(id) {
					return bad(what + ": неверный id")
				}
			}
			return nil
		}
		switch b.Type {
		case BlockShelf:
			if len([]rune(b.Title)) == 0 || len([]rune(b.Title)) > 40 {
				return bad("заголовок полки от 1 до 40 символов")
			}
			if !oneOf(b.Source, "hits", "discount", "new", "category", "manual") {
				return bad("источник: hits, discount, new, category или manual")
			}
			if b.Source == "category" && !httpx.IsUUID(b.CategoryID) {
				return bad("выберите категорию")
			}
			if b.Source == "manual" && len(b.ProductIDs) == 0 {
				return bad("добавьте товары в подборку")
			}
			if err := uuids(b.ProductIDs, 30, "товары"); err != nil {
				return err
			}
			if b.Limit < 1 || b.Limit > 20 {
				return bad("товаров в полке от 1 до 20")
			}
			if !oneOf(b.View, "row", "grid2", "grid3") {
				return bad("вид полки: row, grid2 или grid3")
			}
		case BlockBanners:
			if !oneOf(b.Size, "big", "strip") {
				return bad("размер баннеров: big или strip")
			}
			if err := uuids(b.BannerIDs, 10, "баннеры"); err != nil {
				return err
			}
			// Узкая лента — текст с иконкой и цветом вместо фото.
			if b.Size == "strip" {
				if len([]rune(b.Title)) == 0 || len([]rune(b.Title)) > 60 {
					return bad("текст ленты от 1 до 60 символов")
				}
				if !oneOf(b.Color, "yellow", "red", "green", "dark") {
					return bad("цвет: yellow, red, green или dark")
				}
				if err := checkLink(b.Link); err != nil {
					return bad(err.Error())
				}
			}
		case BlockPromo:
			if !oneOf(b.Kind, "custom", "free_delivery") {
				return bad("тип полоски: custom или free_delivery")
			}
			if b.Kind == "custom" {
				if len([]rune(b.Title)) == 0 || len([]rune(b.Title)) > 60 {
					return bad("текст полоски от 1 до 60 символов")
				}
				if len([]rune(b.Subtitle)) > 80 {
					return bad("подпись не длиннее 80 символов")
				}
				if !oneOf(b.Color, "yellow", "red", "green", "dark") {
					return bad("цвет: yellow, red, green или dark")
				}
				if b.Link != nil {
					if !oneOf(b.Link.Type, "none", "deals", "category", "product", "delivery_terms", "url") {
						return bad("неверная ссылка")
					}
					if (b.Link.Type == "category" || b.Link.Type == "product") && !httpx.IsUUID(b.Link.ID) {
						return bad("ссылка: выберите категорию или товар")
					}
					if b.Link.Type == "url" && !httpURL(b.Link.URL) {
						return bad("ссылка должна начинаться с https://")
					}
				}
			}
		case BlockCategoryIcons:
			if !oneOf(b.Mode, "auto", "manual") || !oneOf(b.Shape, "circle", "square", "tiles") {
				return bad("иконки: режим auto/manual, форма circle/square/tiles")
			}
			if b.Mode == "manual" && len(b.CategoryIDs) == 0 {
				return bad("выберите категории")
			}
			if err := uuids(b.CategoryIDs, 20, "категории"); err != nil {
				return err
			}
		case BlockCatalogSections:
			if !oneOf(b.Mode, "all", "selected") || !oneOf(b.View, "tiles3", "tiles2", "list") {
				return bad("каталог: режим all/selected, вид tiles3/tiles2/list")
			}
			if b.Mode == "selected" && len(b.CategoryIDs) == 0 {
				return bad("выберите разделы")
			}
			if err := uuids(b.CategoryIDs, 30, "разделы"); err != nil {
				return err
			}
		default:
			return bad("неизвестный тип блока")
		}
	}
	return nil
}

func checkLink(l *BlockLink) error {
	if l == nil {
		return nil
	}
	if !oneOf(l.Type, "none", "deals", "category", "product", "delivery_terms", "url") {
		return errors.New("неверная ссылка")
	}
	if (l.Type == "category" || l.Type == "product") && !httpx.IsUUID(l.ID) {
		return errors.New("ссылка: выберите категорию или товар")
	}
	if l.Type == "url" && !httpURL(l.URL) {
		return errors.New("ссылка должна начинаться с https://")
	}
	return nil
}

func httpURL(u string) bool {
	return len(u) > 8 && len(u) <= 500 && u[:8] == "https://"
}

// homeCache — готовые главные магазинов на минуту: главную открывают
// часто, а собирается она из нескольких запросов в базу.
type homeCache struct {
	mu    sync.Mutex
	items map[string]homeCacheItem
}

type homeCacheItem struct {
	home StoreHome
	at   time.Time
}

const homeCacheTTL = time.Minute

// StoreHome — главная магазина: витрина магазина, иначе сети, иначе
// шаблон платформы; закреплённые блоки платформы есть всегда; витрина,
// которую сеть сделала сама, показывается в пределах её тарифа;
// выключенные, вне дат и пустые блоки убраны, полки и баннеры уже с данными.
func (s *Service) StoreHome(ctx context.Context, storeID string) (StoreHome, error) {
	now := s.now()
	s.homes.mu.Lock()
	if it, ok := s.homes.items[storeID]; ok && now.Sub(it.at) < homeCacheTTL {
		s.homes.mu.Unlock()
		return it.home, nil
	}
	s.homes.mu.Unlock()

	st, err := s.storeForClient(ctx, s.pool, storeID)
	if err != nil {
		return StoreHome{}, err
	}
	blocks, version, ownLimit, err := s.storeBlocks(ctx, storeID, st.NetworkID)
	if err != nil {
		return StoreHome{}, err
	}
	filled, err := s.fillBlocks(ctx, storeID, st.NetworkID, blocks, now, false, ownLimit)
	if err != nil {
		return StoreHome{}, err
	}
	out := StoreHome{Version: version, Blocks: filled}

	s.homes.mu.Lock()
	if s.homes.items == nil {
		s.homes.items = map[string]homeCacheItem{}
	}
	s.homes.items[storeID] = homeCacheItem{home: out, at: now}
	s.homes.mu.Unlock()
	return out, nil
}

// storeBlocks выбирает витрину магазина и применяет к ней тариф сети.
// ownLimit — сколько своих баннеров сети можно показать.
func (s *Service) storeBlocks(ctx context.Context, storeID, networkID string) ([]HomeBlock, int, int, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT scope, blocks, version, by_store FROM home_layouts
		WHERE version > 0 AND (store_id = $1 OR (scope = 'network' AND network_id = $2) OR scope = 'platform')`,
		storeID, networkID)
	if err != nil {
		return nil, 0, 0, err
	}
	type lay struct {
		blocks  []HomeBlock
		version int
		byStore bool
	}
	found := map[string]lay{}
	for rows.Next() {
		var scope string
		var raw []byte
		var l lay
		if err := rows.Scan(&scope, &raw, &l.version, &l.byStore); err != nil {
			rows.Close()
			return nil, 0, 0, err
		}
		if err := json.Unmarshal(raw, &l.blocks); err != nil {
			rows.Close()
			return nil, 0, 0, fmt.Errorf("home layout: %w", err)
		}
		found[scope] = l
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, 0, 0, err
	}
	platform := found["platform"]
	plan, err := showcase.ForNetwork(ctx, s.pool, networkID)
	if err != nil {
		return nil, 0, 0, err
	}
	ownLimit := showcase.Allowed(plan.Effective.Banners)
	// Витрина, сделанная сетью, действует только на подходящем тарифе;
	// сделанная супер-админом — всегда.
	usable := func(l lay, perStore bool) bool {
		if !l.byStore {
			return true
		}
		return plan.Effective.Custom && (!perStore || plan.Effective.PerStore)
	}
	for _, c := range []struct {
		scope    string
		perStore bool
	}{{"store", true}, {"network", false}} {
		l, ok := found[c.scope]
		if !ok || !usable(l, c.perStore) {
			continue
		}
		blocks := l.blocks
		if l.byStore {
			blocks = applyPlan(plan.Effective, blocks, blockIDs(platform.blocks))
		}
		return mergePinned(platform.blocks, blocks), l.version, ownLimit, nil
	}
	return platform.blocks, platform.version, ownLimit, nil
}

// fillBlocks убирает выключенные, вне дат и пустые блоки и кладёт в полки
// товары, а в баннеры — баннеры. preview — для редактора: баннеры сети на
// модерации тоже видны.
func (s *Service) fillBlocks(ctx context.Context, storeID, networkID string, blocks []HomeBlock, now time.Time, preview bool, ownLimit int) ([]HomeBlock, error) {
	out := []HomeBlock{}
	var banners []catalog.Banner
	var err error
	for _, b := range blocks {
		if b.Disabled || (b.StartsAt != nil && now.Before(*b.StartsAt)) || (b.EndsAt != nil && !now.Before(*b.EndsAt)) {
			continue
		}
		switch b.Type {
		case BlockShelf:
			if b.Products, err = s.shelfProducts(ctx, storeID, b); err != nil {
				return nil, err
			}
			if len(b.Products) == 0 && !b.ShowEmpty {
				continue
			}
		case BlockBanners:
			if b.Size == "strip" {
				break
			}
			if banners == nil {
				if banners, err = catalog.HomeBanners(ctx, s.pool, networkID, ownLimit, preview); err != nil {
					return nil, err
				}
			}
			b.Banners = pickBanners(banners, b.BannerIDs)
			if len(b.Banners) == 0 {
				continue
			}
		}
		out = append(out, b)
	}
	return out, nil
}

// shelfProducts — товары полки. «Хиты» у нового магазина без продаж
// заменяются самыми популярными, чтобы полка не пустовала.
func (s *Service) shelfProducts(ctx context.Context, storeID string, b HomeBlock) ([]CatalogProduct, error) {
	page := httpx.Page{Limit: b.Limit}
	if page.Limit <= 0 {
		page.Limit = 6
	}
	var f CatalogFilter
	switch b.Source {
	case "hits":
		f = CatalogFilter{Hits: true}
	case "discount":
		f = CatalogFilter{Discount: true, Sort: "discount"}
	case "new":
		f = CatalogFilter{New: true, Sort: "new"}
	case "category":
		f = CatalogFilter{CategoryID: b.CategoryID}
	case "manual":
		if len(b.ProductIDs) == 0 {
			return nil, nil
		}
		f = CatalogFilter{IDs: b.ProductIDs}
	default:
		return nil, nil
	}
	items, err := s.StoreCatalog(ctx, storeID, f, page)
	if err != nil {
		return nil, err
	}
	if b.Source == "hits" && len(items) == 0 {
		return s.StoreCatalog(ctx, storeID, CatalogFilter{}, page)
	}
	if b.Source == "manual" {
		// Порядок подборки — как её составили.
		pos := map[string]int{}
		for i, id := range b.ProductIDs {
			pos[id] = i
		}
		sorted := make([]CatalogProduct, len(items))
		copy(sorted, items)
		for i := 1; i < len(sorted); i++ {
			for j := i; j > 0 && pos[sorted[j].ID] < pos[sorted[j-1].ID]; j-- {
				sorted[j], sorted[j-1] = sorted[j-1], sorted[j]
			}
		}
		items = sorted
	}
	return items, nil
}

// pickBanners — выбранные баннеры в заданном порядке; без выбора — все активные.
func pickBanners(all []catalog.Banner, ids []string) []catalog.Banner {
	if len(ids) == 0 {
		return all
	}
	byID := map[string]catalog.Banner{}
	for _, b := range all {
		byID[b.ID] = b
	}
	out := []catalog.Banner{}
	for _, id := range ids {
		if b, ok := byID[id]; ok {
			out = append(out, b)
		}
	}
	return out
}

// forgetHomes сбрасывает кэш главных (после публикации витрины).
func (s *Service) forgetHomes() {
	s.homes.mu.Lock()
	s.homes.items = nil
	s.homes.mu.Unlock()
}
