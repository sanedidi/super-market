-- Требования App Store / Google Play: удаление аккаунтов и согласие на
-- рекламные push.

-- Курьер «по пути» удаляет аккаунт сам: профиль обезличивается, история
-- заказов, начислений и выплат остаётся.
ALTER TABLE crowd_couriers ADD COLUMN deleted_at timestamptz;

-- Запросы на удаление аккаунтов сотрудников («SM Магазин») и штатных
-- курьеров: их заводит владелец сети, поэтому удаляет супер-админ (для
-- владельца — закрытие сети). source: app — из приложения, web — с сайта.
CREATE TABLE account_deletion_requests (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid        REFERENCES users (id) ON DELETE SET NULL,
    employee_id uuid        REFERENCES employees (id) ON DELETE SET NULL,
    network_id  uuid        REFERENCES networks (id) ON DELETE SET NULL,
    app         text        NOT NULL CHECK (app IN ('store', 'courier')),
    source      text        NOT NULL DEFAULT 'app' CHECK (source IN ('app', 'web')),
    is_owner    boolean     NOT NULL DEFAULT false,
    phone       text        NOT NULL DEFAULT '',
    full_name   text        NOT NULL DEFAULT '',
    reason      text        NOT NULL DEFAULT '' CHECK (length(reason) <= 500),
    status      text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'done', 'rejected')),
    note        text        NOT NULL DEFAULT '' CHECK (length(note) <= 500),
    resolved_by uuid        REFERENCES users (id),
    resolved_at timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX account_deletion_requests_status_idx ON account_deletion_requests (status, created_at DESC);
-- Один открытый запрос на сотрудника: повторный возвращает тот же.
CREATE UNIQUE INDEX account_deletion_requests_pending_idx ON account_deletion_requests (employee_id) WHERE status = 'pending';

-- Рекламные push — только с явного согласия (Apple 4.5.4): у новых
-- покупателей выключены. Существующим настройку не меняем.
ALTER TABLE customers ALTER COLUMN notify_promos SET DEFAULT false;
-- Когда покупатель явно включил рекламные push.
ALTER TABLE customers ADD COLUMN promos_consent_at timestamptz;
