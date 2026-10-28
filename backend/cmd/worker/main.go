// Команда worker — фоновые задачи: Telegram-бот, истечение неоплаченных
// заказов, уведомление супер-админа о непринятых заказах, счета за подписку
// и автосписание их с баланса платформы.
package main

import (
	"context"
	"fmt"
	"github.com/sanedidi/super-market/backend/internal/invoices"
	"github.com/sanedidi/super-market/backend/internal/summary"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/sanedidi/super-market/backend/internal/billing"
	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/debts"
	"github.com/sanedidi/super-market/backend/internal/family"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/notify"
	"github.com/sanedidi/super-market/backend/internal/platform/config"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/logger"
	"github.com/sanedidi/super-market/backend/internal/platform/telegram"
	"github.com/sanedidi/super-market/backend/internal/pos"
	"github.com/sanedidi/super-market/backend/internal/productsearch"
	"github.com/sanedidi/super-market/backend/internal/push"
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
			bot := identity.NewBot(svc, api, log)
			bot.Deeplinks = map[string]identity.DeeplinkFunc{"fam": familyDeeplink(pool, cfg, api, log)}
			bot.Run(ctx)
		}()
	} else {
		close(botDone)
		log.Warn("TELEGRAM_BOT_TOKEN не задан: бот не запущен")
	}
	defer func() { <-botDone }()

	// Push покупателям: очередь отправляется каждые 3 секунды, отдельно от
	// минутных задач, чтобы статус заказа приходил сразу.
	fcm := server.PushSender(cfg, log)
	if fcm == nil {
		log.Warn("FCM_CREDENTIALS не задан: push выключен, уведомления не доставляются")
	}
	pushDone := make(chan struct{})
	go func() {
		defer close(pushDone)
		push.NewDispatcher(pool, fcm, log).Run(ctx, 3*time.Second)
	}()
	defer func() { <-pushDone }()

	// Фото импортированных товаров из каталога ИКПУ: отдельный цикл, очередь большая.
	photosDone := make(chan struct{})
	if cfg.S3Endpoint != "" && cfg.MediaBaseURL != "" {
		fetcher := catalog.NewPhotoFetcher(pool, server.MediaService(cfg), cfg.MediaBaseURL, cfg.TasnifURL, cfg.PhotosPerProduct, log)
		go func() {
			defer close(photosDone)
			fetcher.Run(ctx, 30*time.Second)
		}()
	} else {
		close(photosDone)
		log.Warn("S3_ENDPOINT или MEDIA_BASE_URL не заданы: фото товаров из каталога ИКПУ не загружаются")
	}
	defer func() { <-photosDone }()

	// Данные поиска товаров (вес в выдаче, словарь опечаток) — в своей
	// горутине: пересчёт на большом каталоге не задерживает остальные задачи.
	searchDone := make(chan struct{})
	go func() {
		defer close(searchDone)
		productsearch.NewRanker(pool).Run(ctx, time.Minute, log)
	}()
	defer func() { <-searchDone }()

	dlv, _, ord := server.OrderServices(cfg, pool, sender, log)
	jobs := []Job{
		{Name: "db_ping", Run: pool.Ping},
		{Name: "orders_expire", Run: ord.ExpireUnpaid},
		{Name: "orders_alert", Run: ord.AlertUnaccepted},
		{Name: "popularity", Run: ord.RefreshPopularity},
		{Name: "crowd", Run: ord.CrowdTick},
		{Name: "invoice_scans", Run: invoices.NewService(pool, nil, nil, nil, log).Tick},
		{Name: "family_reminders", Run: family.NewService(pool, ord, dlv, cfg.TelegramBotUsername).Remind},
		{Name: "owner_summary", Run: summary.NewService(pool, log).Tick},
		{Name: "billing", Run: billing.NewService(pool, notify.New(pool, sender, log), log).Tick},
		// Долги покупателей: напоминание в день оплаты (10:00), за 3 дня и после срока.
		{Name: "debt_reminders", Run: debts.NewService(pool, nil, "", cfg.JWTSecret, nil, log).Tick},
		// Смены касс, открытые дольше 20 часов, — закрыть по расчёту (кассир не закрыл день).
		{Name: "pos_shifts_autoclose", Run: pos.NewService(pool, nil).AutoCloseStale},
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

// familyDeeplink — вступление в семью по ссылке t.me/<bot>?start=fam_<код>.
func familyDeeplink(pool *pgxpool.Pool, cfg config.Config, api notify.Sender, log *slog.Logger) identity.DeeplinkFunc {
	dlv, _, ord := server.OrderServices(cfg, pool, api, log)
	svc := family.NewService(pool, ord, dlv, cfg.TelegramBotUsername)
	return func(ctx context.Context, phone, code string) (string, error) {
		name, err := svc.JoinByPhone(ctx, phone, code)
		if err != nil {
			return "", err
		}
		// Язык — из Telegram пользователя (бот кладёт его в ctx).
		return i18n.T(ctx,
			fmt.Sprintf("Вы в семье «%s»! Откройте приложение Super Market — там общие списки покупок.", name),
			fmt.Sprintf("Siz «%s» oilasidasiz! Super Market ilovasini oching — u yerda umumiy xarid roʻyxatlari.", name)), nil
	}
}
