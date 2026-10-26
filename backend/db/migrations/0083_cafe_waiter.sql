-- Кафе, этап 6: официант в телефоне («SM Магазин», право cafe.waiter).

-- Передача стола (О6 → О7): стол остаётся у передающего, пока получатель не
-- примет; не ответил за 3 минуты — предложение считается снятым.
ALTER TABLE bills
    ADD COLUMN transfer_to     uuid        REFERENCES employees (id) ON DELETE SET NULL,
    ADD COLUMN transfer_from   uuid        REFERENCES employees (id) ON DELETE SET NULL,
    ADD COLUMN transfer_reason text        NOT NULL DEFAULT '' CHECK (length(transfer_reason) <= 200),
    ADD COLUMN transfer_at     timestamptz;

-- «Несу»: официант отметил, что блюдо отнесено гостям.
ALTER TABLE bill_items ADD COLUMN served_at timestamptz;

-- Зоны на смену (О8): кто из официантов за какими столами сегодня.
-- Постоянный официант стола (cafe_tables.waiter_id) — значение по умолчанию,
-- запись на день его перекрывает. Уже открытые столы не переезжают.
CREATE TABLE cafe_shift_waiters (
    store_id   uuid NOT NULL REFERENCES stores (id) ON DELETE CASCADE,
    day        date NOT NULL,
    table_id   uuid NOT NULL REFERENCES cafe_tables (id) ON DELETE CASCADE,
    waiter_id  uuid NOT NULL REFERENCES employees (id) ON DELETE CASCADE,
    set_by     uuid REFERENCES employees (id),
    set_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (table_id, day)
);
CREATE INDEX cafe_shift_waiters_store_day_idx ON cafe_shift_waiters (store_id, day);

-- Бегунок цеха без экрана, отправленный с телефона официанта: напечатать
-- должна касса — она узнаёт об этом из /pos/kitchen/status и отмечает
-- напечатанное.
ALTER TABLE kitchen_tickets ADD COLUMN print_pending boolean NOT NULL DEFAULT false;
CREATE INDEX kitchen_tickets_print_pending_idx ON kitchen_tickets (store_id) WHERE print_pending;
