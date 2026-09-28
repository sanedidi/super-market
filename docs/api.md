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
| GET | `/admin/catalog/{kind}` | — все записи |
| POST | `/admin/catalog/{kind}` | brands: `{"name"}` · categories: `{"name", "parent_id"?, "sort"?}` · colors: `{"name", "hex"?: "#FF0000"}` · units: `{"name", "short_name", "is_fractional"?}` |
| PATCH | `/admin/catalog/{kind}/{id}` | любые поля + `is_active` |
| GET | `/store/catalog/{kind}` | только активные |

Единицы «шт», «кг», «л», «уп» создаются миграцией.

### Товары

Товар: `name`, `description`, `brand_id`, `category_id`, `unit_id`, `color_id`, `base_price`, `images` (ссылки), `barcodes`, `is_active`.
Штрихкод уникален на всю платформу — при совпадении ответ 409 `barcode_exists` с `details.product_id`.

| Метод | Путь | Описание |
| --- | --- | --- |
| GET | `/admin/products?q=&category_id=&barcode=&status=` | все товары; `status=pending` — очередь модерации |
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
