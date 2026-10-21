-- Кафе, этап 5: залы, столы и открытый счёт (Figma С1–С9, П9, П10).
-- Счёт стола живёт часами и его дописывают несколько устройств: касса шлёт
-- операции (открыть, дописать, на кухню, отменить, перенести…) с uid —
-- повтор безопасен, касса работает и без интернета (очередь). Оплата — это
-- обычная продажа (sales.bill_id), одна или несколько (разделение счёта).

-- Настройки столов (П10 «Режим работы кафе»).
ALTER TABLE networks
    ADD COLUMN waiter_own_tables boolean NOT NULL DEFAULT true,
    ADD COLUMN precheck_required boolean NOT NULL DEFAULT false,
    ADD COLUMN void_senior_only  boolean NOT NULL DEFAULT true,
    -- ИКПУ строки «Обслуживание» в фискальном чеке.
    ADD COLUMN service_ikpu      text    NOT NULL DEFAULT '' CHECK (service_ikpu = '' OR service_ikpu ~ '^[0-9]{17}$');

-- Залы точки: «Зал», «Терраса», «Топчаны».
CREATE TABLE halls (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id uuid        NOT NULL REFERENCES networks (id),
    store_id   uuid        NOT NULL,
    name       text        NOT NULL CHECK (btrim(name) <> '' AND length(name) <= 40),
    name_uz    text        NOT NULL DEFAULT '' CHECK (length(name_uz) <= 40),
    sort       int         NOT NULL DEFAULT 0,
    is_active  boolean     NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (store_id, network_id) REFERENCES stores (id, network_id) ON DELETE CASCADE
);
CREATE INDEX halls_store_idx ON halls (store_id) WHERE is_active;

-- Стол на схеме: номер, мест, форма, место на сетке (клетки).
CREATE TABLE cafe_tables (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id uuid        NOT NULL REFERENCES networks (id),
    store_id   uuid        NOT NULL REFERENCES stores (id) ON DELETE CASCADE,
    hall_id    uuid        NOT NULL REFERENCES halls (id),
    number     text        NOT NULL CHECK (btrim(number) <> '' AND length(number) <= 8),
    seats      int         NOT NULL DEFAULT 4 CHECK (seats BETWEEN 1 AND 50),
    shape      text        NOT NULL DEFAULT 'rect' CHECK (shape IN ('rect', 'round', 'topchan')),
    x          int         NOT NULL DEFAULT 0 CHECK (x BETWEEN 0 AND 200),
    y          int         NOT NULL DEFAULT 0 CHECK (y BETWEEN 0 AND 200),
    w          int         NOT NULL DEFAULT 2 CHECK (w BETWEEN 1 AND 20),
    h          int         NOT NULL DEFAULT 2 CHECK (h BETWEEN 1 AND 20),
    -- Официант по умолчанию (зона).
    waiter_id  uuid        REFERENCES employees (id) ON DELETE SET NULL,
    bookable   boolean     NOT NULL DEFAULT true,
    -- Обслуживание % у этого стола.
    service    boolean     NOT NULL DEFAULT true,
    is_active  boolean     NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX cafe_tables_number_key ON cafe_tables (store_id, lower(number)) WHERE is_active;
CREATE INDEX cafe_tables_hall_idx ON cafe_tables (hall_id) WHERE is_active;

-- Открытый счёт. id выдаёт касса (открытие без интернета).
CREATE TABLE bills (
    id              uuid          PRIMARY KEY,
    network_id      uuid          NOT NULL REFERENCES networks (id),
    store_id        uuid          NOT NULL REFERENCES stores (id) ON DELETE CASCADE,
    table_id        uuid          REFERENCES cafe_tables (id),
    waiter_id       uuid          REFERENCES employees (id) ON DELETE SET NULL,
    guests          int           NOT NULL DEFAULT 1 CHECK (guests BETWEEN 1 AND 99),
    -- open — идёт; closed — оплачен; void — закрыт без оплаты или объединён.
    status          text          NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed', 'void')),
    service_percent numeric(5, 2) NOT NULL DEFAULT 0 CHECK (service_percent BETWEEN 0 AND 30),
    precheck_at     timestamptz,
    version         int           NOT NULL DEFAULT 1,
    opened_at       timestamptz   NOT NULL DEFAULT now(),
    opened_by       uuid          REFERENCES employees (id),
    device_id       uuid,
    closed_at       timestamptz,
    closed_by       uuid          REFERENCES employees (id),
    void_reason     text          NOT NULL DEFAULT '' CHECK (length(void_reason) <= 200),
    merged_into     uuid          REFERENCES bills (id)
);
-- На столе — один открытый счёт.
CREATE UNIQUE INDEX bills_table_open_key ON bills (table_id) WHERE status = 'open' AND table_id IS NOT NULL;
CREATE INDEX bills_store_open_idx ON bills (store_id) WHERE status = 'open';

-- Позиция счёта. new — ещё не на кухне (удаляется без подтверждения);
-- sent — ушла на кухню (отмена — с причиной и ПИНом старшего).
CREATE TABLE bill_items (
    id            uuid          PRIMARY KEY,
    bill_id       uuid          NOT NULL REFERENCES bills (id) ON DELETE CASCADE,
    seq           int           NOT NULL,
    product_id    uuid          NOT NULL REFERENCES products (id),
    name          text          NOT NULL,
    name_uz       text          NOT NULL DEFAULT '',
    qty           numeric(14,3) NOT NULL CHECK (qty > 0),
    -- Цена за единицу с модификаторами.
    price         numeric(14,2) NOT NULL CHECK (price >= 0),
    -- [{"option_id", "name", "qty", "price", "action"}]
    mods          jsonb         NOT NULL DEFAULT '[]',
    note          text          NOT NULL DEFAULT '' CHECK (length(note) <= 200),
    -- Гость Г1…Г9 (для разделения счёта); null — на весь стол.
    guest         int           CHECK (guest BETWEEN 1 AND 99),
    -- now — сразу на кухню, later — «по команде» («Подать горячее»).
    course        text          NOT NULL DEFAULT 'now' CHECK (course IN ('now', 'later')),
    status        text          NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'sent')),
    sent_at       timestamptz,
    cancelled_qty numeric(14,3) NOT NULL DEFAULT 0 CHECK (cancelled_qty >= 0),
    paid_qty      numeric(14,3) NOT NULL DEFAULT 0 CHECK (paid_qty >= 0),
    created_by    uuid          REFERENCES employees (id),
    created_at    timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (bill_id, seq),
    CHECK (cancelled_qty + paid_qty <= qty)
);

