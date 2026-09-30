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
| PATCH | `/admin/networks/{id}` | `{"name"?, "status"?: "active"\|"blocked"}` — блокировка сразу закрывает доступ сотрудникам |

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
| GET | `/store/permissions` | — | список прав для экрана ролей |
| GET/POST | `/store/roles` | `staff.manage` (POST) | `{"name", "permissions": [...]}` |
| PATCH | `/store/roles/{id}` | `staff.manage` | роль владельца не меняется |
| GET/POST | `/store/employees` | `staff.manage` (POST) | `{"phone", "full_name", "role_id", "all_stores"?, "store_ids"?}` |
| PATCH | `/store/employees/{id}` | `staff.manage` | `{"full_name"?, "role_id"?, "status"?, "all_stores"?, "store_ids"?}`; блокировка закрывает сессии |

Права читаются из базы на каждый запрос: изменение роли или блокировка действуют сразу.

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
| GET | `/store/price-documents` | — | документы «Установка цен» |
| POST | `/store/price-documents` | `prices.manage` | `{"price_type_id", "store_id"?: null — вся сеть, "note"?, "items": [{"product_id", "new_price"}]}` — черновик |
| GET | `/store/price-documents/{id}` | — | со строками и `previous_price` |
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
| GET | `/documents?type=&status=&warehouse_id=&from=&to=` | список |
| POST | `/documents` | черновик `{"type", "warehouse_id", ..., "items": [{"product_id", "qty", "price"?}]}` |
| GET | `/documents/{id}` | со строками; у инвентаризации после проведения `expected_qty` |
| PATCH | `/documents/{id}` | черновик: `counterparty_id`, `currency`, `reason`, `note`, `items` (целиком) |
| DELETE | `/documents/{id}` | удалить черновик |
| POST | `/documents/{id}/post` | провести; 409 `insufficient_stock` с `details.product_id/available/required`, если товара не хватает — тогда ничего не меняется |
| GET | `/stock?warehouse_id=&store_id=&product_id=&q=` | остатки с `avg_cost`, `total_cost`, `avg_cost_usd` |
| GET | `/movements?warehouse_id=&product_id=` | история движения товара |

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
| GET | `/?store_id=&fiscal=pending&from=&to=` | продажи |
| GET | `/{id}` | чек со строками (`returned_qty`) и оплатами |
| POST | `/{id}/fiscal` | касса пробила чек: `{"fiscal_number", "fiscal_sign"}` |
| GET | `/fiscal-control?store_id=` | `pending_sales`, `pending_returns`, `oldest_pending_at` — контроль непробитых чеков |
| POST | `/returns` | возврат по чеку `{"sale_id", "payment_method_id", "reason"?, "items": [{"sale_line", "qty"}]}` |
| GET | `/returns?store_id=&fiscal=pending` | возвраты |
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
| POST | `/client/orders` | оформить: `{"store_id","address_id","items":[{"product_id","qty"}],"payment_provider":"payme"\|"click","comment"}` → `{order, payment_url}`. Товар резервируется |
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
| GET | `/store/orders?store_id=&status=&from=&to=` | | заказы (без неоплаченных) |
| GET | `/store/orders/{id}` | | |
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
| GET | `/admin/orders?status=&stale=true` | заказы; `stale` — оплачены, но не приняты за `ACCEPT_TIMEOUT` |
| GET | `/admin/orders/{id}` | |
| POST | `/admin/orders/{id}/cancel` | `{"reason"}` |
| GET | `/admin/payments?status=refund_pending` | очередь возвратов |
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
| GET/POST | `/admin/billing/tariffs` | `{"name","min_stores","price_per_store"}` — цена за магазин в месяц, USD |
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
(5–600 минут, `eta_min ≤ eta_max`).

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
| GET | `/client/me` | `phone`, `full_name`, `language` (`ru`/`uz`), `city`, `notifications {orders, promos, telegram}`, `telegram_linked`, `support_url`, `privacy_url` |
| PATCH | `/client/me` | Любые из: `full_name`, `language`, `city`, `notifications {orders?, promos?, telegram?}`. Ответ — профиль |
| GET | `/client/me/stats` | `orders_count`, `saved` (сумма скидок доставленных заказов), `addresses_count`, `favorites_count`, `active_order {id, number, status, store_name}` или `null` |
| DELETE | `/client/me` | Удаление аккаунта → 204. 409 `active_order`, пока есть незавершённый заказ. Сессии закрываются, имя, адреса, избранное и устройства удаляются, в заказах стираются телефон и адрес. Новый вход с тем же номером создаёт новый аккаунт |
| POST | `/client/devices` | `{token, platform: ios|android, language?}` — токен FCM для текущей сессии → 204. Вызывать после входа и при обновлении токена |
| GET | `/client/config` | Без входа: `push_enabled`, `support_url`, `privacy_url` |
| DELETE | `/client/devices/{token}` | Забыть устройство → 204. При выходе (`/auth/client/logout`) устройство сессии удаляется само |

### Уведомления о заказе

При смене статуса заказа (`paid`, `accepted`, `picked`, `delivering`, `delivered`, `cancelled`, `expired`)
в той же транзакции создаётся запись в `notifications_outbox` — на языке покупателя, если он не выключил
`notifications.orders`. Воркер каждые 3 секунды отправляет очередь: push через FCM на все устройства,
если ни одно не приняло — сообщение в Telegram-бот (если номер привязан и `notifications.telegram`).
При временной ошибке — до 6 попыток с паузой от 30 секунд. Недействительные токены удаляются.

Данные push: `{"type": "order", "order_id": "…", "status": "…"}` — приложение открывает экран заказа.

Настройка: `FCM_CREDENTIALS` — ключ сервисного аккаунта Firebase (JSON, путь к файлу или base64).
Без него push выключен и работает только Telegram.

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
