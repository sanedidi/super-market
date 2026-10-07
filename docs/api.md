# API

Базовый путь: `/api/v1`. Все тела — JSON. Ошибка всегда в формате:

```json
{"error": {"code": "validation", "message": "текст для человека", "details": {}}}
```

Защищённые маршруты требуют `Authorization: Bearer <access_token>`. Токен выдаётся
на одно приложение: `client` (покупатель), `store` (панель магазина и POS), `admin` (супер-админ).

## Вход (этап 1)

Код входа приходит в Telegram-бот. Перед первым входом человек открывает бота
и нажимает «Поделиться номером» — так бот узнаёт, в какой чат слать коды.

| Метод | Путь | Тело | Ответ |
| --- | --- | --- | --- |
| POST | `/auth/otp/request` | `{"phone"}` | `{"sent": true, "expires_in": 300, "channel": "telegram"\|"sms"}` — код в Telegram, если номер привязан к боту, иначе по SMS (Eskiz, текст — одобренный шаблон `identity.SMSCodeText`) · 409 `telegram_not_linked` с `details.bot_url`, если нет ни бота, ни SMS · 429 `too_many_requests` с `details.retry_after` |
| POST | `/auth/otp/verify` | `{"phone", "code", "app"}` | `{"access_token", "refresh_token", "token_type", "expires_in"}` · 403 — нет доступа к приложению |
| POST | `/auth/refresh` | `{"refresh_token"}` | новая пара токенов; старый refresh больше не действует |
| POST | `/auth/{client,store,admin}/logout` | — | 204 |

Покупатель регистрируется при первом входе. В `admin` входят номера из `SUPER_ADMIN_PHONES`.
В `store` (панель магазина и «SM Магазин») по коду войти нельзя — 403 `password_login_required`,
только по логину и паролю (ниже).
Access-токен живёт 15 минут, refresh — 30 дней. После 5 неверных кодов код сгорает.

**Демо-вход для проверки в App Store / Google Play** — env `REVIEW_LOGIN=+998XXXXXXXXX:123456`. Для этого
номера код не отправляется (ни Telegram, ни SMS) и всегда равен указанному. Работает в приложениях
`client` и `crowd` с обычными проверками: в `crowd` — регистрация с `terms_accepted: true` (иначе 422
`terms_required`). В `admin` демо-номер не входит никогда (400). Для проверки «SM Магазин» проверяющим
дают логин и пароль сотрудника демо-сети.

### Вход в магазин по логину и паролю

Логин и временный пароль владельцу выдаёт супер-админ (при создании сети или позже), сотрудникам —
владелец или менеджер с правом `staff.manage`. Один логин на сотрудника: им же курьер входит в
приложение курьера. Логин — латиница, цифры, `.`, `_`, `-`, 3–32 символа, без учёта регистра.
После 5 неверных паролей подряд вход по логину закрыт на 15 минут (попытка засчитывается до проверки пароля — параллельные запросы лимит не обходят).

Пока пароль временный, токен `store` пускает только на `GET /store/me` (`must_change_password: true`),
`POST /auth/store/password` и `POST /auth/store/logout`; остальные маршруты — 403
`password_change_required`.

| Метод | Путь | Тело | Ответ |
| --- | --- | --- | --- |
| POST | `/auth/store/login` | `{"login", "password"}` | токены + `password_change_required: true`, если пароль временный · 401 `invalid_credentials` с `details.attempts_left` · 429 `too_many_requests` с `details.retry_after` · 403 — сотрудник или сеть отключены |
| POST | `/auth/store/password` | `{"current_password"?, "new_password"}` | 204. Новый пароль: 8–72 символа, буквы и цифры, не совпадает с прежним. `current_password` не нужен, пока пароль временный; иначе неверный — 422 `wrong_password`. Остальные сессии сотрудника (панель и курьер) закрываются |

## Супер-админ (`app=admin`)

| Метод | Путь | Описание |
| --- | --- | --- |
| GET | `/admin/networks?q=&limit=&offset=` | сети, поиск по названию, телефону и логину владельца |
| POST | `/admin/networks` | `{"name", "kind": "chain"\|"single", "owner_phone", "owner_name", "owner_login", "owner_password"}` — сеть + роль «Владелец» + сотрудник-владелец с логином и временным паролем (пароль 8–72 символа; логин и пароль можно не передавать — выдать позже). 409 `login_taken` |
| PATCH | `/admin/networks/{id}/owner` | `{"full_name"?, "phone"?}` — имя и телефон владельца меняет только супер-админ. Новый номер — другой пользователь (аккаунт покупателя остаётся у старого номера), сессии владельца закрываются, логин сохраняется. 409 `employee_exists` — номер уже сотрудник |
| PUT | `/admin/networks/{id}/owner/login` | `{"login", "password"?}` — логин владельца; с паролем — сброс: новый временный пароль, сессии владельца закрываются. Первый логин — только с паролем |
| GET | `/admin/networks/{id}` | сеть |
| GET | `/admin/networks/{id}/stores` | магазины сети (все, включая выключенные) |
| PATCH | `/admin/networks/{id}` | `{"name"?, "status"?: "active"\|"blocked"}` — блокировка сразу закрывает доступ сотрудникам |

Списки супер-админа отдаются страницами: `limit` (по умолчанию 50, максимум 200) и `offset`; общего числа
записей нет — панель запрашивает `limit+1`, чтобы понять, есть ли следующая страница.

### Сводка

| Метод | Путь | Описание |
| --- | --- | --- |
| GET | `/admin/stats` | `stale_orders` (оплачены, но не приняты вовремя), `paid_waiting` (оплачены, ждут принятия), `refunds_pending`, `payouts_requested`, `products_pending` (на модерации), `overdue_networks` (сети с просроченным счётом), `failed_notifications`, `today_orders` и `today_gmv` (оплаченные сегодня по Ташкенту заказы без отменённых, сумма `total`), `accept_timeout_min` |

### Покупатели

| Метод | Путь | Описание |
| --- | --- | --- |
| GET | `/admin/customers?q=&blocked=true&limit=&offset=` | `q` — телефон (от 3 цифр) или имя. Поля: `id`, `phone`, `full_name`, `created_at`, `deleted_at`, `blocked_at`, `blocked_reason`, `orders_count` (без неоплаченных), `last_order_at`, `family_name`, `telegram_linked` |
| GET | `/admin/customers/{id}` | то же + `language`, `city`, `devices_count`, `addresses`, `recent_orders` (20 последних) |
| POST | `/admin/customers/{id}/block` | `{"reason"}` обязательно. 409 `already_blocked` |
| POST | `/admin/customers/{id}/unblock` | 409 `not_blocked` |

Заблокированный покупатель не входит в приложение заново (`/auth/otp/verify` с `app=client` → 403
`customer_blocked`) и не оформляет заказы (`POST /client/orders` → 403 `customer_blocked`). Открытые сессии
не закрываются: он по-прежнему видит свои заказы и возвраты.

### Уведомления покупателям

| Метод | Путь | Описание |
| --- | --- | --- |
| GET | `/admin/notifications?status=&kind=&q=&limit=&offset=` | журнал доставки (`notifications_outbox`): `status` — `pending`, `sent`, `skipped` (нет push), `failed`; `kind` — `order`, `family`, `campaign`, `test`; `q` — телефон (от 3 цифр) или текст заголовка. Поля: `id` (число), `user_id`, `phone`, `kind`, `title`, `body`, `status`, `channel`, `attempts`, `last_error` (причина по-русски), `devices` («iPhone, Android» — куда дошло), `send_after`, `created_at`, `sent_at` |
| POST | `/admin/notifications/{id}/retry` | вернуть `failed`/`skipped` в очередь (попытки с нуля). Иначе 409 `not_failed` |

### Вход курьера по логину и паролю

Логин и пароль курьеру выдаёт магазин. Токен приложения `courier` открывает только `/courier/*`
(и `/auth/courier/logout`); панель магазина с ним недоступна. После 5 неверных паролей подряд вход по
логину закрыт на 15 минут. Новый пароль или отключение входа закрывают все сессии курьера.

| Метод | Путь | Описание |
|---|---|---|
| POST | `/auth/courier/login` | `{login, password}` → токены (`access_token`, `refresh_token`). 401 `invalid_credentials` с `details.attempts_left`; 429 `too_many_requests` с `details.retry_after`; 403 — нет права «Курьер» |
| POST | `/auth/courier/logout` | закрыть сессию |
| GET | `/store/couriers/{employee_id}/login` | `login`, `password_changed_at`, `last_login_at`, `locked`. 404 — входа нет. Права: `staff.manage` или `orders.manage` |
| PUT | `/store/couriers/{employee_id}/login` | `{login, password?}` — логин `[a-z0-9._-]`, 3–32; пароль 8–72 (пустой — не менять), не временный. 409 `login_taken`; 400 — у роли нет `orders.deliver`; 403 — владелец, у курьера в роли есть права кроме доставки, а у вас нет `staff.manage`, или курьер работает в магазинах, которых вы не видите. Это тот же логин, что в `/store/employees/{id}/login`: в приложении курьера пароль сразу постоянный, в панель с ним пустят только после смены |
| DELETE | `/store/couriers/{employee_id}/login` | отключить вход → 204 |

`/store/couriers` отдаёт `login` и `last_login_at`. `/courier/me` — ещё `phone`, `login` и `stores [{id, name, address, phone}]`.
Заказ курьера — ещё `customer_name`, `items_count`, `picked_up_at`, `cash` (брать наличные).
`GET /courier/history?period=today|yesterday|week` (по Ташкенту) → `items [{id, number, store_name, address, total, cash, picked_up_at, delivered_at}]`, `delivered`, `cash_total`, `avg_minutes`.

### Push-рассылки

Рассылка = заголовок (до 65), текст (до 240), переход `target` и аудитория `audience`. Отправляет воркер в `send_at`:
кладёт по уведомлению (`kind = campaign`) на каждого получателя, дальше — как обычные push. Ночью (22:00–08:00
по Ташкенту) время переносится на 08:00. Отписавшиеся от акций (`notifications.promos = false`) не получают, кроме «одного клиента».
У кого нет push — уведомление остаётся в колокольчике (`skipped`, «Нет push»).

`target`: `{type}` — `home`, `catalog`, `map`, `cart`, `orders`, `profile`, `family`; `store` (`store_id`), `category`
(`store_id`, `category_id`), `product` (`store_id`, `product_id`), `deals` (`store_id`); у category/product/deals
`store_id` может быть `nearest` — ближайший магазин покупателя; `block` (`block_id` блока главной платформы); `url` (`https://…`).
Данные push: `{"type": "open", "target": …, "store_id"…, "campaign_id"}`.

`audience`: `{type: all}`, `{type: one, user_id}` или `{type: filter, city?, language? (ru|uz), network_id? | store_id?,
orders? (within | not_within | never), days? (1–365)}` — город в профиле или магазина, где заказывал; сеть/магазин — где заказывал.

