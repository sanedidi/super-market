// Package server собирает HTTP API из модулей. Используется в cmd/api
// и в сквозных тестах, чтобы тесты проверяли ровно то, что запускается.
package server

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/account"
	"github.com/sanedidi/super-market/backend/internal/admin"
	"github.com/sanedidi/super-market/backend/internal/ads"
	"github.com/sanedidi/super-market/backend/internal/ai"
	"github.com/sanedidi/super-market/backend/internal/billing"
	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/debts"
	"github.com/sanedidi/super-market/backend/internal/delivery"
	"github.com/sanedidi/super-market/backend/internal/family"
	"github.com/sanedidi/super-market/backend/internal/finance"
	"github.com/sanedidi/super-market/backend/internal/i18nadmin"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/invoices"
	"github.com/sanedidi/super-market/backend/internal/media"
	"github.com/sanedidi/super-market/backend/internal/notify"
	"github.com/sanedidi/super-market/backend/internal/orders"
	"github.com/sanedidi/super-market/backend/internal/payments"
	"github.com/sanedidi/super-market/backend/internal/platform/config"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/sms"
	"github.com/sanedidi/super-market/backend/internal/platform/telegram"
	"github.com/sanedidi/super-market/backend/internal/pos"
	"github.com/sanedidi/super-market/backend/internal/profile"
	"github.com/sanedidi/super-market/backend/internal/push"
	"github.com/sanedidi/super-market/backend/internal/reports"
	"github.com/sanedidi/super-market/backend/internal/sales"
	"github.com/sanedidi/super-market/backend/internal/setup"
	"github.com/sanedidi/super-market/backend/internal/start"
	"github.com/sanedidi/super-market/backend/internal/summary"
	"github.com/sanedidi/super-market/backend/internal/tenant"
)

// App — собранное приложение: HTTP-обработчик и сервисы, которые нужны
// worker-у и тестам.
type App struct {
	Handler  http.Handler
	Orders   *orders.Service
	Payments *payments.Service
	Billing  *billing.Service
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
	if SMSOverride != nil {
		idSvc.WithSMS(SMSOverride)
	} else if cfg.EskizEmail != "" {
		idSvc.WithSMS(sms.NewEskiz(cfg.EskizAPIURL, cfg.EskizEmail, cfg.EskizPassword, cfg.EskizFrom))
	}
	if err := idSvc.EnsureSuperAdmins(ctx, cfg.SuperAdminPhones); err != nil {
		return nil, err
	}
	auth := identity.NewAuthenticator(idSvc, log)

	dlv, pay, ord := OrderServices(cfg, pool, tg, log)
	bill := billing.NewService(pool, notify.New(pool, tg, log), log)

	salesSvc := sales.NewService(pool)
	debtSvc := debts.NewService(pool, tg, cfg.DevOTPCode, cfg.JWTSecret, sales.CheckShiftTime, log)
	fcm := PushSender(cfg, log)
	invSvc := inventory.NewService(pool)
	mediaSvc := MediaService(cfg)
	aiSvc := ai.NewService(pool, cfg.JWTSecret)
	scans := invoices.NewService(pool, aiSvc, mediaSvc, invSvc, log)
	catSvc := catalog.NewService(pool)
	tenantSvc := tenant.NewService(pool)
	startSvc := start.NewService(pool, aiSvc, mediaSvc, invSvc, catSvc, log)
	if InvoicesSync {
		scans.Sync()
		startSvc.Sync()
	}
	h := httpx.NewRouter(log, pool,
		identity.NewModule(idSvc, auth, log),
		tenant.NewModule(tenantSvc, auth, log),
		setup.NewModule(setup.NewService(pool, tenantSvc, dlv), auth, log),
		catalog.NewModule(catSvc, auth, log),
		finance.NewModule(finance.NewService(pool), auth, log),
		inventory.NewModule(invSvc, auth, log),
		sales.NewModule(salesSvc, auth, log),
		pos.NewModule(pos.NewService(pool, salesSvc).WithDebts(debtSvc), auth, log),
		debts.NewModule(debtSvc, auth, log),
		orders.NewModule(ord, dlv, pay, auth, log),
		billing.NewModule(bill, auth, log),
		ads.NewModule(ads.NewService(pool), auth, log),
		reports.NewModule(reports.NewService(pool), auth, log),
		profile.NewModule(profile.NewService(pool, profile.Links{
			Support: supportURL(cfg), Privacy: cfg.PrivacyURL, Offer: cfg.OfferURL, Bot: botURL(cfg),
			CourierTerms: cfg.CourierTermsURL, CourierApp: cfg.CourierAppURL,
		}, fcm != nil), auth, log),
		family.NewModule(family.NewService(pool, ord, dlv, cfg.TelegramBotUsername), auth, log),
		admin.NewModule(admin.NewService(pool, cfg.AcceptTimeout), auth, log),
		push.NewModule(push.NewService(pool, fcm), auth, log),
		media.NewModule(mediaSvc, auth, log),
		ai.NewModule(aiSvc, auth, log),
		i18nadmin.NewModule(i18nadmin.NewService(pool, aiSvc), auth, log),
		invoices.NewModule(scans, mediaSvc, auth, log),
		start.NewModule(startSvc, mediaSvc, auth, log),
		summary.NewModule(summary.NewService(pool, log), auth, log),
		account.NewModule(account.NewService(pool, idSvc, notify.New(pool, tg, log), log), auth, log),
	)
	return &App{Handler: h, Orders: ord, Payments: pay, Billing: bill}, nil
}

