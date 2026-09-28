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
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/config"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/telegram"
	"github.com/sanedidi/super-market/backend/internal/tenant"
)

// New создаёт обработчик API. tg — отправитель кодов; nil — взять из
// конфига (или работать без бота).
func New(ctx context.Context, cfg config.Config, pool *pgxpool.Pool, tg identity.Sender, log *slog.Logger) (http.Handler, error) {
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

	return httpx.NewRouter(log, pool,
		identity.NewModule(idSvc, auth, log),
		tenant.NewModule(tenant.NewService(pool), auth, log),
		catalog.NewModule(catalog.NewService(pool), auth, log),
	), nil
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
