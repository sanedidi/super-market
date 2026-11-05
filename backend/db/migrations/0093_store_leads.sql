-- Агент добавляет магазин (Figma «SM Агент · Добавить магазин», АМ1–АМ6, и
-- «Супер-админ · Заявки агентов на магазины», С1–С3).
-- Агент «SM Агент» вносит магазин, которого ещё нет в Super Market: название,
-- владелец, телефон и точка на карте. Магазин закреплён за агентом 30 дней.
-- Супер-админ подключает его (создаёт сеть — она навсегда привязана к агенту)
-- или отклоняет с причиной. С первого оплаченного счёта подписки магазина
-- агенту на баланс начисляется 50% от реально оплаченной суммы.
CREATE TABLE IF NOT EXISTS store_leads (
    id                uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Сеть агента (вид distributor), кто отправил.
    agent_network_id  uuid          NOT NULL REFERENCES networks (id) ON DELETE CASCADE,
    employee_id       uuid          REFERENCES employees (id) ON DELETE SET NULL,
    name              text          NOT NULL CHECK (btrim(name) <> ''),
    owner_name        text          NOT NULL CHECK (btrim(owner_name) <> ''),
    owner_phone       text          NOT NULL,
    address           text          NOT NULL DEFAULT '',
    location          geography(Point, 4326) NOT NULL,
    -- pending — ждёт решения (после expires_at — «Срок истёк», считается при чтении);
    -- connected — сеть создана; rejected — отклонена с причиной.
    status            text          NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'connected', 'rejected')),
    reason            text          NOT NULL DEFAULT '',
    expires_at        timestamptz   NOT NULL,
    -- Сеть, созданная по заявке.
    network_id        uuid          REFERENCES networks (id) ON DELETE SET NULL,
    decided_at        timestamptz,
    decided_by        uuid          REFERENCES users (id) ON DELETE SET NULL,
    -- Начисление агенту: первый оплаченный счёт подписки магазина и 50% от него.
    reward_invoice_id uuid          REFERENCES subscription_invoices (id) ON DELETE SET NULL,
    reward_amount     numeric(18,2),
    rewarded_at       timestamptz,
    created_at        timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS store_leads_agent_idx ON store_leads (agent_network_id, created_at DESC);
CREATE INDEX IF NOT EXISTS store_leads_status_idx ON store_leads (status, created_at);
CREATE INDEX IF NOT EXISTS store_leads_location_idx ON store_leads USING gist (location);
CREATE INDEX IF NOT EXISTS store_leads_phone_idx ON store_leads (owner_phone);
-- Одна сеть — одна заявка (один агент).
CREATE UNIQUE INDEX IF NOT EXISTS store_leads_network_uq ON store_leads (network_id) WHERE network_id IS NOT NULL;
-- Начисления, которые ещё ждут первой оплаты.
CREATE INDEX IF NOT EXISTS store_leads_unrewarded_idx ON store_leads (network_id) WHERE status = 'connected' AND rewarded_at IS NULL;

-- Начисление агенту за подключённый магазин — отдельный вид записи баланса.
ALTER TABLE balance_entries DROP CONSTRAINT IF EXISTS balance_entries_kind_check;
ALTER TABLE balance_entries ADD CONSTRAINT balance_entries_kind_check
    CHECK (kind IN ('order', 'refund', 'payout', 'subscription', 'adjustment', 'ad_share', 'commission', 'agent_reward'));
