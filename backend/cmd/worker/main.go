// Команда worker — фоновые задачи: таймер непринятых заказов,
// рассылка уведомлений, подписки, балансы. Задачи добавляются
// на следующих этапах, пока worker только проверяет базу по расписанию.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/sanedidi/super-market/backend/internal/platform/config"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/logger"
)

// Job — одна периодическая задача. Ошибка задачи логируется и не
// останавливает worker: следующая попытка будет на следующем тике.
type Job struct {
	Name string
	Run  func(ctx context.Context) error
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "worker:", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load(os.Getenv)
	if err != nil {
		return err
	}
	log := logger.New(os.Stdout, cfg.LogLevel, cfg.Env == config.EnvProd).With("service", "worker")

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, err := db.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer pool.Close()

	jobs := []Job{
		{Name: "db_ping", Run: pool.Ping},
	}

	log.Info("worker запущен", "interval", cfg.WorkerInterval, "jobs", len(jobs))
	ticker := time.NewTicker(cfg.WorkerInterval)
	defer ticker.Stop()

	for {
		runAll(ctx, log, jobs)
		select {
		case <-ctx.Done():
			log.Info("worker остановлен")
			return nil
		case <-ticker.C:
		}
	}
}

func runAll(ctx context.Context, log *slog.Logger, jobs []Job) {
	for _, j := range jobs {
		start := time.Now()
		if err := j.Run(ctx); err != nil {
			log.Error("задача завершилась с ошибкой", "job", j.Name, "err", err)
			continue
		}
		log.Debug("задача выполнена", "job", j.Name, "duration_ms", time.Since(start).Milliseconds())
	}
}
