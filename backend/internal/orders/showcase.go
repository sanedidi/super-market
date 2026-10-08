package orders

import (
	"context"

	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/showcase"
)

// Витрина магазина в панели («Витрина приложения»): сеть настраивает свою
// главную поверх шаблона в пределах тарифа. Закреплённые блоки платформы
// убрать нельзя — сервер возвращает их на место. Лимиты проверяются при
// публикации, а при показе лишнее после понижения тарифа скрывается, но
// не удаляется.

func blockIDs(blocks []HomeBlock) map[string]bool {
	out := make(map[string]bool, len(blocks))
	for _, b := range blocks {
		out[b.ID] = true
	}
	return out
}

// mergePinned возвращает в витрину закреплённые блоки платформы: в
// нынешнем виде (правки супер-админа доходят до всех) и на их место в
// шаблоне, если сеть их убрала.
func mergePinned(platform, blocks []HomeBlock) []HomeBlock {
	pinned := map[string]HomeBlock{}
	for _, b := range platform {
		if b.Pinned {
			pinned[b.ID] = b
		}
	}
	out := make([]HomeBlock, 0, len(blocks)+len(pinned))
	present := map[string]bool{}
	for _, b := range blocks {
		if p, ok := pinned[b.ID]; ok {
			out = append(out, p)
			present[b.ID] = true
			continue
		}
		b.Pinned = false
		out = append(out, b)
	}
	for i, p := range platform {
		if !p.Pinned || present[p.ID] {
			continue
		}
		at := min(i, len(out))
		out = append(out[:at], append([]HomeBlock{p}, out[at:]...)...)
	}
	return out
}

// own — блок сети: не из шаблона платформы и не закреплённый.
func own(b HomeBlock, template map[string]bool) bool {
	return !b.Pinned && !template[b.ID]
}

func isPromo(b HomeBlock) bool {
	return (b.Type == BlockPromo && b.Kind == "custom") || (b.Type == BlockBanners && b.Size == "strip")
}

// Usage — сколько своих блоков в витрине и какие платные функции нужны.
type Usage struct {
	Banners  int  `json:"banners"`
	Shelves  int  `json:"shelves"`
	Promos   int  `json:"promos"`
	Manual   bool `json:"manual"`
	Schedule bool `json:"schedule"`
}

func usage(blocks []HomeBlock, template map[string]bool) Usage {
	var u Usage
	for _, b := range blocks {
		if b.Pinned {
			continue
		}
		if own(b, template) {
			if b.Type == BlockShelf {
				u.Shelves++
			}
			if isPromo(b) {
				u.Promos++
			}
		}
		if b.Type == BlockShelf && b.Source == "manual" {
			u.Manual = true
		}
		if b.StartsAt != nil || b.EndsAt != nil {
			u.Schedule = true
		}
	}
	return u
}

// checkPlan — можно ли опубликовать блоки на тарифе.
func checkPlan(ctx context.Context, q db.Querier, p showcase.Plan, blocks []HomeBlock, template map[string]bool, perStore bool) error {
	if !p.Custom {
		return lockedCustom(ctx, q, p)
	}
	if perStore && !p.PerStore {
		return lockedPerStore(ctx, q, p)
	}
	u := usage(blocks, template)
	if l := showcase.Allowed(p.Shelves); u.Shelves > l {
		return showcase.LimitNeed(ctx, q, "shelves", p, l, u.Shelves, i18n.Text{RU: "лимит своих полок на тарифе «" + p.Name + "»", UZ: "«" + p.Name + "» tarifida oʻz javonlaringiz limiti tugadi"})
	}
	if l := showcase.Allowed(p.Promos); u.Promos > l {
		return showcase.LimitNeed(ctx, q, "promos", p, l, u.Promos, i18n.Text{RU: "лимит промо-полосок на тарифе «" + p.Name + "»", UZ: "«" + p.Name + "» tarifida promo-chiziqlar limiti tugadi"})
	}
	if u.Manual && !p.Manual {
		return showcase.Locked(ctx, q, p, "manual", i18n.Text{RU: "подборка «вручную»", UZ: "«qoʻlda» toʻplam"})
	}
	if u.Schedule && !p.Schedule {
		return showcase.Locked(ctx, q, p, "schedule", i18n.Text{RU: "расписание блоков", UZ: "bloklar jadvali"})
	}
	return nil
}

