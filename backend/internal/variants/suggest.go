package variants

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/ai"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/variants/naming"
)

// «Найти новые группы»: товары общего каталога, которые ещё не в группе
// и не были в отклонённом предложении, делятся на пачки «бренд +
// подкатегория»; каждую пачку разбирает ИИ (без него — разбор названий).

// SuggestBudget — сколько времени один разбор может спрашивать ИИ; остальное —
// следующим нажатием («ещё есть товары»). Разбор идёт в фоне (job.go).
var SuggestBudget = 10 * time.Minute

const (
	maxBuckets       = 80
	maxBucketProduct = 150
)

// SuggestInput — POST /admin/variant-groups/suggest.
type SuggestInput struct {
	BrandID *string `json:"brand_id"`
}

// SuggestResult — сколько групп предложено.
type SuggestResult struct {
	Created int  `json:"created"`
	Checked int  `json:"checked"` // пачек «бренд + подкатегория» разобрано
	AI      bool `json:"ai"`      // разбирал ИИ (иначе — по названиям)
	More    bool `json:"more"`    // не всё успели — можно нажать ещё раз
	Failed  int  `json:"failed"`  // пачек, на которых ИИ ответил ошибкой
}

type bucket struct {
	brandID, brand    string
	categoryID, catNm string
	ids, names        []string
}

func (s *Service) Suggest(ctx context.Context, in SuggestInput) (SuggestResult, error) {
	var out SuggestResult
	var brand *string
	if in.BrandID != nil && *in.BrandID != "" {
		if !httpx.IsUUID(*in.BrandID) {
			return out, apperr.Validation("brand_id: бренд не найден").Uz("brand_id: brend topilmadi")
		}
		brand = in.BrandID
	}
	rows, err := s.pool.Query(ctx, `
		SELECT p.brand_id, b.name, p.category_id, c.name,
		       array_agg(p.id::text ORDER BY p.name), array_agg(p.name ORDER BY p.name)
		FROM products p
		JOIN brands b ON b.id = p.brand_id
		JOIN categories c ON c.id = p.category_id
		WHERE p.network_id IS NULL AND p.is_active AND p.variant_group_id IS NULL
		  AND ($1::uuid IS NULL OR p.brand_id = $1::uuid)
		  AND NOT EXISTS (
			SELECT 1 FROM variant_group_items i JOIN variant_groups g ON g.id = i.group_id
			WHERE i.product_id = p.id AND g.status IN ('proposed', 'rejected'))
		GROUP BY p.brand_id, b.name, p.category_id, c.name
		HAVING count(*) >= 2
		ORDER BY count(*) DESC, b.name
		LIMIT $2`, brand, maxBuckets+1)
	if err != nil {
		return out, err
	}
	buckets, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (bucket, error) {
		var b bucket
		err := r.Scan(&b.brandID, &b.brand, &b.categoryID, &b.catNm, &b.ids, &b.names)
		return b, err
	})
	if err != nil {
		return out, err
	}
	if len(buckets) > maxBuckets {
		buckets, out.More = buckets[:maxBuckets], true
	}

	conn, err := s.ai.Conn(ctx)
	useAI := err == nil
	if err != nil && !errors.Is(err, ai.ErrNotConfigured) {
		return out, err
	}
	out.AI = useAI
	start := time.Now()
	for _, b := range buckets {
		if useAI && time.Since(start) > SuggestBudget {
			out.More = true
			break
		}
		if len(b.ids) > maxBucketProduct {
			b.ids, b.names = b.ids[:maxBucketProduct], b.names[:maxBucketProduct]
			out.More = true
		}
		var groups []proposal
		if useAI {
			groups, err = s.askAI(ctx, conn, b)
			if err != nil {
				s.log.Warn("variants: ИИ не разобрал пачку", "brand", b.brand, "category", b.catNm, "err", err)
				out.Failed++
				continue
			}
		} else {
			groups = byNames(b)
		}
		out.Checked++
		n, err := s.saveProposals(ctx, b, groups)
		if err != nil {
			return out, err
		}
		out.Created += n
	}
	return out, nil
}

// proposal — группа до записи в базу.
type proposal struct {
	name, nameUz, confidence, note string
	// Названия переключателей; пусто — по значениям (naming.Labels).
	weightLabel, weightLabelUz, flavorLabel, flavorLabelUz string
	items                                                  []naming.Parsed
	flavorUz                                               map[string]string
}

func byNames(b bucket) []proposal {
	items := make([]naming.Item, len(b.ids))
	for i := range b.ids {
		items[i] = naming.Item{ID: b.ids[i], Name: b.names[i], Brand: b.brand}
	}
	var out []proposal
	for _, g := range naming.Suggest(items) {
		out = append(out, proposal{name: g.Name, confidence: "check",
			note: "Собрано по названиям — проверьте переключатели и значения", items: g.Items})
	}
	return out
}

