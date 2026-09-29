-- Этап приложения 1: витрина — акции, характеристики товаров, баннеры,
-- избранное, популярность, логотип и время доставки магазина.

-- Характеристики товара для карточки в приложении: пищевая ценность,
-- состав, срок и условия хранения, страна, объём. Произвольные ключи.
ALTER TABLE products
    ADD COLUMN attributes jsonb NOT NULL DEFAULT '{}'
        CHECK (jsonb_typeof(attributes) = 'object');

-- Логотип и обещанное время доставки («25–35 мин»).
ALTER TABLE stores
    ADD COLUMN logo_url text NOT NULL DEFAULT '',
    ADD COLUMN eta_min  int  CHECK (eta_min BETWEEN 5 AND 600),
    ADD COLUMN eta_max  int  CHECK (eta_max BETWEEN 5 AND 600),
    ADD CONSTRAINT stores_eta_order CHECK (eta_min IS NULL OR eta_max IS NULL OR eta_min <= eta_max);

-- Акции сети для приложения: на время действия товар продаётся онлайн по
-- акционной цене. store_ids пустой — во всех магазинах сети. Если у товара
-- несколько акций, берётся самая низкая цена; акция не повышает цену.
CREATE TABLE promotions (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id uuid        NOT NULL REFERENCES networks (id),
    name       text        NOT NULL CHECK (btrim(name) <> ''),
    starts_at  timestamptz NOT NULL,
    ends_at    timestamptz NOT NULL,
    store_ids  uuid[]      NOT NULL DEFAULT '{}',
    is_active  boolean     NOT NULL DEFAULT true,
    created_by uuid        REFERENCES users (id),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (ends_at > starts_at)
);
CREATE INDEX promotions_active_idx ON promotions (network_id, ends_at) WHERE is_active;

CREATE TABLE promotion_items (
    promotion_id uuid          NOT NULL REFERENCES promotions (id) ON DELETE CASCADE,
    product_id   uuid          NOT NULL REFERENCES products (id),
    price        numeric(14,2) NOT NULL CHECK (price > 0),
    PRIMARY KEY (promotion_id, product_id)
);
CREATE INDEX promotion_items_product_idx ON promotion_items (product_id);

-- Цена до скидки и скидка в заказе (для «Сэкономлено» и отчётов).
ALTER TABLE order_items ADD COLUMN regular_price numeric(18,2);
ALTER TABLE orders ADD COLUMN discount numeric(18,2) NOT NULL DEFAULT 0;

-- Баннеры на главной приложения. network_id пустой — баннер платформы,
-- иначе показывается рядом с магазинами этой сети.
CREATE TABLE banners (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    title      text        NOT NULL CHECK (btrim(title) <> ''),
    subtitle   text        NOT NULL DEFAULT '',
    image_url  text        NOT NULL DEFAULT '',
    color      text        NOT NULL DEFAULT '#155EEF' CHECK (color ~ '^#[0-9A-Fa-f]{6}$'),
    link_type  text        NOT NULL DEFAULT 'none'
        CHECK (link_type IN ('none', 'promotion', 'category', 'product', 'store')),
    link_id    uuid,
    network_id uuid        REFERENCES networks (id),
    starts_at  timestamptz,
    ends_at    timestamptz,
    sort       int         NOT NULL DEFAULT 0,
    is_active  boolean     NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (link_type = 'none' OR link_id IS NOT NULL),
    CHECK (starts_at IS NULL OR ends_at IS NULL OR ends_at > starts_at)
);

-- Избранные товары покупателя.
CREATE TABLE favorites (
    user_id    uuid        NOT NULL REFERENCES users (id),
    product_id uuid        NOT NULL REFERENCES products (id),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, product_id)
);

-- Популярность товара в магазине за 30 дней (кассовые продажи и онлайн-заказы).
-- Пересчитывает воркер раз в час; нужна для сортировки «популярные» и «хитов».
CREATE TABLE product_popularity (
    store_id   uuid          NOT NULL REFERENCES stores (id) ON DELETE CASCADE,
    product_id uuid          NOT NULL REFERENCES products (id),
    qty        numeric(18,3) NOT NULL,
    purchases  int           NOT NULL,
    updated_at timestamptz   NOT NULL DEFAULT now(),
    PRIMARY KEY (store_id, product_id)
);
