-- Этап 6: подписка сетей, вывод денег с баланса платформы.

-- Тарифы: цена за магазин в месяц (USD) в зависимости от числа активных
-- магазинов сети. Действует тариф с наибольшим min_stores, не превышающим
-- число магазинов. Супер-админ меняет тарифы сам.
CREATE TABLE tariffs (
    id              uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    name            text          NOT NULL CHECK (btrim(name) <> ''),
    min_stores      int           NOT NULL CHECK (min_stores >= 1),
    price_per_store numeric(10,2) NOT NULL CHECK (price_per_store >= 0),
    is_active       boolean       NOT NULL DEFAULT true,
    created_at      timestamptz   NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX tariffs_min_stores_active ON tariffs (min_stores) WHERE is_active;

INSERT INTO tariffs (name, min_stores, price_per_store) VALUES
    ('До 3 магазинов', 1, 20),
    ('От 3 магазинов', 3, 15);

-- Общие настройки биллинга (одна строка).
CREATE TABLE billing_settings (
    id                  int           PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    usd_rate            numeric(14,4) NOT NULL DEFAULT 12800 CHECK (usd_rate > 0),
    grace_days          int           NOT NULL DEFAULT 7 CHECK (grace_days BETWEEN 0 AND 60),
    auto_charge_balance boolean       NOT NULL DEFAULT true,
    updated_at          timestamptz   NOT NULL DEFAULT now()
);
INSERT INTO billing_settings DEFAULT VALUES;

-- Индивидуальная цена сети и дата начала оплаты (до неё — бесплатно).
ALTER TABLE networks
    ADD COLUMN custom_price_per_store numeric(10,2) CHECK (custom_price_per_store >= 0),
    ADD COLUMN billing_from date NOT NULL DEFAULT (date_trunc('month', now() AT TIME ZONE 'Asia/Tashkent') + interval '1 month')::date;

-- Счета за подписку: один на сеть за месяц.
CREATE TABLE subscription_invoices (
    id              uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id      uuid          NOT NULL REFERENCES networks (id),
    period          date          NOT NULL CHECK (extract(day FROM period) = 1),
    stores_count    int           NOT NULL CHECK (stores_count > 0),
    price_per_store numeric(10,2) NOT NULL,
    amount_usd      numeric(12,2) NOT NULL,
    rate            numeric(14,4) NOT NULL,
    amount_uzs      numeric(18,2) NOT NULL,
    status          text          NOT NULL DEFAULT 'unpaid' CHECK (status IN ('unpaid', 'paid', 'cancelled')),
    due_date        date          NOT NULL,
    paid_via        text          CHECK (paid_via IN ('balance', 'manual')),
    paid_at         timestamptz,
    note            text          NOT NULL DEFAULT '',
    created_at      timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (network_id, period)
);
CREATE INDEX subscription_invoices_unpaid_idx ON subscription_invoices (network_id, due_date) WHERE status = 'unpaid';

-- Заявки на вывод денег с баланса платформы.
CREATE TABLE payouts (
    id             uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id     uuid          NOT NULL REFERENCES networks (id),
    number         bigint        NOT NULL,
    amount         numeric(18,2) NOT NULL CHECK (amount > 0),
    status         text          NOT NULL DEFAULT 'requested' CHECK (status IN ('requested', 'paid', 'rejected')),
    requisites     text          NOT NULL CHECK (btrim(requisites) <> ''),
    note           text          NOT NULL DEFAULT '',
    admin_note     text          NOT NULL DEFAULT '',
    requested_by   uuid          NOT NULL REFERENCES employees (id),
    processed_at   timestamptz,
    created_at     timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (network_id, number)
);
CREATE INDEX payouts_status_idx ON payouts (status, created_at);

ALTER TABLE balance_entries
    ADD COLUMN invoice_id uuid REFERENCES subscription_invoices (id),
    ADD COLUMN payout_id  uuid REFERENCES payouts (id);
CREATE UNIQUE INDEX balance_entries_invoice_once ON balance_entries (invoice_id) WHERE invoice_id IS NOT NULL;
CREATE UNIQUE INDEX balance_entries_payout_once ON balance_entries (payout_id) WHERE payout_id IS NOT NULL;
