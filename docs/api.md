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
| POST | `/auth/otp/request` | `{"phone"}` | `{"sent": true, "expires_in": 300}` · 409 `telegram_not_linked` с `details.bot_url` · 429 `too_many_requests` с `details.retry_after` |
| POST | `/auth/otp/verify` | `{"phone", "code", "app"}` | `{"access_token", "refresh_token", "token_type", "expires_in"}` · 403 — нет доступа к приложению |
| POST | `/auth/refresh` | `{"refresh_token"}` | новая пара токенов; старый refresh больше не действует |
| POST | `/auth/{client,store,admin}/logout` | — | 204 |

Покупатель регистрируется при первом входе. В `store` можно войти только активному
сотруднику активной сети, в `admin` — номерам из `SUPER_ADMIN_PHONES`.
Access-токен живёт 15 минут, refresh — 30 дней. После 5 неверных кодов код сгорает.

## Супер-админ (`app=admin`)

| Метод | Путь | Описание |
| --- | --- | --- |
| GET | `/admin/networks?q=&limit=&offset=` | сети, поиск по названию и телефону владельца |
| POST | `/admin/networks` | `{"name", "kind": "chain"\|"single", "owner_phone", "owner_name"}` — сеть + роль «Владелец» + сотрудник-владелец |
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
| GET | `/store/me` | — | сеть, права, доступные магазины |
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
| GET | `/pos/sales/{id}` | Чек |
| POST | `/pos/returns` | Как `/store/sales/returns` + `shift_id` |

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
| GET | `/client/me` | `phone`, `full_name`, `language` (`ru`/`uz`), `city`, `notifications {orders, promos}`, `telegram_linked`, `support_url`, `privacy_url` |
| PATCH | `/client/me` | Любые из: `full_name`, `language`, `city`, `notifications {orders?, promos?}`. Ответ — профиль |
| GET | `/client/me/stats` | `orders_count`, `saved` (сумма скидок доставленных заказов), `addresses_count`, `favorites_count`, `active_order {id, number, status, store_name}` или `null` |
| DELETE | `/client/me` | Удаление аккаунта → 204. 409 `active_order`, пока есть незавершённый заказ. Сессии закрываются, имя, адреса, избранное и устройства удаляются, в заказах стираются телефон и адрес. Новый вход с тем же номером создаёт новый аккаунт |
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
