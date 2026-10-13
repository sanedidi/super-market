package start

import (
	"context"
	"sync"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// «Распознать заново» — все нераспознанные разом (Figma «Требуют внимания —
// «Провести все»», В4): карточки «не удалось» (и зависшие «распознаётся»)
// магазина снова уходят Super Market. Распознаются в фоне по retryWorkers
// одновременно, чтобы не упереться в лимиты ИИ; не вышло снова — карточка
// опять «не удалось».

const retryWorkers = 3

// RetryAllInput — POST /store/start/new-items/retry-all.
type RetryAllInput struct {
	StoreID string `json:"store_id"`
}

// RetryAllResult — сколько карточек ушло на распознавание.
type RetryAllResult struct {
	Count int `json:"count"`
}

func (s *Service) RetryAllNewItems(ctx context.Context, p *identity.Principal, in RetryAllInput) (RetryAllResult, error) {
	var out RetryAllResult
	st, err := s.store(ctx, s.pool, p, in.StoreID)
	if err != nil {
		return out, err
	}
	if _, err := s.ai.Conn(ctx); err != nil {
		if ae, ok := apperr.As(err); ok && ae.Code == "ai_not_configured" {
			return out, apperr.Conflict("ai_not_configured", errNewOff(i18n.RU)).Uz(errNewOff(i18n.UZ))
		}
		return out, err
	}
	rows, err := s.pool.Query(ctx, `
		UPDATE start_new_items SET status = 'processing', error = ''
		WHERE store_id = $1 AND network_id = $2
		  AND (status = 'failed' OR (status = 'processing' AND updated_at < now() - $3::interval))
		RETURNING id`, st.ID, p.NetworkID, newStale.String())
	if err != nil {
		return out, err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return out, err
	}
	out.Count = len(ids)
	if len(ids) == 0 {
		return out, nil
	}
	lang := i18n.FromContext(ctx)
	s.run(func() {
		queue := make(chan string)
		var wg sync.WaitGroup
		for range min(retryWorkers, len(ids)) {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for id := range queue {
					s.recognizeNewItem(id, lang)
				}
			}()
		}
		for _, id := range ids {
			queue <- id
		}
		close(queue)
		wg.Wait()
	})
	return out, nil
}
