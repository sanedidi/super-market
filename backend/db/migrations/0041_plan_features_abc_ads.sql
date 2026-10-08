-- Отдельные функции тарифа: ABC/XYZ-анализ (раньше входил в «Расширенные
-- отчёты») и «Реклама брендов» (страница рекламы в панели магазина: доля
-- с рекламы и настройки). ABC/XYZ получают все тарифы, где были
-- расширенные отчёты; рекламу брендов — «Бизнес» и «Сеть». Дальше —
-- галочками у супер-админа.
UPDATE plans SET features = features || '{abc_xyz}', updated_at = now()
WHERE 'reports_pro' = ANY (features) AND NOT 'abc_xyz' = ANY (features);

UPDATE plans SET features = features || '{brand_ads}', updated_at = now()
WHERE key IN ('business', 'network') AND NOT 'brand_ads' = ANY (features);
