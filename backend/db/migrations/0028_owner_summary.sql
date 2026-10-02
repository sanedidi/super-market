-- Итоги дня владельцу: push каждый вечер в выбранный час (время Ташкента).
-- Нет строки — по умолчанию: владельцу включено в 21:00, остальным с правом «Отчёты» — выключено.
CREATE TABLE owner_summary_settings (
    employee_id uuid        PRIMARY KEY REFERENCES employees (id) ON DELETE CASCADE,
    enabled     boolean     NOT NULL,
    hour        int         NOT NULL DEFAULT 21 CHECK (hour BETWEEN 0 AND 23),
    -- День (по Ташкенту), за который сводка уже отправлена.
    last_sent   date,
    updated_at  timestamptz NOT NULL DEFAULT now()
);
