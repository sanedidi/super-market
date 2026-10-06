// Package config читает настройки приложения из переменных окружения.
//
// Все настройки собраны в одной структуре Config, чтобы было видно,
// что именно нужно сервису для запуска. Обязательные значения
// проверяются в Load, и сервис не стартует с неполной конфигурацией.
package config

import (
	"errors"
	"fmt"
	"github.com/sanedidi/super-market/backend/internal/platform/phone"
	"os"
	"strconv"
	"strings"
	"time"
)

// Env — окружение, в котором запущен сервис.
type Env string

const (
	EnvDev  Env = "dev"
	EnvProd Env = "prod"
)

// Config — все настройки backend (API, worker, migrate).
type Config struct {
	Env             Env
	HTTPAddr        string
	DatabaseURL     string
	LogLevel        string
	ShutdownTimeout time.Duration
	WorkerInterval  time.Duration

	// Авторизация.
	JWTSecret  string
	AccessTTL  time.Duration
	RefreshTTL time.Duration
	OTPTTL     time.Duration
	// DevOTPCode — фиксированный код входа без Telegram. Только в dev.
	DevOTPCode string
	// SuperAdminPhones — номера, которые при старте получают роль супер-админа.
	SuperAdminPhones []string

	// Telegram-бот для кодов входа.
	TelegramBotToken    string
	TelegramBotUsername string
	TelegramAPIURL      string

	// SMS для кодов входа (Eskiz): курьерам «по пути» и всем, чей номер не
	// привязан к Telegram-боту. Пустой EskizEmail — коды только в Telegram.
	EskizEmail    string
	EskizPassword string
	EskizFrom     string
	EskizAPIURL   string

	// Онлайн-оплата.
	PaymeMerchantID  string
	PaymeKey         string
	PaymeTest        bool
	ClickServiceID   string
	ClickMerchantID  string
	ClickSecretKey   string
	PaymentReturnURL string
	// Время на оплату заказа, потом он истекает и резерв снимается.
	PaymentTimeout time.Duration
	// Сколько ждать, пока магазин примет оплаченный заказ, до уведомления супер-админа.
	AcceptTimeout time.Duration

	// Push: ключ сервисного аккаунта Firebase (JSON, путь к файлу или base64).
	// Пусто — push выключен, уведомления уходят в Telegram.
	FCMCredentials string
	// Ссылки в профиле приложения: поддержка (по умолчанию — бот) и политика конфиденциальности.
	SupportURL string
	PrivacyURL string
	// OfferURL — публичная оферта (ссылка на экране входа).
	OfferURL string
	// CourierTermsURL — условия для курьеров «по пути».
	CourierTermsURL string
	// CourierAppURL — где скачать приложение курьера (App Store / TestFlight / сайт).
	// Пусто — баннер «Зарабатывайте на доставке» в приложении покупателя скрыт.
	CourierAppURL string

	// ReviewLogin — «+998XXXXXXXXX:123456»: демо-аккаунт для проверки
	// приложений в App Store / Google Play. Для этого номера код не
	// отправляется ни в Telegram, ни по SMS, а всегда равен указанному.
	// Работает в приложениях покупателя, магазина (номер должен быть у
	// активного сотрудника) и курьера «по пути»; в панель супер-админа — нет.
	ReviewLogin string

	// Хранилище фото (MinIO / S3). Пустой S3Endpoint — загрузка фото выключена.
	S3Endpoint  string
	S3AccessKey string
	S3SecretKey string
	S3Bucket    string
	// MediaBaseURL — начало ссылок на фото (https://super-market.uz). Пусто — из адреса запроса.
	MediaBaseURL string

	// TasnifURL — каталог ИКПУ (фото для импортированных товаров), PhotosPerProduct — сколько фото брать.
	TasnifURL        string
	PhotosPerProduct int
}

const devJWTSecret = "dev-secret-do-not-use-in-production"

