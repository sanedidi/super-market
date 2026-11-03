-- Весы магазина и отправка товаров в весы (Figma «Панель магазина · Весы:
-- отправка товаров в весы (любой бренд)», Н1–Н5).
--
-- Весы стоят в сети магазина — сервер их не видит. Отправляет касса Super
-- Market в той же сети: панель создаёт задание, касса забирает его при
-- синхронизации, передаёт товары на весы и сообщает результат.

-- Названия в весах: uz — узбекское (латиница), ru — русское латиницей
-- (кириллицу многие весы не печатают).
ALTER TABLE networks ADD COLUMN scale_name_lang text NOT NULL DEFAULT 'uz' CHECK (scale_name_lang IN ('uz', 'ru'));

-- Весы магазина. brand решает способ: rongta, dahua — касса отправляет
-- напрямую (протокол Dahua, TCP 4001); остальные — файлом для программы весов.
CREATE TABLE scales (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id  uuid        NOT NULL REFERENCES networks (id) ON DELETE CASCADE,
    store_id    uuid        NOT NULL REFERENCES stores (id) ON DELETE CASCADE,
    name        text        NOT NULL CHECK (length(name) BETWEEN 1 AND 60),
    brand       text        NOT NULL CHECK (brand IN ('rongta', 'dahua', 'kuanyi', 'cas', 'massak', 'shtrih', 'other')),
    model       text        NOT NULL DEFAULT '' CHECK (length(model) <= 40),
    host        text        NOT NULL DEFAULT '' CHECK (length(host) <= 60),
    port        int         NOT NULL DEFAULT 4001 CHECK (port BETWEEN 1 AND 65535),
    -- Касса, которая отправляет (в одной сети с весами). Нет — любая касса магазина.
    device_id   uuid        REFERENCES pos_devices (id) ON DELETE SET NULL,
    -- Последняя проверка связи кассой.
    check_at    timestamptz,
    check_ok    boolean,
    check_error text,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX scales_store_idx ON scales (store_id);

-- Что сейчас в каждых весах: номер, цена и название на момент отправки
-- (или «Загружено в весы» для весов через файл). Поменялось — «ждёт отправки».
CREATE TABLE scale_items (
    scale_id   uuid          NOT NULL REFERENCES scales (id) ON DELETE CASCADE,
    product_id uuid          NOT NULL REFERENCES products (id) ON DELETE CASCADE,
    plu        int           NOT NULL,
    price      numeric(14,2) NOT NULL,
    name       text          NOT NULL DEFAULT '',
    sent_at    timestamptz   NOT NULL DEFAULT now(),
    PRIMARY KEY (scale_id, product_id)
);

-- Задания кассе: send — отправить товары (items — снимок на момент нажатия),
-- check — проверить связь. pending → running (касса взяла) → done / failed.
CREATE TABLE scale_jobs (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id uuid        NOT NULL REFERENCES networks (id) ON DELETE CASCADE,
    store_id   uuid        NOT NULL REFERENCES stores (id) ON DELETE CASCADE,
    scale_id   uuid        NOT NULL REFERENCES scales (id) ON DELETE CASCADE,
    kind       text        NOT NULL CHECK (kind IN ('send', 'check')),
    mode       text        NOT NULL DEFAULT 'changed' CHECK (mode IN ('changed', 'all')),
    items      jsonb       NOT NULL DEFAULT '[]',
    total      int         NOT NULL DEFAULT 0,
    status     text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'running', 'done', 'failed')),
    sent       int         NOT NULL DEFAULT 0,
    error      text,
    -- Товары, которые весы не приняли: [{product_id, plu, name, error}].
    failures   jsonb       NOT NULL DEFAULT '[]',
    taken_by   uuid        REFERENCES pos_devices (id) ON DELETE SET NULL,
    taken_at   timestamptz,
    done_at    timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX scale_jobs_open_idx ON scale_jobs (store_id, created_at) WHERE status IN ('pending', 'running');
CREATE INDEX scale_jobs_scale_idx ON scale_jobs (scale_id, created_at DESC);
