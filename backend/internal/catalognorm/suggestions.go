package catalognorm

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/sanedidi/super-market/backend/internal/ai"
	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Исправления карточек общего каталога от магазинов («Предложить
// исправление»): Super Market принимает или отклоняет их сам — тем же путём,
// что супер-админ (магазину уходит пуш). Решение пишется в журнал прогона;
// принятое исправление не откатывается (его правка — дело магазина).

const maxSuggestions = 100

func (s *Service) pendingSuggestions(ctx context.Context) (int, error) {
	var n int
	err := s.pool.QueryRow(ctx, `SELECT count(*)::int FROM product_suggestions WHERE status = 'pending'`).Scan(&n)
	return n, err
}

func (s *Service) reviewSuggestions(ctx context.Context, st *runState) error {
	if s.cat == nil {
		return nil
	}
	list, err := s.cat.AdminSuggestions(ctx, "pending", httpx.Page{Limit: maxSuggestions})
	if err != nil || len(list) == 0 {
		return err
	}
	byCode := map[string]catalog.Suggestion{}
	var asks []ai.SuggestionAsk
	for i, sg := range list {
		code := "r" + itoa(i+1)
		byCode[code] = sg
		ch := map[string][2]any{}
		c, cur := sg.Changes, sg.Current
		if c.Name != nil {
			ch["name"] = [2]any{deref(cur.Name), *c.Name}
		}
		if c.NameUz != nil {
			ch["name_uz"] = [2]any{deref(cur.NameUz), *c.NameUz}
		}
		if c.CategoryID != nil {
			to := ""
			if sg.CategoryName != nil {
				to = *sg.CategoryName
			}
			ch["category"] = [2]any{sg.CurrentCategoryName, to}
		}
		if c.UnitID != nil {
			to := ""
			if sg.UnitName != nil {
				to = *sg.UnitName
			}
			ch["unit"] = [2]any{sg.CurrentUnitName, to}
		}
		if c.Images != nil {
			ch["photos"] = [2]any{lenp(cur.Images), len(*c.Images)}
		}
		if c.Barcodes != nil {
			ch["barcodes"] = [2]any{derefs(cur.Barcodes), *c.Barcodes}
		}
		asks = append(asks, ai.SuggestionAsk{ID: code, Product: sg.ProductName, Changes: ch})
	}
	ans, err := askAI(ctx, s, st, func(c context.Context) (ai.SuggestionAnswer, ai.Usage, error) {
		return st.conn.ReviewSuggestions(c, asks)
	})
	if err != nil {
		st.add(func(x *Stats) { x.Failed++ })
		return nil
	}
	for _, it := range ans.Items {
		sg, ok := byCode[strings.TrimSpace(it.ID)]
		if !ok {
			continue
		}
		delete(byCode, strings.TrimSpace(it.ID))
		reason := strings.TrimSpace(it.Reason)
		if !it.Approve && reason == "" {
			reason = "Исправление не подходит для общей карточки товара"
		}
		approve := it.Approve
		if _, err := s.cat.AdminReviewSuggestion(ctx, sg.ID, approve, reason); err != nil {
			e, isApp := apperr.As(err)
			if !approve || !isApp {
				s.log.Warn("catalognorm: исправление", "suggestion", sg.ID, "err", err)
				continue
			}
			// Принять не вышло (например, штрихкод уже у другого товара) — отклоняем с этой причиной.
			approve, reason = false, e.Text("ru")
			if _, err := s.cat.AdminReviewSuggestion(ctx, sg.ID, false, reason); err != nil {
				s.log.Warn("catalognorm: исправление", "suggestion", sg.ID, "err", err)
				continue
			}
		}
		status := "rejected"
		if approve {
			status = "approved"
			st.add(func(x *Stats) { x.SuggestionsApproved++ })
		} else {
			st.add(func(x *Stats) { x.SuggestionsRejected++ })
		}
		d, _ := json.Marshal(map[string]any{"suggestion_id": sg.ID, "reason": reason, "changes": sg.Changes, "name": sg.ProductName})
		if _, err := s.pool.Exec(ctx, `INSERT INTO catalog_norm_changes (run_id, product_id, kind, new_value, detail, applied)
			VALUES ($1, $2, 'suggestion', $3, $4, true)`, st.id, sg.ProductID, status, d); err != nil {
			return err
		}
	}
	return nil
}

func deref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func derefs(p *[]string) []string {
	if p == nil {
		return []string{}
	}
	return *p
}

func lenp(p *[]string) int {
	if p == nil {
		return 0
	}
	return len(*p)
}
