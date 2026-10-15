-- «SM Агент»: агент регистрируется сам и выбирает свой бренд; оплаты
-- магазина агенту подтверждает агент (Figma «SM Агент · регистрация сам»,
-- «Оплаты поставщику», «Супер-админ · Заявки на бренды»).
--
-- Агент — та же сеть вида distributor. Сам зарегистрированный агент
-- (self_registered) видит магазины только после того, как у него есть хотя
-- бы один бренд: существующий бренд из каталога он выбирает сразу, новый —
-- заявкой, которую рассматривает супер-админ. Один бренд могут возить
-- несколько агентов. Агенты, которых завёл супер-админ, работают как раньше.

ALTER TABLE networks ADD COLUMN self_registered boolean NOT NULL DEFAULT false;

CREATE TABLE distributor_brands (
    network_id uuid        NOT NULL REFERENCES networks (id) ON DELETE CASCADE,
    brand_id   uuid        NOT NULL REFERENCES brands (id),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (network_id, brand_id)
);
CREATE INDEX distributor_brands_brand_idx ON distributor_brands (brand_id);

-- Заявка на новый бренд. pending — ждёт супер-админа; approved — бренд
-- создан (или агент привязан к существующему: linked_existing) и добавлен
-- агенту; rejected — отклонена с причиной (агент может исправить и отправить
-- снова — заявка опять pending).
CREATE TABLE brand_requests (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id      uuid        NOT NULL REFERENCES networks (id) ON DELETE CASCADE,
    employee_id     uuid        REFERENCES employees (id) ON DELETE SET NULL,
    name            text        NOT NULL CHECK (btrim(name) <> '' AND length(name) <= 100),
    category_id     uuid        REFERENCES categories (id),
    manufacturer    text        NOT NULL DEFAULT '' CHECK (length(manufacturer) <= 200),
    comment         text        NOT NULL DEFAULT '' CHECK (length(comment) <= 1000),
    logo_url        text        NOT NULL DEFAULT '' CHECK (length(logo_url) <= 1000),
    status          text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
    brand_id        uuid        REFERENCES brands (id),
    linked_existing boolean     NOT NULL DEFAULT false,
    reason          text        NOT NULL DEFAULT '' CHECK (length(reason) <= 500),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    decided_at      timestamptz,
    decided_by      uuid        REFERENCES users (id),
    CHECK ((status = 'approved') = (brand_id IS NOT NULL)),
    CHECK (status <> 'rejected' OR reason <> '')
);
CREATE INDEX brand_requests_status_idx ON brand_requests (status, created_at DESC);
CREATE INDEX brand_requests_network_idx ON brand_requests (network_id, created_at DESC);
CREATE TRIGGER brand_requests_updated_at BEFORE UPDATE ON brand_requests FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Оплата магазина агенту. Деньги вносит магазин (кассовая операция расхода
-- контрагенту-агенту): у магазина касса и долг меняются сразу, у агента долг
-- магазина уменьшается только после «Получил». pending — ждёт агента;
-- confirmed — агент получил amount; disputed — агент получил received
-- (0 — «Не получал»), магазин согласится или исправит сумму.
CREATE TABLE supply_payments (
    id                uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    distributor_id    uuid          NOT NULL REFERENCES networks (id),
    store_id          uuid          NOT NULL REFERENCES stores (id),
    store_network_id  uuid          NOT NULL REFERENCES networks (id),
    cash_operation_id uuid          NOT NULL UNIQUE REFERENCES cash_operations (id),
    -- Сколько отдал магазин (после исправления — исправленная сумма).
    amount            numeric(18,2) NOT NULL CHECK (amount > 0),
    -- Сколько получил агент по его словам (при «Другая сумма» / «Не получал»).
    received          numeric(18,2) CHECK (received >= 0),
    method            text          NOT NULL DEFAULT 'cash' CHECK (method IN ('cash', 'transfer', 'card')),
    status            text          NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'disputed')),
    note              text          NOT NULL DEFAULT '' CHECK (length(note) <= 500),
    agent_comment     text          NOT NULL DEFAULT '' CHECK (length(agent_comment) <= 500),
    photo_url         text          NOT NULL DEFAULT '' CHECK (length(photo_url) <= 1000),
    created_by        uuid          NOT NULL REFERENCES employees (id),
    created_at        timestamptz   NOT NULL DEFAULT now(),
    updated_at        timestamptz   NOT NULL DEFAULT now(),
    answered_at       timestamptz,
    confirmed_at      timestamptz
);
CREATE INDEX supply_payments_distributor_idx ON supply_payments (distributor_id, status, created_at DESC);
CREATE INDEX supply_payments_store_idx ON supply_payments (store_network_id, distributor_id, created_at DESC);
CREATE TRIGGER supply_payments_updated_at BEFORE UPDATE ON supply_payments FOR EACH ROW EXECUTE FUNCTION set_updated_at();
