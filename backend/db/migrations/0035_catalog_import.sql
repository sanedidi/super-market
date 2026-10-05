-- Импорт товаров в общий каталог из национального каталога ИКПУ (tasnif.soliq.uz)
-- и очередь загрузки фото для них.

-- Очередь фото: одна строка на товар. Воркер берёт pending, спрашивает у
-- источника имена фото по коду (ref — ИКПУ), скачивает, уменьшает и кладёт
-- в хранилище. none — у источника фото нет, failed — не удалось после попыток.
CREATE TABLE product_photo_jobs (
    product_id uuid        PRIMARY KEY REFERENCES products (id) ON DELETE CASCADE,
    source     text        NOT NULL CHECK (source IN ('tasnif')),
    ref        text        NOT NULL CHECK (btrim(ref) <> ''),
    status     text        NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending', 'working', 'done', 'none', 'failed')),
    attempts   int         NOT NULL DEFAULT 0,
    photos     int         NOT NULL DEFAULT 0,
    error      text        NOT NULL DEFAULT '',
    next_at    timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX product_photo_jobs_queue ON product_photo_jobs (next_at) WHERE status = 'pending';

-- Поиск бренда и подкатегории по названию при импорте.
CREATE INDEX IF NOT EXISTS brands_lower_name ON brands (lower(name));
CREATE INDEX IF NOT EXISTS categories_parent_lower_name ON categories (parent_id, lower(name));
-- Фильтр «с фото / без фото» в списке товаров супер-админа.
CREATE INDEX IF NOT EXISTS products_without_images ON products ((cardinality(images) = 0)) WHERE network_id IS NULL;