// Load собирает Config из окружения. getenv передаётся параметром,
// чтобы конфиг можно было тестировать без изменения реального окружения.
func Load(getenv func(string) string) (Config, error) {
	if getenv == nil {
		getenv = os.Getenv
	}

	cfg := Config{
		Env:         Env(valueOr(getenv("APP_ENV"), string(EnvDev))),
		HTTPAddr:    valueOr(getenv("HTTP_ADDR"), ":8080"),
		DatabaseURL: getenv("DATABASE_URL"),
		LogLevel:    strings.ToLower(valueOr(getenv("LOG_LEVEL"), "info")),

		JWTSecret:           getenv("JWT_SECRET"),
		DevOTPCode:          getenv("DEV_OTP_CODE"),
		SuperAdminPhones:    splitList(getenv("SUPER_ADMIN_PHONES")),
		TelegramBotToken:    getenv("TELEGRAM_BOT_TOKEN"),
		TelegramBotUsername: strings.TrimPrefix(getenv("TELEGRAM_BOT_USERNAME"), "@"),
		TelegramAPIURL:      getenv("TELEGRAM_API_URL"),
		EskizEmail:          getenv("ESKIZ_EMAIL"),
		EskizPassword:       getenv("ESKIZ_PASSWORD"),
		EskizFrom:           getenv("ESKIZ_FROM"),
		EskizAPIURL:         getenv("ESKIZ_API_URL"),

		PaymeMerchantID:  getenv("PAYME_MERCHANT_ID"),
		PaymeKey:         getenv("PAYME_KEY"),
		PaymeTest:        getenv("PAYME_TEST") == "true",
		ClickServiceID:   getenv("CLICK_SERVICE_ID"),
		ClickMerchantID:  getenv("CLICK_MERCHANT_ID"),
		ClickSecretKey:   getenv("CLICK_SECRET_KEY"),
		PaymentReturnURL: getenv("PAYMENT_RETURN_URL"),

		FCMCredentials:  getenv("FCM_CREDENTIALS"),
		ReviewLogin:     strings.TrimSpace(getenv("REVIEW_LOGIN")),
		SupportURL:      getenv("SUPPORT_URL"),
		PrivacyURL:      getenv("PRIVACY_URL"),
		OfferURL:        getenv("OFFER_URL"),
		CourierTermsURL: getenv("COURIER_TERMS_URL"),
		CourierAppURL:   getenv("COURIER_APP_URL"),

		S3Endpoint:   strings.TrimRight(getenv("S3_ENDPOINT"), "/"),
		S3AccessKey:  getenv("S3_ACCESS_KEY"),
		S3SecretKey:  getenv("S3_SECRET_KEY"),
		S3Bucket:     valueOr(getenv("S3_BUCKET"), "media"),
		MediaBaseURL: strings.TrimRight(getenv("MEDIA_BASE_URL"), "/"),
		TasnifURL:    valueOr(strings.TrimRight(getenv("TASNIF_URL"), "/"), "https://tasnif.soliq.uz"),
	}

	var errs []error

	if cfg.Env != EnvDev && cfg.Env != EnvProd {
		errs = append(errs, fmt.Errorf("APP_ENV: ожидается %q или %q, получено %q", EnvDev, EnvProd, cfg.Env))
	}
	if cfg.DatabaseURL == "" {
		errs = append(errs, errors.New("DATABASE_URL: обязательная переменная"))
	}
	switch cfg.LogLevel {
	case "debug", "info", "warn", "error":
	default:
		errs = append(errs, fmt.Errorf("LOG_LEVEL: неизвестный уровень %q", cfg.LogLevel))
	}

	var err error
	if cfg.ShutdownTimeout, err = durationOr(getenv("SHUTDOWN_TIMEOUT"), 15*time.Second); err != nil {
		errs = append(errs, fmt.Errorf("SHUTDOWN_TIMEOUT: %w", err))
	}
	cfg.PhotosPerProduct = 2
	if v := getenv("PHOTOS_PER_PRODUCT"); v != "" {
		n, convErr := strconv.Atoi(v)
		if convErr != nil || n < 1 || n > 10 {
			errs = append(errs, fmt.Errorf("PHOTOS_PER_PRODUCT: от 1 до 10"))
		} else {
			cfg.PhotosPerProduct = n
		}
	}
	if cfg.WorkerInterval, err = durationOr(getenv("WORKER_INTERVAL"), time.Minute); err != nil {
		errs = append(errs, fmt.Errorf("WORKER_INTERVAL: %w", err))
	}
	if cfg.AccessTTL, err = durationOr(getenv("ACCESS_TTL"), 15*time.Minute); err != nil {
		errs = append(errs, fmt.Errorf("ACCESS_TTL: %w", err))
	}
	if cfg.RefreshTTL, err = durationOr(getenv("REFRESH_TTL"), 30*24*time.Hour); err != nil {
		errs = append(errs, fmt.Errorf("REFRESH_TTL: %w", err))
	}
	if cfg.OTPTTL, err = durationOr(getenv("OTP_TTL"), 5*time.Minute); err != nil {
		errs = append(errs, fmt.Errorf("OTP_TTL: %w", err))
	}
	if cfg.PaymentTimeout, err = durationOr(getenv("PAYMENT_TIMEOUT"), 15*time.Minute); err != nil {
		errs = append(errs, fmt.Errorf("PAYMENT_TIMEOUT: %w", err))
	}
	if cfg.AcceptTimeout, err = durationOr(getenv("ACCEPT_TIMEOUT"), 10*time.Minute); err != nil {
		errs = append(errs, fmt.Errorf("ACCEPT_TIMEOUT: %w", err))
	}

	switch {
	case cfg.JWTSecret == "" && cfg.Env == EnvDev:
		cfg.JWTSecret = devJWTSecret
	case len(cfg.JWTSecret) < 32:
		errs = append(errs, errors.New("JWT_SECRET: нужно не меньше 32 символов (в prod обязательно)"))
	}
	if cfg.DevOTPCode != "" {
		if cfg.Env == EnvProd {
			errs = append(errs, errors.New("DEV_OTP_CODE: запрещён в prod"))
		} else if len(cfg.DevOTPCode) != 6 || strings.Trim(cfg.DevOTPCode, "0123456789") != "" {
			errs = append(errs, errors.New("DEV_OTP_CODE: нужно 6 цифр"))
		}
	}

	if cfg.ReviewLogin != "" {
		if _, _, err := cfg.Review(); err != nil {
			errs = append(errs, err)
		}
	}

	if len(errs) > 0 {
		return Config{}, errors.Join(errs...)
	}
	return cfg, nil
}

func splitList(v string) []string {
	var out []string
	for _, p := range strings.Split(v, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func valueOr(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

func durationOr(v string, def time.Duration) (time.Duration, error) {
	if v == "" {
		return def, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		// Разрешаем и просто число секунд: SHUTDOWN_TIMEOUT=30.
		secs, convErr := strconv.Atoi(v)
		if convErr != nil {
			return 0, err
		}
		d = time.Duration(secs) * time.Second
	}
	if d <= 0 {
		return 0, fmt.Errorf("должно быть больше нуля, получено %s", d)
	}
	return d, nil
}

// Review разбирает REVIEW_LOGIN на номер и код.
func (c Config) Review() (phoneNumber, code string, err error) {
	if c.ReviewLogin == "" {
		return "", "", nil
	}
	ph, code, ok := strings.Cut(c.ReviewLogin, ":")
	if !ok || len(code) != 6 || strings.Trim(code, "0123456789") != "" {
		return "", "", errors.New("REVIEW_LOGIN: ожидается «номер:6 цифр»")
	}
	ph, err = phone.Normalize(ph)
	if err != nil {
		return "", "", errors.New("REVIEW_LOGIN: неверный номер")
	}
	return ph, code, nil
}
