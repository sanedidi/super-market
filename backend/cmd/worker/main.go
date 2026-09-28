// Команда worker — фоновые задачи: Telegram-бот, истечение неоплаченных
// заказов, уведомление супер-админа о непринятых заказах.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/notify"
	"github.com/sanedidi/super-market/backend/internal/platform/config"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/logger"
	"github.com/sanedidi/super-market/backend/internal/platform/telegram"
	"github.com/sanedidi/super-market/backend/internal/server"
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

	// Telegram-бот: принимает номера телефонов для кодов входа.
	botDone := make(chan struct{})
	var sender notify.Sender
	if cfg.TelegramBotToken != "" {
		api := telegram.New(cfg.TelegramBotToken, cfg.TelegramAPIURL)
		sender = api
		svc := identity.NewService(pool, api, identity.Config{Secret: cfg.JWTSecret}, log)
		go func() {
			defer close(botDone)
			identity.NewBot(svc, api, log).Run(ctx)
		}()
	} else {
		close(botDone)
		log.Warn("TELEGRAM_BOT_TOKEN не задан: бот не запущен")
	}
	defer func() { <-botDone }()

	_, _, ord := server.OrderServices(cfg, pool, sender, log)
	jobs := []Job{
		{Name: "db_ping", Run: pool.Ping},
		{Name: "orders_expire", Run: ord.ExpireUnpaid},
		{Name: "orders_alert", Run: ord.AlertUnaccepted},
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
