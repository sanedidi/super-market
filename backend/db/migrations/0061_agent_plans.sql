-- Отдельная подписка для агентов («SM Агент»): тарифы с аудиторией
-- agent, свой тариф и пробный период новых агентов в настройках биллинга.
-- Цену, функции и пробный срок задаёт супер-админ.

ALTER TABLE plans
    ADD COLUMN audience text NOT NULL DEFAULT 'store' CHECK (audience IN ('store', 'agent'));

-- Тариф агента по умолчанию: все функции «Бизнеса» (склад, приход/расход,
-- инвентаризация), цена 0 — пока супер-админ не задаст свою.
INSERT INTO plans (key, name, name_uz, description, description_uz, price_uzs, min_stores, order_commission,
                   features, limits, is_public, recommended, sort, audience)
SELECT 'agent', 'Агент', 'Agent',
       'Подписка агента: магазины, заказы, склад, оплаты и акт сверки.',
       'Agent obunasi: doʻkonlar, buyurtmalar, ombor, toʻlovlar va solishtirma dalolatnoma.',
       0, 1, 0, b.features, b.limits - 'staff' - 'stores', true, true,
       COALESCE((SELECT max(sort) + 1 FROM plans), 0), 'agent'
FROM plans b WHERE b.key = 'business'
ON CONFLICT (key) DO NOTHING;

-- На случай базы без «Бизнеса».
INSERT INTO plans (key, name, name_uz, recommended, audience)
VALUES ('agent', 'Агент', 'Agent', true, 'agent')
ON CONFLICT (key) DO NOTHING;

ALTER TABLE billing_settings
    ADD COLUMN agent_plan       text NOT NULL DEFAULT 'agent' REFERENCES plans (key),
    ADD COLUMN agent_trial_days int  NOT NULL DEFAULT 30 CHECK (agent_trial_days BETWEEN 0 AND 365);

-- Агенты, созданные раньше, — на тариф агента.
UPDATE networks SET plan_key = 'agent' WHERE kind = 'distributor';

-- Действующий тариф: у агента пробный период — бесплатный срок на его же
-- тарифе (тариф пробного периода магазинов к агентам не относится).
CREATE OR REPLACE FUNCTION network_plan(nid uuid) RETURNS text
    LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN n.kind <> 'distributor' AND n.plan_trial_until >= (now() AT TIME ZONE 'Asia/Tashkent')::date
             AND tp.sort > cp.sort THEN tp.key
        ELSE cp.key
    END
    FROM networks n
    JOIN plans cp ON cp.key = n.plan_key
    CROSS JOIN billing_settings bs
    JOIN plans tp ON tp.key = bs.trial_plan
    WHERE n.id = nid
$$;

-- «Не получал» и магазин согласился: оплата отменена, деньги вернулись в кассу.
ALTER TABLE supply_payments DROP CONSTRAINT supply_payments_status_check;
ALTER TABLE supply_payments ADD CONSTRAINT supply_payments_status_check
    CHECK (status IN ('pending', 'confirmed', 'disputed', 'cancelled'));
