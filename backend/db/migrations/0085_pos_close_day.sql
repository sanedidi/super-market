-- «Закрыть день» одной кнопкой (Figma «Касса · Закрыть день — одной кнопкой,
-- пересчёт по желанию», ЗД1–ЗД5 и «Логика»). Как закрыта смена:
--   pos       — с кассы, кассир пересчитал ящик;
--   pos_quick — с кассы, без пересчёта: сумма в ящике по расчёту;
--   pos_auto  — касса закрыла вчерашнюю смену сама при «Начать день» (бывший pos_stale);
--   auto      — сервер закрыл смену, открытую дольше 20 часов;
--   panel     — владелец закрыл смену в панели магазина.
ALTER TABLE pos_shifts DROP CONSTRAINT IF EXISTS pos_shifts_closed_via_check;
UPDATE pos_shifts SET closed_via = 'pos_auto' WHERE closed_via = 'pos_stale';
ALTER TABLE pos_shifts ADD CONSTRAINT pos_shifts_closed_via_check
    CHECK (closed_via IN ('pos', 'pos_quick', 'pos_auto', 'auto', 'panel'));

-- «Требовать пересчёт при закрытии дня» (панель → Касса → Настройки). По
-- умолчанию выключено: день закрывается одной кнопкой, по расчёту.
ALTER TABLE networks ADD COLUMN IF NOT EXISTS pos_require_recount boolean NOT NULL DEFAULT false;
