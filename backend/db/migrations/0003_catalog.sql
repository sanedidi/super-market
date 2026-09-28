-- Этап 2: справочники, товары с модерацией, типы цен и установка цен.
-- Деньги — numeric(14,2) в сумах.

------------------------------------------------------------- справочники
-- Бренды, категории, цвета и единицы измерения — общие для всей платформы,
-- их ведёт супер-админ. Записи не удаляются, а отключаются (is_active).

CREATE TABLE brands (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    name       text        NOT NULL CHECK (btrim(name) <> ''),
    is_active  boolean     NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX brands_name_key ON brands (lower(name));
CREATE TRIGGER brands_updated_at BEFORE UPDATE ON brands FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE categories (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    parent_id  uuid        REFERENCES categories (id),
    name       text        NOT NULL CHECK (btrim(name) <> ''),
    sort       int         NOT NULL DEFAULT 0,
    is_active  boolean     NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (parent_id IS DISTINCT FROM id)
);
CREATE UNIQUE INDEX categories_name_key ON categories (COALESCE(parent_id, '00000000-0000-0000-0000-000000000000'), lower(name));
CREATE TRIGGER categories_updated_at BEFORE UPDATE ON categories FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE colors (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    name       text        NOT NULL CHECK (btrim(name) <> ''),
    hex        text        NOT NULL DEFAULT '' CHECK (hex = '' OR hex ~ '^#[0-9A-Fa-f]{6}$'),
    is_active  boolean     NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX colors_name_key ON colors (lower(name));
CREATE TRIGGER colors_updated_at BEFORE UPDATE ON colors FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE units (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    name          text        NOT NULL CHECK (btrim(name) <> ''),
    short_name    text        NOT NULL CHECK (btrim(short_name) <> ''),
    -- true — товар продаётся дробным количеством (кг, л).
    is_fractional boolean     NOT NULL DEFAULT false,
    is_active     boolean     NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX units_name_key ON units (lower(name));
CREATE TRIGGER units_updated_at BEFORE UPDATE ON units FOR EACH ROW EXECUTE FUNCTION set_updated_at();

INSERT INTO units (name, short_name, is_fractional) VALUES
    ('Штука', 'шт', false),
    ('Килограмм', 'кг', true),
    ('Литр', 'л', true),
    ('Упаковка', 'уп', false);

------------------------------------------------------------------ товары

CREATE TABLE products (
    id                uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    -- NULL — товар общего каталога; иначе — товар сети, ещё не одобренный
    -- супер-админом. После одобрения товар становится общим (NULL).
    network_id        uuid          REFERENCES networks (id),
    -- Какая сеть предложила товар (для истории модерации).
    proposed_by       uuid          REFERENCES networks (id),
    name              text          NOT NULL CHECK (btrim(name) <> ''),
    description       text          NOT NULL DEFAULT '',
    brand_id          uuid          REFERENCES brands (id),
    category_id       uuid          NOT NULL REFERENCES categories (id),
    unit_id           uuid          NOT NULL REFERENCES units (id),
    color_id          uuid          REFERENCES colors (id),
    -- Базовая цена продажи из общего каталога.
    base_price        numeric(14,2) NOT NULL DEFAULT 0 CHECK (base_price >= 0),
    images            text[]        NOT NULL DEFAULT '{}',
    moderation_status text          NOT NULL DEFAULT 'approved'
                      CHECK (moderation_status IN ('pending', 'approved', 'rejected')),
    rejection_reason  text          NOT NULL DEFAULT '',
    is_active         boolean       NOT NULL DEFAULT true,
    created_at        timestamptz   NOT NULL DEFAULT now(),
    updated_at        timestamptz   NOT NULL DEFAULT now(),
    -- Общий товар всегда одобрен.
    CHECK (network_id IS NOT NULL OR moderation_status = 'approved')
);
CREATE INDEX products_network_idx ON products (network_id);
CREATE INDEX products_category_idx ON products (category_id);
CREATE INDEX products_moderation_idx ON products (moderation_status) WHERE moderation_status = 'pending';
CREATE INDEX products_name_idx ON products (lower(name) text_pattern_ops);
CREATE TRIGGER products_updated_at BEFORE UPDATE ON products FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Штрихкод уникален на всю платформу: один товар — одна карточка.
CREATE TABLE product_barcodes (
    barcode    text PRIMARY KEY CHECK (barcode ~ '^[0-9A-Za-z-]{4,32}$'),
    product_id uuid NOT NULL REFERENCES products (id) ON DELETE CASCADE
);
CREATE INDEX product_barcodes_product_idx ON product_barcodes (product_id);

------------------------------------------------------------------- цены

CREATE TABLE price_types (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id uuid        NOT NULL REFERENCES networks (id),
    name       text        NOT NULL CHECK (btrim(name) <> ''),
    -- Тип по умолчанию: его цены видит приложение, если магазин не выбрал другой.
    is_default boolean     NOT NULL DEFAULT false,
    is_active  boolean     NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (network_id, name),
    UNIQUE (id, network_id)
);
CREATE UNIQUE INDEX price_types_one_default ON price_types (network_id) WHERE is_default;
CREATE TRIGGER price_types_updated_at BEFORE UPDATE ON price_types FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Каждой существующей сети — тип «Розничная».
INSERT INTO price_types (network_id, name, is_default)
SELECT id, 'Розничная', true FROM networks;

-- Какой тип цены магазин показывает в приложении. NULL — тип по умолчанию.
ALTER TABLE stores ADD COLUMN online_price_type_id uuid;
ALTER TABLE stores ADD CONSTRAINT stores_online_price_type_fk
    FOREIGN KEY (online_price_type_id, network_id) REFERENCES price_types (id, network_id);

-- Текущие цены. store_id NULL — цена всей сети, иначе — цена магазина.
-- Итоговая цена: магазина → сети → base_price товара.
CREATE TABLE prices (
    id            uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id    uuid          NOT NULL,
    price_type_id uuid          NOT NULL,
    store_id      uuid,
    product_id    uuid          NOT NULL REFERENCES products (id),
    price         numeric(14,2) NOT NULL CHECK (price >= 0),
    updated_at    timestamptz   NOT NULL DEFAULT now(),
    FOREIGN KEY (price_type_id, network_id) REFERENCES price_types (id, network_id),
    FOREIGN KEY (store_id, network_id) REFERENCES stores (id, network_id)
);
CREATE UNIQUE INDEX prices_network_level ON prices (price_type_id, product_id) WHERE store_id IS NULL;
CREATE UNIQUE INDEX prices_store_level ON prices (price_type_id, store_id, product_id) WHERE store_id IS NOT NULL;

-- Документ «Установка цен». Меняет цены только при проведении.
CREATE TABLE price_documents (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id    uuid        NOT NULL,
    number        bigint      NOT NULL,
    price_type_id uuid        NOT NULL,
    store_id      uuid,
    status        text        NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'posted')),
    note          text        NOT NULL DEFAULT '',
    created_by    uuid        NOT NULL REFERENCES employees (id),
    posted_by     uuid        REFERENCES employees (id),
    posted_at     timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (network_id, number),
    FOREIGN KEY (price_type_id, network_id) REFERENCES price_types (id, network_id),
    FOREIGN KEY (store_id, network_id) REFERENCES stores (id, network_id)
);
CREATE TRIGGER price_documents_updated_at BEFORE UPDATE ON price_documents FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE price_document_items (
    document_id    uuid          NOT NULL REFERENCES price_documents (id) ON DELETE CASCADE,
    product_id     uuid          NOT NULL REFERENCES products (id),
    new_price      numeric(14,2) NOT NULL CHECK (new_price >= 0),
    -- Цена на этом уровне до проведения (NULL — своей цены не было).
    previous_price numeric(14,2),
    PRIMARY KEY (document_id, product_id)
);
