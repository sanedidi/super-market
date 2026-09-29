-- Этап приложения 3: доставка ко времени.

-- Окна доставки магазина: длина окна, на сколько дней вперёд можно выбрать,
-- минимальный запас до начала окна и сколько заказов магазин успевает за окно.
CREATE TABLE delivery_slot_rules (
    store_id     uuid        PRIMARY KEY REFERENCES stores (id) ON DELETE CASCADE,
    enabled      boolean     NOT NULL DEFAULT false,
    slot_minutes int         NOT NULL DEFAULT 60 CHECK (slot_minutes BETWEEN 30 AND 240),
    days_ahead   int         NOT NULL DEFAULT 1 CHECK (days_ahead BETWEEN 0 AND 6),
    lead_minutes int         NOT NULL DEFAULT 60 CHECK (lead_minutes BETWEEN 0 AND 720),
    capacity     int         NOT NULL DEFAULT 5 CHECK (capacity BETWEEN 1 AND 500),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

-- Окно доставки заказа; пусто — «как можно скорее».
ALTER TABLE orders
    ADD COLUMN delivery_from timestamptz,
    ADD COLUMN delivery_to   timestamptz,
    ADD CONSTRAINT orders_delivery_window CHECK (
        (delivery_from IS NULL AND delivery_to IS NULL) OR delivery_to > delivery_from);
CREATE INDEX orders_store_slot_idx ON orders (store_id, delivery_from) WHERE delivery_from IS NOT NULL;
