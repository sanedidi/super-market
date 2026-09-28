# super-market

Платформа для локальных магазинов и сетей: онлайн-заказы с доставкой силами магазина, учёт (закупки, склад, финансы), POS и панель супер-админа.

- Концепция и MVP: https://claude.ai/code/artifact/ed1758d3-5505-49e8-87e0-7c6bf1ac431f
- Архитектура и схема данных: https://claude.ai/code/artifact/5354efa4-3e4f-41a9-bfb1-9254a483052d

## Структура

```
backend/               Go, модульный монолит
  cmd/api              HTTP API
  cmd/worker           фоновые задачи
  cmd/migrate          миграции базы
  internal/platform    config, db, httpx, logger, migrate
  db/migrations        SQL-миграции (встраиваются в бинарник)
apps/                  (следующие этапы)
  client               Flutter, покупатель
  pos                  Flutter, POS
  store-panel          Next.js, панель магазина
  admin                Next.js, супер-админ
deploy/                docker-compose
```

## Быстрый старт

Нужны Docker и Go 1.24+.

```sh
make up          # db (PostGIS), redis, minio, migrate, api, worker
curl localhost:8080/healthz
curl localhost:8080/readyz
make logs
make down
```

Разработка без контейнера для API:

```sh
docker compose -f deploy/docker-compose.yml up -d db
make migrate
make run-api
make test-db     # тесты с интеграционными на локальной базе
```

`make help` — все команды.

## Соглашения

- Миграции: `backend/db/migrations/NNNN_name.sql`, применяются по порядку, каждая в своей транзакции.
- Ошибки API: `{"error": {"code": "...", "message": "..."}}`.
- Маршруты модулей: `/api/v1/...`; служебные: `/healthz`, `/readyz`.
