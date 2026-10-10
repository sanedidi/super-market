-- Вариации товара: группа (бренд + линейка, например «Чипсы Lay's») →
-- вес → вкус. Каждая вариация — обычный товар со своим штрихкодом, фото,
-- ИКПУ и остатком; группа только связывает их для карточки в приложении,
-- кассы и панели магазина.
--
-- Группы предлагает Super Market (ИИ или разбор названий) по уже
-- добавленным товарам, супер-админ проверяет и подтверждает. Пока группа
-- не подтверждена, товары живут отдельно (variant_group_items — черновик
-- предложения); после подтверждения связь пишется в сам товар.

CREATE TABLE variant_groups (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text        NOT NULL CHECK (btrim(name) <> ''),
    name_uz     text        NOT NULL DEFAULT '',
    brand_id    uuid        REFERENCES brands (id),
    category_id uuid        REFERENCES categories (id),
    status      text        NOT NULL DEFAULT 'proposed' CHECK (status IN ('proposed', 'confirmed', 'rejected')),
    -- ai — предложил Super Market, manual — собрал супер-админ.
    source      text        NOT NULL DEFAULT 'ai' CHECK (source IN ('ai', 'manual')),
    -- high — уверенное предложение, check — «проверьте вкусы».
    confidence  text        NOT NULL DEFAULT 'high' CHECK (confidence IN ('high', 'check')),
    note        text        NOT NULL DEFAULT '',
    decided_at  timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX variant_groups_status_idx ON variant_groups (status, created_at DESC);
CREATE TRIGGER variant_groups_updated_at BEFORE UPDATE ON variant_groups FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Товары предложения: вес и вкус, которые Super Market взял из названия
-- (супер-админ может поправить), и галочка «входит в группу».
CREATE TABLE variant_group_items (
    group_id    uuid    NOT NULL REFERENCES variant_groups (id) ON DELETE CASCADE,
    product_id  uuid    NOT NULL REFERENCES products (id) ON DELETE CASCADE,
    weight      text    NOT NULL DEFAULT '' CHECK (length(weight) <= 40),
    weight_uz   text    NOT NULL DEFAULT '' CHECK (length(weight_uz) <= 40),
    -- Вес в граммах (миллилитрах, штуках) — для порядка «90 г, 150 г, 1 кг».
    weight_sort numeric NOT NULL DEFAULT 0,
    flavor      text    NOT NULL DEFAULT '' CHECK (length(flavor) <= 80),
    flavor_uz   text    NOT NULL DEFAULT '' CHECK (length(flavor_uz) <= 80),
    included    boolean NOT NULL DEFAULT true,
    -- Почему товар не вошёл: «Другая линейка (MAXX) — отдельная группа».
    note        text    NOT NULL DEFAULT '',
    sort        int     NOT NULL DEFAULT 0,
    PRIMARY KEY (group_id, product_id)
);
CREATE INDEX variant_group_items_product_idx ON variant_group_items (product_id);

-- Подтверждённая группа — в самом товаре. Обновление строки товара двигает
-- updated_at, и касса получает изменения обычной синхронизацией каталога.
ALTER TABLE products
    ADD COLUMN variant_group_id    uuid    REFERENCES variant_groups (id) ON DELETE SET NULL,
    ADD COLUMN variant_weight      text    NOT NULL DEFAULT '',
    ADD COLUMN variant_weight_uz   text    NOT NULL DEFAULT '',
    ADD COLUMN variant_weight_sort numeric NOT NULL DEFAULT 0,
    ADD COLUMN variant_flavor      text    NOT NULL DEFAULT '',
    ADD COLUMN variant_flavor_uz   text    NOT NULL DEFAULT '',
    ADD COLUMN variant_sort        int     NOT NULL DEFAULT 0;
CREATE INDEX products_variant_group_idx ON products (variant_group_id) WHERE variant_group_id IS NOT NULL;

-- «Своя цена» вкуса в магазине: цена веса, которую магазин ставит на всю
-- группу, этот товар не меняет.
CREATE TABLE variant_own_prices (
    store_id   uuid        NOT NULL REFERENCES stores (id) ON DELETE CASCADE,
    product_id uuid        NOT NULL REFERENCES products (id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (store_id, product_id)
);

-- Расход ИИ на подбор групп.
ALTER TABLE ai_usage DROP CONSTRAINT IF EXISTS ai_usage_kind_check;
ALTER TABLE ai_usage ADD CONSTRAINT ai_usage_kind_check
    CHECK (kind IN ('invoice', 'test', 'shelf', 'translate', 'category', 'product', 'variants'));
