-- Касса (POS): устройства, ПИН кассиров, смены и наличные в ящике,
-- данные товара для налоговой (ИКПУ, НДС, маркировка), PLU, продажи с кассы.

-------------------------------------------------------------- товары

ALTER TABLE products
    ADD COLUMN ikpu         text         NOT NULL DEFAULT '' CHECK (ikpu = '' OR ikpu ~ '^[0-9]{17}$'),
    ADD COLUMN package_code text         NOT NULL DEFAULT '' CHECK (length(package_code) <= 20),
    ADD COLUMN vat_rate     numeric(5,2) NOT NULL DEFAULT 12 CHECK (vat_rate >= 0 AND vat_rate <= 100),
    ADD COLUMN is_marked    boolean      NOT NULL DEFAULT false;

-- Смена штрихкодов меняет товар для кассы: каталог кассы выгружается по updated_at.
CREATE FUNCTION touch_product_from_barcode() RETURNS trigger AS $$
BEGIN
    UPDATE products SET updated_at = now() WHERE id = COALESCE(NEW.product_id, OLD.product_id);
    IF TG_OP = 'UPDATE' AND NEW.product_id <> OLD.product_id THEN
        UPDATE products SET updated_at = now() WHERE id = OLD.product_id;
    END IF;
    RETURN NULL;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER product_barcodes_touch AFTER INSERT OR UPDATE OR DELETE ON product_barcodes
    FOR EACH ROW EXECUTE FUNCTION touch_product_from_barcode();

-- Короткий код товара без штрихкода (хлеб — 1, бананы — 10) в сети.
-- Строка не удаляется: снятый код — plu = NULL, чтобы касса узнала об этом.
CREATE TABLE pos_plu (
    network_id uuid        NOT NULL REFERENCES networks (id),
    product_id uuid        NOT NULL REFERENCES products (id),
    plu        int         CHECK (plu BETWEEN 1 AND 99999),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (network_id, product_id)
);
CREATE UNIQUE INDEX pos_plu_code_idx ON pos_plu (network_id, plu) WHERE plu IS NOT NULL;
CREATE TRIGGER pos_plu_updated_at BEFORE UPDATE ON pos_plu FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Префиксы весовых штрихкодов (EAN-13: ПП КККККК ВВВВВ К — код и вес в граммах).
ALTER TABLE networks
    ADD COLUMN pos_weight_prefixes text[] NOT NULL DEFAULT '{22}',
    ADD COLUMN receipt_header      text   NOT NULL DEFAULT '' CHECK (length(receipt_header) <= 500),
    ADD COLUMN receipt_footer      text   NOT NULL DEFAULT '' CHECK (length(receipt_footer) <= 500);

-------------------------------------------------------- способы оплаты

-- Вид оплаты: кассе нужен для клавиш (Enter — наличные, * — карта, / — QR)
-- и для подсчёта наличных в ящике.
ALTER TABLE payment_methods
    ADD COLUMN kind text NOT NULL DEFAULT 'other' CHECK (kind IN ('cash', 'card', 'qr', 'other'));
UPDATE payment_methods SET kind = 'cash' WHERE name ILIKE 'налич%';
UPDATE payment_methods SET kind = 'card' WHERE name ILIKE 'терминал%' OR name ILIKE 'карт%';
UPDATE payment_methods SET kind = 'qr'   WHERE name ILIKE '%payme%' OR name ILIKE '%click%';

------------------------------------------------------------ сотрудники

-- ПИН кассира: хеш выгружается на кассу для входа без интернета, поэтому
-- защиту даёт токен устройства, а не стойкость хеша к перебору.
ALTER TABLE employees
    ADD COLUMN pin_hash         text        NOT NULL DEFAULT '',
    ADD COLUMN pin_failed       int         NOT NULL DEFAULT 0,
    ADD COLUMN pin_locked_until timestamptz;

----------------------------------------------------------- устройства

CREATE TABLE pos_devices (
    id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id         uuid        NOT NULL,
    store_id           uuid        NOT NULL,
    name               text        NOT NULL CHECK (btrim(name) <> '' AND length(name) <= 60),
    -- Код активации (хеш) живёт сутки; после активации обнуляется.
    activation_hash    bytea,
    activation_expires timestamptz,
    token_hash         bytea       UNIQUE,
    activated_at       timestamptz,
    last_seen_at       timestamptz,
    app_version        text        NOT NULL DEFAULT '',
    revoked_at         timestamptz,
    created_at         timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (store_id, network_id) REFERENCES stores (id, network_id),
    UNIQUE (id, network_id)
);
CREATE INDEX pos_devices_store_idx ON pos_devices (store_id);
CREATE UNIQUE INDEX pos_devices_activation_idx ON pos_devices (activation_hash) WHERE activation_hash IS NOT NULL;

