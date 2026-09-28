-- Этап 3: контрагенты, кассы, курс валют, склад (партии, FIFO, документы).
--
-- Валюты: UZS — основная. Себестоимость партий хранится в UZS и USD
-- (как _xs в Dokondor), курс фиксируется в документе на момент проведения.

------------------------------------------------------------ контрагенты

CREATE TABLE counterparty_types (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id uuid        NOT NULL REFERENCES networks (id),
    name       text        NOT NULL CHECK (btrim(name) <> ''),
    is_active  boolean     NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (network_id, name),
    UNIQUE (id, network_id)
);

CREATE TABLE counterparties (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id uuid        NOT NULL REFERENCES networks (id),
    type_id    uuid,
    name       text        NOT NULL CHECK (btrim(name) <> ''),
    phone      text        NOT NULL DEFAULT '',
    inn        text        NOT NULL DEFAULT '',
    note       text        NOT NULL DEFAULT '',
    is_active  boolean     NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (type_id, network_id) REFERENCES counterparty_types (id, network_id),
    UNIQUE (id, network_id)
);
CREATE INDEX counterparties_network_idx ON counterparties (network_id);
CREATE TRIGGER counterparties_updated_at BEFORE UPDATE ON counterparties FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Взаиморасчёты. Баланс контрагента = сумма amount в UZS.
-- Плюс — мы должны контрагенту (приход товара), минус — он нам (возврат, наша оплата).
CREATE TABLE counterparty_entries (
    id              bigserial     PRIMARY KEY,
    network_id      uuid          NOT NULL,
    counterparty_id uuid          NOT NULL,
    amount          numeric(18,2) NOT NULL,
    doc_type        text          NOT NULL,
    doc_id          uuid          NOT NULL,
    created_at      timestamptz   NOT NULL DEFAULT now(),
    FOREIGN KEY (counterparty_id, network_id) REFERENCES counterparties (id, network_id)
);
CREATE INDEX counterparty_entries_cp_idx ON counterparty_entries (counterparty_id);

------------------------------------------------------------- курс валют

