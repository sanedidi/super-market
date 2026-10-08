-- Единые тарифы магазинов: цена в сумах за магазин в месяц, функции и
-- лимиты. Заменяют две старые схемы — подписку по числу магазинов в $
-- (tariffs) и тарифы витрины «Старт / Бизнес / Про» (showcase_plans).
--
-- Какие функции и лимиты бывают — решает код (пакет plans, реестр); какие
-- из них входят в тариф, цены, комиссия и пробный период — супер-админ.

CREATE TABLE plans (
    key              text          PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_]{1,30}$'),
    name             text          NOT NULL CHECK (btrim(name) <> ''),
    name_uz          text          NOT NULL DEFAULT '',
    description      text          NOT NULL DEFAULT '',
    description_uz   text          NOT NULL DEFAULT '',
    -- Цена за один магазин в месяц, сум.
    price_uzs        numeric(18,2) NOT NULL DEFAULT 0 CHECK (price_uzs >= 0),
    -- Тариф можно выбрать только сети, где столько магазинов или больше.
    min_stores       int           NOT NULL DEFAULT 1 CHECK (min_stores >= 1),
    -- Комиссия платформы с оплаченного онлайн-заказа, %.
    order_commission numeric(5,2)  NOT NULL DEFAULT 0 CHECK (order_commission BETWEEN 0 AND 50),
    -- Включённые функции (ключи из реестра plans.Features).
    features         text[]        NOT NULL DEFAULT '{}',
    -- Лимиты: {"registers": 3, ...}; ключа нет — без лимита.
    limits           jsonb         NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(limits) = 'object'),
    -- Показывать на сайте и в панели магазина (скрытый — только супер-админ назначает).
    is_public        boolean       NOT NULL DEFAULT true,
    -- Архивный тариф нельзя выбрать и назначить; у кого он есть — остаётся.
    is_active        boolean       NOT NULL DEFAULT true,
    recommended      boolean       NOT NULL DEFAULT false,
    sort             int           NOT NULL DEFAULT 0,
    created_at       timestamptz   NOT NULL DEFAULT now(),
    updated_at       timestamptz   NOT NULL DEFAULT now()
);

INSERT INTO plans (key, name, name_uz, description, description_uz, price_uzs, min_stores, order_commission, features, limits, recommended, sort) VALUES
    ('free', 'Бесплатный', 'Bepul',
     'Касса, склад и онлайн-заказы. Комиссия с онлайн-заказа.',
     'Kassa, ombor va onlayn buyurtmalar. Onlayn buyurtmadan komissiya.',
     0, 1, 5, '{}',
     '{"stores": 1, "registers": 1, "staff": 1, "couriers": 1, "banners": 0, "shelves": 0, "promos": 0, "ads": 2}', false, 0),
    ('start', 'Старт', 'Start',
     'Для небольшого магазина: без комиссии, долги покупателей, акции.',
     'Kichik doʻkon uchun: komissiyasiz, xaridorlar qarzi, aksiyalar.',
     149000, 1, 0, '{debts,promotions}',
     '{"stores": 1, "registers": 1, "staff": 3, "couriers": 2, "banners": 0, "shelves": 0, "promos": 0, "ads": 2}', false, 1),
    ('business', 'Бизнес', 'Biznes',
     'Всё для магазина: своя витрина, доставка «по пути», отчёты, накладные по фото.',
     'Doʻkon uchun hammasi: oʻz vitrinasi, «yoʻl-yoʻlakay» yetkazish, hisobotlar, rasmdan nakladnoy.',
     249000, 1, 0,
     '{debts,promotions,invoice_scans,reports_pro,crowd,showcase_custom,showcase_manual,showcase_stats}',
     '{"stores": 1, "registers": 3, "banners": 3, "shelves": 2, "promos": 1, "ads": 2}', true, 2),
    ('network', 'Сеть', 'Tarmoq',
     'Для сетей от 3 магазинов: всё из «Бизнеса», без лимитов, витрина для каждого магазина.',
     '3 ta va undan koʻp doʻkonli tarmoqlar uchun: «Biznes»dagi hammasi, cheklovsiz, har bir doʻkonga vitrina.',
     199000, 3, 0,
     '{debts,promotions,invoice_scans,reports_pro,crowd,showcase_custom,showcase_manual,showcase_schedule,showcase_per_store,showcase_stats,showcase_stats_full,ads_off}',
     '{"ads": 2}', false, 3);