-- Журнал счёта: каждая операция с устройства (id — её uid, повтор не
-- применяется второй раз), кто и когда; для разборов и отчёта «Отмены».
CREATE TABLE bill_events (
    id          uuid        PRIMARY KEY,
    bill_id     uuid        NOT NULL REFERENCES bills (id) ON DELETE CASCADE,
    kind        text        NOT NULL,
    payload     jsonb       NOT NULL DEFAULT '{}',
    employee_id uuid        REFERENCES employees (id),
    device_id   uuid,
    at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX bill_events_bill_idx ON bill_events (bill_id, at);

-- Оплата счёта — продажа (или несколько при разделении) с обслуживанием.
ALTER TABLE sales
    ADD COLUMN bill_id        uuid          REFERENCES bills (id),
    ADD COLUMN service_amount numeric(14,2) NOT NULL DEFAULT 0 CHECK (service_amount >= 0);
CREATE INDEX sales_bill_idx ON sales (bill_id) WHERE bill_id IS NOT NULL;
ALTER TABLE sale_items ADD COLUMN bill_item_id uuid REFERENCES bill_items (id);

-- Кухня: бегунки счёта стола (по отправкам «На кухню»), «по команде» — waiting.
ALTER TABLE kitchen_tickets
    ALTER COLUMN sale_id DROP NOT NULL,
    ADD COLUMN bill_id     uuid REFERENCES bills (id) ON DELETE CASCADE,
    ADD COLUMN batch       int  NOT NULL DEFAULT 0,
    ADD COLUMN table_label text NOT NULL DEFAULT '',
    ADD COLUMN waiter_name text NOT NULL DEFAULT '',
    -- Карточка на экране кухни: продажа или отправка счёта.
    ADD COLUMN order_key   text,
    ADD CONSTRAINT kitchen_tickets_source CHECK ((sale_id IS NULL) <> (bill_id IS NULL));
UPDATE kitchen_tickets SET order_key = sale_id::text WHERE order_key IS NULL;
ALTER TABLE kitchen_tickets ALTER COLUMN order_key SET NOT NULL;
ALTER TABLE kitchen_tickets DROP CONSTRAINT kitchen_tickets_status_check;
ALTER TABLE kitchen_tickets ADD CONSTRAINT kitchen_tickets_status_check
    CHECK (status IN ('waiting', 'new', 'cooking', 'ready', 'served', 'cancelled'));
CREATE UNIQUE INDEX kitchen_tickets_bill_key ON kitchen_tickets (bill_id, batch, workshop_id) WHERE bill_id IS NOT NULL;
CREATE INDEX kitchen_tickets_order_idx ON kitchen_tickets (store_id, order_key);
DROP INDEX kitchen_tickets_active_idx;
CREATE INDEX kitchen_tickets_active_idx ON kitchen_tickets (store_id, status)
    WHERE status IN ('waiting', 'new', 'cooking', 'ready');
ALTER TABLE kitchen_ticket_items ADD COLUMN bill_item_id uuid REFERENCES bill_items (id) ON DELETE CASCADE;
