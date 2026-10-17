-- Посетители страницы invest.super-market.uz (Figma «Супер-админ · Инвест-страница»).
-- Посетитель — браузер со случайным номером из localStorage, без личных данных.
-- Визит — сигналы подряд без перерыва дольше 30 минут.

CREATE TABLE invest_visitors (
    id          text        PRIMARY KEY CHECK (id ~ '^[A-Za-z0-9]{8,64}$'),
    first_seen  timestamptz NOT NULL DEFAULT now(),
    last_seen   timestamptz NOT NULL DEFAULT now(),
    visits      int         NOT NULL DEFAULT 1
);
CREATE INDEX invest_visitors_first_idx ON invest_visitors (first_seen);

CREATE TABLE invest_visits (
    id          bigserial   PRIMARY KEY,
    visitor_id  text        NOT NULL REFERENCES invest_visitors (id) ON DELETE CASCADE,
    -- Первый визит этого посетителя.
    is_new      boolean     NOT NULL,
    started_at  timestamptz NOT NULL DEFAULT now(),
    last_seen   timestamptz NOT NULL DEFAULT now(),
    pings       int         NOT NULL DEFAULT 1,
    -- phone / tablet / computer и подпись «iPhone · Safari».
    kind        text        NOT NULL DEFAULT 'computer',
    device      text        NOT NULL DEFAULT '',
    -- Telegram, WhatsApp, Instagram, «Прямая ссылка» или сайт.
    source      text        NOT NULL DEFAULT ''
);
CREATE INDEX invest_visits_visitor_idx ON invest_visits (visitor_id, last_seen DESC);
CREATE INDEX invest_visits_started_idx ON invest_visits (started_at DESC);
CREATE INDEX invest_visits_last_idx ON invest_visits (last_seen DESC);
