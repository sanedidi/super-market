-- Первая настройка магазина (мастер в панели и «SM Магазин»).
-- hours_set_at — часы работы указаны (пустое расписание = круглосуточно);
-- online_declined_at — магазин выбрал «Пока без доставки».
-- Мастер обязателен, пока в сети нет магазина с точкой на карте и часами работы.

ALTER TABLE stores
    ADD COLUMN hours_set_at       timestamptz,
    ADD COLUMN online_declined_at timestamptz;

-- Уже работающие магазины мастер не проходят.
UPDATE stores SET hours_set_at = now();
UPDATE stores SET online_declined_at = now() WHERE NOT accepts_online;