func lockedCustom(ctx context.Context, q db.Querier, p showcase.Plan) error {
	return showcase.Locked(ctx, q, p, "custom", i18n.Text{RU: "своя витрина", UZ: "oʻz vitrinangiz"})
}

func lockedPerStore(ctx context.Context, q db.Querier, p showcase.Plan) error {
	return showcase.Locked(ctx, q, p, "per_store", i18n.Text{RU: "отдельная витрина для магазина сети", UZ: "tarmoq doʻkoni uchun alohida vitrina"})
}

// applyPlan скрывает при показе то, что не входит в тариф (после понижения
// или конца пробного периода): лишние свои полки и полоски, подборки
// «вручную», блоки с расписанием.
func applyPlan(p showcase.Plan, blocks []HomeBlock, template map[string]bool) []HomeBlock {
	shelves, promos := 0, 0
	out := make([]HomeBlock, 0, len(blocks))
	for _, b := range blocks {
		if b.Pinned {
			out = append(out, b)
			continue
		}
		if !p.Schedule && (b.StartsAt != nil || b.EndsAt != nil) {
			continue
		}
		if !p.Manual && b.Type == BlockShelf && b.Source == "manual" {
			continue
		}
		if own(b, template) && b.Type == BlockShelf {
			if shelves++; shelves > showcase.Allowed(p.Shelves) {
				continue
			}
		}
		if own(b, template) && isPromo(b) {
			if promos++; promos > showcase.Allowed(p.Promos) {
				continue
			}
		}
		out = append(out, b)
	}
	return out
}

// ShowcaseEditor — витрина для панели магазина: блоки, тариф, сколько уже
// использовано и что из шаблона (не считается своим).
type ShowcaseEditor struct {
	Layout      LayoutEditor     `json:"layout"`
	Plan        showcase.Network `json:"plan"`
	Plans       []showcase.Plan  `json:"plans"`
	Usage       Usage            `json:"usage"`
	TemplateIDs []string         `json:"template_ids"`
	PinnedIDs   []string         `json:"pinned_ids"`
	Banners     []catalog.Banner `json:"banners"`
	CanBuy      bool             `json:"can_buy"`
	Stores      []PreviewStore   `json:"stores"`
}

func storeScope(p *identity.Principal, storeID string) (LayoutScope, error) {
	if storeID != "" && !p.CanAccessStore(storeID) {
		return LayoutScope{}, apperr.Forbidden("нет доступа к магазину").Uz("doʻkonga ruxsat yoʻq")
	}
	return LayoutScope{NetworkID: p.NetworkID, StoreID: storeID}, nil
}

// StoreShowcase — витрина сети или её магазина для панели.
func (s *Service) StoreShowcase(ctx context.Context, p *identity.Principal, storeID string) (ShowcaseEditor, error) {
	sc, err := storeScope(p, storeID)
	if err != nil {
		return ShowcaseEditor{}, err
	}
	out := ShowcaseEditor{TemplateIDs: []string{}, PinnedIDs: []string{}, CanBuy: p.Can(identity.PermPayoutsManage)}
	if out.Layout, err = s.LayoutForEditor(ctx, sc); err != nil {
		return out, err
	}
	if out.Plan, err = showcase.ForNetwork(ctx, s.pool, p.NetworkID); err != nil {
		return out, err
	}
	if out.Plans, err = showcase.Plans(ctx, s.pool); err != nil {
		return out, err
	}
	platform, _, err := s.published(ctx, LayoutScope{})
	if err != nil {
		return out, err
	}
	for _, b := range platform {
		out.TemplateIDs = append(out.TemplateIDs, b.ID)
		if b.Pinned {
			out.PinnedIDs = append(out.PinnedIDs, b.ID)
		}
	}
	// Закреплённые блоки — и в том, что видит редактор.
	out.Layout.Blocks = mergePinned(platform, out.Layout.Blocks)
	if out.Layout.Draft != nil {
		out.Layout.Draft = mergePinned(platform, out.Layout.Draft)
	}
	current := out.Layout.Blocks
	if out.Layout.Draft != nil {
		current = out.Layout.Draft
	}
	out.Usage = usage(current, blockIDs(platform))
	if out.Usage.Banners, err = catalog.ActiveNetworkBanners(ctx, s.pool, p.NetworkID); err != nil {
		return out, err
	}
	if out.Banners, err = catalog.HomeBanners(ctx, s.pool, p.NetworkID, 1<<30, true); err != nil {
		return out, err
	}
	if out.Stores, err = s.PreviewStores(ctx, p.NetworkID, false); err != nil {
		return out, err
	}
	return out, nil
}