--------------------------------------------------------------- смены

CREATE TABLE pos_shifts (
    id            uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id    uuid          NOT NULL,
    store_id      uuid          NOT NULL,
    device_id     uuid          NOT NULL,
    number        bigint        NOT NULL,
    client_uid    text          NOT NULL CHECK (length(client_uid) BETWEEN 8 AND 64),
    opened_by     uuid          NOT NULL REFERENCES employees (id),
    opened_at     timestamptz   NOT NULL,
    opening_cash  numeric(18,2) NOT NULL CHECK (opening_cash >= 0),
    closed_by     uuid          REFERENCES employees (id),
    closed_at     timestamptz,
    expected_cash numeric(18,2),
    counted_cash  numeric(18,2) CHECK (counted_cash >= 0),
    diff          numeric(18,2),
    diff_reason   text          NOT NULL DEFAULT '' CHECK (length(diff_reason) <= 300),
    created_at    timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (network_id, number),
    UNIQUE (network_id, client_uid),
    FOREIGN KEY (store_id, network_id) REFERENCES stores (id, network_id),
    FOREIGN KEY (device_id, network_id) REFERENCES pos_devices (id, network_id),
    UNIQUE (id, network_id)
);
-- На одной кассе открыта не больше чем одна смена.
CREATE UNIQUE INDEX pos_shifts_open_idx ON pos_shifts (device_id) WHERE closed_at IS NULL;
CREATE INDEX pos_shifts_store_idx ON pos_shifts (store_id, opened_at DESC);

-- Внесение и изъятие наличных из ящика кассы.
CREATE TABLE pos_cash_moves (
    id         uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id uuid          NOT NULL,
    shift_id   uuid          NOT NULL,
    client_uid text          NOT NULL CHECK (length(client_uid) BETWEEN 8 AND 64),
    kind       text          NOT NULL CHECK (kind IN ('in', 'out')),
    amount     numeric(18,2) NOT NULL CHECK (amount > 0),
    reason     text          NOT NULL DEFAULT '' CHECK (length(reason) <= 200),
    created_by uuid          NOT NULL REFERENCES employees (id),
    created_at timestamptz   NOT NULL,
    UNIQUE (network_id, client_uid),
    FOREIGN KEY (shift_id, network_id) REFERENCES pos_shifts (id, network_id)
);
CREATE INDEX pos_cash_moves_shift_idx ON pos_cash_moves (shift_id);

------------------------------------------------------------- продажи

ALTER TABLE sales
    ADD COLUMN device_id     uuid,
    ADD COLUMN shift_id      uuid,
    ADD COLUMN fiscal_qr     text NOT NULL DEFAULT '' CHECK (length(fiscal_qr) <= 500),
    ADD COLUMN fiscal_module text NOT NULL DEFAULT '' CHECK (length(fiscal_module) <= 64),
    ADD CONSTRAINT sales_device_fk FOREIGN KEY (device_id, network_id) REFERENCES pos_devices (id, network_id),
    ADD CONSTRAINT sales_shift_fk FOREIGN KEY (shift_id, network_id) REFERENCES pos_shifts (id, network_id);
CREATE INDEX sales_shift_idx ON sales (shift_id) WHERE shift_id IS NOT NULL;

ALTER TABLE sale_items
    -- Коды маркировки DataMatrix, по одному на штуку.
    ADD COLUMN marking_codes text[]        NOT NULL DEFAULT '{}',
    -- Продано с кассы без интернета больше, чем было на складе: себестоимость
    -- этой части неизвестна (0), остаток надо поправить приходом.
    ADD COLUMN short_qty     numeric(14,3) NOT NULL DEFAULT 0 CHECK (short_qty >= 0);

ALTER TABLE customer_returns
    ADD COLUMN device_id uuid,
    ADD COLUMN shift_id  uuid,
    ADD CONSTRAINT customer_returns_device_fk FOREIGN KEY (device_id, network_id) REFERENCES pos_devices (id, network_id),
    ADD CONSTRAINT customer_returns_shift_fk FOREIGN KEY (shift_id, network_id) REFERENCES pos_shifts (id, network_id);
CREATE INDEX customer_returns_shift_idx ON customer_returns (shift_id) WHERE shift_id IS NOT NULL;
