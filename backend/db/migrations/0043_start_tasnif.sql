-- «Начало работы»: товар, которого нет в центральной базе, магазин находит в
-- каталоге ИКПУ (tasnif.soliq.uz) и добавляет — он создаётся в общем каталоге.

-- Строка «Моих товаров», добавленная из каталога ИКПУ.
ALTER TABLE start_lines DROP CONSTRAINT IF EXISTS start_lines_source_check;
ALTER TABLE start_lines ADD CONSTRAINT start_lines_source_check
    CHECK (source IN ('photo', 'barcode', 'catalog', 'search', 'new', 'manual', 'tasnif'));

-- Подбор категории Super Market для товара из каталога ИКПУ.
ALTER TABLE ai_usage DROP CONSTRAINT IF EXISTS ai_usage_kind_check;
ALTER TABLE ai_usage ADD CONSTRAINT ai_usage_kind_check CHECK (kind IN ('invoice', 'test', 'shelf', 'translate', 'category'));

-- Категория по коду ИКПУ: ищем товары общего каталога с тем же началом кода.
CREATE INDEX IF NOT EXISTS products_attr_ikpu_idx ON products ((attributes ->> 'ikpu') text_pattern_ops)
    WHERE network_id IS NULL AND attributes ? 'ikpu';