// SaveStoreDraft — черновик витрины сети; закреплённые блоки платформы
// возвращаются на место.
func (s *Service) SaveStoreDraft(ctx context.Context, p *identity.Principal, storeID string, blocks []HomeBlock) (ShowcaseEditor, error) {
	sc, err := storeScope(p, storeID)
	if err != nil {
		return ShowcaseEditor{}, err
	}
	plan, err := showcase.ForNetwork(ctx, s.pool, p.NetworkID)
	if err != nil {
		return ShowcaseEditor{}, err
	}
	if !plan.Effective.Custom {
		return ShowcaseEditor{}, lockedCustom(ctx, s.pool, plan.Effective)
	}
	if storeID != "" && !plan.Effective.PerStore {
		return ShowcaseEditor{}, lockedPerStore(ctx, s.pool, plan.Effective)
	}
	if err := s.checkOwnBanners(ctx, p.NetworkID, blocks); err != nil {
		return ShowcaseEditor{}, err
	}
	platform, _, err := s.published(ctx, LayoutScope{})
	if err != nil {
		return ShowcaseEditor{}, err
	}
	if _, err := s.SaveDraft(ctx, sc, mergePinned(platform, blocks)); err != nil {
		return ShowcaseEditor{}, err
	}
	return s.StoreShowcase(ctx, p, storeID)
}

// checkOwnBanners — сеть ставит в витрину только свои баннеры и баннеры
// платформы.
func (s *Service) checkOwnBanners(ctx context.Context, networkID string, blocks []HomeBlock) error {
	ids := []string{}
	for _, b := range blocks {
		ids = append(ids, b.BannerIDs...)
	}
	if len(ids) == 0 {
		return nil
	}
	var bad int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM banners WHERE id = ANY($1::uuid[]) AND network_id IS NOT NULL AND network_id <> $2`,
		ids, networkID).Scan(&bad); err != nil {
		return err
	}
	if bad > 0 {
		return apperr.Validation("баннеры: можно ставить только свои баннеры и баннеры Super Market").Uz("bannerlar: faqat oʻz bannerlaringiz va Super Market bannerlarini qoʻyish mumkin")
	}
	return nil
}

// PublishStore публикует витрину сети с проверкой тарифа.
func (s *Service) PublishStore(ctx context.Context, p *identity.Principal, storeID string) (ShowcaseEditor, error) {
	sc, err := storeScope(p, storeID)
	if err != nil {
		return ShowcaseEditor{}, err
	}
	plan, err := showcase.ForNetwork(ctx, s.pool, p.NetworkID)
	if err != nil {
		return ShowcaseEditor{}, err
	}
	platform, _, err := s.published(ctx, LayoutScope{})
	if err != nil {
		return ShowcaseEditor{}, err
	}
	template := blockIDs(platform)
	if _, err := s.Publish(ctx, sc, p.UserID, true, func(blocks []HomeBlock) error {
		return checkPlan(ctx, s.pool, plan.Effective, mergePinned(platform, blocks), template, storeID != "")
	}); err != nil {
		return ShowcaseEditor{}, err
	}
	return s.StoreShowcase(ctx, p, storeID)
}

// StoreLayoutAct — сброс черновика, откат версии, возврат к шаблону.
func (s *Service) StoreLayoutAct(ctx context.Context, p *identity.Principal, storeID string, fn func(LayoutScope) error) (ShowcaseEditor, error) {
	sc, err := storeScope(p, storeID)
	if err != nil {
		return ShowcaseEditor{}, err
	}
	if err := fn(sc); err != nil {
		return ShowcaseEditor{}, err
	}
	return s.StoreShowcase(ctx, p, storeID)
}

// ChoosePlan — сеть переходит на другой тариф витрины. Плата войдёт в
// ближайший счёт за подписку; понижение сразу скрывает лишнее.
func (s *Service) ChoosePlan(ctx context.Context, p *identity.Principal, key string) (ShowcaseEditor, error) {
	if err := p.Require(identity.PermPayoutsManage); err != nil {
		return ShowcaseEditor{}, err
	}
	if _, err := showcase.Choose(ctx, s.pool, p.NetworkID, key); err != nil {
		return ShowcaseEditor{}, err
	}
	s.forgetHomes()
	return s.StoreShowcase(ctx, p, "")
}
