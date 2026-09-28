-- Этап 1: сети, магазины, склады, пользователи, роли, сотрудники, вход.

-- updated_at обновляется автоматически при любом UPDATE.
CREATE FUNCTION set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END $$;

------------------------------------------------------------------ tenant

CREATE TABLE networks (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    name       text        NOT NULL CHECK (btrim(name) <> ''),
    -- chain — сеть магазинов, single — одиночный магазин (ровно один магазин).
    kind       text        NOT NULL CHECK (kind IN ('chain', 'single')),
    status     text        NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'blocked')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER networks_updated_at BEFORE UPDATE ON networks
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE stores (
    id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id           uuid        NOT NULL REFERENCES networks (id),
    name                 text        NOT NULL CHECK (btrim(name) <> ''),
    address              text        NOT NULL DEFAULT '',
    phone                text        NOT NULL DEFAULT '',
    -- Точка магазина на карте (долгота, широта, WGS 84).
    location             geography(Point, 4326),
    status               text        NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    default_warehouse_id uuid,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, network_id)
);
CREATE INDEX stores_network_idx ON stores (network_id);
CREATE INDEX stores_location_idx ON stores USING gist (location);
CREATE TRIGGER stores_updated_at BEFORE UPDATE ON stores
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE warehouses (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id uuid        NOT NULL,
    store_id   uuid        NOT NULL,
    name       text        NOT NULL CHECK (btrim(name) <> ''),
    is_active  boolean     NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    -- Склад принадлежит магазину той же сети.
    FOREIGN KEY (store_id, network_id) REFERENCES stores (id, network_id),
    UNIQUE (store_id, name),
    UNIQUE (id, store_id)
);
CREATE TRIGGER warehouses_updated_at BEFORE UPDATE ON warehouses
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Склад по умолчанию обязан быть складом этого же магазина.
-- DEFERRABLE: магазин и его первый склад создаются в одной транзакции.
ALTER TABLE stores
    ADD CONSTRAINT stores_default_warehouse_fk
    FOREIGN KEY (default_warehouse_id, id) REFERENCES warehouses (id, store_id)
    DEFERRABLE INITIALLY DEFERRED;

---------------------------------------------------------------- identity

CREATE TABLE users (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Номер в формате E.164: +998901234567.
    phone      text        NOT NULL UNIQUE CHECK (phone ~ '^\+[1-9][0-9]{9,14}$'),
    full_name  text        NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER users_updated_at BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Номер, которым человек поделился в Telegram-боте. Привязка по номеру,
-- а не по пользователю: поделиться можно ещё до первого входа.
CREATE TABLE telegram_links (
    phone      text        PRIMARY KEY,
    chat_id    bigint      NOT NULL,
    tg_user_id bigint      NOT NULL,
    linked_at  timestamptz NOT NULL DEFAULT now()
);

-- Одноразовые коды входа. Храним только HMAC кода.
CREATE TABLE auth_codes (
    phone      text        PRIMARY KEY,
    code_hash  bytea       NOT NULL,
    attempts   int         NOT NULL DEFAULT 0,
    sent_at    timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL
);

CREATE TABLE platform_admins (
    user_id    uuid        PRIMARY KEY REFERENCES users (id),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE customers (
    user_id    uuid        PRIMARY KEY REFERENCES users (id),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE roles (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id  uuid        NOT NULL REFERENCES networks (id),
    name        text        NOT NULL CHECK (btrim(name) <> ''),
    permissions text[]      NOT NULL DEFAULT '{}',
    -- Роль владельца: все права, её нельзя изменить или удалить.
    is_owner    boolean     NOT NULL DEFAULT false,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (network_id, name),
    UNIQUE (id, network_id)
);
CREATE UNIQUE INDEX roles_one_owner_per_network ON roles (network_id) WHERE is_owner;
CREATE TRIGGER roles_updated_at BEFORE UPDATE ON roles
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Сотрудник сети. MVP: один человек работает в одной сети.
CREATE TABLE employees (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id uuid        NOT NULL REFERENCES networks (id),
    user_id    uuid        NOT NULL UNIQUE REFERENCES users (id),
    role_id    uuid        NOT NULL,
    full_name  text        NOT NULL CHECK (btrim(full_name) <> ''),
    status     text        NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    -- true — доступ ко всем магазинам сети, false — только из employee_stores.
    all_stores boolean     NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (role_id, network_id) REFERENCES roles (id, network_id),
    UNIQUE (id, network_id)
);
CREATE INDEX employees_network_idx ON employees (network_id);
CREATE TRIGGER employees_updated_at BEFORE UPDATE ON employees
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE employee_stores (
    employee_id uuid NOT NULL,
    store_id    uuid NOT NULL,
    network_id  uuid NOT NULL,
    PRIMARY KEY (employee_id, store_id),
    FOREIGN KEY (employee_id, network_id) REFERENCES employees (id, network_id) ON DELETE CASCADE,
    FOREIGN KEY (store_id, network_id) REFERENCES stores (id, network_id)
);

-- Сессия = один вход на одном устройстве. Refresh-токен храним как хеш.
CREATE TABLE sessions (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      uuid        NOT NULL REFERENCES users (id),
    app          text        NOT NULL CHECK (app IN ('client', 'store', 'admin')),
    refresh_hash bytea       NOT NULL UNIQUE,
    user_agent   text        NOT NULL DEFAULT '',
    created_at   timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,
    revoked_at   timestamptz
);
CREATE INDEX sessions_user_idx ON sessions (user_id);
