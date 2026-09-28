package config

import (
	"strings"
	"testing"
	"time"
)

func env(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestLoadDefaults(t *testing.T) {
	cfg, err := Load(env(map[string]string{"DATABASE_URL": "postgres://localhost/db"}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Env != EnvDev {
		t.Errorf("Env = %q, want %q", cfg.Env, EnvDev)
	}
	if cfg.HTTPAddr != ":8080" {
		t.Errorf("HTTPAddr = %q, want :8080", cfg.HTTPAddr)
	}
	if cfg.ShutdownTimeout != 15*time.Second {
		t.Errorf("ShutdownTimeout = %s, want 15s", cfg.ShutdownTimeout)
	}
	if cfg.WorkerInterval != time.Minute {
		t.Errorf("WorkerInterval = %s, want 1m", cfg.WorkerInterval)
	}
}

func TestLoadOverrides(t *testing.T) {
	cfg, err := Load(env(map[string]string{
		"APP_ENV":          "prod",
		"JWT_SECRET":       "0123456789abcdef0123456789abcdef",
		"HTTP_ADDR":        ":9000",
		"DATABASE_URL":     "postgres://db",
		"LOG_LEVEL":        "DEBUG",
		"SHUTDOWN_TIMEOUT": "30",
		"WORKER_INTERVAL":  "10s",
	}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Env != EnvProd || cfg.HTTPAddr != ":9000" || cfg.LogLevel != "debug" {
		t.Errorf("unexpected cfg: %+v", cfg)
	}
	if cfg.ShutdownTimeout != 30*time.Second {
		t.Errorf("ShutdownTimeout = %s, want 30s", cfg.ShutdownTimeout)
	}
	if cfg.WorkerInterval != 10*time.Second {
		t.Errorf("WorkerInterval = %s, want 10s", cfg.WorkerInterval)
	}
}

func TestLoadCollectsAllErrors(t *testing.T) {
	_, err := Load(env(map[string]string{
		"APP_ENV":          "staging",
		"LOG_LEVEL":        "loud",
		"SHUTDOWN_TIMEOUT": "-5s",
	}))
	if err == nil {
		t.Fatal("expected error")
	}
	for _, want := range []string{"APP_ENV", "DATABASE_URL", "LOG_LEVEL", "SHUTDOWN_TIMEOUT"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not mention %s", err, want)
		}
	}
}

func TestLoadAuthRules(t *testing.T) {
	cfg, err := Load(env(map[string]string{"DATABASE_URL": "x"}))
	if err != nil || cfg.JWTSecret == "" {
		t.Fatalf("dev must get a default JWT secret: %v", err)
	}

	_, err = Load(env(map[string]string{"APP_ENV": "prod", "DATABASE_URL": "x"}))
	if err == nil || !strings.Contains(err.Error(), "JWT_SECRET") {
		t.Errorf("prod without JWT_SECRET: err = %v", err)
	}

	_, err = Load(env(map[string]string{
		"APP_ENV": "prod", "DATABASE_URL": "x",
		"JWT_SECRET":   "0123456789abcdef0123456789abcdef",
		"DEV_OTP_CODE": "111111",
	}))
	if err == nil || !strings.Contains(err.Error(), "DEV_OTP_CODE") {
		t.Errorf("DEV_OTP_CODE in prod must fail: err = %v", err)
	}

	cfg, err = Load(env(map[string]string{"DATABASE_URL": "x", "SUPER_ADMIN_PHONES": " +998900000001, 998900000002 ,"}))
	if err != nil || len(cfg.SuperAdminPhones) != 2 {
		t.Errorf("SUPER_ADMIN_PHONES = %v, err %v", cfg.SuperAdminPhones, err)
	}
}
