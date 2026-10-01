-- Витрина магазина в приложении: тарифы «Старт / Бизнес / Про» с лимитами,
-- пробный период, баннеры сетей с модерацией. Цены, лимиты и пробный
-- период настраивает супер-админ.
CREATE TABLE showcase_plans (
    key          text        PRIMARY KEY CHECK (key IN ('start', 'business', 'pro')),
    name         text        NOT NULL CHECK (btrim(name) <> ''),
    price_uzs    numeric(18,2) NOT NULL DEFAULT 0 CHECK (price_uzs >= 0),
    -- Своя витрина: порядок блоков, свои блоки.
    custom       boolean     NOT NULL DEFAULT false,
    -- Лимиты своих блоков; NULL — без лимита.
    banners      int         CHECK (banners >= 0),
    shelves      int         CHECK (shelves >= 0),
    promos       int         CHECK (promos >= 0),
    manual       boolean     NOT NULL DEFAULT false,
    schedule     boolean     NOT NULL DEFAULT false,
    per_store    boolean     NOT NULL DEFAULT false,
    stats        text        NOT NULL DEFAULT 'none' CHECK (stats IN ('none', 'basic', 'full')),
    recommended  boolean     NOT NULL DEFAULT false,
    sort         int         NOT NULL DEFAULT 0,
    updated_at   timestamptz NOT NULL DEFAULT now()
);
INSERT INTO showcase_plans (key, name, price_uzs, custom, banners, shelves, promos, manual, schedule, per_store, stats, recommended, sort) VALUES
    ('start',    'Старт',  0,      false, 0,    0,    0,    false, false, false, 'none',  false, 0),
    ('business', 'Бизнес', 150000, true,  3,    2,    1,    true,  false, false, 'basic', true,  1),
    ('pro',      'Про',    350000, true,  NULL, NULL, NULL, true,  true,  true,  'full',  false, 2);

-- Тариф сети и пробный период (на тариф trial_plan до showcase_trial_until).
ALTER TABLE networks
    ADD COLUMN showcase_plan        text NOT NULL DEFAULT 'start' REFERENCES showcase_plans (key),
    ADD COLUMN showcase_trial_until date;

ALTER TABLE billing_settings
    ADD COLUMN showcase_trial_plan text NOT NULL DEFAULT 'business' REFERENCES showcase_plans (key),
    ADD COLUMN showcase_trial_days int  NOT NULL DEFAULT 30 CHECK (showcase_trial_days BETWEEN 0 AND 365);

-- Плата за витрину входит в ежемесячный счёт за подписку.
ALTER TABLE subscription_invoices
    ADD COLUMN showcase_plan text,
    ADD COLUMN showcase_uzs  numeric(18,2) NOT NULL DEFAULT 0;

-- Баннеры сетей проходят модерацию супер-админа, как товары.
ALTER TABLE banners
    ADD COLUMN owner         text NOT NULL DEFAULT 'platform' CHECK (owner IN ('platform', 'network')),
    ADD COLUMN moderation    text NOT NULL DEFAULT 'approved' CHECK (moderation IN ('pending', 'approved', 'rejected')),
    ADD COLUMN reject_reason text NOT NULL DEFAULT '';
CREATE INDEX banners_pending_idx ON banners (created_at) WHERE moderation = 'pending';

-- Витрину опубликовала сама сеть (тогда при показе действуют лимиты её
-- тарифа); витрины, сделанные супер-админом, лимитам не подчиняются.
ALTER TABLE home_layouts ADD COLUMN by_store boolean NOT NULL DEFAULT false;
