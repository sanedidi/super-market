// Package config читает настройки приложения из переменных окружения.
//
// Все настройки собраны в одной структуре Config, чтобы было видно,
// что именно нужно сервису для запуска. Обязательные значения
// проверяются в Load, и сервис не стартует с неполной конфигурацией.
package config

import (
	"errors"
	"fmt"
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
}

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
	if cfg.WorkerInterval, err = durationOr(getenv("WORKER_INTERVAL"), time.Minute); err != nil {
		errs = append(errs, fmt.Errorf("WORKER_INTERVAL: %w", err))
	}

	if len(errs) > 0 {
		return Config{}, errors.Join(errs...)
	}
	return cfg, nil
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