-- Тариф сети, пробный период и индивидуальная цена (сум за магазин).
ALTER TABLE networks
    ADD COLUMN plan_key         text REFERENCES plans (key),
    ADD COLUMN plan_trial_until date,
    ADD COLUMN custom_price_uzs numeric(18,2) CHECK (custom_price_uzs >= 0);

-- Уже работающие сети (пилот): бесплатно, пока супер-админ не решит
-- иначе — одиночные на «Бизнесе», сети магазинов на «Сети» (иначе упрутся
-- в лимит одного магазина). Пробный период им не нужен.
UPDATE networks SET plan_key = CASE WHEN kind = 'chain' THEN 'network' ELSE 'business' END, custom_price_uzs = 0;
ALTER TABLE networks ALTER COLUMN plan_key SET NOT NULL,
                     ALTER COLUMN plan_key SET DEFAULT 'free';

-- Пробный период новых сетей: на каком тарифе и сколько дней (0 — без пробного).
ALTER TABLE billing_settings
    ADD COLUMN trial_plan text NOT NULL DEFAULT 'business' REFERENCES plans (key),
    ADD COLUMN trial_days int  NOT NULL DEFAULT 14 CHECK (trial_days BETWEEN 0 AND 365);

-- Счета теперь в сумах по тарифу; старые поля в $ остаются для истории.
ALTER TABLE subscription_invoices
    ADD COLUMN plan_key text,
    ADD COLUMN plan_name text NOT NULL DEFAULT '',
    ALTER COLUMN price_per_store TYPE numeric(18,2),
    ALTER COLUMN amount_usd DROP NOT NULL,
    ALTER COLUMN rate DROP NOT NULL,
    ADD COLUMN currency text NOT NULL DEFAULT 'USD' CHECK (currency IN ('USD', 'UZS'));
ALTER TABLE subscription_invoices ALTER COLUMN currency SET DEFAULT 'UZS';

-- Комиссия платформы с онлайн-заказа — отдельная запись баланса.
ALTER TABLE balance_entries DROP CONSTRAINT IF EXISTS balance_entries_kind_check;
ALTER TABLE balance_entries ADD CONSTRAINT balance_entries_kind_check
    CHECK (kind IN ('order', 'refund', 'payout', 'subscription', 'adjustment', 'ad_share', 'commission'));

-- Старые схемы тарифов больше не нужны.
ALTER TABLE networks
    DROP COLUMN showcase_plan,
    DROP COLUMN showcase_trial_until,
    DROP COLUMN custom_price_per_store;
ALTER TABLE billing_settings
    DROP COLUMN showcase_trial_plan,
    DROP COLUMN showcase_trial_days;
DROP TABLE showcase_plans;
DROP TABLE tariffs;

-- Действующий тариф сети: пробный, если он ещё идёт и выше выбранного,
-- иначе выбранный. Одна формула для Go и для SQL-проверок.
CREATE FUNCTION network_plan(nid uuid) RETURNS text
    LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN n.plan_trial_until >= (now() AT TIME ZONE 'Asia/Tashkent')::date AND tp.sort > cp.sort THEN tp.key
        ELSE cp.key
    END
    FROM networks n
    JOIN plans cp ON cp.key = n.plan_key
    CROSS JOIN billing_settings bs
    JOIN plans tp ON tp.key = bs.trial_plan
    WHERE n.id = nid
$$;

-- Есть ли функция в действующем тарифе сети.
CREATE FUNCTION network_has_feature(nid uuid, feature text) RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT COALESCE((SELECT feature = ANY (p.features) FROM plans p WHERE p.key = network_plan(nid)), false)
$$;
