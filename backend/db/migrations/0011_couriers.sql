-- Этап приложения 4: курьеры магазина и отслеживание заказа.

-- Курьер — сотрудник с правом orders.deliver. Здесь его транспорт, смена и
-- последняя точка (храним только последнюю; при доставке точка не нужна
-- покупателю и перестаёт показываться).
CREATE TABLE couriers (
    employee_id  uuid        PRIMARY KEY REFERENCES employees (id) ON DELETE CASCADE,
    network_id   uuid        NOT NULL REFERENCES networks (id),
    vehicle      text        NOT NULL DEFAULT 'foot' CHECK (vehicle IN ('foot', 'bike', 'scooter', 'car')),
    on_shift     boolean     NOT NULL DEFAULT false,
    location     geography(Point, 4326),
    accuracy_m   int,
    heading      int CHECK (heading BETWEEN 0 AND 359),
    located_at   timestamptz,
    updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX couriers_network_idx ON couriers (network_id);

-- Курьер заказа и ожидаемое время прибытия.
ALTER TABLE orders
    ADD COLUMN courier_id  uuid REFERENCES employees (id),
    ADD COLUMN assigned_at timestamptz,
    ADD COLUMN picked_up_at timestamptz,
    ADD COLUMN eta_at      timestamptz;
CREATE INDEX orders_courier_idx ON orders (courier_id, status) WHERE courier_id IS NOT NULL;
