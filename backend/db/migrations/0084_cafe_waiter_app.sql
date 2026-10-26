-- Кафе, этап 6 (экраны официанта): комментарий к столу и вид бегунка в
-- очереди печати кассы.

-- Комментарий при открытии стола (О5): детский стул, у окна…
ALTER TABLE bills ADD COLUMN comment text NOT NULL DEFAULT '' CHECK (length(comment) <= 200);

-- Что печатать из очереди телефона: send — бегунок отправки (у «по команде» —
-- «пока не готовить»), fire — «ПОДАВАТЬ» после «Подать горячее» с телефона.
ALTER TABLE kitchen_tickets ADD COLUMN print_kind text NOT NULL DEFAULT 'send' CHECK (print_kind IN ('send', 'fire'));
