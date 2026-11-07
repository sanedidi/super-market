-- «SM Продажник» — обход с записью пути (Figma «SM Продажник · Обход с записью
-- пути», П1–П7, и «Супер-админ · Продажники», С1–С3).
--
-- Продажники Super Market ходят по районам и отмечают магазины. Путь пишется
-- только во время обхода («Начать обход» → «Закончить»). Город поделён на
-- клетки 100×100 м: клетка, через которую прошёл любой продажник, считается
-- обойдённой навсегда — другой продажник видит её на карте и не повторяет путь.

-- Токены приложения продажника.
ALTER TABLE sessions DROP CONSTRAINT IF EXISTS sessions_app_check;
ALTER TABLE sessions ADD CONSTRAINT sessions_app_check
    CHECK (app IN ('client', 'store', 'admin', 'courier', 'crowd', 'field'));

-- «Есть обновление» для нового приложения.
ALTER TABLE app_versions DROP CONSTRAINT IF EXISTS app_versions_app_check;
ALTER TABLE app_versions ADD CONSTRAINT app_versions_app_check
    CHECK (app IN ('client', 'store', 'courier', 'agent', 'employee', 'field'));

-- Районы Ташкента. Граница задаётся супер-админом на карте один раз;
-- без границы покрытие района не считается.
CREATE TABLE IF NOT EXISTS field_districts (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text        NOT NULL UNIQUE CHECK (btrim(name) <> ''),
    name_uz     text        NOT NULL DEFAULT '',
    -- Граница: [[lat, lng], ...] — многоугольник (пустой массив — не задана).
    boundary    jsonb       NOT NULL DEFAULT '[]',
    -- Сколько клеток 100×100 м внутри границы (считается при сохранении).
    total_cells int         NOT NULL DEFAULT 0,
    sort        int         NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO field_districts (name, name_uz, sort) VALUES
    ('Алмазар', 'Olmazor', 1),
    ('Бектемир', 'Bektemir', 2),
    ('Мирабад', 'Mirobod', 3),
    ('Мирзо-Улугбек', 'Mirzo Ulugʻbek', 4),
    ('Сергели', 'Sergeli', 5),
    ('Учтепа', 'Uchtepa', 6),
    ('Чиланзар', 'Chilonzor', 7),
    ('Шайхантахур', 'Shayxontohur', 8),
    ('Юнусабад', 'Yunusobod', 9),
    ('Яккасарай', 'Yakkasaroy', 10),
    ('Яшнабад', 'Yashnobod', 11),
    ('Янгихаёт', 'Yangihayot', 12)
ON CONFLICT (name) DO NOTHING;

-- Продажники. Логин и пароль выдаёт супер-админ; телефон — в users.
CREATE TABLE IF NOT EXISTS field_reps (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid        NOT NULL UNIQUE REFERENCES users (id),
    full_name       text        NOT NULL CHECK (btrim(full_name) <> ''),
    district_id     uuid        REFERENCES field_districts (id) ON DELETE SET NULL,
    login           text        NOT NULL UNIQUE,
    password_hash   text        NOT NULL,
    status          text        NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'blocked')),
    -- Цвет линии продажника на карте супер-админа.
    color           text        NOT NULL DEFAULT '#E11D2A',
    failed_attempts int         NOT NULL DEFAULT 0,
    locked_until    timestamptz,
    last_login_at   timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- Обходы. Открытый (active или paused) у продажника — один.