| Метод | Путь | Описание |
|---|---|---|
| GET | `/admin/push/overview` | `with_push`, `without_push`, `promos_off` — покупатели; `sent_30d`, `total_30d`, `delivered_30d` (%); `push_enabled` |
| POST | `/admin/push/campaigns/preview` | тело как у создания → `recipients`, `with_push`, `without_push`, `send_at` (после ночного переноса), `shifted`, `target_title` («Лимонария → Фрукты»), `audience_title` |
| POST | `/admin/push/campaigns` | `{title, body, target, audience, send_at?}` (`send_at: null` — сейчас) → 201 рассылка. 400, если никто не подходит |
| GET | `/admin/push/campaigns?status=` | `scheduled`, `sending`, `sent`, `cancelled`. Поля: `id`, `title`, `body`, `target`, `target_title`, `audience`, `audience_title`, `send_at`, `status`, `recipients`, `created_by`, `created_at`, `started_at`, `finished_at`, `cancelled_at`, `stats {pending, sent, no_push, failed}` |
| GET | `/admin/push/campaigns/{id}` | рассылка |
| GET | `/admin/push/campaigns/{id}/recipients?status=&q=` | `status` — `sent`, `not_sent`, `pending`; `q` — телефон или имя. Поля: `phone`, `name`, `status`, `devices`, `reason`, `sent_at` |
| POST | `/admin/push/campaigns/{id}/cancel` | только `scheduled`, иначе 409 `campaign_started` |
| GET | `/admin/push/customer?phone=` | покупатель для «одного клиента» и теста (без phone — сам админ): `user_id`, `phone`, `name`, `orders`, `last_order_at`, `promos_on`, `devices [{platform, name, last_seen_at}]` |
| POST | `/admin/push/test` | `{phone?, title?, body?, target?}` — отправить сразу; ответ `results [{name, ok, reason, ms}]`. 409 `no_devices`, `push_disabled`. Пишется в журнал (`kind = test`) |
| GET | `/admin/push/blocks` | блоки главной платформы для перехода `block`: `id`, `title` |
| GET | `/admin/push/cities` | города магазинов и покупателей |

## Панель магазина (`app=store`)

| Метод | Путь | Право | Описание |
| --- | --- | --- | --- |
| GET | `/store/me` | — | сеть, права, доступные магазины; `full_name`, `phone`, `role_name` сотрудника; `must_change_password` — вошёл по временному паролю |
| GET | `/store/stores` | — | магазины, к которым есть доступ |
| POST | `/store/stores` | `stores.manage` | `{"name", "address"?, "phone"?, "lat"?, "lng"?}` — создаёт и «Основной склад»; у `single` только один магазин |
| GET | `/store/stores/{id}` | — | магазин |
| PATCH | `/store/stores/{id}` | `stores.manage` | + `status`, `default_warehouse_id` |
| GET | `/store/warehouses?store_id=` | — | склады |
| POST | `/store/warehouses` | `stores.manage` | `{"store_id", "name"}` |
| PATCH | `/store/warehouses/{id}` | `stores.manage` | `{"name"?, "is_active"?}`; склад по умолчанию отключить нельзя |
| GET | `/store/permissions` | `staff.manage` | список прав для экрана ролей |
| GET/POST | `/store/roles` | `staff.manage` | `{"name", "permissions": [...]}` |
| PATCH | `/store/roles/{id}` | `staff.manage` | роль владельца не меняется |
| GET/POST | `/store/employees` | `staff.manage` | `{"phone", "full_name", "role_id", "all_stores"?, "store_ids"?}` |
| PATCH | `/store/employees/{id}` | `staff.manage` | `{"full_name"?, "role_id"?, "status"?, "all_stores"?, "store_ids"?}`; блокировка закрывает сессии; у владельца — только `full_name` |
| GET/PUT/DELETE | `/store/employees/{id}/login` | `staff.manage` | логин сотрудника для панели и «SM Магазин»: `{"login", "password"?}`; пароль временный — при первом входе сотрудник придумает свой; новый пароль или отключение закрывают его сессии. Ответ: `employee_id`, `login`, `must_change_password`, `password_changed_at`, `last_login_at`, `locked`. 403 — логин владельца (меняет только супер-админ) или сотрудник видит магазины, которых не видите вы |

Права читаются из базы на каждый запрос: изменение роли или блокировка действуют сразу.

Сотрудник без доступа ко всем магазинам правит магазины других сотрудников только в пределах своих:
`store_ids` из запроса заменяют лишь видимые ему магазины, остальные магазины сотрудника сохраняются.
Назначить магазин, к которому нет доступа, или изменить `all_stores` он не может — 403.

Небольшие справочники (`/store/stores`, `/store/warehouses`, `/store/roles`, `/store/price-types`, `/store/finance/cashboxes`,
`/payment-methods`, `/reasons`, `/counterparty-types`) без `limit` отдаются целиком, с `limit`/`offset` — страницей.

### Права на чтение

Списки и карточки разделов читаются только с правом на раздел, иначе 403 `forbidden`
с `details.permission` (первое подходящее право) и `details.any_of` (любое из них):

| Что | Право (любое из) |
| --- | --- |
| `/store/permissions`, `/store/roles`, `/store/employees` | `staff.manage` |
| `/store/price-documents*`, `/store/promotions*` | `prices.manage` |
| `/store/finance/counterparties*`, `/store/finance/counterparty-types` | `counterparties.manage`, `inventory.manage`, `finance.manage` |
| `/store/finance/rates` | `finance.manage`, `inventory.manage` |
| `/store/finance/cashboxes*`, `/reasons`, `/operations`, `/transfers`, `/handovers` | `finance.manage` |
| `/store/inventory/documents*` | `inventory.manage` |
| `/store/sales*` (чеки, возвраты, итоги, контроль чеков) | `sales.pos`, `sales.return`, `reports.view` |
| `/store/orders*`, `/store/couriers` | `orders.manage` (курьеры работают через `/courier/*`) |
| `/store/stores/{id}/delivery`, `/store/stores/{id}/zones` | `stores.manage`, `orders.manage` |
| `/store/balance*`, `/store/payouts`, `/store/billing*` | `payouts.manage` |
| `/store/reports/*` | `reports.view` |

Всем сотрудникам доступны: `/store/me`, магазины, склады, товары, справочники каталога, типы цен,
способы оплаты, остатки и история движения. Себестоимость в остатках и движениях
(`avg_cost`, `total_cost`, `avg_cost_usd`, `unit_cost`, `cost_value`) отдаётся только с `inventory.manage` или `reports.view`,
иначе этих полей нет в ответе.

## Каталог (этап 2)

Деньги — строки в сумах с двумя знаками (`"15000.00"`). В запросах сумму можно передать числом или строкой.

### Справочники

`{kind}` — `brands`, `categories`, `colors`, `units`. Общие для всей платформы, ведёт супер-админ.
Записи не удаляются: `is_active: false` скрывает их из панели магазина.

| Метод | Путь | Тело |
| --- | --- | --- |
| GET | `/admin/catalog/{kind}?q=&limit=&offset=` | записи по страницам (по умолчанию 50, максимум 200); `q` — поиск по названию. Для категорий: `exclude_tree={id}` — без этой категории и её потомков (варианты родителя), в ответе есть `parent_name` |
| POST | `/admin/catalog/{kind}` | brands: `{"name"}` · categories: `{"name", "parent_id"?, "sort"?}` · colors: `{"name", "hex"?: "#FF0000"}` · units: `{"name", "short_name", "is_fractional"?}` |
| PATCH | `/admin/catalog/{kind}/{id}` | любые поля + `is_active`. Категорию нельзя вложить в саму себя или в свою подкатегорию — 400 `validation` |
| GET | `/store/catalog/{kind}` | только активные |

Единицы «шт», «кг», «л», «уп» создаются миграцией.

### Товары

Товар: `name`, `description`, `brand_id`, `category_id`, `unit_id`, `color_id`, `base_price`, `images` (ссылки), `barcodes`, `is_active`.
Штрихкод уникален на всю платформу — при совпадении ответ 409 `barcode_exists` с `details.product_id`.
В PATCH `brand_id`/`color_id`: нет поля или `null` — не менять, `""` — убрать бренд/цвет.

| Метод | Путь | Описание |
| --- | --- | --- |
| GET | `/admin/products?q=&category_id=&barcode=&status=&limit=&offset=` | все товары; `status=pending` — очередь модерации, `approved`, `rejected` |
| POST | `/admin/products` | товар общего каталога (сразу одобрен) |
| GET/PATCH | `/admin/products/{id}` | |
| POST | `/admin/products/{id}/approve` | товар сети становится общим (`network_id` → null) |
| POST | `/admin/products/{id}/reject` | `{"reason"}` |
| GET | `/store/products?q=&category_id=&barcode=&store_id=&price_type_id=` | общие товары + свои. С `store_id` в ответе есть `price`, `price_source` (`store`/`network`/`base`) и `price_type_id` |
| POST | `/store/products` | `catalog.manage` — свой товар, уходит на модерацию |
| GET/PATCH | `/store/products/{id}` | свой товар можно править до одобрения; правка отклонённого снова отправляет на модерацию |

Поиск по категории включает все её подкатегории. `q` ищет по названию и точному штрихкоду.

### Цены

Итоговая цена товара в магазине по выбранному типу цены: цена магазина → цена сети → `base_price`.
Тип цены для приложения — `stores.online_price_type_id` (PATCH `/store/stores/{id}`), если не задан — тип по умолчанию сети.
У каждой новой сети автоматически есть тип «Розничная» (по умолчанию).

| Метод | Путь | Право | Описание |
| --- | --- | --- | --- |
| GET | `/store/price-types` | — | |
| POST | `/store/price-types` | `catalog.manage` | `{"name"}` |
| PATCH | `/store/price-types/{id}` | `catalog.manage` | `{"name"?, "is_active"?, "is_default": true}` |
| GET | `/store/price-documents` | `prices.manage` | документы «Установка цен» |
| POST | `/store/price-documents` | `prices.manage` | `{"price_type_id", "store_id"?: null — вся сеть, "note"?, "items": [{"product_id", "new_price"}]}` — черновик |
| GET | `/store/price-documents/{id}` | `prices.manage` | со строками: `previous_price` (после проведения), `current_price` — действующая сейчас цена на уровне документа |
| PATCH | `/store/price-documents/{id}` | `prices.manage` | `{"note"?, "items"?}` — только черновик, `items` заменяются целиком |
| POST | `/store/price-documents/{id}/post` | `prices.manage` | провести: записать цены, запомнить прежние |

Документ на всю сеть может создать только сотрудник с доступом ко всем магазинам.

## Склад (этап 3)

Все пути под `/store/inventory`, право на изменения — `inventory.manage`. Количество — строка/число до 3 знаков (`"2.5"`);
у штучных товаров только целое.

Складской документ один на все виды, различается полем `type`:

| type | Что делает | Обязательные поля |
| --- | --- | --- |
| `income` | приход от поставщика: новая партия, долг поставщику + | `warehouse_id`, `counterparty_id`, `currency` (UZS/USD), в строках `price` |
| `supplier_return` | возврат поставщику: списание FIFO, долг − | `warehouse_id`, `counterparty_id`; `price` необязательна — тогда по себестоимости |
| `transfer` | между складами (и между магазинами сети): партии переезжают со своей себестоимостью | `warehouse_id`, `to_warehouse_id` |
| `write_off` | списание FIFO | `warehouse_id`, `reason` |
| `posting` | оприходование (начальные остатки, находки) | `warehouse_id`, в строках `price` — себестоимость |
| `inventory` | инвентаризация: `qty` в строках — факт; при проведении излишек приходуется по последней себестоимости, недостача списывается FIFO | `warehouse_id` |

