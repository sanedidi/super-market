-- Журнал удалений сетей и магазинов супер-админом (Figma «Супер-админ ·
-- удаление сетей и магазинов»): кто, когда, что и сколько строк удалено.
-- Ссылок на удалённое нет — только копии названий и идентификаторов.
CREATE TABLE IF NOT EXISTS admin_deletions (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    kind         text        NOT NULL CHECK (kind IN ('network', 'store')),
    target_id    uuid        NOT NULL,
    name         text        NOT NULL,
    network_id   uuid        NOT NULL,
    network_name text        NOT NULL,
    -- Сколько строк удалено по таблицам и у скольких чужих строк обнулена
    -- ссылка (например, «предложила сеть» у одобренных товаров).
    deleted      jsonb       NOT NULL DEFAULT '{}',
    detached     jsonb       NOT NULL DEFAULT '{}',
    -- Деньги на балансе сети в момент удаления (только для сети).
    balance      numeric(18,2) NOT NULL DEFAULT 0,
    -- Копия денежной истории на момент удаления: платежи покупателей (для
    -- сверки с Payme/Click), выплаты, счета за подписку, баланс, долги.
    money        jsonb       NOT NULL DEFAULT '{}',
    deleted_by   uuid        REFERENCES users (id) ON DELETE SET NULL,
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS admin_deletions_created_idx ON admin_deletions (created_at DESC);

-- Расход агента магазину (shipment) остаётся в истории агента, даже если
-- супер-админ удалил сеть магазина: тогда to_store_id обнуляется. Магазин-
-- получатель по-прежнему бывает только у расхода.
ALTER TABLE stock_documents DROP CONSTRAINT IF EXISTS stock_documents_shipment_store;
ALTER TABLE stock_documents ADD CONSTRAINT stock_documents_shipment_store CHECK (to_store_id IS NULL OR type = 'shipment');
