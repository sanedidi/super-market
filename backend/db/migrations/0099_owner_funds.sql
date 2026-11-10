-- Оплата поставщику своими деньгами владельца (Figma «Правки 10 нояб» Б4).
-- Деньги проходят через главную кассу сети: приход от владельца и сразу
-- расход поставщику — остаток кассы не меняется. «Вернуть мне позже» —
-- приход от контрагента-владельца: магазин должен владельцу (виден в долгах).
ALTER TABLE counterparties ADD COLUMN IF NOT EXISTS is_owner boolean NOT NULL DEFAULT false;
CREATE UNIQUE INDEX IF NOT EXISTS counterparties_owner_uq ON counterparties (network_id) WHERE is_owner;