| Метод | Путь | Описание |
| --- | --- | --- |
| GET | `/documents?type=&status=&store_id=&warehouse_id=&from=&to=&limit=&offset=` | список, новые сверху; `store_id` — документы складов магазина, перемещения — и входящие на его склады |
| POST | `/documents` | черновик `{"type", "warehouse_id", ..., "items": [{"product_id", "qty", "price"?}]}` |
| GET | `/documents/{id}` | со строками; у инвентаризации после проведения `expected_qty` |
| PATCH | `/documents/{id}` | черновик: `counterparty_id`, `currency`, `reason`, `note`, `items` (целиком) |
| DELETE | `/documents/{id}` | удалить черновик |
| POST | `/documents/{id}/post` | провести; 409 `insufficient_stock` с `details.product_id/available/required`, если товара не хватает — тогда ничего не меняется |
| GET | `/stock?warehouse_id=&store_id=&product_id=&q=&limit=&offset=` | остатки с `avg_cost`, `total_cost`, `avg_cost_usd` |
| GET | `/stock/summary?warehouse_id=&store_id=&product_id=&q=` | итоги по всем строкам фильтра: `positions` (склад × товар), `products`, `cost_value` (себестоимость, UZS) |
| GET | `/movements?warehouse_id=&product_id=&limit=&offset=` | история движения, новые сверху; с `product_id` — ещё `balance_after` (остаток после операции, верен на любой странице) |

Цена в строке (`price`) — до 4 знаков после точки (`"1234.5678"`), так же и в ответе.
Себестоимость партии хранится в UZS и USD по курсу на момент проведения. Приход в USD без установленного курса не проводится.
Номера документов — свои для каждого вида в сети.

## Финансы (этап 3)

Все пути под `/store/finance`. Права: `finance.manage` (кассы, операции, курс, перемещения), `counterparties.manage`.

| Метод | Путь | Описание |
| --- | --- | --- |
| GET/POST | `/rates` | курс: `{"rate": 12700}` — сумов за 1 USD; действует последний |
| GET/POST/PATCH | `/counterparty-types`, `/counterparty-types/{id}` | `{"name", "is_active"?}` |
| GET/POST | `/counterparties?q=` | `{"name", "type_id"?, "phone"?, "inn"?, "note"?}`; в ответе `balance` (UZS): плюс — мы должны, минус — нам |
| GET/PATCH | `/counterparties/{id}` | |
| GET | `/counterparties/{id}/entries` | акт сверки |
| GET/POST/PATCH | `/reasons`, `/reasons/{id}` | финансовые причины `{"name", "kind": "income"\|"expense"}` |
| GET | `/cashboxes` | кассы с `balance`; главная видна только при доступе ко всем магазинам |
| POST | `/cashboxes` | `{"name", "currency"?, "store_id"?}` — без `store_id` главная касса (например, USD) |
| PATCH | `/cashboxes/{id}` | `{"name"?, "is_active"?}` |
| GET | `/cashboxes/{id}/entries` | выписка |
| GET/POST/PATCH | `/payment-methods?store_id=` | способ оплаты → касса, куда идут деньги |
| GET | `/operations?cashbox_id=&from=&to=` | кассовые операции (включая главную кассу) |
| POST | `/operations` | `{"kind": "income"\|"expense", "cashbox_id", "amount", "counterparty_id"? или "reason_id"?, "note"?}`; расход сверх остатка — 409 `insufficient_cash` |
| GET/POST | `/transfers` | из кассы в кассу `{"from_id", "to_id", "amount"}`; между валютами — по курсу |
| GET/POST | `/handovers` | сдача кассы `{"from_id", "amount"}` — в главную кассу той же валюты |

Каждый новый магазин получает кассу и способы оплаты «Наличные» и «Терминал», каждая сеть — «Главную кассу».

## Продажи POS (этап 4)

Все пути под `/store/sales`. Права: `sales.pos` — продажа и регистрация чека, `sales.discount` — скидки, `sales.return` — возврат.

| Метод | Путь | Описание |
| --- | --- | --- |
| POST | `/` | продажа (тело ниже). 201 — новая, 200 — повтор с тем же `client_uid` (офлайн-синхронизация) |
| GET | `/?store_id=&fiscal=pending&from=&to=&q=&limit=&offset=` | продажи; `q` — номер чека (можно с «№») или от 3 цифр телефона покупателя |
| GET | `/summary?store_id=&fiscal=pending&from=&to=` | итоги по всем чекам фильтра: `sales_count`, `subtotal`, `discount`, `revenue`, `returns_count`, `returns` (по дате возврата), `net` = `revenue − returns` |
| GET | `/{id}` | чек со строками (`returned_qty`) и оплатами |
| POST | `/{id}/fiscal` | касса пробила чек: `{"fiscal_number", "fiscal_sign"}` |
| GET | `/fiscal-control?store_id=` | `pending_sales`, `pending_returns`, `oldest_pending_at` — контроль непробитых чеков |
| POST | `/returns` | возврат по чеку `{"sale_id", "payment_method_id", "reason"?, "items": [{"sale_line", "qty"}]}` |
| GET | `/returns?store_id=&fiscal=pending&sale_id=&from=&to=` | возвраты; `sale_id` — возвраты по чеку |
| GET | `/returns/{id}` | |
| POST | `/returns/{id}/fiscal` | чек возврата |

Тело продажи:

```json
{
  "client_uid": "uuid, генерирует POS",
  "store_id": "...",
  "warehouse_id": "необязательно — склад магазина по умолчанию",
  "price_type_id": "необязательно — тип цены сети по умолчанию",
  "sold_at": "необязательно — время продажи на кассе при офлайне (не старше 7 дней)",
  "customer_phone": "", "note": "",
  "items": [{"product_id": "...", "qty": 2, "discount": 1000}],
  "payments": [{"payment_method_id": "...", "amount": 20000}]
}
```

Цена берётся с сервера (магазин → сеть → базовая), клиент передаёт только количество и скидку на строку.
Сумма оплат должна точно совпадать с итогом (сдачу считает касса). Товар списывается по FIFO; если не хватает — 409 `insufficient_stock`.
Возврат: сумма пропорциональна оплаченной сумме строки (со скидкой), товар возвращается в те же партии по той же себестоимости.

## Касса POS (приложение кассы, этап 1 — бекенд)

Касса входит не по коду из Telegram, а токеном устройства. Владелец создаёт кассу в панели и получает
код активации (живёт сутки), касса меняет код на постоянный токен `pd_…`. Кассир выбирается по ПИНу на самой
кассе (в том числе без интернета) и передаётся в каждом запросе заголовком `X-Cashier-ID`; сервер проверяет,
что сотрудник активен и имеет доступ к магазину кассы. Владелец на кассе получает все права, но только в этом магазине.

### Касса (`Authorization: Bearer pd_…`)

| Метод | Путь | Что делает |
| --- | --- | --- |
| POST | `/pos/activate` | `{code, app_version}` → `{token, device_id, store_id, …}`; без токена |
| GET | `/pos/catalog?since=<version>` | Товары (цена, штрихкоды, PLU, ИКПУ, НДС, маркировка), кассиры с хешем ПИНа, способы оплаты (`kind`: cash/card/qr/other), настройки чека. Без `since` — целиком, с `since` — изменения (с перекрытием в минуту) |
| POST | `/pos/login` | `{employee_id, pin}` — проверка ПИНа онлайн; 5 ошибок → блок на 5 минут (`429 pin_locked`) |
| GET | `/pos/shifts/current` | Открытая смена кассы с X-отчётом или `{shift: null}` |
| POST | `/pos/shifts` | Открыть смену `{client_uid, opening_cash, opened_at?}`; 201/200 (повтор), `409 shift_open` |
| GET | `/pos/shifts/{id}` | Смена с X-отчётом: продажи, возвраты, по способам оплаты, ожидаемые наличные |
| POST | `/pos/shifts/{id}/cash-moves` | Внесение/изъятие `{client_uid, kind: in/out, amount, reason}` |
| POST | `/pos/shifts/{id}/close` | `{counted_cash, diff_reason}` — расхождение без причины → 400; повтор → та же смена |
| POST | `/pos/sales` | Как `/store/sales` + `shift_id`, `fiscal: {number, sign, qr, module}`, `items[].marking_codes`, `items[].price` (цена, по которой касса пробила чек — офлайн могла быть старая). Магазин — кассы; нехватка остатка и снятый с продажи товар не отклоняют продажу, недостача — в `sale_items.short_qty` |
| GET | `/pos/sales?q=` | Поиск чека для возврата: номер или `client_uid` (QR на чеке кассы) |
| GET | `/pos/sales/{id}` | Чек; в строках для чека возврата — `ikpu`, `package_code`, `vat_rate`, `marking_codes`, в чеке — `fiscal_module` |
| POST | `/pos/returns` | Как `/store/sales/returns` + `shift_id` |
| POST | `/pos/returns/{id}/fiscal` | `{fiscal_number, fiscal_sign, fiscal_qr?, fiscal_module?}` — касса пробила чек возврата на фискальном модуле (только свои возвраты) |

Наличные в ящике: размен + продажи `kind = cash` − возвраты `kind = cash` + внесения − изъятия.

### Панель магазина

| Метод | Путь | Право |
| --- | --- | --- |
| GET/POST | `/store/pos/devices` | `stores.manage` — список, создать кассу (сразу с кодом) |
| POST | `/store/pos/devices/{id}/code` | новый код активации |
| POST | `/store/pos/devices/{id}/revoke` | отключить кассу |
| GET | `/store/pos/pins?store_id=` | `staff.manage` — сотрудники магазина: есть ли ПИН, права на кассе (`can_pos`, `can_discount`, `can_return`) |
| PUT | `/store/pos/pins/{employee_id}` | `staff.manage` — `{pin}` 4–6 цифр, уникален в сети |
| DELETE | `/store/pos/pins/{employee_id}` | `staff.manage` — убрать ПИН (сотрудник пропадёт из списка на кассе) |
| GET | `/store/pos/shifts`, `/store/pos/shifts/{id}` | `reports.view` или `finance.manage` |
| PUT | `/store/pos/products/{id}/tax` | `catalog.manage` — ИКПУ, код упаковки, НДС, маркировка (только свои товары) |
| PUT | `/store/pos/products/{id}/plu` | `catalog.manage` — короткий код `{plu}` или `null` |
| PUT | `/store/pos/payment-methods/{id}/kind` | `finance.manage` — cash/card/qr/other |
| GET/PUT | `/store/pos/settings` | весовые префиксы, шапка и низ чека (`stores.manage`) |

Супер-админ: `PUT /admin/pos/products/{id}/tax` — налоговые поля общих товаров платформы.

## Онлайн-заказы (этап 5)

### Приложение покупателя (`app=client`)

