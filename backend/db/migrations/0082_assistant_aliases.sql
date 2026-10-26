-- Помощник: как владелец называет товары («kola» → Coca-Cola 1,5 л, «sut» →
-- молоко Nestle 1 л). Запоминается, когда владелец выбрал товар из
-- нескольких, и подсказывается модели в следующий раз.
CREATE TABLE assistant_aliases (
    network_id uuid        NOT NULL REFERENCES networks (id) ON DELETE CASCADE,
    word       text        NOT NULL CHECK (length(word) BETWEEN 2 AND 60),
    product_id uuid        NOT NULL REFERENCES products (id) ON DELETE CASCADE,
    uses       int         NOT NULL DEFAULT 1,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (network_id, word)
);
