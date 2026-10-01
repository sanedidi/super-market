-- Вход курьера в приложение по логину и паролю. Логин и пароль задаёт
-- магазин (панель → Курьеры); сессии курьера — приложение 'courier',
-- им доступны только маршруты /courier/*.
CREATE TABLE courier_logins (
    employee_id         uuid        PRIMARY KEY REFERENCES employees (id) ON DELETE CASCADE,
    network_id          uuid        NOT NULL REFERENCES networks (id),
    login               text        NOT NULL UNIQUE CHECK (login ~ '^[a-z0-9][a-z0-9._-]{2,31}$'),
    password_hash       text        NOT NULL,
    failed_attempts     int         NOT NULL DEFAULT 0,
    locked_until        timestamptz,
    password_changed_at timestamptz NOT NULL DEFAULT now(),
    last_login_at       timestamptz,
    created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX courier_logins_network_idx ON courier_logins (network_id);

ALTER TABLE sessions DROP CONSTRAINT IF EXISTS sessions_app_check;
ALTER TABLE sessions ADD CONSTRAINT sessions_app_check CHECK (app IN ('client', 'store', 'admin', 'courier'));