| Метод | Путь | Описание |
| --- | --- | --- |
| GET | `/client/stores/nearby?lat=&lng=` | магазины, которые доставляют в точку, ближайшие первыми; `recommended` у трёх ближайших открытых; `delivery` — стоимость, минимальная сумма, `is_open`. Без входа |
| GET | `/client/stores/{id}/categories` | категории, где у магазина есть товар. Без входа |
| GET | `/client/stores/{id}/products?q=&category_id=` | товары с ценой приложения и остатком (за вычетом резервов). Без входа |
| GET/POST | `/client/addresses` | адреса: `{"label","address","entrance","floor","apartment","comment","lat","lng"}` |
| PUT/DELETE | `/client/addresses/{id}` | |
| POST | `/client/checkout/preview` | расчёт корзины: строки с `problem` (`out_of_stock`, `not_enough`, `fractional`, `unavailable`), доставка, `can_order`, `problems` (`items`, `store_closed`, `min_order_amount`, `not_deliverable`, `store_not_accepting`) |
| POST | `/client/orders` | оформить: `{"store_id","address_id","items":[{"product_id","qty"}],"payment_provider":"payme"\|"click"\|"cash","comment"}` → `{order, payment_url}`. Товар резервируется. **Временно** `cash` — наличные курьеру: заказ сразу «paid», `payment_url` пустой |
| GET | `/client/orders`, `/client/orders/{id}` | заказы с историей статусов |
| POST | `/client/orders/{id}/cancel` | отмена до принятия магазином; оплаченный — деньги к возврату |
| GET | `/client/orders/{id}/payment-url` | ссылка на оплату ещё раз |

Статусы: `awaiting_payment` → `paid` → `accepted` → `picking` → `picked` → `delivering` → `delivered`;
`cancelled`, `expired` (не оплачен за `PAYMENT_TIMEOUT`, 15 мин).

### Панель магазина

| Метод | Путь | Право | Описание |
| --- | --- | --- | --- |
| GET/PUT | `/store/stores/{id}/delivery` | `stores.manage` | `accepts_online`, `min_order_amount`, `delivery_radius_m`, `working_hours` [{weekday 0–6, opens, closes}], `rules` |
| GET/POST | `/store/stores/{id}/zones` | `stores.manage` | зоны доставки `{"name","price","polygon":[[lng,lat],...]}` |
| PATCH/DELETE | `/store/stores/{id}/zones/{zone}` | | |
| GET | `/store/orders?store_id=&status=&from=&to=&q=&limit=&offset=` | `orders.manage` | заказы (без неоплаченных); `q` — номер заказа (можно с «№») или от 3 цифр телефона покупателя |
| GET | `/store/orders/{id}` | `orders.manage` | строки с `price`, `old_price` (цена до акции или `null`), заказ с `discount` |
| POST | `/store/orders/{id}/accept` · `/start-picking` · `/start-delivery` · `/delivered` | `orders.manage` | смена статуса |
| POST | `/store/orders/{id}/picked` | `orders.manage` | собран: `{"items":[{"line":1,"warehouse_id":"..."}]}` — строки с другого склада (отметка `from_other_warehouse`) |
| POST | `/store/orders/{id}/cancel` | `orders.manage` | `{"reason"}`, до сборки |
| POST | `/store/orders/{id}/fiscal` | `orders.manage` | чек после сборки |

Правила доставки (`rules`, по порядку `sort`, первое подходящее задаёт цену):
`fixed {price}`, `distance {base, per_km}` (км округляются вверх), `zone {}` (цена зоны), `free_from {amount}` (бесплатно от суммы).
Если у магазина есть активные зоны — доставка только в зоны, иначе — в радиусе.

### Супер-админ

| Метод | Путь | Описание |
| --- | --- | --- |
| GET | `/admin/orders?status=&stale=true&q=&network_id=&store_id=&payment_provider=&from=&to=&limit=&offset=` | заказы; `stale` — оплачены, но не приняты за `ACCEPT_TIMEOUT` (заказ ко времени — не позже чем за час до окна); `q` — номер заказа или телефон покупателя (от 3 цифр); `payment_provider` — `payme`/`click`; `from`/`to` — дата создания `YYYY-MM-DD` (`to` не включается). У просроченных `accept_overdue: true` |
| GET | `/admin/orders/{id}` | с `items` (`old_price` — цена до скидки), `history`, `discount`, `delivery_from`/`delivery_to`, `courier_name`, `eta_at`, `payment_deadline` |
| POST | `/admin/orders/{id}/cancel` | `{"reason"}` |
| GET | `/admin/payments?status=refund_pending&limit=&offset=` | очередь возвратов |
| POST | `/admin/payments/{id}/refunded` | деньги возвращены в кабинете Click (Payme сообщает сам) |

### Платёжные системы

| Путь | Кто вызывает |
| --- | --- |
| POST `/payments/payme` | Payme Merchant API (JSON-RPC, Basic `Paycom:PAYME_KEY`), `account.order_id` |
| POST `/payments/click/prepare`, `/payments/click/complete` | Click SHOP API, `merchant_trans_id` = id заказа |

## Баланс, вывод, подписка (этап 6)

### Панель магазина (право `payouts.manage`)

| Метод | Путь | Описание |
| --- | --- | --- |
| GET | `/store/balance` | `available` (к выводу), `pending` (оплачено, ещё не доставлено), `next_payout_at` |
| GET | `/store/balance/entries?from=&to=` | движения баланса: `order`, `payout`, `subscription`, `adjustment` |
| GET | `/store/payouts?status=` | заявки на вывод |
| POST | `/store/payouts` | `{"amount","requisites","note"}` — раз в 7 дней, не больше доступного |
| GET | `/store/billing` | тариф сети: число магазинов, цена за магазин, сумма в месяц, долг, `overdue` |
| GET | `/store/billing/invoices?status=unpaid\|paid\|cancelled\|overdue` | счета |
| POST | `/store/billing/invoices/{id}/pay` | оплатить счёт с баланса |

### Супер-админ

| Метод | Путь | Описание |
| --- | --- | --- |
| GET/PUT | `/admin/billing/settings` | `usd_rate` (курс для счетов), `grace_days` (дней на оплату), `auto_charge_balance` |
| GET/POST | `/admin/billing/tariffs?limit=&offset=` | `{"name","min_stores","price_per_store"}` — цена за магазин в месяц, USD |
| PATCH | `/admin/billing/tariffs/{id}` | в т.ч. `is_active` |
| GET | `/admin/billing/networks?overdue=true` | сети: магазины, цена, баланс, долг |
| GET/PATCH | `/admin/billing/networks/{id}` | `{"custom_price_per_store"}`, `{"clear_custom_price":true}`, `{"billing_from":"YYYY-MM-01"}` |
| GET | `/admin/billing/invoices?network_id=&status=` | счета |
| POST | `/admin/billing/invoices/generate` | выставить счета за текущий месяц сейчас (обычно делает worker) |
| POST | `/admin/billing/invoices/{id}/paid` · `/cancel` | `{"note"}` — оплачено вручную / списать |
| GET | `/admin/payouts?status=requested&network_id=` | заявки на вывод |
| POST | `/admin/payouts/{id}/paid` | `{"note"}` — деньги переведены |
| POST | `/admin/payouts/{id}/reject` | `{"note"}` обязательно — сумма возвращается на баланс |

## Отчёты (этап 6)

Право `reports.view`. Параметры: `from`, `to` (по умолчанию — с начала месяца по сейчас, `to` не включается), `store_id`.

| Метод | Путь | Описание |
| --- | --- | --- |
| GET | `/store/reports/cash-flow?cashbox_id=` | по кассам: остаток на начало, приход, расход, на конец; строки по статьям (продажи, возвраты, финансовые причины, расчёты с контрагентами, сдача кассы, из кассы в кассу) |
| GET | `/store/reports/profit-loss` | выручка (POS − возвраты + онлайн + доставка), себестоимость FIFO, валовая прибыль, списания и инвентаризация, прочие доходы и расходы по причинам, подписка платформы, чистая прибыль |

## Витрина приложения (этап приложения 1)

### Без входа (гостевой просмотр, Apple 5.1.1)

Эти маршруты приложения покупателя работают **без токена** (токен, если есть, ни на что не влияет — личных
данных в ответах нет): `GET /client/config`, `GET /client/home?lat=&lng=`, `GET /client/stores/nearby?lat=&lng=`,
`GET /client/stores/{id}/home`, `GET /client/stores/{id}/categories`, `GET /client/stores/{id}/products`,
`GET /client/stores/{id}/products/{pid}`, `GET /client/stores/{id}/products/{pid}/related`,
`GET /client/search?lat=&lng=&q=`, `GET /client/stores/{id}/slots`, `POST /client/home/events`.
Точку гость передаёт в `lat`/`lng` (геолокация или точка на карте) — сохранённые адреса не нужны.
Цены — обычные цены магазина и акции (персональных цен нет), избранное приложение берёт отдельно из
`GET /client/favorites` только после входа.

Только со входом (без токена — 401): профиль, статистика, избранное, адреса, корзина (`/client/checkout/preview`),
заказы, уведомления, долги, семья, «Хочу доставку» (`/client/wishes`, `/client/stores/{id}/wish`), устройства.

### Приложение покупателя

| Метод | Путь | Что делает |
| --- | --- | --- |
| GET | `/client/home?lat=&lng=` | Главная: `banners`, `stores` (как `/nearby`), `deals` — товары со скидкой ближайшего открытого магазина или `null` |
| GET | `/client/stores/{id}/products` | Каталог. Параметры: `q`, `category_id`, `brand_id`, `ids=a,b` (до 200), `discount=1`, `new=1` (меньше 30 дней), `hits=1` (от 3 покупок за 30 дней), `sort=popular` (по умолчанию) `\| price_asc \| price_desc \| new \| name \| discount`, `limit`, `offset` |
| GET | `/client/stores/{id}/products/{pid}` | Карточка товара: поля каталога + `category_name`, `attributes`, `store_id`, `store_name`. Нет в наличии — 404 |
| GET | `/client/stores/{id}/products/{pid}/related?limit=10` | «С этим покупают»: чаще всего покупают вместе в этом магазине за 90 дней, иначе популярное из той же категории |
| GET | `/client/favorites` | `{"product_ids": [...]}` (нужен вход) |
| POST | `/client/favorites` | `{"product_id"}` → список id |
| DELETE | `/client/favorites/{pid}` | → список id |

Товар в каталоге теперь содержит `old_price` (цена до скидки или `null`), `discount_percent`, `is_new`.
`/client/stores/nearby` — ещё `logo_url`, `eta_min`, `eta_max` (минуты, могут быть `null`).
`/client/checkout/preview` — поле `discount` (скидка по акциям) и `old_price` в строках; заказ — `discount`
и `old_price` в позициях.

Цена в приложении = обычная цена магазина (цена магазина → цена сети → базовая), а если действует акция и её
цена ниже — акционная. Кассовые цены акции не меняют.

### Панель магазина (право `prices.manage`)

| Метод | Путь | Что делает |
| --- | --- | --- |
| GET | `/store/promotions?status=running\|scheduled\|ended` | Акции сети; `status` у каждой: `scheduled`, `running`, `ended`, `disabled` |
| POST | `/store/promotions` | `{name, starts_at, ends_at, store_ids?, is_active?, items: [{product_id, price}]}`; `store_ids` пустой — все магазины (только сотруднику всех магазинов) |
| GET | `/store/promotions/{id}` | Акция с товарами |
| PATCH | `/store/promotions/{id}` | Любые поля; `items` заменяет список целиком; `is_active: false` — выключить |

