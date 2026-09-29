-- Этап приложения 2: профиль покупателя, устройства для push, очередь уведомлений.

-- Настройки покупателя. deleted_at — аккаунт удалён (заказы остаются
-- обезличенными для учёта и фискализации).
ALTER TABLE customers
    ADD COLUMN language        text        NOT NULL DEFAULT 'ru' CHECK (language IN ('ru', 'uz')),
    ADD COLUMN city            text        NOT NULL DEFAULT '',
    ADD COLUMN notify_orders   boolean     NOT NULL DEFAULT true,
    ADD COLUMN notify_promos   boolean     NOT NULL DEFAULT true,
    ADD COLUMN notify_telegram boolean     NOT NULL DEFAULT true,
    ADD COLUMN deleted_at      timestamptz;

-- Телефоны покупателя с токеном FCM. Токен привязан к сессии: при выходе
-- устройство удаляется.
CREATE TABLE devices (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    session_id   uuid        REFERENCES sessions (id) ON DELETE SET NULL,
    token        text        NOT NULL UNIQUE CHECK (length(token) BETWEEN 20 AND 4096),
    platform     text        NOT NULL CHECK (platform IN ('ios', 'android')),
    language     text        NOT NULL DEFAULT 'ru' CHECK (language IN ('ru', 'uz')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX devices_user_idx ON devices (user_id);
CREATE INDEX devices_session_idx ON devices (session_id);

-- Очередь уведомлений покупателям. Запись добавляется в той же транзакции,
-- что и событие (смена статуса заказа), отправляет воркер: push на все
-- устройства, если их нет — в Telegram. При ошибке — повтор с паузой.
CREATE TABLE notifications_outbox (
    id         bigserial   PRIMARY KEY,
    user_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    kind       text        NOT NULL,
    title      text        NOT NULL,
    body       text        NOT NULL,
    data       jsonb       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(data) = 'object'),
    send_after timestamptz NOT NULL DEFAULT now(),
    status     text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sent', 'skipped', 'failed')),
    channel    text        NOT NULL DEFAULT '',
    attempts   int         NOT NULL DEFAULT 0,
    last_error text        NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    sent_at    timestamptz
);
CREATE INDEX notifications_outbox_pending_idx ON notifications_outbox (send_after) WHERE status = 'pending';
CREATE INDEX notifications_outbox_user_idx ON notifications_outbox (user_id, created_at DESC);
