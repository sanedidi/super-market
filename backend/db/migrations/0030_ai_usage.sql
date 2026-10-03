-- Расход ИИ: токены каждого запроса и их стоимость (Figma «Админка · ИИ-сервис» → А3).

-- Цена токенов из прайса сервиса: за 1 млн токенов на вход и на выход,
-- в валюте цены; rate_uzs — сколько сумов в 1 единице этой валюты.
ALTER TABLE ai_settings
    ADD COLUMN price_in       numeric(14,6) NOT NULL DEFAULT 0 CHECK (price_in >= 0),
    ADD COLUMN price_out      numeric(14,6) NOT NULL DEFAULT 0 CHECK (price_out >= 0),
    ADD COLUMN price_currency text          NOT NULL DEFAULT 'USD' CHECK (price_currency IN ('USD', 'RUB', 'UZS')),
    ADD COLUMN rate_uzs       numeric(14,4) NOT NULL DEFAULT 12650 CHECK (rate_uzs > 0);

-- Один запрос к ИИ. Цена фиксируется в момент запроса: смена цены старое не пересчитывает.
CREATE TABLE ai_usage (
    id            bigserial     PRIMARY KEY,
    at            timestamptz   NOT NULL DEFAULT now(),
    -- invoice — накладная магазина, test — проверка подключения супер-админом.
    kind          text          NOT NULL CHECK (kind IN ('invoice', 'test')),
    network_id    uuid          REFERENCES networks (id),
    store_id      uuid          REFERENCES stores (id),
    employee_id   uuid          REFERENCES employees (id),
    scan_id       uuid          REFERENCES invoice_scans (id) ON DELETE SET NULL,
    provider      text          NOT NULL DEFAULT '',
    model         text          NOT NULL DEFAULT '',
    input_tokens  int           NOT NULL DEFAULT 0 CHECK (input_tokens >= 0),
    output_tokens int           NOT NULL DEFAULT 0 CHECK (output_tokens >= 0),
    ok            boolean       NOT NULL,
    cost          numeric(18,6) NOT NULL DEFAULT 0,
    currency      text          NOT NULL DEFAULT 'USD',
    cost_uzs      numeric(18,2) NOT NULL DEFAULT 0
);
CREATE INDEX ai_usage_at_idx ON ai_usage (at);
CREATE INDEX ai_usage_network_idx ON ai_usage (network_id, at);
