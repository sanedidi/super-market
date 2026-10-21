-- Кафе, этап 2: то, что нужно панели (Figma «Веб-панель»: П1 Меню → Блюда,
-- П2 Блюдо, П3 Модификаторы, П5 Склад продуктов, П7/П7б Цеха, П11/П12 Заготовки).

-- Цех: значок, норма приготовления по умолчанию и когда печатать бегунок
-- (always — всегда, offline — если экран цеха не в сети, never — нет).
ALTER TABLE workshops
    ADD COLUMN icon         text NOT NULL DEFAULT 'fire' CHECK (icon IN ('fire', 'bakery', 'bar', 'soup', 'grill', 'salad', 'pizza', 'cafe')),
    ADD COLUMN cook_minutes int  NOT NULL DEFAULT 15 CHECK (cook_minutes BETWEEN 1 AND 600),
    ADD COLUMN ticket_print text NOT NULL DEFAULT 'offline' CHECK (ticket_print IN ('always', 'offline', 'never'));

-- Выход порции для меню и чека («350 г», «5 шт»).
ALTER TABLE products ADD COLUMN portion text NOT NULL DEFAULT '' CHECK (length(portion) <= 30);

-- Продукт техкарты, который не учитываем на складе (вода): не списывается
-- и не входит в себестоимость.
ALTER TABLE recipe_items ADD COLUMN not_tracked boolean NOT NULL DEFAULT false;

-- Порция меньше («0,5 порции») может стоить дешевле: доплата варианта с
-- коэффициентом бывает отрицательной. Вариант «+ блюдо» (салат к плову)
-- списывает продукты этого блюда по его техкарте.
ALTER TABLE modifier_options DROP CONSTRAINT modifier_options_price_check;
ALTER TABLE modifier_options ADD CONSTRAINT modifier_options_price_check CHECK (price >= 0 OR action = 'factor');

-- Стоп-лист точки: блюдо закончилось — касса и приложение его не продают.
CREATE TABLE stop_list (
    store_id   uuid        NOT NULL REFERENCES stores (id) ON DELETE CASCADE,
    product_id uuid        NOT NULL REFERENCES products (id) ON DELETE CASCADE,
    created_by uuid        REFERENCES employees (id),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (store_id, product_id)
);

-- Производство: кто готовил и когда (П12).
ALTER TABLE production_docs
    ADD COLUMN cook_id     uuid        REFERENCES employees (id),
    ADD COLUMN produced_at timestamptz NOT NULL DEFAULT now();
