-- Реклама брендов на главной: рекламодатели, кампании (полка или фото-баннер
-- с товарами бренда), правила для сетей, доля сетей с рекламы, счета и акты
-- брендам от платформы.

-- Правила рекламы (одна строка) и реквизиты платформы для счетов и актов.
CREATE TABLE ad_settings (
    id                       int           PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    network_share_pct        numeric(5,2)  NOT NULL DEFAULT 25 CHECK (network_share_pct BETWEEN 0 AND 100),
    share_to_subscription    boolean       NOT NULL DEFAULT true,
    allow_hide_brands        boolean       NOT NULL DEFAULT true,
    allow_exclude_categories boolean       NOT NULL DEFAULT true,
    -- Реквизиты платформы (исполнитель в счетах и актах).
    company_name             text          NOT NULL DEFAULT '',
    company_inn              text          NOT NULL DEFAULT '',
    company_address          text          NOT NULL DEFAULT '',
    company_bank             text          NOT NULL DEFAULT '',
    company_account          text          NOT NULL DEFAULT '',
    company_mfo              text          NOT NULL DEFAULT '',
    company_director         text          NOT NULL DEFAULT '',
    updated_at               timestamptz   NOT NULL DEFAULT now()
);
INSERT INTO ad_settings DEFAULT VALUES;

-- Сколько рекламы на главной по тарифу витрины: ads_max — по умолчанию,
-- ads_reducible — сеть может поставить меньше (1 или 0).
ALTER TABLE showcase_plans
    ADD COLUMN ads_max       int     NOT NULL DEFAULT 2 CHECK (ads_max BETWEEN 0 AND 2),
    ADD COLUMN ads_reducible boolean NOT NULL DEFAULT false;
UPDATE showcase_plans SET ads_reducible = true WHERE key = 'pro';

-- Настройки рекламы сети: скрытые бренды, исключённые категории, сколько
-- рекламных блоков (NULL — по тарифу).
ALTER TABLE networks
    ADD COLUMN ads_hidden_brands       uuid[] NOT NULL DEFAULT '{}',
    ADD COLUMN ads_excluded_categories uuid[] NOT NULL DEFAULT '{}',
    ADD COLUMN ads_max                 int    CHECK (ads_max BETWEEN 0 AND 2);

-- Рекламодатель — юрлицо бренда (для договора, счёта и акта).
CREATE TABLE ad_advertisers (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    name             text        NOT NULL CHECK (btrim(name) <> ''),
    inn              text        NOT NULL DEFAULT '',
    address          text        NOT NULL DEFAULT '',
    bank             text        NOT NULL DEFAULT '',
    account          text        NOT NULL DEFAULT '',
    mfo              text        NOT NULL DEFAULT '',
    contract_number  text        NOT NULL DEFAULT '',
    contract_date    date,
    contact          text        NOT NULL DEFAULT '',
    created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ad_campaigns (
    id               uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    advertiser_id    uuid          NOT NULL REFERENCES ad_advertisers (id),
    brand_id         uuid          NOT NULL REFERENCES brands (id),
    format           text          NOT NULL CHECK (format IN ('shelf', 'banner')),
    title            text          NOT NULL CHECK (btrim(title) <> ''),
    subtitle         text          NOT NULL DEFAULT '',
    image_url        text          NOT NULL DEFAULT '',
    product_ids      uuid[]        NOT NULL DEFAULT '{}',
    network_ids      uuid[]        NOT NULL DEFAULT '{}',
    place            text          NOT NULL DEFAULT 'after_platform' CHECK (place IN ('after_platform', 'end')),
    starts_at        timestamptz   NOT NULL,
    ends_at          timestamptz   NOT NULL,
    pricing          text          NOT NULL CHECK (pricing IN ('period', 'cpm')),
    price            numeric(18,2) NOT NULL CHECK (price >= 0),
    impression_limit bigint        CHECK (impression_limit > 0),
    paused           boolean       NOT NULL DEFAULT false,
    created_at       timestamptz   NOT NULL DEFAULT now(),
    updated_at       timestamptz   NOT NULL DEFAULT now(),
    CHECK (ends_at > starts_at)
);
CREATE INDEX ad_campaigns_live_idx ON ad_campaigns (starts_at, ends_at) WHERE NOT paused;

-- Оплачиваемые показы: один покупатель — один показ кампании в день
-- (защита от накрутки). Анонимные показы в оплату и долю не идут.
CREATE TABLE ad_views (
    campaign_id uuid NOT NULL REFERENCES ad_campaigns (id) ON DELETE CASCADE,
    day         date NOT NULL,
    user_id     uuid NOT NULL,
    store_id    uuid NOT NULL REFERENCES stores (id) ON DELETE CASCADE,
    PRIMARY KEY (campaign_id, day, user_id)
);
CREATE INDEX ad_views_store_idx ON ad_views (store_id, day);

-- Доля сети с рекламы за месяц; уходит в зачёт счёта за подписку.
CREATE TABLE network_ad_shares (
    network_id  uuid          NOT NULL REFERENCES networks (id),
    period      date          NOT NULL CHECK (extract(day FROM period) = 1),
    amount      numeric(18,2) NOT NULL CHECK (amount >= 0),
    pct         numeric(5,2)  NOT NULL,
    views       bigint        NOT NULL DEFAULT 0,
    -- applied — часть, зачтённая в счёт; credited — остаток на баланс.
    applied     numeric(18,2) NOT NULL DEFAULT 0,
    credited    numeric(18,2) NOT NULL DEFAULT 0,
    invoice_id  uuid          REFERENCES subscription_invoices (id),
    settled_at  timestamptz,
    created_at  timestamptz   NOT NULL DEFAULT now(),
    PRIMARY KEY (network_id, period)
);

ALTER TABLE subscription_invoices ADD COLUMN ad_share_uzs numeric(18,2) NOT NULL DEFAULT 0;

ALTER TABLE balance_entries DROP CONSTRAINT IF EXISTS balance_entries_kind_check;
ALTER TABLE balance_entries ADD CONSTRAINT balance_entries_kind_check
    CHECK (kind IN ('order', 'refund', 'payout', 'subscription', 'adjustment', 'ad_share'));

-- Счета брендам; акт — по оплаченному счёту.
CREATE SEQUENCE ad_invoice_number;
CREATE TABLE ad_invoices (
    id            uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    number        bigint        NOT NULL UNIQUE DEFAULT nextval('ad_invoice_number'),
    campaign_id   uuid          NOT NULL REFERENCES ad_campaigns (id),
    period_from   date          NOT NULL,
    period_to     date          NOT NULL CHECK (period_to >= period_from),
    views         bigint        NOT NULL DEFAULT 0,
    amount        numeric(18,2) NOT NULL CHECK (amount > 0),
    status        text          NOT NULL DEFAULT 'unpaid' CHECK (status IN ('unpaid', 'paid', 'cancelled')),
    paid_at       timestamptz,
    act_number    bigint,
    act_date      date,
    created_at    timestamptz   NOT NULL DEFAULT now()
);
CREATE SEQUENCE ad_act_number;
