-- Статистика главной: показы и нажатия блоков из приложения (суммы по
-- дням) и из какого блока пришёл товар в заказе.
CREATE TABLE home_stats_daily (
    day      date   NOT NULL,
    store_id uuid   NOT NULL REFERENCES stores (id) ON DELETE CASCADE,
    block_id uuid   NOT NULL,
    views    bigint NOT NULL DEFAULT 0 CHECK (views >= 0),
    clicks   bigint NOT NULL DEFAULT 0 CHECK (clicks >= 0),
    PRIMARY KEY (store_id, day, block_id)
);

ALTER TABLE order_items ADD COLUMN home_block_id uuid;
CREATE INDEX order_items_home_block_idx ON order_items (home_block_id) WHERE home_block_id IS NOT NULL;