func (s *Service) askAI(ctx context.Context, conn ai.Conn, b bucket) ([]proposal, error) {
	ask := ai.VariantAsk{Brand: b.brand, Category: b.catNm}
	known := map[string]string{}
	for i := range b.ids {
		ask.Products = append(ask.Products, ai.VariantProduct{ID: b.ids[i], Name: b.names[i]})
		known[b.ids[i]] = b.names[i]
	}
	actx, cancel := context.WithTimeout(ctx, 60*time.Second)
	ans, u, err := conn.GroupVariants(actx, ask)
	cancel()
	if u.Input+u.Output > 0 || err == nil {
		if rerr := s.ai.Record(context.WithoutCancel(ctx), ai.UsageRecord{Kind: "variants", Provider: conn.Provider,
			Model: conn.Model, Usage: u, OK: err == nil}); rerr != nil {
			s.log.Error("ai usage", "kind", "variants", "err", rerr)
		}
	}
	if err != nil {
		return nil, err
	}
	used := map[string]bool{}
	var out []proposal
	for _, g := range ans.Groups {
		name := strings.TrimSpace(g.Name)
		if name == "" {
			continue
		}
		p := proposal{name: name, nameUz: strings.TrimSpace(g.NameUz), confidence: "high", note: strings.TrimSpace(g.Note),
			flavorUz:    map[string]string{},
			weightLabel: clip(naming.Capitalize(strings.TrimSpace(g.WeightLabel)), maxLabel), weightLabelUz: clip(naming.Capitalize(strings.TrimSpace(g.WeightLabelUz)), maxLabel),
			flavorLabel: clip(naming.Capitalize(strings.TrimSpace(g.FlavorLabel)), maxLabel), flavorLabelUz: clip(naming.Capitalize(strings.TrimSpace(g.FlavorLabelUz)), maxLabel)}
		if g.Confidence == "check" {
			p.confidence = "check"
		}
		seen := map[string]bool{}
		distinct := 0
		for _, it := range g.Items {
			if _, ok := known[it.ID]; !ok || used[it.ID] {
				continue
			}
			used[it.ID] = true
			weight := strings.TrimSpace(it.Weight)
			weightUz := strings.TrimSpace(it.WeightUz)
			if weightUz == "" {
				weightUz = naming.WeightUz(weight)
			}
			flavor := naming.Capitalize(strings.TrimSpace(it.Flavor))
			parsed := naming.Parsed{ID: it.ID, Weight: weight, WeightUz: weightUz, WeightSort: naming.WeightSort(weight),
				Flavor: flavor, Included: true}
			k := naming.Fold(weight) + "|" + naming.Fold(flavor)
			if seen[k] {
				parsed.Included, parsed.Note = false, "Похоже на дубль: те же значения переключателей"
			} else {
				seen[k] = true
				distinct++
			}
			p.flavorUz[it.ID] = strings.TrimSpace(it.FlavorUz)
			p.items = append(p.items, parsed)
		}
		if distinct >= 2 {
			out = append(out, p)
		}
	}
	return out, nil
}

// saveProposals — новые предложения одной пачки.
// Источник — всегда «ai»: и ответ ИИ, и разбор названий — предложения Super Market.
func (s *Service) saveProposals(ctx context.Context, b bucket, groups []proposal) (int, error) {
	if len(groups) == 0 {
		return 0, nil
	}
	n := 0
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		for _, g := range groups {
			// Товар мог попасть в группу, пока шёл запрос к ИИ.
			ids := make([]string, len(g.items))
			for i, it := range g.items {
				ids[i] = it.ID
			}
			var busy int
			if err := tx.QueryRow(ctx, `
				SELECT count(*)::int FROM products p
				WHERE p.id = ANY ($1::uuid[]) AND (p.variant_group_id IS NOT NULL OR EXISTS (
					SELECT 1 FROM variant_group_items i JOIN variant_groups vg ON vg.id = i.group_id
					WHERE i.product_id = p.id AND vg.status IN ('proposed', 'rejected')))`, ids).Scan(&busy); err != nil {
				return err
			}
			if busy > 0 {
				continue
			}
			// Названия переключателей: от ИИ, а чего нет — по значениям.
			var weights, flavors []string
			for _, it := range g.items {
				if it.Included {
					weights, flavors = append(weights, it.Weight), append(flavors, it.Flavor)
				}
			}
			// Переключатель есть, только если у товаров есть значения (у вазы веса нет).
			wl, wlUz, fl, flUz := naming.Labels(weights, flavors)
			if g.weightLabel != "" && wl != "" {
				wl, wlUz = g.weightLabel, g.weightLabelUz
			}
			if g.flavorLabel != "" && fl != "" {
				fl, flUz = g.flavorLabel, g.flavorLabelUz
			}
			var id string
			if err := tx.QueryRow(ctx, `
				INSERT INTO variant_groups (name, name_uz, brand_id, category_id, source, confidence, note,
				                            weight_label, weight_label_uz, flavor_label, flavor_label_uz)
				VALUES ($1, $2, $3, $4, 'ai', $5, $6, $7, $8, $9, $10) RETURNING id`,
				g.name, g.nameUz, b.brandID, b.categoryID, g.confidence, g.note, wl, wlUz, fl, flUz).Scan(&id); err != nil {
				return err
			}
			for i, it := range g.items {
				if _, err := tx.Exec(ctx, `
					INSERT INTO variant_group_items (group_id, product_id, weight, weight_uz, weight_sort, flavor, flavor_uz, included, note, sort)
					VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
					id, it.ID, clip(it.Weight, maxWeight), clip(it.WeightUz, maxWeight), it.WeightSort,
					clip(it.Flavor, maxFlavor), clip(g.flavorUz[it.ID], maxFlavor), it.Included, it.Note, i+1); err != nil {
					return err
				}
			}
			n++
		}
		return nil
	})
	return n, err
}
