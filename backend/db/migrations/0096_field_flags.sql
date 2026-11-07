-- «SM Продажник» — «Зайти потом» (Figma П8–П11, «Логика · Зайти потом»).
--
-- Продажник во время обхода видит магазин по дороге и одним нажатием ставит
-- жёлтый флажок там, где стоит, — и идёт дальше. Фото витрины и название — по
-- желанию. Флажки видят все продажники. Флажок закрывается сам, когда любой
-- продажник отмечает магазин ближе 50 м от него; «Не магазин» убирает флажок
-- у всех; автор может удалить свой флажок всегда. Срока нет.

CREATE TABLE IF NOT EXISTS field_flags (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    rep_id       uuid        NOT NULL REFERENCES field_reps (id),
    walk_id      uuid        REFERENCES field_walks (id) ON DELETE SET NULL,
    location     geography(Point, 4326) NOT NULL,
    accuracy     real,
    name         text        NOT NULL DEFAULT '',
    photo_url    text        NOT NULL DEFAULT '',
    -- open — ждёт визита; visited — магазин отметили рядом; removed — «Не магазин» или удалён автором.
    status       text        NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'visited', 'removed')),
    close_reason text        NOT NULL DEFAULT '' CHECK (close_reason IN ('', 'visited', 'not_store', 'deleted')),
    closed_at    timestamptz,
    closed_by    uuid        REFERENCES field_reps (id),
    place_id     uuid        REFERENCES field_places (id) ON DELETE SET NULL,
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS field_flags_open_geo_idx ON field_flags USING gist (location) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS field_flags_rep_idx ON field_flags (rep_id, created_at DESC);