// MediaService — фото в MinIO; без S3_ENDPOINT загрузка выключена.
func MediaService(cfg config.Config) *media.Service {
	var store *media.S3
	if cfg.S3Endpoint != "" {
		store = &media.S3{
			Endpoint:  cfg.S3Endpoint,
			AccessKey: cfg.S3AccessKey,
			SecretKey: cfg.S3SecretKey,
			Bucket:    cfg.S3Bucket,
			HTTP:      &http.Client{Timeout: 60 * time.Second},
		}
	}
	return media.NewService(store, cfg.MediaBaseURL)
}

// PushSender — отправитель FCM, если ключ Firebase задан и читается
// (иначе nil: push выключен). Тесты подменяют его через PushOverride.
func PushSender(cfg config.Config, log *slog.Logger) push.Sender {
	if PushOverride != nil {
		return PushOverride
	}
	creds, err := push.LoadCredentials(cfg.FCMCredentials)
	if err != nil || creds == nil {
		if err != nil {
			log.Error("FCM_CREDENTIALS не читается", "err", err)
		}
		return nil
	}
	f, err := push.NewFCM(creds)
	if err != nil {
		log.Error("FCM_CREDENTIALS не читается", "err", err)
		return nil
	}
	return f
}

// SMSOverride — подмена SMS в тестах.
var SMSOverride identity.SMSSender

// InvoicesSync — распознавать накладные сразу в запросе (тесты).
var InvoicesSync bool

// PushOverride — подмена FCM в тестах.
var PushOverride push.Sender

// botURL — бот, который присылает коды входа.
func botURL(cfg config.Config) string {
	if cfg.TelegramBotUsername == "" {
		return ""
	}
	return "https://t.me/" + cfg.TelegramBotUsername
}

// supportURL — поддержка в Telegram: SUPPORT_URL или сам бот.
func supportURL(cfg config.Config) string {
	if cfg.SupportURL != "" {
		return cfg.SupportURL
	}
	if cfg.TelegramBotUsername != "" {
		return "https://t.me/" + cfg.TelegramBotUsername
	}
	return ""
}

// OrderServices создаёт доставку, платежи и заказы (общие для API и worker).
func OrderServices(cfg config.Config, pool *pgxpool.Pool, tg notify.Sender, log *slog.Logger) (*delivery.Service, *payments.Service, *orders.Service) {
	dlv := delivery.NewService(pool)
	pay := payments.NewService(pool, PaymentsConfig(cfg), log)
	ord := orders.NewService(pool, dlv, pay, notify.New(pool, tg, log), orders.Config{
		PaymentTimeout: cfg.PaymentTimeout,
		AcceptTimeout:  cfg.AcceptTimeout,
		Secret:         cfg.JWTSecret,
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
	reviewPhone, reviewCode, _ := cfg.Review()
	return identity.Config{
		ReviewPhone: reviewPhone,
		ReviewCode:  reviewCode,
		Secret:      cfg.JWTSecret,
		AccessTTL:   cfg.AccessTTL,
		RefreshTTL:  cfg.RefreshTTL,
		OTPTTL:      cfg.OTPTTL,
		DevOTPCode:  cfg.DevOTPCode,
		BotUsername: cfg.TelegramBotUsername,
	}
}
