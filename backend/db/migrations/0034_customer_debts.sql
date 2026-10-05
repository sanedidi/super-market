-- Долги покупателей (насия): продажа в долг на кассе, погашение, списание,
-- напоминания, спор «Это не я». Долг ведётся по магазину, покупатель —
-- по номеру телефона внутри сети. Баланс — сумма записей журнала.

-- Переключатель «Даёт в долг» — у каждого магазина. Покупателям не отдаётся.
ALTER TABLE stores ADD COLUMN debt_enabled boolean NOT NULL DEFAULT false;

-- Настройки сети. Нет строки — значения по умолчанию.
CREATE TABLE debt_settings (
    network_id       uuid          PRIMARY KEY REFERENCES networks (id),
    default_limit    numeric(18,2) NOT NULL DEFAULT 500000 CHECK (default_limit >= 0),
    -- Лимит покупателя, который не подтвердил номер кодом.
    unverified_limit numeric(18,2) NOT NULL DEFAULT 100000 CHECK (unverified_limit >= 0),
    term_days        int           NOT NULL DEFAULT 30 CHECK (term_days BETWEEN 1 AND 365),
    require_code     boolean       NOT NULL DEFAULT true,
    -- Напоминания за 3 дня до срока и после просрочки. В день оплаты — всегда.
    extra_reminders  boolean       NOT NULL DEFAULT true,
    updated_at       timestamptz   NOT NULL DEFAULT now()
);

CREATE TABLE debtors (
    id           uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id   uuid          NOT NULL REFERENCES networks (id),
    phone        text          NOT NULL CHECK (phone ~ '^\+[1-9][0-9]{9,14}$'),
    full_name    text          NOT NULL DEFAULT '',
    -- Свой лимит покупателя; NULL — из настроек сети.
    credit_limit numeric(18,2) CHECK (credit_limit IS NULL OR credit_limit >= 0),
    -- Стоп-лист: в долг не давать.
    blocked      boolean       NOT NULL DEFAULT false,
    verified_at  timestamptz,
    note         text          NOT NULL DEFAULT '',
    created_at   timestamptz   NOT NULL DEFAULT now(),
    updated_at   timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (network_id, phone),
    UNIQUE (id, network_id)
);
CREATE INDEX debtors_phone_idx ON debtors (phone);
CREATE TRIGGER debtors_updated_at BEFORE UPDATE ON debtors FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Журнал долга. Плюс — долг вырос (продажа), минус — погашение, возврат, списание.
CREATE TABLE debt_entries (
    id         bigserial     PRIMARY KEY,
    network_id uuid          NOT NULL,
    debtor_id  uuid          NOT NULL,
    store_id   uuid          NOT NULL,
    amount     numeric(18,2) NOT NULL CHECK (amount <> 0),
    doc_type   text          NOT NULL CHECK (doc_type IN ('sale', 'payment', 'return', 'writeoff')),
    doc_id     uuid          NOT NULL,
    created_at timestamptz   NOT NULL DEFAULT now(),
    FOREIGN KEY (debtor_id, network_id) REFERENCES debtors (id, network_id),
    FOREIGN KEY (store_id, network_id) REFERENCES stores (id, network_id)
);
CREATE INDEX debt_entries_debtor_idx ON debt_entries (debtor_id, store_id, created_at, id);
CREATE INDEX debt_entries_store_idx ON debt_entries (store_id, created_at);

-- Продажа: часть итога в долг (остальное — способами оплаты).
ALTER TABLE sales
    ADD COLUMN debt_amount     numeric(18,2) NOT NULL DEFAULT 0 CHECK (debt_amount >= 0),
    ADD COLUMN debtor_id       uuid REFERENCES debtors (id),
    -- Касса продала в долг сверх лимита или в стоп-лист без связи — для контроля.
    ADD COLUMN debt_over_limit boolean NOT NULL DEFAULT false,
    ADD CONSTRAINT sales_debt_debtor CHECK (debt_amount = 0 OR debtor_id IS NOT NULL);

