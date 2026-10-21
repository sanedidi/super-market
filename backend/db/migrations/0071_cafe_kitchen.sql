-- Кафе, этап 4: кухня. Экран кухни и экран выдачи — устройства кассы другого
-- вида (активируются тем же кодом), бегунки по цехам с статусами, принтер
-- цеха, настройки заказов на кухне и версия событий магазина для ожидания
-- изменений (long polling поверх LISTEN/NOTIFY).

-- Вид устройства: касса, экран кухни (цеха или всех цехов), экран выдачи.
ALTER TABLE pos_devices
    ADD COLUMN kind        text NOT NULL DEFAULT 'pos' CHECK (kind IN ('pos', 'kitchen', 'display')),
    ADD COLUMN workshop_id uuid REFERENCES workshops (id) ON DELETE SET NULL;

-- Принтер бегунков цеха: none — касса печатает на свой принтер чеков («к кассе
-- через USB»), network — касса отправляет бегунок на IP:порт в сети кафе.
-- Состояние присылает касса, которая печатает.
ALTER TABLE workshops
    ADD COLUMN printer_kind    text        NOT NULL DEFAULT 'none' CHECK (printer_kind IN ('none', 'network')),
    ADD COLUMN printer_host    text        NOT NULL DEFAULT '' CHECK (length(printer_host) <= 100),
    ADD COLUMN printer_port    int         NOT NULL DEFAULT 9100 CHECK (printer_port BETWEEN 1 AND 65535),
    ADD COLUMN printer_paper   int         NOT NULL DEFAULT 80 CHECK (printer_paper IN (58, 80)),
    ADD COLUMN printer_ok      boolean,
    ADD COLUMN printer_pending int         NOT NULL DEFAULT 0 CHECK (printer_pending >= 0),
    ADD COLUMN printer_seen_at timestamptz,
    -- «Тест печати» из панели: касса магазина печатает тестовый бегунок.
    ADD COLUMN printer_test_at timestamptz;

-- Настройки заказов на кухне (Figma П7 «Заказы на кухне» и «Экран выдачи»).
ALTER TABLE networks
    ADD COLUMN kitchen_sound        boolean NOT NULL DEFAULT true,
    ADD COLUMN display_show_cooking boolean NOT NULL DEFAULT true,
    ADD COLUMN display_hide_minutes int     NOT NULL DEFAULT 5 CHECK (display_hide_minutes BETWEEN 1 AND 120);

-- Бегунок цеха: заказ (продажа) делится по цехам. Статусы:
-- new → cooking → ready → served; cancelled — заказ отменён (возврат).
-- Цех без экрана кухни получает бегунок сразу «served»: его печатает касса.
CREATE TABLE kitchen_tickets (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id   uuid        NOT NULL REFERENCES networks (id),
    store_id     uuid        NOT NULL REFERENCES stores (id) ON DELETE CASCADE,
    sale_id      uuid        NOT NULL REFERENCES sales (id) ON DELETE CASCADE,
    workshop_id  uuid        REFERENCES workshops (id) ON DELETE SET NULL,
    order_no     int,
    order_type   text        NOT NULL DEFAULT 'here' CHECK (order_type IN ('here', 'takeaway', 'delivery')),
    status       text        NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'cooking', 'ready', 'served', 'cancelled')),
    cook_minutes int         NOT NULL DEFAULT 15,
    cashier_name text        NOT NULL DEFAULT '',
    -- Таймер на экране кухни — от оплаты.
    paid_at      timestamptz NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    started_at   timestamptz,
    ready_at     timestamptz,
    served_at    timestamptz,
    cancelled_at timestamptz,
    UNIQUE (sale_id, workshop_id)
);
CREATE INDEX kitchen_tickets_active_idx ON kitchen_tickets (store_id, status)
    WHERE status IN ('new', 'cooking', 'ready');
CREATE INDEX kitchen_tickets_sale_idx ON kitchen_tickets (sale_id);

CREATE TABLE kitchen_ticket_items (
    id            uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    ticket_id     uuid          NOT NULL REFERENCES kitchen_tickets (id) ON DELETE CASCADE,
    line          int           NOT NULL,
    product_id    uuid          NOT NULL REFERENCES products (id),
    name          text          NOT NULL,
    name_uz       text          NOT NULL DEFAULT '',
    qty           numeric(14,3) NOT NULL,
    -- [{"name": "Без лука", "action": "remove", "qty": 1}]
    mods          jsonb         NOT NULL DEFAULT '[]',
    note          text          NOT NULL DEFAULT '',
    done          boolean       NOT NULL DEFAULT false,
    cancelled_qty numeric(14,3) NOT NULL DEFAULT 0,
    UNIQUE (ticket_id, line)
);

-- Версия событий магазина: растёт при каждом изменении бегунков, стоп-листа
-- и настроек кухни. Экраны ждут, пока версия станет больше известной им.
CREATE TABLE store_event_versions (
    store_id uuid   PRIMARY KEY REFERENCES stores (id) ON DELETE CASCADE,
    version  bigint NOT NULL DEFAULT 0
);