CREATE TABLE IF NOT EXISTS field_walks (
    id            uuid             PRIMARY KEY DEFAULT gen_random_uuid(),
    rep_id        uuid             NOT NULL REFERENCES field_reps (id) ON DELETE CASCADE,
    status        text             NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused', 'ended')),
    started_at    timestamptz      NOT NULL DEFAULT now(),
    ended_at      timestamptz,
    -- manual — нажал «Закончить»; auto — закрыт в 21:00 или после долгой паузы.
    end_reason    text             NOT NULL DEFAULT '' CHECK (end_reason IN ('', 'manual', 'auto')),
    paused_at     timestamptz,
    -- Пауза поставлена сервером: стоит на месте больше 30 минут.
    auto_paused   boolean          NOT NULL DEFAULT false,
    pause_sec     int              NOT NULL DEFAULT 0,
    distance_m    double precision NOT NULL DEFAULT 0,
    -- Сколько метров прошёл по клеткам, которые раньше обошёл другой продажник.
    other_m       double precision NOT NULL DEFAULT 0,
    new_cells     int              NOT NULL DEFAULT 0,
    points        int              NOT NULL DEFAULT 0,
    mock_points   int              NOT NULL DEFAULT 0,
    -- Разрывы: между точками больше 2 минут (не было связи или GPS).
    gaps          int              NOT NULL DEFAULT 0,
    last_lat      double precision,
    last_lng      double precision,
    last_at       timestamptz,
    -- Где и когда последний раз сдвинулся больше чем на 50 м (для автопаузы).
    moved_lat     double precision,
    moved_lng     double precision,
    last_moved_at timestamptz,
    created_at    timestamptz      NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS field_walks_open_uq ON field_walks (rep_id) WHERE status <> 'ended';
CREATE INDEX IF NOT EXISTS field_walks_rep_idx ON field_walks (rep_id, started_at DESC);
CREATE INDEX IF NOT EXISTS field_walks_started_idx ON field_walks (started_at);

-- Точки пути.
CREATE TABLE IF NOT EXISTS field_points (
    walk_id  uuid             NOT NULL REFERENCES field_walks (id) ON DELETE CASCADE,
    at       timestamptz      NOT NULL,
    lat      double precision NOT NULL,
    lng      double precision NOT NULL,
    accuracy real             NOT NULL DEFAULT 0,
    mocked   boolean          NOT NULL DEFAULT false,
    PRIMARY KEY (walk_id, at)
);
CREATE INDEX IF NOT EXISTS field_points_geo_idx ON field_points (lat, lng);

-- События обхода для хронологии супер-админа: start, pause, resume, finish,
-- auto_pause, auto_finish, other (зашёл в клетки, которые обошёл другой продажник).
CREATE TABLE IF NOT EXISTS field_walk_events (
    walk_id uuid             NOT NULL REFERENCES field_walks (id) ON DELETE CASCADE,
    at      timestamptz      NOT NULL,
    kind    text             NOT NULL,
    lat     double precision,
    lng     double precision,
    data    jsonb            NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS field_walk_events_walk_idx ON field_walk_events (walk_id, at);

-- Обойдённые клетки 100×100 м — навсегда. cx, cy — номер клетки (см. field/grid.go).
-- Кто обошёл первым.
CREATE TABLE IF NOT EXISTS field_cells (
    cx       int         NOT NULL,
    cy       int         NOT NULL,
    rep_id   uuid        NOT NULL REFERENCES field_reps (id) ON DELETE CASCADE,
    walk_id  uuid        REFERENCES field_walks (id) ON DELETE SET NULL,
    first_at timestamptz NOT NULL,
    PRIMARY KEY (cx, cy)
);
CREATE INDEX IF NOT EXISTS field_cells_rep_idx ON field_cells (rep_id);

-- Клетки, где был каждый продажник (свой путь на карте — красным).
CREATE TABLE IF NOT EXISTS field_rep_cells (
    rep_id   uuid        NOT NULL REFERENCES field_reps (id) ON DELETE CASCADE,
    cx       int         NOT NULL,
    cy       int         NOT NULL,
    first_at timestamptz NOT NULL,
    PRIMARY KEY (rep_id, cx, cy)
);

-- Магазины, отмеченные продажниками (точка на карте и последний результат).
CREATE TABLE IF NOT EXISTS field_places (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    location      geography(Point, 4326) NOT NULL,
    name          text        NOT NULL DEFAULT '',
    last_result   text        NOT NULL CHECK (last_result IN ('lead', 'refused', 'closed', 'later', 'ours')),
    last_visit_at timestamptz NOT NULL,
    last_rep_id   uuid        REFERENCES field_reps (id) ON DELETE SET NULL,
    -- «Прийти позже»: когда и кто придёт.
    remind_on     date,
    photo_url     text        NOT NULL DEFAULT '',
    lead_id       uuid        REFERENCES store_leads (id) ON DELETE SET NULL,
    visits        int         NOT NULL DEFAULT 1,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS field_places_geo_idx ON field_places USING gist (location);
CREATE INDEX IF NOT EXISTS field_places_remind_idx ON field_places (last_rep_id, remind_on) WHERE last_result = 'later';

-- Визиты: история магазина (кто, когда и с каким результатом).
CREATE TABLE IF NOT EXISTS field_visits (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    place_id   uuid        NOT NULL REFERENCES field_places (id) ON DELETE CASCADE,
    rep_id     uuid        NOT NULL REFERENCES field_reps (id) ON DELETE CASCADE,
    walk_id    uuid        REFERENCES field_walks (id) ON DELETE SET NULL,
    result     text        NOT NULL CHECK (result IN ('lead', 'refused', 'closed', 'later', 'ours')),
    location   geography(Point, 4326) NOT NULL,
    accuracy   real,
    name       text        NOT NULL DEFAULT '',
    -- Отказ: причина (expensive, has_program, not_interested, no_trust, owner_against, other)
    -- и какая программа уже есть (billz, regos, 1c, notebook, other).
    reason     text        NOT NULL DEFAULT '',
    program    text        NOT NULL DEFAULT '',
    comment    text        NOT NULL DEFAULT '',
    photo_url  text        NOT NULL DEFAULT '',
    remind_on  date,
    lead_id    uuid        REFERENCES store_leads (id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS field_visits_place_idx ON field_visits (place_id, created_at DESC);
CREATE INDEX IF NOT EXISTS field_visits_rep_idx ON field_visits (rep_id, created_at DESC);
CREATE INDEX IF NOT EXISTS field_visits_walk_idx ON field_visits (walk_id);

-- Заявка «Подключить» от продажника: та же store_leads, но без сети агента
-- (продажник на окладе — 50% ему не начисляется).
ALTER TABLE store_leads ALTER COLUMN agent_network_id DROP NOT NULL;
ALTER TABLE store_leads ADD COLUMN IF NOT EXISTS rep_id uuid REFERENCES field_reps (id);
ALTER TABLE store_leads DROP CONSTRAINT IF EXISTS store_leads_owner_check;
ALTER TABLE store_leads ADD CONSTRAINT store_leads_owner_check CHECK (agent_network_id IS NOT NULL OR rep_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS store_leads_rep_idx ON store_leads (rep_id, created_at DESC) WHERE rep_id IS NOT NULL;
