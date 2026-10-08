-- Ассортимент магазина («Мои товары»): товары центральной базы, которые есть
-- в магазине. Раздел «Товары» панели показывает только их, центральная база —
-- только в поиске при добавлении. Магазин заводит их сам в «Начале работы»;
-- потом товар попадает сюда сам — с приходом на склад магазина или ценой магазина.

CREATE TABLE store_products (
    network_id uuid        NOT NULL,
    store_id   uuid        NOT NULL,
    product_id uuid        NOT NULL REFERENCES products (id) ON DELETE CASCADE,
    added_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (store_id, product_id),
    FOREIGN KEY (store_id, network_id) REFERENCES stores (id, network_id) ON DELETE CASCADE
);
CREATE INDEX store_products_network_idx ON store_products (network_id, product_id);
CREATE INDEX store_products_product_idx ON store_products (product_id);

-- Товар пришёл на склад магазина (приход, оприходование, перемещение, излишек).
CREATE FUNCTION store_products_from_batch() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO store_products (network_id, store_id, product_id)
    SELECT w.network_id, w.store_id, NEW.product_id FROM warehouses w WHERE w.id = NEW.warehouse_id
    ON CONFLICT DO NOTHING;
    RETURN NULL;
END $$;
CREATE TRIGGER batches_store_products AFTER INSERT ON batches
    FOR EACH ROW EXECUTE FUNCTION store_products_from_batch();

-- Магазин поставил свою цену на товар.
CREATE FUNCTION store_products_from_price() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO store_products (network_id, store_id, product_id)
    VALUES (NEW.network_id, NEW.store_id, NEW.product_id)
    ON CONFLICT DO NOTHING;
    RETURN NULL;
END $$;
CREATE TRIGGER prices_store_products AFTER INSERT OR UPDATE OF price ON prices
    FOR EACH ROW WHEN (NEW.store_id IS NOT NULL) EXECUTE FUNCTION store_products_from_price();

-- Уже работающие магазины: всё, что было на складе, в цене магазина, в продажах
-- и в проведённом «Начале работы».
INSERT INTO store_products (network_id, store_id, product_id, added_at)
SELECT w.network_id, w.store_id, b.product_id, min(b.created_at)
FROM batches b JOIN warehouses w ON w.id = b.warehouse_id
GROUP BY w.network_id, w.store_id, b.product_id
ON CONFLICT DO NOTHING;

INSERT INTO store_products (network_id, store_id, product_id, added_at)
SELECT network_id, store_id, product_id, min(updated_at)
FROM prices WHERE store_id IS NOT NULL
GROUP BY network_id, store_id, product_id
ON CONFLICT DO NOTHING;

INSERT INTO store_products (network_id, store_id, product_id, added_at)
SELECT s.network_id, s.store_id, i.product_id, min(s.created_at)
FROM sales s JOIN sale_items i ON i.sale_id = s.id
GROUP BY s.network_id, s.store_id, i.product_id
ON CONFLICT DO NOTHING;

INSERT INTO store_products (network_id, store_id, product_id, added_at)
SELECT d.network_id, d.store_id, l.product_id, min(l.added_at)
FROM start_lines l JOIN start_drafts d ON d.id = l.draft_id
WHERE d.status = 'posted'
GROUP BY d.network_id, d.store_id, l.product_id
ON CONFLICT DO NOTHING;

-- «Начало работы» в два шага: сначала магазин выбирает товары (количества
-- ещё нет), потом в «Инвентаризации: Начало работы» вводит количество и цену
-- продажи (обе обязательны, можно 0) и, по желанию, себестоимость.
ALTER TABLE start_lines ALTER COLUMN qty DROP NOT NULL;
ALTER TABLE start_lines DROP CONSTRAINT start_lines_qty_check;
ALTER TABLE start_lines ADD CONSTRAINT start_lines_qty_check CHECK (qty >= 0);
ALTER TABLE start_lines DROP CONSTRAINT start_lines_price_check;
ALTER TABLE start_lines ADD CONSTRAINT start_lines_price_check CHECK (price >= 0);

-- «Похожий товар уже есть» — магазин ответил «всё равно добавить»: для этой
-- пары больше не спрашиваем. Пара хранится упорядоченной (меньший id первым).
CREATE TABLE start_similar_ok (
    store_id   uuid        NOT NULL REFERENCES stores (id) ON DELETE CASCADE,
    product_id uuid        NOT NULL REFERENCES products (id) ON DELETE CASCADE,
    similar_id uuid        NOT NULL REFERENCES products (id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (store_id, product_id, similar_id),
    CHECK (product_id < similar_id)
);
