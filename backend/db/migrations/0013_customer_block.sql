-- Супер-админ может заблокировать покупателя: он не входит в приложение
-- заново и не оформляет заказы; причина видна в админке.

ALTER TABLE customers
    ADD COLUMN blocked_at     timestamptz,
    ADD COLUMN blocked_reason text NOT NULL DEFAULT '' CHECK (length(blocked_reason) <= 500);

CREATE INDEX customers_created_idx ON customers (created_at DESC);
CREATE INDEX notifications_outbox_status_idx ON notifications_outbox (status, created_at DESC);
