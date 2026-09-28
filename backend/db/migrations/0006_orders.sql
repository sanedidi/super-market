-- Этап 5: доставка, адреса покупателей, онлайн-заказы, резерв товара,
-- онлайн-оплата (Payme, Click), баланс сетей на платформе.

--------------------------------------------------------------- доставка

ALTER TABLE stores
    ADD COLUMN accepts_online    boolean       NOT NULL DEFAULT false,
    ADD COLUMN min_order_amount  numeric(18,2) NOT NULL DEFAULT 0 CHECK (min_order_amount >= 0),
    -- Радиус доставки, если у магазина нет зон. 0 — не доставляет.
    ADD COLUMN delivery_radius_m int           NOT NULL DEFAULT 3000 CHECK (delivery_radius_m >= 0);

-- Часы работы: день недели 0 (вс) … 6 (сб), время по Ташкенту.
-- Нет записей — магазин принимает заказы круглосуточно.
CREATE TABLE store_working_hours (
    store_id uuid     NOT NULL REFERENCES stores (id) ON DELETE CASCADE,
    weekday  smallint NOT NULL CHECK (weekday BETWEEN 0 AND 6),
    opens    time     NOT NULL,
    closes   time     NOT NULL,
    PRIMARY KEY (store_id, weekday)
);

CREATE TABLE delivery_zones (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id uuid        NOT NULL,
    store_id   uuid        NOT NULL,
    name       text        NOT NULL CHECK (btrim(name) <> ''),
    area       geography(Polygon, 4326) NOT NULL,
    -- Цена доставки в этой зоне (для правила zone).
    price      numeric(18,2) NOT NULL DEFAULT 0 CHECK (price >= 0),
    is_active  boolean     NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (store_id, network_id) REFERENCES stores (id, network_id)
);
CREATE INDEX delivery_zones_area_idx ON delivery_zones USING gist (area);

-- Правила стоимости доставки. Применяются по порядку sort:
--   fixed     {"price": 10000}
--   distance  {"base": 5000, "per_km": 2000}
--   zone      {} — цена берётся из зоны, в которую попал адрес
--   free_from {"amount": 200000} — бесплатно от суммы товаров
CREATE TABLE delivery_rules (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id uuid        NOT NULL,
    store_id   uuid        NOT NULL,
    type       text        NOT NULL CHECK (type IN ('fixed', 'distance', 'zone', 'free_from')),
    params     jsonb       NOT NULL DEFAULT '{}',
    sort       int         NOT NULL DEFAULT 0,
    FOREIGN KEY (store_id, network_id) REFERENCES stores (id, network_id)
);
CREATE INDEX delivery_rules_store_idx ON delivery_rules (store_id, sort);

------------------------------------------------------ адреса покупателей

