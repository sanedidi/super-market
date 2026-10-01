-- Push-рассылки покупателям из супер-админки. Telegram больше не запасной
-- канал уведомлений: бот остаётся только для кодов входа.

CREATE TABLE push_campaigns (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    title        text        NOT NULL CHECK (length(title) BETWEEN 1 AND 65),
    body         text        NOT NULL CHECK (length(body) BETWEEN 1 AND 240),
    -- Куда ведёт нажатие: {"type": "category", "store_id": "...", "category_id": "..."}.
    target       jsonb       NOT NULL DEFAULT '{"type":"home"}' CHECK (jsonb_typeof(target) = 'object'),
    target_title text        NOT NULL DEFAULT '',
    -- Кому: {"type": "all" | "filter" | "one", "city", "language", "network_id", "store_id", "orders", "days", "user_id"}.
    audience     jsonb       NOT NULL DEFAULT '{"type":"all"}' CHECK (jsonb_typeof(audience) = 'object'),
    audience_title text      NOT NULL DEFAULT '',
    send_at      timestamptz NOT NULL,
    status       text        NOT NULL DEFAULT 'scheduled'
                             CHECK (status IN ('scheduled', 'sending', 'sent', 'cancelled')),
    recipients   int         NOT NULL DEFAULT 0,
    created_by   uuid        REFERENCES users (id) ON DELETE SET NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    started_at   timestamptz,
    finished_at  timestamptz,
    cancelled_at timestamptz
);
CREATE INDEX push_campaigns_due_idx ON push_campaigns (send_at) WHERE status = 'scheduled';
CREATE INDEX push_campaigns_created_idx ON push_campaigns (created_at DESC);

ALTER TABLE notifications_outbox
    ADD COLUMN campaign_id uuid REFERENCES push_campaigns (id) ON DELETE CASCADE,
    -- Куда доставлено: «iPhone, Android».
    ADD COLUMN devices text NOT NULL DEFAULT '';
CREATE INDEX notifications_outbox_campaign_idx ON notifications_outbox (campaign_id, status) WHERE campaign_id IS NOT NULL;

-- Уведомления больше не дублируются в Telegram.
ALTER TABLE customers DROP COLUMN notify_telegram;
