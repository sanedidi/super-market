-- Дистрибьюторы (Figma «SM Дистрибьютор · приложение»).
--
-- Дистрибьютор — это сеть вида distributor с одной точкой (склад-магазин,
-- как у одиночного магазина): те же товары («Начало работы»), склад,
-- приход, инвентаризация, списание. Его «цена продажи» — отпускная цена для
-- магазинов (тип цен по умолчанию). Покупатели его точку не видят.
--
-- Магазин и дистрибьютор связываются (supply_links): по коду на месте или по
-- запросу одной из сторон, вторая подтверждает. Только после связи
-- дистрибьютор видит остатки и продажи СВОИХ товаров в этом магазине, а
-- магазин — прайс дистрибьютора и может отправить ему заказ.
--
-- Заказ поставщику (supply_orders): новый → принят → собран → доставлен
-- (или отклонён / отменён магазином). Доставка = проведённый расход
-- (stock_documents.type = 'shipment') у дистрибьютора; при проведении у
-- магазина появляется черновик прихода «от дистрибьютора», магазин
-- подтверждает его сам. Деньги через платформу не идут.

ALTER TABLE networks DROP CONSTRAINT networks_kind_check;
ALTER TABLE networks ADD CONSTRAINT networks_kind_check CHECK (kind IN ('chain', 'single', 'distributor'));

-- Условия дистрибьютора, которые видят магазины: доставка, минимальный заказ,
-- отсрочка — свободным текстом; срок поставки в днях — для рекомендаций.
ALTER TABLE networks
    ADD COLUMN supply_terms text NOT NULL DEFAULT '' CHECK (length(supply_terms) <= 500),
    ADD COLUMN lead_days    int  NOT NULL DEFAULT 2 CHECK (lead_days BETWEEN 1 AND 30);

-------------------------------------------------------------------- связи

