-- Новый дизайн приложения покупателя:
--  * картинки категорий (плитки каталога);
--  * имя и фамилия отдельно, дата рождения и пол (экран «Как вас зовут?»);
--  * время согласия с офертой;
--  * история уведомлений в приложении (колокольчик) — отметка «прочитано».

ALTER TABLE categories
    ADD COLUMN image_url text NOT NULL DEFAULT '' CHECK (length(image_url) <= 1000);

ALTER TABLE customers
    ADD COLUMN first_name        text NOT NULL DEFAULT '' CHECK (length(first_name) <= 60),
    ADD COLUMN last_name         text NOT NULL DEFAULT '' CHECK (length(last_name) <= 60),
    ADD COLUMN birth_date        date CHECK (birth_date IS NULL OR birth_date BETWEEN DATE '1900-01-01' AND DATE '2100-01-01'),
    ADD COLUMN gender            text NOT NULL DEFAULT '' CHECK (gender IN ('', 'male', 'female')),
    ADD COLUMN terms_accepted_at timestamptz;

-- Имя и фамилия из уже заполненного полного имени: первое слово — имя.
UPDATE customers c SET
    first_name = left(split_part(btrim(u.full_name), ' ', 1), 60),
    last_name  = left(btrim(substr(btrim(u.full_name), length(split_part(btrim(u.full_name), ' ', 1)) + 1)), 60)
FROM users u WHERE u.id = c.user_id AND btrim(u.full_name) <> '';

ALTER TABLE notifications_outbox ADD COLUMN read_at timestamptz;
CREATE INDEX notifications_outbox_unread_idx ON notifications_outbox (user_id) WHERE read_at IS NULL;
