-- Приложение «SM Сотрудник» (Figma «Super Market · SM Сотрудник», С1–С13).

-- Сборка онлайн-заказа сотрудником (С6–С9): «Взять в сборку» закрепляет
-- заказ за сборщиком — второй его не возьмёт; каждый товар подтверждается
-- сканом (picked_qty); собранный заказ — число пакетов для курьера и
-- отметка «Передал курьеру».
ALTER TABLE orders
    ADD COLUMN IF NOT EXISTS picker_id          uuid REFERENCES employees (id),
    ADD COLUMN IF NOT EXISTS picking_started_at timestamptz,
    ADD COLUMN IF NOT EXISTS bags               int CHECK (bags IS NULL OR bags BETWEEN 0 AND 99),
    ADD COLUMN IF NOT EXISTS handed_at          timestamptz;
CREATE INDEX IF NOT EXISTS orders_picker_idx ON orders (picker_id) WHERE picker_id IS NOT NULL;

ALTER TABLE order_items
    ADD COLUMN IF NOT EXISTS picked_qty numeric(14,3) NOT NULL DEFAULT 0 CHECK (picked_qty >= 0);

-- «Нет на полке» → «Убрать из заказа» (С8): что убрали, на сколько
-- уменьшилась сумма и кто убрал. Строка заказа удаляется, след — здесь.
CREATE TABLE IF NOT EXISTS order_removed_items (
    id          bigserial     PRIMARY KEY,
    order_id    uuid          NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
    line        int           NOT NULL,
    product_id  uuid          NOT NULL REFERENCES products (id),
    qty         numeric(14,3) NOT NULL,
    price       numeric(18,2) NOT NULL,
    total       numeric(18,2) NOT NULL,
    employee_id uuid          REFERENCES employees (id),
    created_at  timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS order_removed_items_order_idx ON order_removed_items (order_id);

-- Фото к складскому документу (списание из «SM Сотрудник»: причина и фото
-- обязательны, С11).
ALTER TABLE stock_documents ADD COLUMN IF NOT EXISTS photos text[] NOT NULL DEFAULT '{}';

-- Автозадача «Поменять ценники» (С12): цена товара в магазине изменилась —
-- сотрудник меняет ценник на полке и отмечает это. Отметка — до какой
-- цены ценник уже поменян.
CREATE TABLE IF NOT EXISTS price_tag_marks (
    store_id    uuid          NOT NULL REFERENCES stores (id) ON DELETE CASCADE,
    product_id  uuid          NOT NULL REFERENCES products (id) ON DELETE CASCADE,
    price       numeric(14,2) NOT NULL,
    employee_id uuid          REFERENCES employees (id) ON DELETE SET NULL,
    marked_at   timestamptz   NOT NULL DEFAULT now(),
    PRIMARY KEY (store_id, product_id)
);

-- «SM Сотрудник» — отдельное приложение в сторах: своя версия и «Есть обновление».
ALTER TABLE app_versions DROP CONSTRAINT IF EXISTS app_versions_app_check;
ALTER TABLE app_versions ADD CONSTRAINT app_versions_app_check
    CHECK (app IN ('client', 'store', 'courier', 'agent', 'employee'));
