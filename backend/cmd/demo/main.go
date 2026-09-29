// Команда demo — наполняет платформу демо-данными и удаляет их.
//
//	demo seed [телефон]   сети, магазины, товары, остатки, продажи, акции, баннеры;
//	                      телефон (или первый из SUPER_ADMIN_PHONES) становится
//	                      владельцем сети «Baraka Market»
//	demo clean            удаляет всё, что создал seed
//
// Запуск на сервере: docker compose run --rm api demo seed.
// seed работает через HTTP API внутри процесса — с той же проверкой данных,
// что и панели; наружу ничего не открывается.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/sanedidi/super-market/backend/internal/platform/config"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "demo:", err)
		os.Exit(1)
	}
}

func run() error {
	if len(os.Args) < 2 || (os.Args[1] != "seed" && os.Args[1] != "clean") {
		return fmt.Errorf("использование: demo seed [телефон] | demo clean")
	}
	cfg, err := config.Load(os.Getenv)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, err := db.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer pool.Close()
	if _, err := pool.Exec(ctx, `CREATE TABLE IF NOT EXISTS demo_seed (
		kind text NOT NULL, id text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
		PRIMARY KEY (kind, id))`); err != nil {
		return err
	}

	if os.Args[1] == "clean" {
		return clean(ctx, pool)
	}
	owner := ""
	if len(os.Args) > 2 {
		owner = os.Args[2]
	} else if len(cfg.SuperAdminPhones) > 0 {
		owner = cfg.SuperAdminPhones[0]
	}
	return seed(ctx, cfg, pool, owner)
}
