-- Кафе и рестораны, этап 1 (план «Кафе и рестораны: план реализации»,
-- Figma «Super Market · Кафе и рестораны»): тип бизнеса сети, блюда и
-- заготовки, группы меню, цеха, техкарты, модификаторы, производство
-- заготовок и «минус» продуктов, который закрывает следующий приход.
--
-- Блюдо и заготовка — это обычные товары сети (products) с kind = dish/prep:
-- касса, цены, ИКПУ, фото и продажи работают с ними как с товаром. Блюдо не
-- лежит на складе — при продаже списываются продукты по техкарте. Заготовка
-- лежит на складе партиями: её делает документ «Производство».

------------------------------------------------------------- тип бизнеса

-- store — магазин (как раньше), cafe — кафе / ресторан. Меняет только супер-админ.
ALTER TABLE networks
    ADD COLUMN business_type   text         NOT NULL DEFAULT 'store' CHECK (business_type IN ('store', 'cafe')),
    -- Как работает кафе: у прилавка, со столами или и так и так.
    ADD COLUMN cafe_mode       text         NOT NULL DEFAULT 'counter' CHECK (cafe_mode IN ('counter', 'tables', 'both')),
    -- Обслуживание, % — только для счетов столов (этап 5).
    ADD COLUMN service_percent numeric(5,2) NOT NULL DEFAULT 0 CHECK (service_percent >= 0 AND service_percent <= 30);

------------------------------------------------------------------- цеха

-- Цех — куда уходит блюдо готовиться: «Кухня», «Гриль», «Бар». У нового
-- кафе сразу есть цех «Кухня» (is_default) — туда попадает всё, что не
-- разнесено по другим цехам.
CREATE TABLE workshops (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id uuid        NOT NULL REFERENCES networks (id),
    name       text        NOT NULL CHECK (btrim(name) <> '' AND length(name) <= 60),
    name_uz    text        NOT NULL DEFAULT '' CHECK (length(name_uz) <= 60),
    sort       int         NOT NULL DEFAULT 0,
    is_default boolean     NOT NULL DEFAULT false,
    is_active  boolean     NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, network_id)
);
CREATE UNIQUE INDEX workshops_name_key ON workshops (network_id, lower(name));
CREATE UNIQUE INDEX workshops_default_key ON workshops (network_id) WHERE is_default;
CREATE TRIGGER workshops_updated_at BEFORE UPDATE ON workshops FOR EACH ROW EXECUTE FUNCTION set_updated_at();

------------------------------------------------------------ группы меню

