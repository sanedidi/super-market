# super-market

Платформа для локальных магазинов и сетей: онлайн-заказы с доставкой силами магазина, учёт (закупки, склад, финансы), POS и панель супер-админа.

- Концепция и MVP: https://claude.ai/code/artifact/ed1758d3-5505-49e8-87e0-7c6bf1ac431f
- Архитектура и схема данных: https://claude.ai/code/artifact/5354efa4-3e4f-41a9-bfb1-9254a483052d
- API: [docs/api.md](docs/api.md)
- Выпуск мобильных приложений в Google Play и App Store: [docs/release.md](docs/release.md)

## Структура

```
backend/               Go, модульный монолит
  cmd/api              HTTP API
  cmd/worker           фоновые задачи
  cmd/migrate          миграции базы
  internal/identity    вход (супер-админ — код из Telegram, магазин — логин и пароль), сессии, роли, сотрудники
  internal/tenant      сети, магазины, склады
  internal/catalog     справочники, товары, модерация, цены
  internal/inventory   партии FIFO, складские документы, резервы
  internal/finance     кассы, контрагенты, курс, кассовые операции
  internal/sales       POS-продажи, возвраты, фискальные чеки
  internal/delivery    доставка: часы, зоны, правила, магазины рядом
  internal/orders      онлайн-заказы
  internal/payments    Payme, Click, возвраты
  internal/billing     подписка, баланс платформы, вывод денег
  internal/reports     денежный поток, прибыль и убыток
  internal/notify      уведомления в Telegram
  internal/server      сборка API из модулей
  internal/platform    config, db, httpx, logger, migrate, money, telegram, token
  db/migrations        SQL-миграции (встраиваются в бинарник)
web/                   React + Ant Design
  shared               API-клиент, вход, общие компоненты
  store                панель магазина  (/)
  admin                панель супер-админа  (/admin/)
apps/                  Flutter
  client               приложение покупателя
  pos                  POS для планшета, телефона, десктопа
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

Панели (нужен Node.js 22, API на :8080):

```sh
cd web && npm install
npm run dev:store   # http://localhost:5173
npm run dev:admin   # http://localhost:5174/admin/
```

## Первый вход

1. Скопируй `.env.example` в `.env`, впиши `TELEGRAM_BOT_TOKEN` и свой номер в `SUPER_ADMIN_PHONES`.
2. `make up`, открой бота в Telegram и нажми «Поделиться номером».
3. `POST /api/v1/auth/otp/request` → код придёт в бот → `POST /api/v1/auth/otp/verify` с `"app": "admin"`.

Без Telegram: `DEV_OTP_CODE=111111` в `.env` — код не отправляется, подходит `111111` (только dev).

Магазин входит по логину и паролю: супер-админ при подключении сети задаёт владельцу логин и временный
пароль (панель супер-админа → «Подключить сеть» или карточка сети → «Владелец и вход»). При первом входе
владелец придумывает свой пароль. Сотрудникам логины выдаёт владелец: панель магазина → Сотрудники → «Выдать логин».

## Демо-данные

Чтобы посмотреть платформу «вживую», загрузите демо-данные: 3 сети и 6 магазинов в Ташкенте,
94 товара с характеристиками, остатки, цены сетей, кассовые продажи, акции и баннеры.

- На сервере: GitHub → Actions → **demo-data** → Run workflow → `seed` (или `clean`, чтобы удалить).
  Или без Actions: запишите в `deploy/demo-request` строку `seed <метка>` / `clean <метка>` и запушьте —
  деплой выполнит запрос один раз (новая метка — новый запуск).
  Владельцем сети Baraka Market станет указанный телефон (по умолчанию — первый из `SUPER_ADMIN_PHONES`),
  так что в панели магазина будут видны её данные.
- Локально: `cd backend && go run ./cmd/demo seed` / `go run ./cmd/demo clean`.
- Демо-доступ для проверки в App Store / Google Play: после `seed` — `review` (в Actions или
  `go run ./cmd/demo review`; нужен `REVIEW_LOGIN`). Номер из `REVIEW_LOGIN` станет сотрудником
  Baraka Market со всеми правами (в «SM Магазин» входит по логину `review.store`), курьером «по пути»
  с подтверждённой личностью и покупателем с адресом; для приложения курьера магазина заводится логин `review`.
  Пароли постоянные (выводятся из `JWT_SECRET`),
  повторный запуск безопасен; в конце печатается текст для заметок проверяющему.

`clean` удаляет только то, что загрузили `seed` и `review`.

## Соглашения

- Миграции: `backend/db/migrations/NNNN_name.sql`, применяются по порядку, каждая в своей транзакции.
- Ошибки API: `{"error": {"code": "...", "message": "..."}}`.
- Маршруты модулей: `/api/v1/...`; служебные: `/healthz`, `/readyz`.
