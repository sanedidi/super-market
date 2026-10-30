-- Долг вручную (Figma «Приложения» → «SM Магазин · Долг вручную», Р1–Р6):
-- старый долг покупателя (например, из тетради) вносится в «SM Магазин» по
-- номеру, имени и сумме. Касса, остатки и прибыль не меняются — в журнал
-- долга пишется запись doc_type = 'manual'.
CREATE TABLE IF NOT EXISTS debt_manual (
    id         uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id uuid          NOT NULL,
    number     bigint        NOT NULL,
    debtor_id  uuid          NOT NULL,
    store_id   uuid          NOT NULL,
    amount     numeric(18,2) NOT NULL CHECK (amount > 0),
    note       text          NOT NULL DEFAULT '',
    over_limit boolean       NOT NULL DEFAULT false,
    created_by uuid          NOT NULL REFERENCES employees (id),
    created_at timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (network_id, number),
    FOREIGN KEY (debtor_id, network_id) REFERENCES debtors (id, network_id),
    FOREIGN KEY (store_id, network_id) REFERENCES stores (id, network_id)
);
CREATE INDEX IF NOT EXISTS debt_manual_debtor_idx ON debt_manual (debtor_id);

ALTER TABLE debt_entries DROP CONSTRAINT IF EXISTS debt_entries_doc_type_check;
ALTER TABLE debt_entries ADD CONSTRAINT debt_entries_doc_type_check
    CHECK (doc_type IN ('sale', 'payment', 'return', 'writeoff', 'manual'));
