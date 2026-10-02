-- Crowd-доставка: обычные пользователи становятся курьерами «по пути».
-- Вход по телефону и коду, личность подтверждает продавец в магазине
-- (копию документа не храним), заказ выдаётся по коду и вручается по коду
-- покупателя. Вознаграждение — в журнал курьера, бонус — магазину,
-- который проверил курьера.

-- Настройки: одна строка, меняет супер-админ.
CREATE TABLE crowd_settings (
    id                   boolean       PRIMARY KEY DEFAULT true CHECK (id),
    courier_fee          numeric(18,2) NOT NULL DEFAULT 10000 CHECK (courier_fee >= 0),
    platform_fee         numeric(18,2) NOT NULL DEFAULT 5000 CHECK (platform_fee >= 0),
    -- Доплата курьеру, если заказ ждал дольше long_wait_minutes.
    long_wait_bonus      numeric(18,2) NOT NULL DEFAULT 2000 CHECK (long_wait_bonus >= 0),
    long_wait_minutes    int           NOT NULL DEFAULT 5 CHECK (long_wait_minutes BETWEEN 1 AND 120),
    -- Сколько заказ ждёт crowd-курьера, потом — штатному.
    wait_minutes         int           NOT NULL DEFAULT 10 CHECK (wait_minutes BETWEEN 1 AND 240),
    -- Сколько курьеру дойти до магазина после принятия.
    pickup_minutes       int           NOT NULL DEFAULT 15 CHECK (pickup_minutes BETWEEN 5 AND 120),
    radius_m             int           NOT NULL DEFAULT 2000 CHECK (radius_m BETWEEN 200 AND 20000),
    detour_m             int           NOT NULL DEFAULT 1000 CHECK (detour_m BETWEEN 100 AND 10000),
    store_bonus          numeric(18,2) NOT NULL DEFAULT 5000 CHECK (store_bonus >= 0),
    store_bonus_count    int           NOT NULL DEFAULT 5 CHECK (store_bonus_count BETWEEN 0 AND 50),
    store_bonus_hold_days int          NOT NULL DEFAULT 7 CHECK (store_bonus_hold_days BETWEEN 0 AND 60),
    -- Уровни: лимит суммы заказа и заказов одновременно.
    newbie_limit         numeric(18,2) NOT NULL DEFAULT 150000,
    newbie_parallel      int           NOT NULL DEFAULT 1,
    reliable_after       int           NOT NULL DEFAULT 20,
    reliable_ontime      int           NOT NULL DEFAULT 90 CHECK (reliable_ontime BETWEEN 0 AND 100),
    reliable_limit       numeric(18,2) NOT NULL DEFAULT 400000,
    reliable_parallel    int           NOT NULL DEFAULT 2,
    trusted_after        int           NOT NULL DEFAULT 100,
    trusted_ontime       int           NOT NULL DEFAULT 95 CHECK (trusted_ontime BETWEEN 0 AND 100),
    trusted_limit        numeric(18,2) NOT NULL DEFAULT 1000000,
    trusted_parallel     int           NOT NULL DEFAULT 3,
    updated_at           timestamptz   NOT NULL DEFAULT now()
);
INSERT INTO crowd_settings DEFAULT VALUES;

-- Магазины, где заказы предлагаются crowd-курьерам (пилот включает супер-админ).
ALTER TABLE stores ADD COLUMN crowd_enabled boolean NOT NULL DEFAULT false;

