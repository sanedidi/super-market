-- Финансы понятно (Figma «SM Магазин · Финансы понятно», Ф1–Ф4, П1).
--
-- Касса магазина — это наличные в ящике. Раньше «Терминал» поступал в ту же
-- кассу, и «Остаток в кассе» был наличные + терминал без размена. Теперь у
-- каждого магазина вторая касса — «Терминал (банк)»: деньги по карте и QR
-- уходят на счёт, в ящик не попадают и не сдаются.

ALTER TABLE cashboxes
    ADD COLUMN kind text NOT NULL DEFAULT 'cash' CHECK (kind IN ('cash', 'bank'));

INSERT INTO cashboxes (network_id, store_id, name, kind)
SELECT s.network_id, s.id, 'Терминал (банк) · ' || s.name, 'bank'
FROM stores s
WHERE EXISTS (SELECT 1 FROM cashboxes c JOIN payment_methods m ON m.cashbox_id = c.id
              WHERE c.store_id = s.id AND c.currency = 'UZS' AND m.kind IN ('card', 'qr'));

-- Продажи по карте и QR после последней сдачи кассы — в банк (раньше их
-- нельзя трогать: сдачи уже забрали их из кассы магазина).
WITH bank AS (
    SELECT c.id, c.store_id FROM cashboxes c WHERE c.kind = 'bank'
), moved AS (
    SELECT e.id AS entry_id, sp.sale_id, sp.payment_method_id, b.id AS bank_id
    FROM cash_entries e
    JOIN cashboxes c ON c.id = e.cashbox_id AND c.kind = 'cash' AND c.store_id IS NOT NULL
    JOIN bank b ON b.store_id = c.store_id
    JOIN sale_payments sp ON sp.sale_id = e.doc_id AND sp.cashbox_id = e.cashbox_id AND sp.amount = e.amount
    JOIN payment_methods m ON m.id = sp.payment_method_id AND m.kind IN ('card', 'qr')
    WHERE e.doc_type = 'sale'
      AND e.created_at > COALESCE((SELECT max(t.created_at) FROM cash_transfers t WHERE t.from_id = c.id), '-infinity')
      -- Тот же чек и та же сумма наличными — не угадать, какая проводка чья.
      AND NOT EXISTS (SELECT 1 FROM sale_payments sp2 JOIN payment_methods m2 ON m2.id = sp2.payment_method_id
                      WHERE sp2.sale_id = sp.sale_id AND sp2.amount = sp.amount AND m2.kind NOT IN ('card', 'qr'))
), upd AS (
    UPDATE cash_entries e SET cashbox_id = moved.bank_id FROM moved WHERE e.id = moved.entry_id RETURNING e.id
)
UPDATE sale_payments sp SET cashbox_id = moved.bank_id
FROM moved WHERE sp.sale_id = moved.sale_id AND sp.payment_method_id = moved.payment_method_id;

UPDATE payment_methods m SET cashbox_id = b.id
FROM cashboxes c, cashboxes b
WHERE m.cashbox_id = c.id AND c.kind = 'cash' AND c.store_id IS NOT NULL AND c.currency = 'UZS'
  AND b.kind = 'bank' AND b.store_id = c.store_id AND m.kind IN ('card', 'qr');

-- Сдача кассы: сколько оставили в ящике на размен и недостача (плюс —
-- не хватило, минус — лишнее) при пересчёте.
ALTER TABLE cash_transfers
    ADD COLUMN left_amount numeric(18,2) CHECK (left_amount >= 0),
    ADD COLUMN shortage    numeric(18,2);
