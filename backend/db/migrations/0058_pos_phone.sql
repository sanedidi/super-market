-- Касса в телефоне (Figma «SM Магазин · Касса в телефоне»).
--
-- Телефон сотрудника в приложении «SM Магазин» становится кассой магазина:
-- своя смена (открывается сама), продажи и долги — через API кассы, как на
-- POS. Касса-телефон привязана к сотруднику: продаёт только от его имени,
-- и в лимит касс тарифа не входит (бесплатно).
ALTER TABLE pos_devices ADD COLUMN employee_id uuid REFERENCES employees (id);

-- Один телефон-касса на сотрудника в магазине (повторный вход выдаёт новый токен).
CREATE UNIQUE INDEX pos_devices_phone_idx ON pos_devices (store_id, employee_id)
    WHERE employee_id IS NOT NULL AND revoked_at IS NULL;