CREATE TABLE supply_links (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id         uuid        NOT NULL,
    store_network_id uuid        NOT NULL,
    distributor_id   uuid        NOT NULL REFERENCES networks (id),
    -- requested — ждёт ответа второй стороны; active — подключены;
    -- rejected — отклонён; disconnected — одна из сторон отключилась.
    status           text        NOT NULL CHECK (status IN ('requested', 'active', 'rejected', 'disconnected')),
    -- Кто сделал последний запрос (или ввёл код): store, distributor, code.
    requested_by     text        NOT NULL CHECK (requested_by IN ('store', 'distributor', 'code')),
    message          text        NOT NULL DEFAULT '' CHECK (length(message) <= 500),
    ended_by         text        NOT NULL DEFAULT '' CHECK (ended_by IN ('', 'store', 'distributor')),
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    accepted_at      timestamptz,
    FOREIGN KEY (store_id, store_network_id) REFERENCES stores (id, network_id) ON DELETE CASCADE,
    UNIQUE (store_id, distributor_id),
    CHECK (store_network_id <> distributor_id)
);
CREATE INDEX supply_links_distributor_idx ON supply_links (distributor_id, status);
CREATE INDEX supply_links_store_idx ON supply_links (store_id, status);
CREATE TRIGGER supply_links_updated_at BEFORE UPDATE ON supply_links FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Код «Договориться на месте»: дистрибьютор показывает его в магазине,
-- владелец вводит в «SM Магазин» — связь сразу активна. 4 цифры, 10 минут.
CREATE TABLE supply_link_codes (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    distributor_id uuid        NOT NULL REFERENCES networks (id),
    store_id       uuid        NOT NULL REFERENCES stores (id) ON DELETE CASCADE,
    code           text        NOT NULL CHECK (code ~ '^[0-9]{4}$'),
    created_by     uuid        NOT NULL REFERENCES employees (id),
    expires_at     timestamptz NOT NULL,
    used_at        timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX supply_link_codes_store_idx ON supply_link_codes (store_id, code) WHERE used_at IS NULL;

-- Контрагент, заведённый автоматически для второй стороны:
--   у магазина — дистрибьютор (приходы от него, долг ему);
--   у дистрибьютора — магазин (расходы ему, его долг).
ALTER TABLE counterparties
    ADD COLUMN distributor_id uuid REFERENCES networks (id),
    ADD COLUMN store_id       uuid REFERENCES stores (id);
CREATE UNIQUE INDEX counterparties_distributor_uniq ON counterparties (network_id, distributor_id) WHERE distributor_id IS NOT NULL;
CREATE UNIQUE INDEX counterparties_store_uniq ON counterparties (network_id, store_id) WHERE store_id IS NOT NULL;

------------------------------------------------------------------- заказы

CREATE TABLE supply_orders (
    id               uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Нумерация — у дистрибьютора (network_id = дистрибьютор).
    network_id       uuid          NOT NULL REFERENCES networks (id),
    number           bigint        NOT NULL,
    link_id          uuid          NOT NULL REFERENCES supply_links (id),
    store_id         uuid          NOT NULL REFERENCES stores (id),
    store_network_id uuid          NOT NULL REFERENCES networks (id),
    store_number     bigint        NOT NULL,
    status           text          NOT NULL DEFAULT 'new'
                     CHECK (status IN ('new', 'accepted', 'assembled', 'delivered', 'rejected', 'cancelled')),
    deliver_by       date,
    note             text          NOT NULL DEFAULT '' CHECK (length(note) <= 500),
    reject_reason    text          NOT NULL DEFAULT '' CHECK (length(reject_reason) <= 500),
    total            numeric(18,2) NOT NULL DEFAULT 0,
    -- Расход дистрибьютора по этому заказу (создаётся при «Собран»).
    shipment_id      uuid          REFERENCES stock_documents (id),
    created_by       uuid          NOT NULL REFERENCES employees (id),
    created_at       timestamptz   NOT NULL DEFAULT now(),
    updated_at       timestamptz   NOT NULL DEFAULT now(),
    accepted_at      timestamptz,
    assembled_at     timestamptz,
    delivered_at     timestamptz,
    UNIQUE (network_id, number),
    UNIQUE (store_network_id, store_number)
);
CREATE INDEX supply_orders_network_idx ON supply_orders (network_id, status, created_at DESC);
CREATE INDEX supply_orders_store_idx ON supply_orders (store_id, created_at DESC);
CREATE TRIGGER supply_orders_updated_at BEFORE UPDATE ON supply_orders FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE supply_order_items (
    order_id   uuid          NOT NULL REFERENCES supply_orders (id) ON DELETE CASCADE,
    line       int           NOT NULL,
    product_id uuid          NOT NULL REFERENCES products (id),
    -- Сколько заказал магазин.
    qty        numeric(14,3) NOT NULL CHECK (qty > 0),
    -- Сколько отгрузит дистрибьютор (может поменять до «Собран»).
    ship_qty   numeric(14,3) NOT NULL CHECK (ship_qty >= 0),
    -- Отпускная цена на момент заказа.
    price      numeric(18,2) NOT NULL CHECK (price >= 0),
    PRIMARY KEY (order_id, line)
);

--------------------------------------------------- расход и приход по нему

ALTER TABLE stock_documents DROP CONSTRAINT stock_documents_type_check;
ALTER TABLE stock_documents ADD CONSTRAINT stock_documents_type_check
    CHECK (type IN ('income', 'supplier_return', 'transfer', 'write_off', 'posting', 'inventory', 'shipment'));

-- shipment — расход дистрибьютора магазину: to_store_id — магазин,
-- counterparty_id — его контрагент у дистрибьютора, цены — отпускные.
-- У прихода магазина, созданного по расходу, source_shipment_id — этот расход.
ALTER TABLE stock_documents
    ADD COLUMN to_store_id        uuid REFERENCES stores (id),
    ADD COLUMN supply_order_id    uuid REFERENCES supply_orders (id),
    ADD COLUMN source_shipment_id uuid REFERENCES stock_documents (id),
    -- Когда магазин провёл приход по этому расходу и сколько штук разошлось
    -- (принято − отгружено; 0 — без расхождений).
    ADD COLUMN received_at        timestamptz,
    ADD COLUMN received_diff      numeric(14,3),
    ADD CONSTRAINT stock_documents_shipment_store CHECK ((type = 'shipment') = (to_store_id IS NOT NULL));
CREATE INDEX stock_documents_to_store_idx ON stock_documents (to_store_id) WHERE to_store_id IS NOT NULL;
CREATE UNIQUE INDEX stock_documents_source_shipment_uniq ON stock_documents (source_shipment_id) WHERE source_shipment_id IS NOT NULL;
