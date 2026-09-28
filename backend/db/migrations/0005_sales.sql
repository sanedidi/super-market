-- Этап 4: продажи POS, возврат от клиента, контроль фискальных чеков.

CREATE TABLE sales (
    id              uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id      uuid          NOT NULL,
    store_id        uuid          NOT NULL,
    warehouse_id    uuid          NOT NULL REFERENCES warehouses (id),
    number          bigint        NOT NULL,
    -- Идентификатор, который генерирует POS. Повторная отправка той же
    -- продажи (например, после работы без интернета) вернёт уже созданную.
    client_uid      text          NOT NULL CHECK (length(client_uid) BETWEEN 8 AND 64),
    price_type_id   uuid          NOT NULL,
    subtotal        numeric(18,2) NOT NULL,
    discount        numeric(18,2) NOT NULL DEFAULT 0,
    total           numeric(18,2) NOT NULL,
    cost            numeric(18,2) NOT NULL,
    customer_phone  text          NOT NULL DEFAULT '',
    note            text          NOT NULL DEFAULT '',
    cashier_id      uuid          NOT NULL REFERENCES employees (id),
    -- Когда продажа прошла на кассе (может быть раньше created_at при офлайне).
    sold_at         timestamptz   NOT NULL,
    fiscal_status   text          NOT NULL DEFAULT 'pending' CHECK (fiscal_status IN ('pending', 'registered')),
    fiscal_number   text          NOT NULL DEFAULT '',
    fiscal_sign     text          NOT NULL DEFAULT '',
    fiscal_at       timestamptz,
    created_at      timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (network_id, number),
    UNIQUE (network_id, client_uid),
    FOREIGN KEY (store_id, network_id) REFERENCES stores (id, network_id),
    FOREIGN KEY (price_type_id, network_id) REFERENCES price_types (id, network_id)
);
CREATE INDEX sales_store_idx ON sales (store_id, sold_at DESC);
CREATE INDEX sales_fiscal_pending_idx ON sales (network_id) WHERE fiscal_status = 'pending';

CREATE TABLE sale_items (
    sale_id    uuid          NOT NULL REFERENCES sales (id),
    line       int           NOT NULL,
    product_id uuid          NOT NULL REFERENCES products (id),
    qty        numeric(14,3) NOT NULL CHECK (qty > 0),
    price      numeric(18,2) NOT NULL,
    discount   numeric(18,2) NOT NULL DEFAULT 0,
    total      numeric(18,2) NOT NULL,
    cost       numeric(18,2) NOT NULL,
    PRIMARY KEY (sale_id, line)
);

-- Из каких партий списан товар (нужно для возврата по той же себестоимости).
CREATE TABLE sale_item_batches (
    id            bigserial     PRIMARY KEY,
    sale_id       uuid          NOT NULL,
    line          int           NOT NULL,
    batch_id      uuid          NOT NULL REFERENCES batches (id),
    qty           numeric(14,3) NOT NULL,
    unit_cost     numeric(18,4) NOT NULL,
    unit_cost_usd numeric(18,6) NOT NULL,
    FOREIGN KEY (sale_id, line) REFERENCES sale_items (sale_id, line)
);

CREATE TABLE sale_payments (
    sale_id           uuid          NOT NULL REFERENCES sales (id),
    payment_method_id uuid          NOT NULL REFERENCES payment_methods (id),
    cashbox_id        uuid          NOT NULL REFERENCES cashboxes (id),
    amount            numeric(18,2) NOT NULL CHECK (amount > 0)
);

CREATE TABLE customer_returns (
    id                uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id        uuid          NOT NULL,
    store_id          uuid          NOT NULL,
    sale_id           uuid          NOT NULL REFERENCES sales (id),
    number            bigint        NOT NULL,
    total             numeric(18,2) NOT NULL,
    cost              numeric(18,2) NOT NULL,
    payment_method_id uuid          NOT NULL REFERENCES payment_methods (id),
    cashbox_id        uuid          NOT NULL REFERENCES cashboxes (id),
    reason            text          NOT NULL DEFAULT '',
    created_by        uuid          NOT NULL REFERENCES employees (id),
    fiscal_status     text          NOT NULL DEFAULT 'pending' CHECK (fiscal_status IN ('pending', 'registered')),
    fiscal_number     text          NOT NULL DEFAULT '',
    fiscal_sign       text          NOT NULL DEFAULT '',
    fiscal_at         timestamptz,
    created_at        timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (network_id, number),
    FOREIGN KEY (store_id, network_id) REFERENCES stores (id, network_id)
);
CREATE INDEX customer_returns_sale_idx ON customer_returns (sale_id);

CREATE TABLE customer_return_items (
    return_id uuid          NOT NULL REFERENCES customer_returns (id),
    sale_line int           NOT NULL,
    qty       numeric(14,3) NOT NULL CHECK (qty > 0),
    total     numeric(18,2) NOT NULL,
    cost      numeric(18,2) NOT NULL,
    PRIMARY KEY (return_id, sale_line)
);
