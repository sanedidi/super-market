-- Сдача наличных курьером в кассу магазина (Figma «Правки 16 окт» → К10, К11, М33, М34).
-- Журнал наличных на руках у штатного курьера: плюс — наличные доставленного
-- заказа, минус — то, что магазин подтвердил при сдаче. На руках = сумма записей.
-- Заказы, доставленные до этой миграции, в журнал не попадают.

CREATE TABLE courier_cash_handovers (
    id                uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id        uuid          NOT NULL,
    store_id          uuid          NOT NULL,
    courier_id        uuid          NOT NULL REFERENCES employees (id),
    amount            numeric(18,2) NOT NULL CHECK (amount > 0),
    -- Сколько магазин получил на самом деле (пока ждёт — NULL).
    received          numeric(18,2) CHECK (received >= 0 AND received <= amount),
    status            text          NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'received')),
    comment           text          NOT NULL DEFAULT '',
    cashbox_id        uuid          REFERENCES cashboxes (id),
    answered_by       uuid          REFERENCES employees (id),
    created_at        timestamptz   NOT NULL DEFAULT now(),
    answered_at       timestamptz,
    FOREIGN KEY (store_id, network_id) REFERENCES stores (id, network_id),
    CHECK ((status = 'received') = (received IS NOT NULL))
);
CREATE INDEX courier_cash_handovers_store_idx ON courier_cash_handovers (store_id, status, created_at DESC);
CREATE INDEX courier_cash_handovers_courier_idx ON courier_cash_handovers (courier_id, created_at DESC);

CREATE TABLE courier_cash_entries (
    id          bigserial     PRIMARY KEY,
    network_id  uuid          NOT NULL,
    store_id    uuid          NOT NULL,
    courier_id  uuid          NOT NULL REFERENCES employees (id),
    amount      numeric(18,2) NOT NULL,
    order_id    uuid          REFERENCES orders (id),
    handover_id uuid          REFERENCES courier_cash_handovers (id),
    created_at  timestamptz   NOT NULL DEFAULT now(),
    FOREIGN KEY (store_id, network_id) REFERENCES stores (id, network_id),
    CHECK ((order_id IS NULL) <> (handover_id IS NULL))
);
CREATE UNIQUE INDEX courier_cash_entries_order_uniq ON courier_cash_entries (order_id) WHERE order_id IS NOT NULL;
CREATE INDEX courier_cash_entries_courier_idx ON courier_cash_entries (courier_id, store_id);
