package variants

import (
	"context"
	"sync"
	"time"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// «Найти новые группы» идёт в фоне: ИИ разбирает пачки товаров минутами, а
// HTTP-запрос живёт 30 секунд (WriteTimeout API) и 90 секунд за nginx.
// POST запускает разбор и сразу отвечает состоянием, панель опрашивает GET.

// SuggestSync — разбирать сразу в запросе (тесты).
var SuggestSync bool

// SuggestStatus — состояние фонового разбора.
type SuggestStatus struct {
	Running bool `json:"running"`
	SuggestResult
	Error      string     `json:"error"`
	StartedAt  *time.Time `json:"started_at"`
	FinishedAt *time.Time `json:"finished_at"`
}

type suggestJob struct {
	mu     sync.Mutex
	status SuggestStatus
}

// StartSuggest запускает разбор, если он ещё не идёт, и отдаёт состояние.
func (s *Service) StartSuggest(ctx context.Context, in SuggestInput) (SuggestStatus, error) {
	// Неверный бренд — ошибка сразу, а не в фоне.
	if in.BrandID != nil && *in.BrandID != "" && !httpx.IsUUID(*in.BrandID) {
		return SuggestStatus{}, apperr.Validation("brand_id: бренд не найден").Uz("brand_id: brend topilmadi")
	}
	if SuggestSync {
		now := time.Now()
		res, err := s.Suggest(ctx, in)
		if err != nil {
			return SuggestStatus{}, err
		}
		return SuggestStatus{SuggestResult: res, StartedAt: &now, FinishedAt: &now}, nil
	}
	s.job.mu.Lock()
	defer s.job.mu.Unlock()
	if s.job.status.Running {
		return s.job.status, nil
	}
	now := time.Now()
	s.job.status = SuggestStatus{Running: true, StartedAt: &now}
	lang := i18n.FromContext(ctx)
	go func() {
		// Паника в разборе не должна ронять API и оставлять «идёт» навсегда.
		defer func() {
			if p := recover(); p != nil {
				s.log.Error("variants: паника в разборе", "panic", p)
				s.job.mu.Lock()
				defer s.job.mu.Unlock()
				done := time.Now()
				s.job.status.Running, s.job.status.FinishedAt = false, &done
				s.job.status.Error = i18n.Pick(lang, "не удалось найти группы — попробуйте ещё раз", "guruhlarni topib boʻlmadi — qayta urinib koʻring")
			}
		}()
		bctx := i18n.WithLang(context.Background(), lang)
		res, err := s.Suggest(bctx, in)
		done := time.Now()
		s.job.mu.Lock()
		defer s.job.mu.Unlock()
		s.job.status.Running, s.job.status.SuggestResult, s.job.status.FinishedAt = false, res, &done
		if err != nil {
			s.log.Error("variants: разбор не удался", "err", err)
			if e, ok := apperr.As(err); ok {
				s.job.status.Error = e.Text(lang)
			} else {
				s.job.status.Error = i18n.Pick(lang, "не удалось найти группы — попробуйте ещё раз", "guruhlarni topib boʻlmadi — qayta urinib koʻring")
			}
		}
	}()
	return s.job.status, nil
}

// SuggestState — состояние последнего разбора.
func (s *Service) SuggestState() SuggestStatus {
	s.job.mu.Lock()
	defer s.job.mu.Unlock()
	return s.job.status
}
