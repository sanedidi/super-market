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