`PATCH /store/stores/{id}` — поле `logo_url`. `PUT /store/stores/{id}/delivery` — `eta_min`, `eta_max`
(5–600 минут, `eta_min ≤ eta_max`). Поле не передано — не меняется, `null` — время сбрасывается и не показывается.

### Супер-админ

| Метод | Путь | Что делает |
| --- | --- | --- |
| GET | `/admin/banners?limit=&offset=` | Баннеры по страницам; `network_name` — сеть, если баннер только для неё |
| POST | `/admin/banners` | `{title, subtitle?, image_url?, color? (#RRGGBB), link_type: none\|promotion\|category\|product\|store, link_id?, network_id? (пусто — баннер платформы), starts_at?, ends_at?, sort?, is_active?}` |
| PATCH | `/admin/banners/{id}` | Любые поля. `starts_at`/`ends_at`: нет поля — не менять, `null` — снять ограничение |

Товар (`/admin/products`, `/store/products`) — поле `attributes`: `nutrition` (`{kcal, protein, fat, carbs}` на
100 г, числа), строки `composition`, `shelf_life`, `storage`, `country`, `volume`, `manufacturer`.

Воркер раз в час пересчитывает популярность товаров (`product_popularity`) по кассовым продажам и онлайн-заказам
за 30 дней.

## Профиль и уведомления (этап приложения 2)

### Приложение покупателя

| Метод | Путь | Описание |
|---|---|---|
| GET | `/client/me` | `phone`, `full_name`, `language` (`ru`/`uz`), `city`, `notifications {orders, promos, promos_consent_at}`, `telegram_linked`, `support_url`, `privacy_url` |
| PATCH | `/client/me` | Любые из: `full_name`, `language`, `city`, `notifications {orders?, promos?}`. Ответ — профиль. `notifications.promos: true` — явное согласие на рекламные push (записывается `promos_consent_at`), `false` — отказ (`promos_consent_at: null`) |
| GET | `/client/me/stats` | `orders_count`, `saved` (сумма скидок доставленных заказов), `addresses_count`, `favorites_count`, `active_order {id, number, status, store_name}` или `null` |
| DELETE | `/client/me` | Удаление аккаунта → 204. 409 `active_order` (`details: {account: "client", order_number}`), пока есть незавершённый заказ. Сессии закрываются, имя, адреса, избранное и устройства удаляются, в заказах стираются телефон и адрес. Номер освобождается (новый вход создаёт новый аккаунт), если он не нужен сотруднику, супер-админу или курьеру «по пути» |
| POST | `/client/devices` | `{token, platform: ios|android, language?}` — токен FCM для текущей сессии → 204. Вызывать после входа и при обновлении токена |
| GET | `/client/config` | Без входа: `push_enabled`, `support_url`, `privacy_url` |
| DELETE | `/client/devices/{token}` | Забыть устройство → 204. При выходе (`/auth/client/logout`) устройство сессии удаляется само |

### Уведомления о заказе

При смене статуса заказа (`paid`, `accepted`, `picked`, `delivering`, `delivered`, `cancelled`, `expired`)
в той же транзакции создаётся запись в `notifications_outbox` — на языке покупателя, если он не выключил
`notifications.orders`. Воркер каждые 3 секунды отправляет очередь: push через FCM на все устройства.
В Telegram уведомления не дублируются (бот — только для кодов входа). Нет устройств — `skipped` с причиной.
При временной ошибке — до 6 попыток с паузой от 30 секунд. Недействительные токены удаляются.

Данные push: `{"type": "order", "order_id": "…", "status": "…"}` — приложение открывает экран заказа.

**Рекламные push (рассылки, Apple 4.5.4).** С миграции `0037` у новых покупателей `notifications.promos = false`:
рассылки супер-админа уходят только тем, кто включил их сам (`PATCH /client/me {"notifications": {"promos": true}}` —
экран согласия или переключатель в профиле). У покупателей, зарегистрированных раньше, настройка не менялась;
`promos_consent_at: null` при `promos: true` — согласие получено до этого правила.

Настройка: `FCM_CREDENTIALS` — ключ сервисного аккаунта Firebase (JSON, путь к файлу или base64).
Без него push выключен: уведомления видны только в колокольчике приложения.

## Доставка ко времени (этап приложения 3)

### Панель магазина

`PUT /store/stores/{id}/delivery` принимает и `GET` возвращает `slots`:
`{enabled, slot_minutes (30–240), days_ahead (0–6), lead_minutes (0–720), capacity (1–500)}`.
Окна строятся по часам работы магазина (без часов работы — 08:00–22:00), по времени Ташкента.

`GET /store/orders?sort=delivery` — сначала заказы «как можно скорее» и ближайшие окна.
В заказе: `delivery_from`, `delivery_to` (null — как можно скорее). Заказ ко времени нужно принять не
позже чем за час до окна — иначе уведомление супер-админу (`ACCEPT_TIMEOUT` отсчитывается от этого момента).

### Приложение покупателя

| Метод | Путь | Описание |
|---|---|---|
| GET | `/client/stores/{id}/slots` | `{enabled, days: [{date, slots: [{from, to, status: free|past|full, left}]}]}` на сегодня и `days_ahead` дней вперёд |

`POST /client/checkout/preview` и `POST /client/orders` принимают `delivery_from` — начало окна ровно как
его вернул `/slots`. Пусто — как можно скорее. Если окно заняли или оно прошло, в `problems` будет
`slot_full` или `slot_unavailable`. При заказе ко времени закрытый сейчас магазин не мешает оформлению.
Места в окне считаются под блокировкой: последнее место займёт только один заказ.

В заказе, который ждёт оплаты, есть `payment_deadline` — до какого момента нужно оплатить.

## Курьеры и отслеживание (этап приложения 4)

Курьер — сотрудник магазина с правом `orders.deliver` («Курьер: доставка заказов»). Входит в
приложение курьера как сотрудник (`app: store`).

### Панель магазина (право `orders.manage`)

| Метод | Путь | Описание |
|---|---|---|
| GET | `/store/couriers?store_id=` | Курьеры магазина: `employee_id, full_name, phone, vehicle, on_shift, lat, lng, located_at, active_orders`; сначала на смене |
| POST | `/store/orders/{id}/assign-courier` | `{courier_id}` или `{courier_id: null}` — назначить или снять. Статусы: принят, сборка, собран, в пути. Курьеру уходит сообщение в Telegram |

В заказе: `courier_id`, `courier_name`, `eta_at`.

### Курьер (право `orders.deliver`)

| Метод | Путь | Описание |
|---|---|---|
| GET | `/courier/me` | `employee_id, full_name, network_name, vehicle, on_shift` |
| POST | `/courier/shift` | `{on_shift?, vehicle?: foot|bike|scooter|car}`. Уход со смены стирает точку |
| POST | `/courier/location` | `{lat, lng, accuracy?, heading?}` раз в 10–15 с → 204. Пересчитывает время прибытия заказов в пути |
| GET | `/courier/orders` | `[{order, store: {name, address, phone, lat, lng}}]` — активные и доставленные за 12 часов |
| GET | `/courier/orders/{id}` | Один заказ курьера |
| POST | `/courier/orders/{id}/picked-up` | Забрал собранный заказ → «в пути», считается `eta_at` |
| POST | `/courier/orders/{id}/delivered` | Вручил → «доставлен», деньги в балансе становятся доступны |

Время прибытия: расстояние по прямой × 1,35 при средней скорости транспорта (пешком 5, велосипед 14,
скутер 22, машина 25 км/ч) + 2 минуты. Считается от свежей (не старше 10 минут) точки курьера, иначе от магазина.

### Приложение покупателя

`GET /client/orders/{id}/tracking` → `{status, status_title, eta_at, eta_minutes, courier: {name, vehicle,
phone, location: {lat, lng}, located_at} | null, store: {lat, lng}, store_name, destination: {lat, lng}}`.
Телефон и точка курьера — только пока заказ в пути; после доставки курьер не показывается.

## Моя семья (этап приложения 5)

Семья — до 10 человек; один человек — в одной семье. Создатель — владелец (`owner`), остальные — `member`.
Все пути — приложение покупателя (`app: client`).

| Метод | Путь | Описание |
|---|---|---|
| GET | `/client/family` | `{family: null}` или `{family: {id, name, my_role, members: [{user_id, name, label, phone, role, is_me}], active_requests, requests_for_me}}` |
| POST | `/client/family` | `{name}` — создать (201). Уже в семье → 409 |
| POST | `/client/family/invites` | Код на 7 дней: `{code, url, expires_at}`; `url` — `t.me/<бот>?start=fam_<код>` |
| POST | `/client/family/join` | `{code, label?}` — вступить. Код одноразовый; неверный или устаревший → 400 |
| POST | `/client/family/leave` | Выйти → 204. Владелец передаёт семью самому давнему участнику; последний — семья удаляется |
| PATCH | `/client/family/members/{user_id}` | `{label}` — подпись («Мама», «Муж») |
| DELETE | `/client/family/members/{user_id}` | Исключить (только владелец) → 204 |
| GET | `/client/family/suggestions` | Частые покупки за 90 дней: `[{product_id, name, times}]` |
| GET | `/client/family/requests` | Активные просьбы; `?status=history` — выполненные и отменённые |
| POST | `/client/family/requests` | `{title?, assignee_id?, comment?, remind_at?, remind_at_store?, deliver_offer_at?, items: [{product_id? , text?, qty?}]}` (201). Без `assignee_id` — всей семье |
| GET | `/client/family/requests/{id}` | Просьба с `items: [{id, line, product_id, product_name, unit_short, image, text, qty, bought, bought_by_name}]` |
| POST | `/client/family/requests/{id}/items/{item}/bought` | `{bought}` — отметить. Статус: `pending` → `partial` → `bought` (автору push) |
| POST | `/client/family/requests/{id}/snooze` | `{minutes?}` (по умолчанию 60) — напомнить позже |
| POST | `/client/family/requests/{id}/cancel` | Отменить (автор или владелец) |
| GET | `/client/family/requests/{id}/to-cart?lat=&lng=` | «Заказать домой»: `{store, lines: [{item_id, qty, product}], found, total, message?}` — ближайший из 5 магазинов, где есть больше всего некупленных товаров |
| POST | `/client/family/requests/{id}/ordered` | `{order_id}` — заказ оформлен → `ordered`, автору push |

Просьба в ответах: `id, title, comment, status, author_id, author_name, assignee_id, assignee_name, remind_at,
remind_at_store, deliver_offer_at, order_id, items_total, items_bought, summary, created_at, for_me`.

Push (`data.type = family_request`, `data.request_id`): новая просьба — сразу; напоминание в `remind_at`
(если оно позже чем через 5 минут); предложение заказать домой в `deliver_offer_at`. Приглашение также
работает через бота: `/start fam_<код>` — бот просит номер (если ещё не привязан) и добавляет в семью.

## Курьеры «по пути» (crowd-доставка)

Обычный пользователь входит в приложение курьера в режиме «По пути» по телефону и коду
(`POST /auth/otp/request {phone, app: "crowd"}` → `channel: "sms"` при настроенном Eskiz, иначе `"telegram"`;
`POST /auth/otp/verify {phone, code, app: "crowd", terms_accepted: true}` — согласие обязательно при первом входе,
иначе 422 `terms_required`). Токен `crowd` открывает только `/crowd/*` и `/auth/crowd/logout`; заблокированный — 403 `crowd_blocked`.
Пока личность не подтверждена в магазине (`status: unverified`), заказы не предлагаются. Ссылки на условия и
политику — `GET /client/config` (`courier_terms_url`, `privacy_url`).
`courier_app_url` (env `COURIER_APP_URL`) — в `/client/config` и `/client/profile`: ссылка на приложение курьера для баннера
«Зарабатывайте на доставке» в профиле покупателя; пусто — баннер скрыт.

