-- Помощник — чат с владельцем в панели магазина (тест; Figma «Super Market ·
-- Помощник», страница «Веб-панель · тест», П1–П3). Владелец пишет, говорит
-- или прикрепляет накладную; помощник отвечает и делает приход, показывает
-- остатки, подсказывает, что заказать, — через те же сервисы, что и панель.

CREATE TABLE assistant_messages (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id  uuid        NOT NULL REFERENCES networks (id) ON DELETE CASCADE,
    store_id    uuid        NOT NULL REFERENCES stores (id) ON DELETE CASCADE,
    employee_id uuid        NOT NULL REFERENCES employees (id) ON DELETE CASCADE,
    -- owner — владелец, assistant — помощник, system — строка «сделано»
    -- (журнал действий помощника).
    role        text        NOT NULL CHECK (role IN ('owner', 'assistant', 'system')),
    -- text, audio, image, action (нажата кнопка), done (действие выполнено), error.
    kind        text        NOT NULL DEFAULT 'text',
    text        text        NOT NULL DEFAULT '',
    -- Расшифровка голосового (у owner/audio), появляется после ответа модели.
    transcript  text,
    lang        text        NOT NULL DEFAULT '',
    images      text[]      NOT NULL DEFAULT '{}',
    -- Что показать кроме текста: кнопки, карточки, таблицы, ссылки (см. assistant.Block).
    blocks      jsonb       NOT NULL DEFAULT '[]',
    status      text        NOT NULL DEFAULT 'done' CHECK (status IN ('pending', 'done', 'failed')),
    scan_id     uuid        REFERENCES invoice_scans (id) ON DELETE SET NULL,
    intent      text        NOT NULL DEFAULT '',
    args        jsonb       NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX assistant_messages_chat ON assistant_messages (store_id, employee_id, created_at);

-- Состояние чата: накладная, над которой сейчас работаем.
CREATE TABLE assistant_chats (
    store_id    uuid        NOT NULL REFERENCES stores (id) ON DELETE CASCADE,
    employee_id uuid        NOT NULL REFERENCES employees (id) ON DELETE CASCADE,
    scan_id     uuid        REFERENCES invoice_scans (id) ON DELETE SET NULL,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (store_id, employee_id)
);

ALTER TABLE ai_usage DROP CONSTRAINT IF EXISTS ai_usage_kind_check;
ALTER TABLE ai_usage ADD CONSTRAINT ai_usage_kind_check
    CHECK (kind IN ('invoice', 'test', 'shelf', 'translate', 'category', 'product', 'variants', 'photo', 'photo_test', 'photo_store', 'assistant'));
