-- Чек возврата с кассы: QR и номер фискального модуля, как у продажи.
ALTER TABLE customer_returns
    ADD COLUMN fiscal_qr     text NOT NULL DEFAULT '' CHECK (length(fiscal_qr) <= 500),
    ADD COLUMN fiscal_module text NOT NULL DEFAULT '' CHECK (length(fiscal_module) <= 64);