### Курьер (`app=crowd`)

| Метод | Путь | Описание |
| --- | --- | --- |
| GET/PUT | `/crowd/me` | профиль: `code` (KR-12345), `status`, `full_name`, `vehicle`, `online`, `dest`, уровень и прогресс. PUT — `{vehicle?, online?}` |
| PUT | `/crowd/route` | `{dest: {lat, lng, title} \| null}` — куда иду |
| POST | `/crowd/location` | `{lat, lng}` — точка курьера (пересчитывает время прибытия у покупателя) |
| GET | `/crowd/points` | магазины, где можно подтвердить личность |
| GET | `/crowd/offers` | `state` (`ok`, `unverified`, `offline`, `busy`, `no_location`) и `items` — заказы рядом с крюком к `dest`, вознаграждение |
| POST | `/crowd/offers/{id}/accept` | взять заказ → код выдачи (3 символа), срок «забрать до». 409 — заказ уже взят или превышен лимит уровня |
| GET | `/crowd/orders`, `/crowd/orders/{id}` | мои активные заказы; QR выдачи `sm-pickup:<номер>:<код>` |
| POST | `/crowd/orders/{id}/release` | отказаться до выдачи |
| POST | `/crowd/orders/{id}/deliver` | `{code}` — 4 цифры от покупателя; 5 попыток. Начисляет вознаграждение |
| POST | `/crowd/orders/{id}/problem` | `{kind: no_handoff\|other, note}` — инцидент для поддержки |
| GET | `/crowd/earnings` | баланс, следующая выплата, неделя и журнал начислений |
| DELETE | `/crowd/me` | удалить аккаунт → 204. 409 `active_order` (`details: {account: "crowd", order_number}`) — заказ на руках (взят или в пути); 409 `unpaid_balance` (`details: {account: "crowd", balance}`) — невыплаченный остаток > 0. Имя, дата рождения, хэш документа (у заблокированного хэш остаётся), маршрут и точка стираются, сессии закрываются; заказы, начисления, выплаты и нарушения остаются без имени. Номер освобождается, если он не нужен покупателю или сотруднику; иначе повторный вход в `crowd` — регистрация заново с согласием и новой проверкой личности (код KR- прежний) |

### Панель магазина (право `orders.manage`)

| Метод | Путь | Описание |
| --- | --- | --- |
| POST | `/store/crowd/lookup` | `{code}` — QR `sm-courier:KR-…` или код → карточка курьера |
| POST | `/store/crowd/verify` | `{code, store_id, decision: approve\|reject, doc_type: passport\|id_card, full_name, birth_date, doc_last4, photo_match, doc_valid, reason}`. Возраст от 18; документ хранится только хэшем, 409 `doc_used` — уже у другого курьера. Магазин должен быть подключён |
| GET | `/store/crowd/bonuses?store_id=` | `credited_month`, `pending`, `verified`, `per_delivery`, `max_deliveries`, `items` |
| POST | `/store/orders/{id}/crowd-handover` | `{code}` — QR или код выдачи курьера → заказ «в пути» |
| POST | `/store/orders/{id}/crowd-release` | снять курьера «по пути» до выдачи |

Заказ отдаёт `delivery_mode` (`staff`/`crowd`), `crowd_courier_id`, `crowd_courier_phone`, `crowd_pickup_until`,
`crowd_open` (сейчас предлагается курьерам). Для заказа курьера «по пути» «В путь»/«Доставлен» и назначение
штатного — 409 `crowd_courier`. Покупатель видит `handoff_code` в `/client/orders/{id}`, пока заказ собран или в пути,
и `courier.crowd: true` в отслеживании.

### Супер-админ

| Метод | Путь | Описание |
| --- | --- | --- |
| GET | `/admin/crowd/overview` | сегодня взято/предложено, среднее время, курьеры по статусам, инциденты, к выплате, бонусы |
| GET | `/admin/crowd/couriers?status=&q=&limit=&offset=` | курьеры с уровнем, % вовремя, балансом |
| POST | `/admin/crowd/couriers/{id}/block`, `/unblock` | `{reason}` — блокировка закрывает сессии и снимает невыданные заказы |
| GET | `/admin/crowd/incidents?status=open\|resolved` | нарушения и жалобы |
| POST | `/admin/crowd/incidents/{id}/resolve` | `{resolution, violation, penalty?}` |
| GET/POST | `/admin/crowd/payouts` | к выплате / `{courier_ids, note}` — отметить выплату |
| GET/PUT | `/admin/crowd/settings` | тарифы, время ожидания, радиус и крюк, бонус магазину, уровни |
| GET | `/admin/crowd/stores?q=` · PUT `/admin/crowd/stores/{id}` | `{crowd_enabled}` — подключить магазин к пилоту |

Воркер `crowd` (каждый тик `WORKER_INTERVAL`) снимает заказы, не забранные вовремя (нарушение), отменяет бонусы магазинам за нарушителей
и начисляет бонусы после проверочного срока, если у курьера есть доставки из других магазинов.

## Дерево товаров «бренд → категория → товар»

| Метод | Путь | Описание |
| --- | --- | --- |
| GET | `/admin/products/groups?q=&category_id=&status=` | `{brands: [{brand_id, brand_name, count, pending, categories: [{category_id, category_name, count, pending}]}], total}` — бренды по алфавиту, `brand_id: null` («Без бренда») в конце; `pending` — на модерации |
| GET | `/store/products/groups?q=&category_id=` | то же для сети (общий каталог + свои товары); `pending` — свои товары на модерации |

Товары группы — обычный список (`/admin/products`, `/store/products`) с `brand_id` (uuid или `none` — без бренда),
`leaf_category_id` (ровно эта категория, без подкатегорий) и `sort=name`.

## ИИ-сервис и приход по фото накладной

### Супер-админ

| Метод | Путь | Описание |
| --- | --- | --- |
| GET | `/admin/ai` | `provider` (`openai` — OpenAI и совместимые, `anthropic`), `base_url`, `model`, `has_key`, `key_last4`, `configured`, `checked_at`, `check_ok`, `check_message`, `month_scans`, `month_failed`. Ключ не отдаётся |
| PUT | `/admin/ai` | `{provider, base_url, api_key?, model}` — пустой `api_key` оставляет сохранённый (только для того же сервиса и адреса). Ключ шифруется (AES-GCM от `JWT_SECRET`) |
| POST | `/admin/ai/models` | `{provider, base_url, api_key?}` → `items [{id, vision}]` — модели ключа; `vision` по названию (`null` — неизвестно) |
| POST | `/admin/ai/test` | `{}` — проверить сохранённое (результат записывается) или `{provider, base_url, api_key, model}` — проверить введённое. Модель читает тестовую накладную → `{ok, message, ms}` |
| GET | `/admin/ai/usage` | `?from=&to=` (YYYY-MM-DD, `to` не включается; по умолчанию — текущий месяц), `group=network\|store\|employee`, `network_id?` → `{totals {requests, invoices, photos, errors, tests, input_tokens, output_tokens, cost_uzs}, days [{date, requests, input_tokens, output_tokens, cost_uzs}], items [{id, name, sub, network_id, stores, employees, requests, invoices, photos, errors, input_tokens, output_tokens, cost_uzs, share}], prices, model}`; `photos` — фото полок «Начала работы». Строка с пустым `id` — проверки подключения |
| PUT | `/admin/ai/prices` | `{price_in, price_out, currency: USD\|RUB\|UZS, rate_uzs}` — цена за 1 млн токенов; стоимость запроса фиксируется в момент запроса |

Ошибки сервиса — 502 `ai_error` с понятным текстом («ключ не подходит…», «закончились средства…»).

### Магазин (право `inventory.manage`)

Фото загружаются через `POST /store/uploads`, в накладную передаются полученные ссылки.

| Метод | Путь | Описание |
| --- | --- | --- |
| POST | `/store/invoice-scans` | `{store_id, images: [url, …до 5]}` → 202, накладная `processing`; распознавание в фоне. 409 `ai_not_configured` |
| GET | `/store/invoice-scans?store_id=` | последние накладные (без строк) |
| GET | `/store/invoice-scans/{id}` | `status` (`processing`, `ready`, `failed`, `done`), `supplier_name/inn`, `invoice_number/date`, `currency`, `invoice_total`, `lines_total`, `total_matches`, `counterparty_id/name`, `document_id/number/status`, `error`, `counts {ok, check, missing, skipped}`, `lines [{line, name, barcode, unit, qty, price, sum, product_id, product_name, unit_short, match, confidence, skipped, state, last_price, price_change}]` |
| POST | `/store/invoice-scans/{id}/retry` | распознать заново после ошибки |
| PUT | `/store/invoice-scans/{id}/supplier` | `{counterparty_id}` или `{create: true}` (завести из распознанного); строки пересопоставляются |
| PUT | `/store/invoice-scans/{id}/lines/{n}` | `{product_id?, qty?, price?, skip?, remember?}` — `remember` запоминает название строки для поставщика |
| GET | `/store/invoice-scans/{id}/lines/{n}/suggestions?q=` | до 8 похожих товаров `{product_id, name, barcode, unit_short, score}` |
| POST | `/store/invoice-scans/{id}/document` | `{warehouse_id?, post}` → приход (черновик или проведённый) на основной склад магазина. 409 `lines_unmatched` |

Состояние строки: `ok`; `check` — похожее название ниже 75% или цена отличается от прошлого прихода больше чем на 5%;
`missing` — товар не найден; `skipped`. Сопоставление: штрихкод → запомненное название поставщика → похожее название (pg_trgm).
Воркер `invoice_scans` помечает зависшие распознавания (>10 мин) ошибкой.

## Все магазины рядом, «Хочу доставку», поиск по всем магазинам

`GET /client/home` дополнительно отдаёт `others` — активные магазины до 10 км, которые по адресу не доставляют:
`{id, network_id, network_name, name, address, lat, lng, logo_url, distance_m, is_open, reason}`; `reason`:
`not_online` — магазин не принимает онлайн-заказы, `out_of_zone` — адрес вне зоны доставки. Их витрина открыта:
`/client/stores/{id}/home|categories|products|products/{pid}|related` работают и для магазинов без онлайн-заказов
(корзина и заказ — только у доставляющих: `checkout/preview` и `orders` → 404).

