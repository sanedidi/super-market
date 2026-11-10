package catalognorm

import (
	"context"
	"errors"
	"time"

	"github.com/sanedidi/super-market/backend/internal/ai"
)

// AutoEvery — как часто автоматический режим проверяет новые товары.
var AutoEvery = 10 * time.Minute

// StartWorker — прогоны, оборванные перезапуском, помечаются «прерван»;
// в режиме auto новые товары (и товары магазинов на модерации) проходят
// автонормализацию сами.
func (s *Service) StartWorker() {
	ctx := context.Background()
	if _, err := s.pool.Exec(ctx, `
		UPDATE catalog_norm_runs SET status = CASE WHEN status = 'applying' THEN 'done' ELSE 'interrupted' END,
		       error = CASE WHEN status = 'applying' THEN 'применение прервано перезапуском — нажмите «Применить» ещё раз' ELSE 'прерван перезапуском сервера' END,
		       finished_at = COALESCE(finished_at, now())
		WHERE status IN ('running', 'applying')`); err != nil {
		s.log.Error("catalognorm: прерванные прогоны", "err", err)
	}
	go func() {
		time.Sleep(time.Minute)
		for {
			if err := s.AutoOnce(ctx); err != nil {
				s.log.Error("catalognorm: автоматический прогон", "err", err)
			}
			time.Sleep(AutoEvery)
		}
	}()
}

// AutoOnce — один автоматический прогон новых товаров, если режим auto
// включён, ИИ подключён и есть что разбирать. Возвращает без ошибки, если
// делать нечего или идёт другой прогон.
func (s *Service) AutoOnce(ctx context.Context) error {
	set, err := s.Settings(ctx)
	if err != nil {
		return err
	}
	if !set.Auto || set.Pending == 0 && set.Suggestions == 0 {
		return nil
	}
	if _, err := s.ai.Conn(ctx); err != nil {
		if errors.Is(err, ai.ErrNotConfigured) {
			return nil
		}
		return err
	}
	if !s.acquire() {
		return nil
	}
	defer s.release()
	in := StartInput{OnlyNew: true}
	id, err := s.newRun(ctx, "auto", in, nil)
	if err != nil {
		return err
	}
	s.execute(ctx, id, in, AutoLimit)
	return nil
}