CREATE TABLE crowd_couriers (
    user_id           uuid        PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
    -- Код курьера для продавца: KR-48213.
    code              text        NOT NULL UNIQUE CHECK (code ~ '^KR-[0-9]{5}$'),
    status            text        NOT NULL DEFAULT 'unverified' CHECK (status IN ('unverified', 'active', 'blocked')),
    -- Из документа при проверке.
    full_name         text        NOT NULL DEFAULT '' CHECK (length(full_name) <= 120),
    birth_date        date,
    doc_hash          bytea,
    verified_at       timestamptz,
    verified_store_id uuid        REFERENCES stores (id),
    vehicle           text        NOT NULL DEFAULT 'foot' CHECK (vehicle IN ('foot', 'bike', 'scooter', 'car')),
    online            boolean     NOT NULL DEFAULT false,
    -- Куда идёт: заказы подбираются с небольшим крюком к этой точке.
    dest              geography(Point, 4326),
    dest_title        text        NOT NULL DEFAULT '' CHECK (length(dest_title) <= 120),
    location          geography(Point, 4326),
    located_at        timestamptz,
    blocked_reason    text        NOT NULL DEFAULT '' CHECK (length(blocked_reason) <= 500),
    terms_accepted_at timestamptz NOT NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX crowd_couriers_status_idx ON crowd_couriers (status);
CREATE UNIQUE INDEX crowd_couriers_doc_idx ON crowd_couriers (doc_hash) WHERE doc_hash IS NOT NULL;
CREATE TRIGGER crowd_couriers_updated_at BEFORE UPDATE ON crowd_couriers FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Факт проверки личности. Скан документа не хранится, номер — только хэшем.
CREATE TABLE courier_verifications (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    courier_id   uuid        NOT NULL REFERENCES crowd_couriers (user_id) ON DELETE CASCADE,
    network_id   uuid        NOT NULL REFERENCES networks (id),
    store_id     uuid        NOT NULL REFERENCES stores (id),
    employee_id  uuid        NOT NULL REFERENCES employees (id),
    doc_type     text        NOT NULL CHECK (doc_type IN ('passport', 'id_card')),
    full_name    text        NOT NULL DEFAULT '',
    birth_date   date,
    doc_hash     bytea,
    result       text        NOT NULL CHECK (result IN ('approved', 'rejected')),
    reason       text        NOT NULL DEFAULT '' CHECK (length(reason) <= 500),
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX courier_verifications_courier_idx ON courier_verifications (courier_id, created_at DESC);
CREATE INDEX courier_verifications_store_idx ON courier_verifications (store_id, created_at DESC);

-- Заказ у crowd-курьера.
ALTER TABLE orders
    ADD COLUMN crowd_courier_id   uuid REFERENCES crowd_couriers (user_id),
    ADD COLUMN crowd_accepted_at  timestamptz,
    ADD COLUMN crowd_pickup_until timestamptz,
    ADD COLUMN crowd_fee          numeric(18,2),
    -- Код выдачи (QR курьера в магазине) и код вручения (называет покупатель).
    ADD COLUMN pickup_code        text,
    ADD COLUMN handoff_code       text,
    ADD COLUMN handoff_attempts   int NOT NULL DEFAULT 0;
CREATE INDEX orders_crowd_courier_idx ON orders (crowd_courier_id, status) WHERE crowd_courier_id IS NOT NULL;
CREATE INDEX orders_crowd_open_idx ON orders (picked_at) WHERE status = 'picked' AND courier_id IS NULL AND crowd_courier_id IS NULL;

-- Деньги курьера: начисления (+) и выплаты (−). Баланс — сумма строк.
CREATE TABLE crowd_ledger (
    id         bigserial     PRIMARY KEY,
    courier_id uuid          NOT NULL REFERENCES crowd_couriers (user_id) ON DELETE CASCADE,
    order_id   uuid          REFERENCES orders (id),
    kind       text          NOT NULL CHECK (kind IN ('delivery', 'wait_bonus', 'penalty', 'payout', 'adjustment')),
    amount     numeric(18,2) NOT NULL,
    note       text          NOT NULL DEFAULT '' CHECK (length(note) <= 300),
    created_by uuid          REFERENCES users (id),
    created_at timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX crowd_ledger_courier_idx ON crowd_ledger (courier_id, created_at DESC);
CREATE UNIQUE INDEX crowd_ledger_order_kind_idx ON crowd_ledger (order_id, kind) WHERE order_id IS NOT NULL;

-- Бонус магазину за первые доставки проверенного им курьера.
CREATE TABLE store_crowd_bonuses (
    id           uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id   uuid          NOT NULL REFERENCES networks (id),
    store_id     uuid          NOT NULL REFERENCES stores (id),
    courier_id   uuid          NOT NULL REFERENCES crowd_couriers (user_id) ON DELETE CASCADE,
    order_id     uuid          NOT NULL UNIQUE REFERENCES orders (id),
    amount       numeric(18,2) NOT NULL,
    status       text          NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'credited', 'cancelled')),
    available_at timestamptz   NOT NULL,
    credited_at  timestamptz,
    created_at   timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX store_crowd_bonuses_store_idx ON store_crowd_bonuses (store_id, created_at DESC);
CREATE INDEX store_crowd_bonuses_pending_idx ON store_crowd_bonuses (available_at) WHERE status = 'pending';

-- Нарушения и жалобы.
CREATE TABLE courier_incidents (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    courier_id  uuid        NOT NULL REFERENCES crowd_couriers (user_id) ON DELETE CASCADE,
    order_id    uuid        REFERENCES orders (id),
    kind        text        NOT NULL CHECK (kind IN ('pickup_timeout', 'no_handoff', 'complaint', 'released', 'other')),
    note        text        NOT NULL DEFAULT '' CHECK (length(note) <= 500),
    -- Нарушение ли это (влияет на уровень); отказ до магазина — нет.
    violation   boolean     NOT NULL DEFAULT false,
    status      text        NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved')),
    resolution  text        NOT NULL DEFAULT '' CHECK (length(resolution) <= 500),
    resolved_by uuid        REFERENCES users (id),
    resolved_at timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX courier_incidents_courier_idx ON courier_incidents (courier_id, created_at DESC);
CREATE INDEX courier_incidents_open_idx ON courier_incidents (created_at DESC) WHERE status = 'open';

ALTER TABLE sessions DROP CONSTRAINT IF EXISTS sessions_app_check;
ALTER TABLE sessions ADD CONSTRAINT sessions_app_check CHECK (app IN ('client', 'store', 'admin', 'courier', 'crowd'));