| Метод | Путь | Описание |
| --- | --- | --- |
| GET | `/client/search?lat=&lng=&q=&only_delivering=1&limit=` | поиск по названию или штрихкоду во всех магазинах рядом (доставляющие + до 10 км; `only_delivering` — только доставляющие). `q` короче 2 символов — пусто. → `{items [{product {id, name, description, brand_name, category_id, unit_short, is_fractional, images, is_new}, offers [{store_id, store_name, network_name, delivers, eta_min, eta_max, distance_m, is_open, reason, price, old_price, discount_percent, available}], min_price}], stores}`. Предложения: привезут → дешевле → ближе; товары: есть с доставкой → название начинается с запроса → больше магазинов |
| GET | `/client/wishes` | id магазинов, где покупатель нажал «Хочу доставку» |
| POST | `/client/stores/{id}/wish` | `{lat, lng}` — точка адреса → `{store_id, wished: true}`; повтор обновляет точку. Один голос на магазин |
| DELETE | `/client/stores/{id}/wish` | снять → `{store_id, wished: false}` |
| GET | `/store/stores/{id}/wishes` | панель (право `stores.manage` или `orders.manage`): `{accepts_online, total, week, month, nearest_m, farthest_m, out_of_zone, out_of_zone_week}` |
| GET | `/admin/delivery-wishes?limit=&offset=` | `{totals {total, week, stores}, items [{store_id, store_name, network_id, network_name, total, week, accepts_online, out_of_zone, hidden}]}` — по убыванию голосов; `hidden` — магазин сейчас не виден покупателям |

## Первая настройка магазина (панель и «SM Магазин»)

Мастер обязателен, пока в сети нет магазина с точкой на карте и указанными часами работы (`required`): панель и
приложение показывают только его, сотрудникам без права `stores.manage` — «Магазин ещё настраивается». Шаги
сохраняются сразу, прогресс общий для панели и приложения. Доставку можно пропустить — тогда на главной чек-лист,
пока не включены онлайн-заказы или не выбрано «Пока без доставки». Уже работавшие до мастера магазины считаются настроенными.

| Метод | Путь | Описание |
| --- | --- | --- |
| GET | `/store/setup?store_id=` | `{required, can_setup, store {id, name, phone, address, lat, lng} \| null, working_hours, steps {store, hours, delivery, done}, delivery {accepts_online, declined, delivery_radius_m, min_order_amount, eta_min, eta_max, fee, free_from}, wishes}`. Без `store_id` — первый доступный магазин (настроенный — первым); `wishes` — сколько нажали «Хочу доставку» |
| POST | `/store/setup/store` | право `stores.manage`: `{store_id?, name, phone?, address, lat, lng, city?}` — без `store_id` и без магазинов создаёт первый магазин (с основным складом и кассой), иначе меняет первый/указанный → состояние |
| PUT | `/store/setup/hours` | `{store_id, working_hours: [{weekday 0–6, opens, closes}]}`; пустой список — круглосуточно → состояние |
| PUT | `/store/setup/delivery` | `{store_id, mode: "none"}` — пока без доставки (онлайн-заказы выключены) или `{store_id, mode: "deliver", delivery_radius_m (100–100 000), fee, free_from?, min_order_amount?, eta_min?, eta_max?}` — включает онлайн-заказы; правила `fixed` и `free_from` заменяются, зоны и цена по расстоянию остаются → состояние |

Шаги: `store` — у магазина есть точка; `hours` — часы сохранены (в том числе через `PUT /store/stores/{id}/delivery`);
`delivery` — онлайн-заказы включены или выбрано «Пока без доставки».

## Начало работы (панель и «SM Магазин», право `inventory.manage`)

Магазин заводит товары, которые у него уже есть. Один открытый черновик на основной склад магазина — общий для
панели и приложения. Нет основного склада — 409 `no_warehouse`. Товары: общий каталог и свои товары сети.

| Метод | Путь | Описание |
| --- | --- | --- |
| GET | `/store/start?store_id=&q=&only=no_cost\|new&limit=&offset=` | `{id (null — не начат), store_id, store_name, warehouse_id, warehouse_name, status (open, posting), lines, totals {products, qty, cost_total, price_total, no_cost, pending}, stock_products, last_posted_at}`. Строки — новые сверху (`limit` до 1000, по умолчанию 200): `{product_id, name, image, unit_short, is_fractional, barcode, qty, cost, price, current_price, source, own, moderation, posted, added_at}`. `price` null — останется действующая цена (`current_price`) |
| POST | `/store/start/lines` | `{store_id, items: [{product_id, qty?, add?, cost?, price?, barcode?, source?}]}` (1–500) → `{lines, totals}`. Черновик создаётся сам. `add: true` — прибавить `qty` (по умолчанию 1) — повторный скан. `cost`/`price: null` — сбросить. `barcode` — привязать штрихкод к товару (право `catalog.manage`; чужой — 409 `barcode_exists`, `details.product_id`). Штучный товар — целое количество. `source`: `photo`, `barcode`, `catalog`, `search`, `new`, `manual` |
| DELETE | `/store/start/lines/{product_id}?store_id=` | убрать товар → `totals` |
| GET | `/store/start/catalog?store_id=&q=` | `{groups [{category_ids, category_names, brand_id, brand_name, count, selected}], total, selected}` — путь категории от корня + бренд; `selected` — сколько уже в черновике |
| GET | `/store/start/catalog/items?store_id=&category_id=&brand_id=&q=` | товары группы (ровно эта категория; `brand_id=none` — без бренда), до 200: `{product_id, name, image, unit_short, current_price, barcode, own, selected}` |
| POST | `/store/start/catalog/select` | `{store_id, category_id?, brand_id?, exact?, q?, selected}` — отметить (по 1 шт) или снять всю группу; `category_id` — с подкатегориями, `exact: true` — только сама категория. До 2000 товаров за раз → `{changed, totals}` |
| POST | `/store/start/photos` | `{store_id, images: [url, …до 6]}` (из `POST /store/uploads`) → 202, `processing`; Super Market ищет товары в фоне. 409 `ai_not_configured` |
| GET | `/store/start/photos/{id}` | `{status (processing, ready, failed), error, images, counts {found, choose, missing}, items [{n, name, brand, barcode, qty, state, product, candidates [{product_id, name, image, unit_short, current_price, barcode, score}], brand_id, category_id, in_draft}]}` |
| POST | `/store/start/photos/{id}/retry` | распознать заново |
| POST | `/store/start/post` | `{store_id}` → установка цен магазина (изменённые цены, право `prices.manage`) и оприходование на основной склад по закупочным ценам (по 1000 строк; без закупки — себестоимость 0) → `{draft_id, products, qty, cost_total, documents [{id, number}], price_document, visible, pending}`. Пустой — 409 `draft_empty` |

Фото: модель перечисляет товары и штуки → поиск по штрихкоду (100%), иначе по похожему названию (pg_trgm, +15 за бренд).
`found` — лучший ≥ 70 и отрыв от второго ≥ 8; `choose` — есть похожие ≥ 35; `missing` — нет. Расход — в `ai_usage` (`kind = shelf`).
Повторное проведение после сбоя пропускает уже проведённые строки. Покупатель видит товар, когда он в общем каталоге,
активен и есть в наличии на складе магазина.

## Уведомления сотрудникам магазина (приложение «SM Магазин»)

| Метод | Путь | Описание |
|---|---|---|
| POST | `/store/devices` | `{token, platform: ios\|android}` — токен FCM сотрудника → 204. Вызывать после входа и при обновлении токена |
| DELETE | `/store/devices/{token}` | Забыть устройство (перед выходом) → 204 |

Устройства и очередь `notifications_outbox` разделены по приложению (`app`: `client`, `store`); рассылки покупателям
идут только на `client`. Сотрудник получает push, только если у него есть устройство `store`, он активен,
у него есть доступ к магазину и нужное право (владелец — всегда).

| Событие | Кому | `data` |
|---|---|---|
| Заказ оплачен (или оформлен наличными) — «Новый заказ №N» | право `orders.manage` | `{type: order, order_id}` |
| Заказ не принят вовремя — «Заказ №N ждёт M мин» | `orders.manage` | `{type: order, order_id}` |
| Курьер «по пути» взял заказ | `orders.manage` | `{type: order, order_id}` |
| Накладная распознана / не распознана | автор накладной | `{type: invoice, scan_id}` |

## Контроль кассиров, долги поставщикам, итоги дня (приложение магазина)

| Метод | Путь | Право | Описание |
|---|---|---|---|
| GET | `/store/pos/cashiers?store_id=&from=&to=` | `reports.view` или `finance.manage` | по умолчанию — сегодня. `signals [{kind, text, employee_id, shift_id}]`, `items [{employee_id, full_name, sales_count, revenue, discounts, max_discount_pct, returns_count, returns_total, fiscal_pending, shortage, surplus, open_shift, flags, shifts[{id, number, store_name, device_name, opened_at, closed_at, diff}]}]` |
| GET | `/store/pos/shifts/{id}/events` | то же | события смены по времени: `open`, `return`, `discount` (от 10% на чек), `cash_in`, `cash_out`, `close` |
| GET | `/store/finance/debts?side=we_owe\|they_owe\|all&q=` | `counterparties.manage`, `inventory.manage` или `finance.manage` | `we_owe`, `we_owe_count`, `they_owe`, `they_owe_count`, `items [{id, name, phone, inn, balance, last_payment_at, last_income_at, days_unpaid}]` — по сумме долга |
| GET | `/store/finance/counterparties/{id}/statement?from=&to=` | то же | акт сверки (по умолчанию — с начала месяца): `opening`, `closing`, `items [{at, kind, title, note, amount, balance}]`, новые сверху. Оплата — `POST /store/finance/operations` `{kind: expense, cashbox_id, amount, counterparty_id, note}` |
| GET | `/store/summary?date=&store_id=` | `reports.view` | итоги дня: `revenue`, `revenue_prev`, `change_pct`, `profit`, `margin_pct`, `sales_count`, `avg_check`, `orders_count`, `orders_total`, `alerts [{kind, level, title, text, target, id}]`, `stores` (если магазинов больше одного), `money {stores_cash, main_cash, available}` (по правам) |
| GET/PUT | `/store/summary/settings` | `reports.view` | `{enabled, hour}` — push «Итоги дня» в выбранный час (Ташкент). По умолчанию у владельца включено в 21:00 |

Сигналы кассиров: недостача на закрытии смены; от 3 возвратов за период; скидки от 5% суммы чеков или от 15% на один чек;
чеки без фискального признака старше часа. «Требует внимания» в итогах: недостачи за день, товары, которых осталось
меньше чем на 2 дня продаж (по средним за 14 дней), поставщики без оплаты 14+ дней, счёт подписки (срок ≤ 3 дня или просрочен),
оплаченные заказы, не принятые 10+ минут. Push итогов — `data {type: summary, date}`, один раз в день.

### Смена 24 часа

Продажа и возврат с кассы в смене, которая на момент операции (`sold_at` или сейчас) идёт дольше 24 часов, —
409 `shift_expired`: смену нужно закрыть (Z-отчёт) и открыть новую. Касса сама предупреждает за 2 часа и
останавливает продажи; без связи больше 24 часов касса тоже не продаёт, пока очередь не уйдёт.


## Импорт товаров из каталога ИКПУ (супер-админ)

Товары со штрихкодом из национального каталога ИКПУ (tasnif.soliq.uz) добавляются в общий каталог пачками.
Повторная пачка безопасна: товар ищется по штрихкоду.

