-- «Хочу доставку»: покупатель отмечает магазин рядом, который ему не доставляет.
-- Это голос, а не заказ: один на магазин; точка адреса — чтобы магазин видел,
-- далеко ли до тех, кто ждёт доставку (и вне ли они зоны доставки).

CREATE TABLE delivery_wishes (
    store_id   uuid                   NOT NULL REFERENCES stores (id) ON DELETE CASCADE,
    user_id    uuid                   NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    location   geography(Point, 4326) NOT NULL,
    created_at timestamptz            NOT NULL DEFAULT now(),
    updated_at timestamptz            NOT NULL DEFAULT now(),
    PRIMARY KEY (store_id, user_id)
);
CREATE INDEX delivery_wishes_store_idx ON delivery_wishes (store_id, created_at DESC);
CREATE INDEX delivery_wishes_user_idx ON delivery_wishes (user_id);