-- Курс: сколько сумов за 1 USD. Действует последний установленный.
CREATE TABLE currency_rates (
    id         bigserial     PRIMARY KEY,
    network_id uuid          NOT NULL REFERENCES networks (id),
    rate       numeric(14,4) NOT NULL CHECK (rate > 0),
    created_by uuid          REFERENCES employees (id),
    created_at timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX currency_rates_network_idx ON currency_rates (network_id, created_at DESC);

------------------------------------------------------------------ кассы

CREATE TABLE cashboxes (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id uuid        NOT NULL REFERENCES networks (id),
    -- NULL — главная касса сети (одна на сеть).
    store_id   uuid,
    name       text        NOT NULL CHECK (btrim(name) <> ''),
    currency   text        NOT NULL DEFAULT 'UZS' CHECK (currency IN ('UZS', 'USD')),
    is_main    boolean     NOT NULL DEFAULT false,
    is_active  boolean     NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (store_id, network_id) REFERENCES stores (id, network_id),
    UNIQUE (id, network_id),
    CHECK (is_main = (store_id IS NULL))
);
CREATE UNIQUE INDEX cashboxes_one_main ON cashboxes (network_id, currency) WHERE is_main;

-- Движение денег. Баланс кассы = сумма amount (в валюте кассы).
CREATE TABLE cash_entries (
    id         bigserial     PRIMARY KEY,
    network_id uuid          NOT NULL,
    cashbox_id uuid          NOT NULL,
    amount     numeric(18,2) NOT NULL,
    doc_type   text          NOT NULL,
    doc_id     uuid          NOT NULL,
    created_at timestamptz   NOT NULL DEFAULT now(),
    FOREIGN KEY (cashbox_id, network_id) REFERENCES cashboxes (id, network_id)
);
CREATE INDEX cash_entries_cashbox_idx ON cash_entries (cashbox_id, created_at);

CREATE TABLE payment_methods (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id uuid        NOT NULL REFERENCES networks (id),
    name       text        NOT NULL CHECK (btrim(name) <> ''),
    -- Куда поступают деньги этим способом.
    cashbox_id uuid        NOT NULL,
    is_active  boolean     NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (cashbox_id, network_id) REFERENCES cashboxes (id, network_id),
    UNIQUE (cashbox_id, name),
    UNIQUE (id, network_id)
);

CREATE TABLE financial_reasons (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id uuid        NOT NULL REFERENCES networks (id),
    name       text        NOT NULL CHECK (btrim(name) <> ''),
    kind       text        NOT NULL CHECK (kind IN ('income', 'expense')),
    is_active  boolean     NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (network_id, kind, name),
    UNIQUE (id, network_id)
);

-- Кассовая операция: приход или расход по одной кассе.
CREATE TABLE cash_operations (
    id              uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id      uuid          NOT NULL,
    number          bigint        NOT NULL,
    kind            text          NOT NULL CHECK (kind IN ('income', 'expense')),
    cashbox_id      uuid          NOT NULL,
    amount          numeric(18,2) NOT NULL CHECK (amount > 0),
    -- Сумма в UZS по курсу на момент операции (для кассы в USD).
    amount_uzs      numeric(18,2) NOT NULL,
    rate            numeric(14,4),
    counterparty_id uuid,
    reason_id       uuid,
    note            text          NOT NULL DEFAULT '',
    created_by      uuid          NOT NULL REFERENCES employees (id),
    created_at      timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (network_id, number),
    FOREIGN KEY (cashbox_id, network_id) REFERENCES cashboxes (id, network_id),
    FOREIGN KEY (counterparty_id, network_id) REFERENCES counterparties (id, network_id),
    FOREIGN KEY (reason_id, network_id) REFERENCES financial_reasons (id, network_id),
    CHECK (counterparty_id IS NOT NULL OR reason_id IS NOT NULL)
);

-- Перемещение денег: из кассы в кассу или сдача кассы в главную.
CREATE TABLE cash_transfers (
    id          uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id  uuid          NOT NULL,
    number      bigint        NOT NULL,
    kind        text          NOT NULL CHECK (kind IN ('transfer', 'handover')),
    from_id     uuid          NOT NULL,
    to_id       uuid          NOT NULL,
    amount_from numeric(18,2) NOT NULL CHECK (amount_from > 0),
    amount_to   numeric(18,2) NOT NULL CHECK (amount_to > 0),
    rate        numeric(14,4),
    note        text          NOT NULL DEFAULT '',
    created_by  uuid          NOT NULL REFERENCES employees (id),
    created_at  timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (network_id, number),
    FOREIGN KEY (from_id, network_id) REFERENCES cashboxes (id, network_id),
    FOREIGN KEY (to_id, network_id) REFERENCES cashboxes (id, network_id),
    CHECK (from_id <> to_id)
);

------------------------------------------------------------------- склад

-- Партия — товар, пришедший на склад одним документом по одной цене.
CREATE TABLE batches (
    id             uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id     uuid          NOT NULL,
    warehouse_id   uuid          NOT NULL REFERENCES warehouses (id),
    product_id     uuid          NOT NULL REFERENCES products (id),
    doc_type       text          NOT NULL,
    doc_id         uuid          NOT NULL,
    qty_initial    numeric(14,3) NOT NULL CHECK (qty_initial > 0),
    qty_remaining  numeric(14,3) NOT NULL CHECK (qty_remaining >= 0 AND qty_remaining <= qty_initial),
    -- Себестоимость единицы: в UZS и в USD.
    unit_cost      numeric(18,4) NOT NULL CHECK (unit_cost >= 0),
    unit_cost_usd  numeric(18,6) NOT NULL CHECK (unit_cost_usd >= 0),
    created_at     timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX batches_fifo_idx ON batches (warehouse_id, product_id, created_at, id) WHERE qty_remaining > 0;

-- Журнал всех движений товара.
CREATE TABLE stock_movements (
    id            bigserial     PRIMARY KEY,
    network_id    uuid          NOT NULL,
    warehouse_id  uuid          NOT NULL,
    product_id    uuid          NOT NULL,
    batch_id      uuid          NOT NULL REFERENCES batches (id),
    qty           numeric(14,3) NOT NULL CHECK (qty <> 0),
    unit_cost     numeric(18,4) NOT NULL,
    unit_cost_usd numeric(18,6) NOT NULL,
    doc_type      text          NOT NULL,
    doc_id        uuid          NOT NULL,
    created_at    timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX stock_movements_wp_idx ON stock_movements (warehouse_id, product_id, created_at);
CREATE INDEX stock_movements_doc_idx ON stock_movements (doc_id);

-- Складские документы всех видов в одной таблице:
--   income          приход от поставщика      warehouse, counterparty, currency, rate, цены
--   supplier_return возврат поставщику        warehouse, counterparty, currency, rate, цены
--   transfer        между складами            warehouse → to_warehouse
--   write_off       списание                  warehouse, reason
--   posting         оприходование             warehouse, цены (себестоимость)
--   inventory       инвентаризация            warehouse, фактическое количество
CREATE TABLE stock_documents (
    id              uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id      uuid          NOT NULL,
    type            text          NOT NULL CHECK (type IN ('income', 'supplier_return', 'transfer', 'write_off', 'posting', 'inventory')),
    number          bigint        NOT NULL,
    status          text          NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'posted')),
    warehouse_id    uuid          NOT NULL REFERENCES warehouses (id),
    to_warehouse_id uuid          REFERENCES warehouses (id),
    counterparty_id uuid,
    currency        text          NOT NULL DEFAULT 'UZS' CHECK (currency IN ('UZS', 'USD')),
    rate            numeric(14,4),
    reason          text          NOT NULL DEFAULT '',
    note            text          NOT NULL DEFAULT '',
    total           numeric(18,2) NOT NULL DEFAULT 0,
    created_by      uuid          NOT NULL REFERENCES employees (id),
    posted_by       uuid          REFERENCES employees (id),
    posted_at       timestamptz,
    created_at      timestamptz   NOT NULL DEFAULT now(),
    updated_at      timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (network_id, type, number),
    FOREIGN KEY (counterparty_id, network_id) REFERENCES counterparties (id, network_id),
    CHECK (to_warehouse_id IS DISTINCT FROM warehouse_id)
);
CREATE INDEX stock_documents_network_idx ON stock_documents (network_id, type, created_at DESC);
CREATE TRIGGER stock_documents_updated_at BEFORE UPDATE ON stock_documents FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE stock_document_items (
    document_id  uuid          NOT NULL REFERENCES stock_documents (id) ON DELETE CASCADE,
    line         int           NOT NULL,
    product_id   uuid          NOT NULL REFERENCES products (id),
    -- Для инвентаризации — фактическое количество; для остальных — сколько двигаем.
    qty          numeric(14,3) NOT NULL CHECK (qty >= 0),
    -- Цена за единицу в валюте документа (приход, возврат, оприходование).
    price        numeric(18,4),
    -- Заполняется при проведении инвентаризации: учётное количество.
    expected_qty numeric(14,3),
    PRIMARY KEY (document_id, line)
);

------------------------------------------- кассы для существующих сетей

INSERT INTO cashboxes (network_id, store_id, name, is_main)
SELECT id, NULL, 'Главная касса', true FROM networks;

INSERT INTO cashboxes (network_id, store_id, name)
SELECT network_id, id, 'Касса ' || name FROM stores;

INSERT INTO payment_methods (network_id, name, cashbox_id)
SELECT c.network_id, m.name, c.id
FROM cashboxes c CROSS JOIN (VALUES ('Наличные'), ('Терминал')) AS m (name)
WHERE NOT c.is_main;