| Метод | Путь | Описание |
|---|---|---|
| POST | `/admin/catalog-import` | `{source: "tasnif", items: [{barcode, name, brand, category: ["Раздел", "Подкатегория"], unit: "шт"\|"кг", description, attributes, ikpu, attach_to?}]}` (1–500) → `{created, attached, skipped, errors [{barcode, message}]}`. Бренд и категории находятся по названию без учёта регистра или создаются. `attach_to` — точное название существующего товара общего каталога: ему добавляются штрихкод и атрибуты, новый не создаётся. Штрихкод уже есть — `skipped` (товару дописывается `ikpu`). В `attributes` пишутся `ikpu`, `ikpu_name`, `package`, `marked`, `source` |
| GET | `/admin/catalog-import/status` | `{products, with_photo, without_photo, photo_jobs {pending, working, done, none, failed}, last_photo_error}` — по общему каталогу |
| POST | `/admin/catalog-import/retry-photos` | вернуть в очередь задачи фото с ошибкой → `{requeued}` |
| GET | `/admin/products?photo=with\|without` | фильтр «с фото / без фото» (и в `/admin/products/groups`) |

Фото: у каждого нового товара с ИКПУ — задача в `product_photo_jobs`. Воркер берёт по 20 задач, 4 параллельно:
`GET tasnif.soliq.uz/api/cls-api/integration-mxik/references/get/mxik/picture-names?mxik_code=<ИКПУ>` →
`…/get/file/<имя>`; фото уменьшается до 1000 px по большей стороне (JPEG, белый фон), до `PHOTOS_PER_PRODUCT`
штук (по умолчанию 2), кладётся в хранилище и ставится товару, если своих фото у него нет. Нет фото у
источника — `none`; ошибка сети — повтор через 10, 20, … минут, после 5 попыток — `failed`. Источник —
`TASNIF_URL` (по умолчанию https://tasnif.soliq.uz).

## Долги покупателей

Магазин продаёт «в долг» покупателю по номеру телефона. Долг считается по журналу `debt_entries`
(продажа +, оплата −, возврат −, списание −) отдельно по каждой паре «покупатель — магазин»; покупатель
один на сеть. Срок — `term_days` с первой покупки в долг после последнего нуля. Признак магазина
`debt_enabled` («Даёт в долг») только показывает или прячет кнопку «В долг» на кассе — покупателям его не отдаём.

Права: `debts.give` — продавать в долг на кассе; `debts.manage` — список, оплата, напоминания, лимиты, списания,
споры, настройки. Принять погашение на кассе может любой кассир (`sales.pos`).

### Касса (токен устройства, `X-Cashier-ID`)

| Метод | Путь | Описание |
|---|---|---|
| GET | `/pos/catalog` | дополнительно `settings.debt_enabled` и `debtors [{phone, full_name, debt, limit, blocked, verified}]` — для работы без связи |
| GET | `/pos/debtors?phone=` | `{found, phone, debtor: Balance\|null, purchases, unverified_limit, default_limit, require_code, debt_enabled}` |
| POST | `/pos/debtors/code` | `{phone}` → `{channel: telegram\|push\|dev, expires_in}`; 409 `no_channel` — некуда отправить, записать без кода |
| POST | `/pos/debtors/verify` | `{phone, code, full_name}` → как `GET /pos/debtors`, номер подтверждён (лимит — `default_limit`) |
| POST | `/pos/sales` | `debt: {phone, full_name, amount}` — часть итога в долг; `payments` — остаток (может быть пустым). Сверх лимита касса не останавливается: продажа сохраняется с `debt_over_limit` |
| POST | `/pos/returns` | возврат чека с долгом сначала уменьшает долг: в ответе `debt_amount`, деньгами отдаётся остальное |
| POST | `/pos/debt-payments` | `{client_uid, shift_id, phone, amount, payment_method_id, paid_at}` — погашение на кассе, идемпотентно по `client_uid`; наличные попадают в «должно быть в ящике» |

Без фискального модуля продажа в долг работает; с фискальным модулем касса её не проводит, пока не уточнены правила ОФД.

### Панель и «SM Магазин»

| Метод | Путь | Право | Описание |
|---|---|---|---|
| GET | `/store/debtors?store_id=&status=all\|overdue\|blocked\|unverified\|disputes&q=` | `debts.manage` или `debts.give` | `items [Balance]`: `debtor_id, phone, full_name, store_id, store_name, amount, limit, available, blocked, verified, since, due_date, overdue_days, last_paid_at, last_reminder_at, open_disputes` — по сумме долга |
| GET | `/store/debtors/summary?store_id=` | то же | `total, count, overdue, overdue_count, unverified, open_disputes, given_today, given_today_count, paid_today, paid_today_cash, paid_today_other` |
| GET | `/store/debtors/{id}?store_id=` | то же | карточка: `phone, full_name, credit_limit, blocked, verified, note, has_app, stores [Balance], entries [{id, store_id, store_name, doc_type, doc_id, number, amount, balance, detail, employee, dispute_status, created_at}], sales_count, sales_amount` |
| PATCH | `/store/debtors/{id}` | `debts.manage` | `{full_name, credit_limit (null — по настройкам сети), blocked, note}` |
| POST | `/store/debtors/{id}/remind` | `debts.manage` | `{store_id}` → `{sent_at, next_at}`; 409 `no_debt`, `no_app`, `too_soon` (не чаще раза в сутки) |
| POST | `/store/debt-payments` | `debts.manage` | `{debtor_id, store_id, amount, payment_method_id, note}` → `{id, number, amount, payment_method, payment_kind, balance, paid_at}`; деньги — в кассу способа оплаты |
| POST | `/store/debt-writeoffs` | `debts.manage` | `{debtor_id, store_id, amount, reason}` |
| GET | `/store/debt-disputes?store_id=&status=open\|accepted\|rejected\|all` | `debts.manage` | жалобы «Это не я» |
| POST | `/store/debt-disputes/{id}/resolve` | `debts.manage` | `{status: accepted}` — запись ошибочна, долг списывается; `rejected` — запись верна. Покупателю — push |
| GET/PUT | `/store/debt-settings` | `debts.manage` | `{default_limit, unverified_limit, term_days, require_code, extra_reminders, stores [{store_id, name, debt_enabled}]}` (по умолчанию 500 000 / 100 000 / 30 дней) |
| PUT | `/store/debt-settings/stores/{id}` | `debts.manage` | `{debt_enabled}` — «Даёт в долг» |

### Приложение покупателя

| Метод | Путь | Описание |
|---|---|---|
| GET | `/client/debts` | долги по номеру аккаунта во всех сетях: `{total, next_due, stores [{store_id, name, address, phone, logo_url, lat, lng, amount, since, due_date, overdue_days}]}` |
| GET | `/client/debts/{store_id}` | то же по магазину + `entries [{id, doc_type, number, amount, balance, detail, dispute_status, created_at, sale?: {total, paid, debt, items [{name, qty, unit, total}]}}]` |
| POST | `/client/debts/entries/{id}/dispute` | `{comment}` — «Это не я» по покупке в долг; владельцу push `{type: debt_dispute, entry_id}`; 409 `already_disputed` |

Уведомления покупателю — `data {type: debt, store_id}`: `debt_added` (записали в долг), `debt_paid` (оплата принята),
`debt_reminder` (день оплаты — всегда в 10:00 по Ташкенту; за 3 дня и после просрочки — если `extra_reminders`;
ручное «Напомнить»). Тихие часы 22:00–08:00: уведомление ждёт утра.

## Удаление аккаунтов (App Store / Google Play)

Покупатель удаляет аккаунт сам — `DELETE /client/me`, курьер «по пути» — `DELETE /crowd/me` (см. выше).
Сотрудников «SM Магазин» и штатных курьеров заводит владелец сети, поэтому из приложения отправляется
**запрос**, а удаляет супер-админ (отключает сотрудника; для владельца — закрывает сеть).

| Метод | Путь | Кто | Описание |
| --- | --- | --- | --- |
| POST | `/store/me/deletion-request` | `app=store` | Тело необязательно: `{reason?}` (до 500 символов). 201 — запрос создан, 200 — уже есть открытый (тот же). Ответ — запрос (ниже). Супер-админам и владельцу сети (если просит не он) — сообщение в Telegram-бот |
| POST | `/courier/me/deletion-request` | `app=courier` (и `store`) | То же для приложения курьера (вход по логину и паролю), `app: "courier"` |
| GET | `/admin/account-deletion-requests?status=pending\|done\|rejected&limit=&offset=` | `app=admin` | Запросы, открытые сверху |
| POST | `/admin/account-deletion-requests/{id}/done` | `app=admin` | `{note?}` — выполнено. 409 `already_resolved` — уже обработан |
| POST | `/admin/account-deletion-requests/{id}/reject` | `app=admin` | `{note?}` — отклонено |

Запрос: `{id, app: store|courier, source: app|web, status: pending|done|rejected, is_owner, phone, full_name, reason, note,
user_id, employee_id, network_id, network_name, created_at, resolved_at}`. `is_owner: true` — владелец сети: удаление
аккаунта = закрытие сети. Отметка «выполнено» сама ничего не удаляет — супер-админ отключает сотрудника или сеть.

### С сайта, без входа (ссылка для Google Play)

| Метод | Путь | Тело | Ответ |
| --- | --- | --- | --- |
| POST | `/public/account-deletion/request` | `{phone}` | Код как при входе (`/auth/otp/request`: Telegram, если номер привязан к боту, иначе SMS; пауза 60 с — 429 `too_many_requests`). `{"sent": true, "expires_in", "resend_in", "channel"}` · 404 `account_not_found` — у номера нет аккаунта (покупателя, курьера «по пути» или сотрудника) |
| POST | `/public/account-deletion/confirm` | `{phone, code}` | `{"deleted": ["crowd", "client"], "requested": ["store"\|"courier"]}` · 400 — код неверный (5 попыток, потом код сгорает) |

`confirm` удаляет аккаунт покупателя и курьера «по пути» по тем же правилам, что `DELETE /client/me` и `DELETE /crowd/me`,
в одной транзакции: если хоть одно правило не выполнено (409 `active_order` / `unpaid_balance` с `details.account`),
не удаляется ничего (код при этом использован — нужен новый). Сотруднику или штатному курьеру создаётся запрос
супер-админу (`source: "web"`, `requested: ["store"]` или `["courier"]`). Код общий с входом: код, запрошенный здесь,
подходит и для входа, и наоборот — оба подтверждают владение номером.

## Удаление (DELETE → 204)

Ответы: 404 — нет записи; 409 `in_use` — запись используется (`details.deactivate: true` — можно отключить);
409 с особым кодом — служебная запись (`default_price_type`, `main_cashbox`, `owner_role`, `owner`, `self`,
`document_posted`, `campaign_sent`).

Панель магазина: `/store/finance/{counterparties,counterparty-types,reasons,cashboxes,payment-methods}/{id}`,
`/store/price-types/{id}`, `/store/warehouses/{id}`, `/store/roles/{id}`, `/store/employees/{id}`,
`/store/products/{id}` (свой товар), `/store/price-documents/{id}` (черновик), `/store/promotions/{id}`,
`/store/banners/{id}`, `/store/pos/devices/{id}` (не подключённая касса), `/store/inventory/documents/{id}` (черновик).

Супер-админ: `/admin/catalog/{kind}/{id}`, `/admin/products/{id}`, `/admin/banners/{id}`, `/admin/billing/tariffs/{id}`,
`/admin/ads/advertisers/{id}`, `/admin/ads/campaigns/{id}` (без показов), `/admin/push/campaigns/{id}` (scheduled/cancelled).
