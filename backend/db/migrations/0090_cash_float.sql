-- Касса не копит деньги (Figma «SM Магазин · Касса: норма размена, «К сдаче»
-- → «Принято», разовый пересчёт ящика» М1–М6 и «Касса · «Закрыть день»
-- оставляет размен по норме…» ЗД6–ЗД7).
--
-- Раньше «Закрыть день» без пересчёта переносил весь остаток ящика в размен
-- нового дня, а владелец забирал деньги без «Сдать кассу» — «размен» рос
-- без конца. Теперь у магазина своя норма размена: при закрытии дня в ящике
-- остаётся норма, остальное — «К сдаче» владельцу (кассир кладёт в конверт),
-- владелец в «SM Магазин» нажимает «Принял».

-- Настройки магазин задаёт сам — значений по умолчанию нет:
--   cash_float          — норма размена; NULL — не задана, в ящике остаётся всё (как раньше);
--   recount_every_days  — пересчёт ящика при «Закрыть день»: NULL — не требовать,
--                         1 — каждый день, 7 — раз в 7 дней;
--   handover_remind     — уведомление владельцу в 21:00, если есть «К сдаче».
ALTER TABLE stores
    ADD COLUMN IF NOT EXISTS cash_float          numeric(18,2) CHECK (cash_float >= 0),
    ADD COLUMN IF NOT EXISTS recount_every_days  int CHECK (recount_every_days IN (1, 7)),
    ADD COLUMN IF NOT EXISTS handover_remind     boolean NOT NULL DEFAULT true,
    ADD COLUMN IF NOT EXISTS handover_reminded_on date;

-- «К сдаче»: закрыли день — сколько отложили владельцу. accepted_at — владелец
-- принял (received — сколько получил, shortage — недостача: плюс — не
-- хватило, минус — лишнее), transfer_id — сдача кассы в главную кассу.
CREATE TABLE IF NOT EXISTS pending_handovers (
    id          uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id  uuid          NOT NULL REFERENCES networks (id) ON DELETE CASCADE,
    store_id    uuid          NOT NULL REFERENCES stores (id) ON DELETE CASCADE,
    cashbox_id  uuid          NOT NULL REFERENCES cashboxes (id) ON DELETE CASCADE,
    shift_id    uuid          NOT NULL UNIQUE REFERENCES pos_shifts (id) ON DELETE CASCADE,
    amount      numeric(18,2) NOT NULL CHECK (amount > 0),
    left_amount numeric(18,2) NOT NULL DEFAULT 0 CHECK (left_amount >= 0),
    created_at  timestamptz   NOT NULL DEFAULT now(),
    accepted_at timestamptz,
    accepted_by uuid          REFERENCES employees (id) ON DELETE SET NULL,
    received    numeric(18,2) CHECK (received >= 0),
    shortage    numeric(18,2),
    transfer_id uuid          REFERENCES cash_transfers (id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS pending_handovers_open_idx ON pending_handovers (store_id) WHERE accepted_at IS NULL;
CREATE INDEX IF NOT EXISTS pending_handovers_store_idx ON pending_handovers (store_id, created_at DESC);
