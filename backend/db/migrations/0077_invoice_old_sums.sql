-- Накладные, распознанные до 0075 (сумма строки не сохранялась): если строка
-- одна, её сумма — «Итого» накладной. Пересчитываем упаковку по сумме, как
-- invoices.GuessPack: 1 коробка × 30 450 за кг при «Итого» 365 400 → 12 кг.
WITH one AS (
    SELECT l.scan_id, l.line, s.invoice_total AS total, l.qty, l.price,
           COALESCE(u.is_fractional, false) AS fractional
    FROM invoice_scan_lines l
    JOIN invoice_scans s ON s.id = l.scan_id
    LEFT JOIN products p ON p.id = l.product_id
    LEFT JOIN units u ON u.id = p.unit_id
    WHERE s.status = 'ready' AND l.read_sum IS NULL AND s.invoice_total > 0
      AND (SELECT count(*) FROM invoice_scan_lines x WHERE x.scan_id = l.scan_id) = 1
), r AS (
    SELECT *, CASE WHEN qty > 0 AND price > 0 THEN total / (qty * price) END AS ratio FROM one
), packed AS (
    SELECT *, CASE
                  WHEN ratio IS NULL OR ratio <= 1.05 OR ratio > 1000 THEN 1
                  WHEN fractional THEN round(ratio, 3)
                  WHEN round(ratio) >= 2 AND abs(ratio - round(ratio)) / round(ratio) <= 0.03 THEN round(ratio)
                  ELSE 1
              END AS new_pack
    FROM r
)
UPDATE invoice_scan_lines l
SET read_sum = p.total,
    pack = p.new_pack,
    pack_source = CASE WHEN p.new_pack <> 1 THEN 'sum' ELSE l.pack_source END,
    cost = CASE WHEN p.qty > 0 THEN round(p.total / (p.qty * p.new_pack), 2) ELSE l.cost END
FROM packed p
WHERE l.scan_id = p.scan_id AND l.line = p.line;
