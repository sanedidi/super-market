-- Быстрые кнопки кассы: товары, которые владелец закрепил на вкладке «Частые».
-- Остальные места касса заполняет сама самыми продаваемыми за 30 дней.
CREATE TABLE pos_quick_keys (
    store_id   uuid        NOT NULL REFERENCES stores (id) ON DELETE CASCADE,
    product_id uuid        NOT NULL REFERENCES products (id) ON DELETE CASCADE,
    position   int         NOT NULL CHECK (position >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (store_id, product_id)
);
CREATE INDEX pos_quick_keys_store_idx ON pos_quick_keys (store_id, position);

-- Самые продаваемые товары магазина считаются по чекам за 30 дней.
CREATE INDEX IF NOT EXISTS sale_items_product_idx ON sale_items (product_id);