CREATE TABLE customer_addresses (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid        NOT NULL REFERENCES users (id),
    label      text        NOT NULL DEFAULT '',
    address    text        NOT NULL CHECK (btrim(address) <> ''),
    entrance   text        NOT NULL DEFAULT '',
    floor      text        NOT NULL DEFAULT '',
    apartment  text        NOT NULL DEFAULT '',
    comment    text        NOT NULL DEFAULT '',
    location   geography(Point, 4326) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX customer_addresses_user_idx ON customer_addresses (user_id);

------------------------------------------------------------------ заказы

CREATE TABLE orders (
    id                uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id        uuid          NOT NULL,
    store_id          uuid          NOT NULL,
    warehouse_id      uuid          NOT NULL REFERENCES warehouses (id),
    number            bigint        NOT NULL,
    customer_id       uuid          NOT NULL REFERENCES users (id),
    status            text          NOT NULL CHECK (status IN (
                          'awaiting_payment', 'paid', 'accepted', 'picking', 'picked',
                          'delivering', 'delivered', 'cancelled', 'expired')),
    price_type_id     uuid          NOT NULL,
    subtotal          numeric(18,2) NOT NULL,
    delivery_fee      numeric(18,2) NOT NULL,
    total             numeric(18,2) NOT NULL,
    cost              numeric(18,2) NOT NULL DEFAULT 0,
    -- Адрес копируется в заказ: правка адреса в профиле не меняет заказ.
    address           text          NOT NULL,
    entrance          text          NOT NULL DEFAULT '',
    floor             text          NOT NULL DEFAULT '',
    apartment         text          NOT NULL DEFAULT '',
    address_comment   text          NOT NULL DEFAULT '',
    location          geography(Point, 4326) NOT NULL,
    distance_m        int           NOT NULL,
    customer_phone    text          NOT NULL,
    comment           text          NOT NULL DEFAULT '',
    payment_provider  text          NOT NULL CHECK (payment_provider IN ('payme', 'click')),
    paid_at           timestamptz,
    accepted_at       timestamptz,
    picked_at         timestamptz,
    delivered_at      timestamptz,
    cancelled_at      timestamptz,
    cancel_reason     text          NOT NULL DEFAULT '',
    -- Когда супер-админу ушло уведомление «заказ не принят за 10 минут».
    alerted_at        timestamptz,
    fiscal_status     text          NOT NULL DEFAULT 'pending' CHECK (fiscal_status IN ('pending', 'registered')),
    fiscal_number     text          NOT NULL DEFAULT '',
    fiscal_sign       text          NOT NULL DEFAULT '',
    fiscal_at         timestamptz,
    created_at        timestamptz   NOT NULL DEFAULT now(),
    updated_at        timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (network_id, number),
    FOREIGN KEY (store_id, network_id) REFERENCES stores (id, network_id)
);
CREATE INDEX orders_store_status_idx ON orders (store_id, status, created_at DESC);
CREATE INDEX orders_customer_idx ON orders (customer_id, created_at DESC);
CREATE INDEX orders_paid_not_accepted_idx ON orders (paid_at) WHERE status = 'paid';
CREATE INDEX orders_awaiting_idx ON orders (created_at) WHERE status = 'awaiting_payment';
CREATE TRIGGER orders_updated_at BEFORE UPDATE ON orders FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE order_items (
    order_id             uuid          NOT NULL REFERENCES orders (id),
    line                 int           NOT NULL,
    product_id           uuid          NOT NULL REFERENCES products (id),
    qty                  numeric(14,3) NOT NULL CHECK (qty > 0),
    price                numeric(18,2) NOT NULL,
    total                numeric(18,2) NOT NULL,
    -- С какого склада фактически собран товар и отличается ли он от склада по умолчанию.
    picked_warehouse_id  uuid          REFERENCES warehouses (id),
    from_other_warehouse boolean       NOT NULL DEFAULT false,
    cost                 numeric(18,2),
    PRIMARY KEY (order_id, line)
);

CREATE TABLE order_status_history (
    id         bigserial   PRIMARY KEY,
    order_id   uuid        NOT NULL REFERENCES orders (id),
    status     text        NOT NULL,
    actor      text        NOT NULL,
    note       text        NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX order_status_history_order_idx ON order_status_history (order_id, id);

-- Резерв товара под заказ до сборки. Доступный остаток = остаток − резервы.
CREATE TABLE stock_reservations (
    order_id     uuid          NOT NULL REFERENCES orders (id),
    warehouse_id uuid          NOT NULL REFERENCES warehouses (id),
    product_id   uuid          NOT NULL REFERENCES products (id),
    qty          numeric(14,3) NOT NULL CHECK (qty > 0),
    PRIMARY KEY (order_id, product_id)
);
CREATE INDEX stock_reservations_wp_idx ON stock_reservations (warehouse_id, product_id);

------------------------------------------------------------------- оплата

CREATE TABLE payments (
    id           uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Числовой номер платежа (Click требует целый merchant_prepare_id).
    seq          bigserial     NOT NULL UNIQUE,
    order_id     uuid          NOT NULL REFERENCES orders (id),
    provider     text          NOT NULL CHECK (provider IN ('payme', 'click')),
    amount       numeric(18,2) NOT NULL CHECK (amount > 0),
    -- created → paid → (refund_pending →) refunded; created → cancelled.
    status       text          NOT NULL DEFAULT 'created'
                 CHECK (status IN ('created', 'paid', 'cancelled', 'refund_pending', 'refunded')),
    -- Идентификатор транзакции у провайдера.
    external_id  text,
    -- Данные провайдера (время создания у Payme, prepare id у Click и т. п.).
    provider_data jsonb        NOT NULL DEFAULT '{}',
    paid_at      timestamptz,
    cancelled_at timestamptz,
    refunded_at  timestamptz,
    cancel_reason int,
    created_at   timestamptz   NOT NULL DEFAULT now(),
    updated_at   timestamptz   NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX payments_external_key ON payments (provider, external_id) WHERE external_id IS NOT NULL;
CREATE INDEX payments_order_idx ON payments (order_id);
CREATE TRIGGER payments_updated_at BEFORE UPDATE ON payments FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Сырые запросы провайдеров — для разбора спорных случаев.
CREATE TABLE payment_events (
    id         bigserial   PRIMARY KEY,
    provider   text        NOT NULL,
    method     text        NOT NULL,
    request    jsonb       NOT NULL,
    response   jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

-------------------------------------------------- баланс сети на платформе

-- Деньги онлайн-заказов, которые платформа должна сети.
-- pending — заказ оплачен, но не доставлен; available — можно выводить.
CREATE TABLE balance_entries (
    id         bigserial     PRIMARY KEY,
    network_id uuid          NOT NULL REFERENCES networks (id),
    store_id   uuid,
    order_id   uuid          REFERENCES orders (id),
    kind       text          NOT NULL CHECK (kind IN ('order', 'refund', 'payout', 'subscription', 'adjustment')),
    status     text          NOT NULL CHECK (status IN ('pending', 'available')),
    amount     numeric(18,2) NOT NULL,
    note       text          NOT NULL DEFAULT '',
    created_at timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX balance_entries_network_idx ON balance_entries (network_id, created_at);
CREATE UNIQUE INDEX balance_entries_order_once ON balance_entries (order_id, kind) WHERE order_id IS NOT NULL;
