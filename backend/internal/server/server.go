// Package server собирает HTTP API из модулей. Используется в cmd/api
// и в сквозных тестах, чтобы тесты проверяли ровно то, что запускается.
package server

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/delivery"
	"github.com/sanedidi/super-market/backend/internal/finance"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/notify"
	"github.com/sanedidi/super-market/backend/internal/orders"
	"github.com/sanedidi/super-market/backend/internal/payments"
	"github.com/sanedidi/super-market/backend/internal/platform/config"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/telegram"
	"github.com/sanedidi/super-market/backend/internal/sales"
	"github.com/sanedidi/super-market/backend/internal/tenant"
)

// App — собранное приложение: HTTP-обработчик и сервисы, которые нужны
// worker-у и тестам.
type App struct {
	Handler  http.Handler
	Orders   *orders.Service
	Payments *payments.Service
}

// New создаёт обработчик API. tg — отправитель кодов; nil — взять из
// конфига (или работать без бота).
func New(ctx context.Context, cfg config.Config, pool *pgxpool.Pool, tg identity.Sender, log *slog.Logger) (http.Handler, error) {
	app, err := Build(ctx, cfg, pool, tg, log)
	if err != nil {
		return nil, err
	}
	return app.Handler, nil
}

// Build собирает приложение целиком.
func Build(ctx context.Context, cfg config.Config, pool *pgxpool.Pool, tg identity.Sender, log *slog.Logger) (*App, error) {
	if tg == nil && cfg.TelegramBotToken != "" {
		client := telegram.New(cfg.TelegramBotToken, cfg.TelegramAPIURL)
		tg = client
		if cfg.TelegramBotUsername == "" {
			// Имя бота нужно для ссылки t.me/<bot> в ответе «номер не привязан».
			meCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
			me, err := client.GetMe(meCtx)
			cancel()
			if err != nil {
				log.Warn("не удалось узнать имя бота, задайте TELEGRAM_BOT_USERNAME", "err", err)
			} else {
				cfg.TelegramBotUsername = me.Username
				log.Info("telegram-бот подключён", "username", me.Username)
			}
		}
	}
	idSvc := identity.NewService(pool, tg, IdentityConfig(cfg), log)
	if err := idSvc.EnsureSuperAdmins(ctx, cfg.SuperAdminPhones); err != nil {
		return nil, err
	}
	auth := identity.NewAuthenticator(idSvc, log)

	dlv, pay, ord := OrderServices(cfg, pool, tg, log)

	h := httpx.NewRouter(log, pool,
		identity.NewModule(idSvc, auth, log),
		tenant.NewModule(tenant.NewService(pool), auth, log),
		catalog.NewModule(catalog.NewService(pool), auth, log),
		finance.NewModule(finance.NewService(pool), auth, log),
		inventory.NewModule(inventory.NewService(pool), auth, log),
		sales.NewModule(sales.NewService(pool), auth, log),
		orders.NewModule(ord, dlv, pay, auth, log),
	)
	return &App{Handler: h, Orders: ord, Payments: pay}, nil
}

// OrderServices создаёт доставку, платежи и заказы (общие для API и worker).
func OrderServices(cfg config.Config, pool *pgxpool.Pool, tg notify.Sender, log *slog.Logger) (*delivery.Service, *payments.Service, *orders.Service) {
	dlv := delivery.NewService(pool)
	pay := payments.NewService(pool, PaymentsConfig(cfg), log)
	ord := orders.NewService(pool, dlv, pay, notify.New(pool, tg, log), orders.Config{
		PaymentTimeout: cfg.PaymentTimeout,
		AcceptTimeout:  cfg.AcceptTimeout,
	}, log)
	return dlv, pay, ord
}

// PaymentsConfig переводит общий конфиг в настройки платежей.
func PaymentsConfig(cfg config.Config) payments.Config {
	return payments.Config{
		PaymeMerchantID: cfg.PaymeMerchantID,
		PaymeKey:        cfg.PaymeKey,
		PaymeTest:       cfg.PaymeTest,
		ClickServiceID:  cfg.ClickServiceID,
		ClickMerchantID: cfg.ClickMerchantID,
		ClickSecretKey:  cfg.ClickSecretKey,
		ReturnURL:       cfg.PaymentReturnURL,
	}
}

// IdentityConfig переводит общий конфиг в настройки входа.
func IdentityConfig(cfg config.Config) identity.Config {
	return identity.Config{
		Secret:      cfg.JWTSecret,
		AccessTTL:   cfg.AccessTTL,
		RefreshTTL:  cfg.RefreshTTL,
		OTPTTL:      cfg.OTPTTL,
		DevOTPCode:  cfg.DevOTPCode,
		BotUsername: cfg.TelegramBotUsername,
	}
}