-- «Плов и вторые», «Супы», «Напитки». Цех группы — по умолчанию для её блюд.
CREATE TABLE menu_groups (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id  uuid        NOT NULL REFERENCES networks (id),
    name        text        NOT NULL CHECK (btrim(name) <> '' AND length(name) <= 60),
    name_uz     text        NOT NULL DEFAULT '' CHECK (length(name_uz) <= 60),
    color       text        NOT NULL DEFAULT '' CHECK (color = '' OR color ~ '^#[0-9a-fA-F]{6}$'),
    sort        int         NOT NULL DEFAULT 0,
    workshop_id uuid        REFERENCES workshops (id),
    is_active   boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX menu_groups_name_key ON menu_groups (network_id, lower(name));
CREATE TRIGGER menu_groups_updated_at BEFORE UPDATE ON menu_groups FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-------------------------------------------------------- блюда, заготовки

-- Служебная категория общего каталога для блюд и заготовок (у товара
-- категория обязательна). Не активна — в приложении и фильтрах её нет.
INSERT INTO categories (id, name, name_uz, is_active)
VALUES ('00000000-0000-0000-0000-0000000caf01', 'Блюда и заготовки кафе', 'Kafe taomlari va yarim tayyor mahsulotlari', false)
ON CONFLICT (id) DO NOTHING;

-- Единица блюда — порция.
INSERT INTO units (name, short_name, is_fractional, name_uz, short_name_uz)
SELECT 'Порция', 'порц', false, 'Porsiya', 'porsiya'
WHERE NOT EXISTS (SELECT 1 FROM units WHERE lower(name) = 'порция');

ALTER TABLE products
    -- goods — товар (как раньше), dish — блюдо, prep — заготовка.
    ADD COLUMN kind          text          NOT NULL DEFAULT 'goods' CHECK (kind IN ('goods', 'dish', 'prep')),
    -- Код блюда для поиска на кассе («12» → плов).
    ADD COLUMN menu_code     int           CHECK (menu_code BETWEEN 1 AND 99999),
    ADD COLUMN menu_group_id uuid          REFERENCES menu_groups (id),
    -- Свой цех блюда; NULL — цех группы меню, иначе цех «Кухня».
    ADD COLUMN workshop_id   uuid          REFERENCES workshops (id),
    -- Норма приготовления, мин (таймер на экране кухни).
    ADD COLUMN cook_minutes  int           CHECK (cook_minutes BETWEEN 1 AND 600),
    -- Срок годности заготовки, часов.
    ADD COLUMN shelf_hours   int           CHECK (shelf_hours BETWEEN 1 AND 8760),
    -- Выход техкарты: на сколько единиц блюда / заготовки рассчитаны продукты
    -- (техкарта теста — на 5 кг, плова — на 1 порцию).
    ADD COLUMN yield_qty     numeric(14,3) NOT NULL DEFAULT 1 CHECK (yield_qty > 0),
    -- Блюдо и заготовка — всегда товар своей сети (не уходят в общий каталог).
    ADD CONSTRAINT products_kind_network CHECK (kind = 'goods' OR network_id IS NOT NULL);
CREATE UNIQUE INDEX products_menu_code_key ON products (network_id, menu_code) WHERE menu_code IS NOT NULL;
CREATE INDEX products_kind_idx ON products (network_id, kind) WHERE kind <> 'goods';

----------------------------------------------------------------- техкарты

-- Техкарта блюда или заготовки: сколько продукта (товар или заготовка) идёт
-- на yield_qty единиц. Количество — в единицах продукта (кг, л, шт).
CREATE TABLE recipe_items (
    product_id    uuid          NOT NULL REFERENCES products (id) ON DELETE CASCADE,
    line          int           NOT NULL CHECK (line > 0),
    ingredient_id uuid          NOT NULL REFERENCES products (id),
    qty           numeric(14,4) NOT NULL CHECK (qty > 0),
    PRIMARY KEY (product_id, line),
    UNIQUE (product_id, ingredient_id),
    CHECK (ingredient_id <> product_id)
);
CREATE INDEX recipe_items_ingredient_idx ON recipe_items (ingredient_id);

------------------------------------------------------------ модификаторы

-- Группа модификаторов: «Размер» (выбрать 1, обязательно), «Добавить»,
-- «Убрать». min_select > 0 — обязательная группа; max_select 0 — без предела.
CREATE TABLE modifier_groups (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id uuid        NOT NULL REFERENCES networks (id),
    name       text        NOT NULL CHECK (btrim(name) <> '' AND length(name) <= 60),
    name_uz    text        NOT NULL DEFAULT '' CHECK (length(name_uz) <= 60),
    min_select int         NOT NULL DEFAULT 0 CHECK (min_select BETWEEN 0 AND 20),
    max_select int         NOT NULL DEFAULT 0 CHECK (max_select BETWEEN 0 AND 20),
    sort       int         NOT NULL DEFAULT 0,
    is_active  boolean     NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (max_select = 0 OR max_select >= min_select)
);
CREATE UNIQUE INDEX modifier_groups_name_key ON modifier_groups (network_id, lower(name));
CREATE TRIGGER modifier_groups_updated_at BEFORE UPDATE ON modifier_groups FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Вариант модификатора. Что он делает со складом:
--   add    — «+ сыр»: дополнительно списать qty продукта product_id;
--   remove — «без лука»: не списывать продукт product_id из техкарты;
--   factor — «0,5 порции»: умножить всю техкарту на factor;
--   none   — только для кухни («острее»), склад не трогает.
CREATE TABLE modifier_options (
    id         uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id   uuid          NOT NULL REFERENCES modifier_groups (id) ON DELETE CASCADE,
    name       text          NOT NULL CHECK (btrim(name) <> '' AND length(name) <= 60),
    name_uz    text          NOT NULL DEFAULT '' CHECK (length(name_uz) <= 60),
    -- Доплата к цене блюда (может быть 0).
    price      numeric(14,2) NOT NULL DEFAULT 0 CHECK (price >= 0),
    action     text          NOT NULL DEFAULT 'none' CHECK (action IN ('none', 'add', 'remove', 'factor')),
    product_id uuid          REFERENCES products (id),
    qty        numeric(14,4) CHECK (qty > 0),
    factor     numeric(6,3)  CHECK (factor > 0 AND factor <= 10),
    sort       int           NOT NULL DEFAULT 0,
    is_active  boolean       NOT NULL DEFAULT true,
    created_at timestamptz   NOT NULL DEFAULT now(),
    updated_at timestamptz   NOT NULL DEFAULT now(),
    CHECK (CASE action
             WHEN 'add'    THEN product_id IS NOT NULL AND qty IS NOT NULL AND factor IS NULL
             WHEN 'remove' THEN product_id IS NOT NULL AND qty IS NULL AND factor IS NULL
             WHEN 'factor' THEN product_id IS NULL AND qty IS NULL AND factor IS NOT NULL
             ELSE product_id IS NULL AND qty IS NULL AND factor IS NULL END)
);
CREATE INDEX modifier_options_group_idx ON modifier_options (group_id);
CREATE TRIGGER modifier_options_updated_at BEFORE UPDATE ON modifier_options FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Какие группы модификаторов есть у блюда.
CREATE TABLE product_modifier_groups (
    product_id uuid NOT NULL REFERENCES products (id) ON DELETE CASCADE,
    group_id   uuid NOT NULL REFERENCES modifier_groups (id) ON DELETE CASCADE,
    sort       int  NOT NULL DEFAULT 0,
    PRIMARY KEY (product_id, group_id)
);
CREATE INDEX product_modifier_groups_group_idx ON product_modifier_groups (group_id);

----------------------------------------------------------------- продажа

-- Модификаторы строки чека (цена — на момент продажи).
CREATE TABLE sale_item_modifiers (
    sale_id   uuid          NOT NULL,
    line      int           NOT NULL,
    option_id uuid          NOT NULL REFERENCES modifier_options (id),
    name      text          NOT NULL,
    qty       int           NOT NULL DEFAULT 1 CHECK (qty BETWEEN 1 AND 20),
    price     numeric(14,2) NOT NULL DEFAULT 0,
    PRIMARY KEY (sale_id, line, option_id),
    FOREIGN KEY (sale_id, line) REFERENCES sale_items (sale_id, line)
);

-- Что списано по техкарте за строку с блюдом: продукт, сколько нужно было,
-- сколько не хватило и себестоимость (уточняется, когда «минус» закрывает
-- приход). Партии — в sale_item_batches той же строки.
CREATE TABLE sale_item_ingredients (
    sale_id       uuid          NOT NULL,
    line          int           NOT NULL,
    ingredient_id uuid          NOT NULL REFERENCES products (id),
    qty           numeric(14,3) NOT NULL CHECK (qty > 0),
    short_qty     numeric(14,3) NOT NULL DEFAULT 0 CHECK (short_qty >= 0),
    cost          numeric(18,2) NOT NULL DEFAULT 0,
    PRIMARY KEY (sale_id, line, ingredient_id),
    FOREIGN KEY (sale_id, line) REFERENCES sale_items (sale_id, line)
);
CREATE INDEX sale_item_ingredients_ingredient_idx ON sale_item_ingredients (ingredient_id);

-------------------------------------------------------- «минус» продуктов

-- Кафе продаёт блюдо, даже если продуктов по учёту не хватило (их просто не
-- оприходовали). Недостача ждёт здесь, пока приход или производство не
-- досписет её из новой партии; инвентаризация закрывает её без списания
-- (посчитан фактический остаток).
CREATE TABLE stock_shortfalls (
    id           bigserial     PRIMARY KEY,
    network_id   uuid          NOT NULL REFERENCES networks (id),
    warehouse_id uuid          NOT NULL REFERENCES warehouses (id),
    product_id   uuid          NOT NULL REFERENCES products (id),
    qty          numeric(14,3) NOT NULL CHECK (qty > 0),
    qty_closed   numeric(14,3) NOT NULL DEFAULT 0 CHECK (qty_closed >= 0 AND qty_closed <= qty),
    -- Документ, в котором не хватило: продажа (с номером строки) или производство.
    doc_type     text          NOT NULL,
    doc_id       uuid          NOT NULL,
    sale_line    int,
    -- Себестоимость досписанного (из приходов).
    closed_cost  numeric(18,2) NOT NULL DEFAULT 0,
    created_at   timestamptz   NOT NULL DEFAULT now(),
    closed_at    timestamptz,
    -- stock — досписано из прихода, inventory — закрыто инвентаризацией.
    closed_by    text          CHECK (closed_by IN ('stock', 'inventory'))
);
CREATE INDEX stock_shortfalls_open_idx ON stock_shortfalls (warehouse_id, product_id, created_at, id) WHERE closed_at IS NULL;
CREATE INDEX stock_shortfalls_doc_idx ON stock_shortfalls (doc_id);

----------------------------------------------------------- производство

-- «Произвести»: списать продукты по техкарте заготовки и положить на склад
-- партию заготовки по их себестоимости (со сроком годности).
CREATE TABLE production_docs (
    id           uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id   uuid          NOT NULL REFERENCES networks (id),
    number       bigint        NOT NULL,
    store_id     uuid          NOT NULL REFERENCES stores (id),
    warehouse_id uuid          NOT NULL REFERENCES warehouses (id),
    product_id   uuid          NOT NULL REFERENCES products (id),
    qty          numeric(14,3) NOT NULL CHECK (qty > 0),
    cost         numeric(18,2) NOT NULL DEFAULT 0,
    expires_at   timestamptz,
    note         text          NOT NULL DEFAULT '' CHECK (length(note) <= 500),
    -- Повтор с экрана кухни без интернета не создаёт второй документ.
    client_uid   text          CHECK (client_uid IS NULL OR length(client_uid) BETWEEN 8 AND 64),
    created_by   uuid          NOT NULL REFERENCES employees (id),
    created_at   timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (network_id, number),
    UNIQUE (network_id, client_uid)
);
CREATE INDEX production_docs_store_idx ON production_docs (store_id, created_at DESC);

CREATE TABLE production_doc_items (
    doc_id        uuid          NOT NULL REFERENCES production_docs (id),
    ingredient_id uuid          NOT NULL REFERENCES products (id),
    qty           numeric(14,3) NOT NULL CHECK (qty > 0),
    short_qty     numeric(14,3) NOT NULL DEFAULT 0 CHECK (short_qty >= 0),
    cost          numeric(18,2) NOT NULL DEFAULT 0,
    PRIMARY KEY (doc_id, ingredient_id)
);

-- Срок годности партии (заготовки).
ALTER TABLE batches ADD COLUMN expires_at timestamptz;
