-- Этап приложения 5: «Моя семья» — общий список покупок с напоминаниями.

CREATE TABLE families (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id   uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name       text        NOT NULL DEFAULT 'Моя семья' CHECK (btrim(name) <> ''),
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Человек состоит не больше чем в одной семье. label — как его видят в семье («Жена»).
CREATE TABLE family_members (
    family_id uuid        NOT NULL REFERENCES families (id) ON DELETE CASCADE,
    user_id   uuid        NOT NULL UNIQUE REFERENCES users (id) ON DELETE CASCADE,
    role      text        NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'member')),
    label     text        NOT NULL DEFAULT '' CHECK (length(label) <= 40),
    joined_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (family_id, user_id)
);

-- Одноразовые приглашения: код идёт в ссылку t.me/<бот>?start=fam_<код>.
CREATE TABLE family_invites (
    code       text        PRIMARY KEY CHECK (code ~ '^[A-Z0-9]{8}$'),
    family_id  uuid        NOT NULL REFERENCES families (id) ON DELETE CASCADE,
    created_by uuid        REFERENCES users (id) ON DELETE SET NULL,
    expires_at timestamptz NOT NULL,
    used_by    uuid        REFERENCES users (id) ON DELETE SET NULL,
    used_at    timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Просьба купить. assignee_id пусто — любой из семьи. remind_at — когда
-- напомнить; deliver_offer_at — если к этому времени не куплено, предложить
-- доставку домой.
CREATE TABLE shopping_requests (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id        uuid        NOT NULL REFERENCES families (id) ON DELETE CASCADE,
    author_id        uuid        REFERENCES users (id) ON DELETE SET NULL,
    assignee_id      uuid        REFERENCES users (id) ON DELETE SET NULL,
    title            text        NOT NULL CHECK (btrim(title) <> '' AND length(title) <= 80),
    comment          text        NOT NULL DEFAULT '' CHECK (length(comment) <= 500),
    remind_at        timestamptz,
    remind_at_store  boolean     NOT NULL DEFAULT false,
    deliver_offer_at timestamptz,
    status           text        NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'partial', 'bought', 'ordered', 'cancelled')),
    order_id         uuid        REFERENCES orders (id) ON DELETE SET NULL,
    reminded_at      timestamptz,
    offered_at       timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX shopping_requests_family_idx ON shopping_requests (family_id, created_at DESC);
CREATE INDEX shopping_requests_due_idx ON shopping_requests (remind_at)
    WHERE status IN ('pending', 'partial') AND reminded_at IS NULL;

-- Что купить: товар из каталога или свой текст («помидоры»).
CREATE TABLE shopping_request_items (
    id         uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id uuid          NOT NULL REFERENCES shopping_requests (id) ON DELETE CASCADE,
    line       int           NOT NULL,
    product_id uuid          REFERENCES products (id),
    text       text          NOT NULL DEFAULT '' CHECK (length(text) <= 100),
    qty        numeric(12,3) NOT NULL DEFAULT 1 CHECK (qty > 0),
    bought     boolean       NOT NULL DEFAULT false,
    bought_by  uuid          REFERENCES users (id) ON DELETE SET NULL,
    bought_at  timestamptz,
    UNIQUE (request_id, line),
    CHECK (product_id IS NOT NULL OR btrim(text) <> '')
);
