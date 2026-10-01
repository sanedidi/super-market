-- ВРЕМЕННО: оплата наличными курьеру, пока Payme и Click не подключены.
-- Убрать вместе с кодом (поиск: CashOnDelivery) — см. docs/progress.md.
ALTER TABLE orders DROP CONSTRAINT IF EXISTS orders_payment_provider_check;
ALTER TABLE orders ADD CONSTRAINT orders_payment_provider_check
    CHECK (payment_provider IN ('payme', 'click', 'cash'));
