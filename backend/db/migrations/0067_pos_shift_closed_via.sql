-- Откуда закрыта смена кассы (Figma «Касса · «Не принято N» и зависшая смена
-- на сервере», «Панель · Смены — закрыть зависшую смену»):
--   pos       — кассир закрыл смену на кассе (Z-отчёт);
--   pos_stale — касса закрыла свою старую смену, которая осталась открытой на
--               сервере (Z-отчёт не дошёл); сумма в ящике — по расчёту;
--   panel     — владелец закрыл смену в панели магазина.
ALTER TABLE pos_shifts ADD COLUMN IF NOT EXISTS closed_via text
    CHECK (closed_via IN ('pos', 'pos_stale', 'panel'));

UPDATE pos_shifts SET closed_via = 'pos' WHERE closed_at IS NOT NULL AND closed_via IS NULL;
