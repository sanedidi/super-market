COMPOSE = docker compose -f deploy/docker-compose.yml --env-file $(if $(wildcard .env),.env,.env.example)
DB_URL ?= postgres://market:market@localhost:5432/market?sslmode=disable

.PHONY: help up down logs ps migrate run-api run-worker test test-db fmt vet build

help: ## Список команд
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

up: ## Поднять всё окружение (db, redis, minio, migrate, api, worker)
	$(COMPOSE) up -d --build

down: ## Остановить окружение
	$(COMPOSE) down

logs: ## Логи api и worker
	$(COMPOSE) logs -f api worker

ps: ## Статус контейнеров
	$(COMPOSE) ps

migrate: ## Применить миграции к локальной базе (без docker)
	cd backend && DATABASE_URL="$(DB_URL)" go run ./cmd/migrate

run-api: ## Запустить api локально (база из docker)
	cd backend && DATABASE_URL="$(DB_URL)" go run ./cmd/api

run-worker: ## Запустить worker локально
	cd backend && DATABASE_URL="$(DB_URL)" go run ./cmd/worker

test: ## Юнит-тесты
	cd backend && go test -race ./...

test-db: ## Тесты вместе с интеграционными (нужна база из make up)
	cd backend && TEST_DATABASE_URL="$(DB_URL)" go test -race -count=1 ./...

fmt: ## gofmt
	cd backend && gofmt -w .

vet: ## go vet
	cd backend && go vet ./...

build: ## Собрать бинарники в backend/bin
	cd backend && go build -o bin/ ./cmd/...