-- Возврат по чеку с долгом сначала уменьшает долг.
ALTER TABLE customer_returns ADD COLUMN debt_amount numeric(18,2) NOT NULL DEFAULT 0 CHECK (debt_amount >= 0);

CREATE TABLE debt_payments (
    id                uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id        uuid          NOT NULL,
    number            bigint        NOT NULL,
    -- С кассы — идентификатор кассы (повтор после офлайна не создаёт дубль).
    client_uid        text          CHECK (client_uid IS NULL OR length(client_uid) BETWEEN 8 AND 64),
    debtor_id         uuid          NOT NULL,
    store_id          uuid          NOT NULL,
    amount            numeric(18,2) NOT NULL CHECK (amount > 0),
    payment_method_id uuid          NOT NULL REFERENCES payment_methods (id),
    cashbox_id        uuid          NOT NULL REFERENCES cashboxes (id),
    note              text          NOT NULL DEFAULT '',
    created_by        uuid          NOT NULL REFERENCES employees (id),
    device_id         uuid          REFERENCES pos_devices (id),
    shift_id          uuid          REFERENCES pos_shifts (id),
    paid_at           timestamptz   NOT NULL DEFAULT now(),
    created_at        timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (network_id, number),
    FOREIGN KEY (debtor_id, network_id) REFERENCES debtors (id, network_id),
    FOREIGN KEY (store_id, network_id) REFERENCES stores (id, network_id)
);
CREATE UNIQUE INDEX debt_payments_client_uid ON debt_payments (network_id, client_uid) WHERE client_uid IS NOT NULL;
CREATE INDEX debt_payments_shift_idx ON debt_payments (shift_id) WHERE shift_id IS NOT NULL;

CREATE TABLE debt_writeoffs (
    id         uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id uuid          NOT NULL,
    number     bigint        NOT NULL,
    debtor_id  uuid          NOT NULL,
    store_id   uuid          NOT NULL,
    amount     numeric(18,2) NOT NULL CHECK (amount > 0),
    reason     text          NOT NULL CHECK (btrim(reason) <> ''),
    created_by uuid          NOT NULL REFERENCES employees (id),
    created_at timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (network_id, number),
    FOREIGN KEY (debtor_id, network_id) REFERENCES debtors (id, network_id),
    FOREIGN KEY (store_id, network_id) REFERENCES stores (id, network_id)
);

-- «Это не я» — покупатель оспаривает запись долга.
CREATE TABLE debt_disputes (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id  uuid        NOT NULL,
    entry_id    bigint      NOT NULL REFERENCES debt_entries (id),
    user_id     uuid        NOT NULL REFERENCES users (id),
    comment     text        NOT NULL DEFAULT '',
    status      text        NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'accepted', 'rejected')),
    resolved_by uuid        REFERENCES employees (id),
    resolved_at timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (entry_id, user_id)
);
CREATE INDEX debt_disputes_open_idx ON debt_disputes (network_id) WHERE status = 'open';

-- Напоминания: автоматические — по одному на срок и вид, ручные — не чаще раза в сутки.
CREATE TABLE debt_reminders (
    id         bigserial   PRIMARY KEY,
    network_id uuid        NOT NULL,
    debtor_id  uuid        NOT NULL,
    store_id   uuid        NOT NULL,
    kind       text        NOT NULL CHECK (kind IN ('before', 'due', 'overdue', 'manual')),
    due_date   date        NOT NULL,
    created_by uuid        REFERENCES employees (id),
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (debtor_id, network_id) REFERENCES debtors (id, network_id)
);
CREATE UNIQUE INDEX debt_reminders_auto ON debt_reminders (debtor_id, store_id, kind, due_date) WHERE kind <> 'manual';
CREATE INDEX debt_reminders_last_idx ON debt_reminders (debtor_id, store_id, created_at DESC);

-- Коды подтверждения номера при первом долге (храним только HMAC).
CREATE TABLE debt_codes (
    network_id uuid        NOT NULL REFERENCES networks (id),
    phone      text        NOT NULL,
    code_hash  bytea       NOT NULL,
    attempts   int         NOT NULL DEFAULT 0,
    sent_at    timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    PRIMARY KEY (network_id, phone)
);
