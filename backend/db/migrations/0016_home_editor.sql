-- Редактор главной в админке: черновик, публикация, версии и откат.
-- Витрина с version = 0 ещё не опубликована — приложение её не видит
-- (у сети появляется строка, как только начали черновик).
ALTER TABLE home_layouts
    ADD COLUMN published_by     uuid REFERENCES users (id) ON DELETE SET NULL,
    ADD COLUMN draft_updated_at timestamptz;
ALTER TABLE home_layouts ALTER COLUMN published_at DROP NOT NULL;

CREATE TABLE home_layout_versions (
    layout_id    uuid        NOT NULL REFERENCES home_layouts (id) ON DELETE CASCADE,
    version      int         NOT NULL,
    blocks       jsonb       NOT NULL CHECK (jsonb_typeof(blocks) = 'array'),
    published_at timestamptz NOT NULL DEFAULT now(),
    published_by uuid        REFERENCES users (id) ON DELETE SET NULL,
    PRIMARY KEY (layout_id, version)
);

INSERT INTO home_layout_versions (layout_id, version, blocks, published_at)
SELECT id, version, blocks, COALESCE(published_at, now()) FROM home_layouts WHERE version > 0;

-- «Большой · только фото»: подпись баннера не рисуется поверх фото.
ALTER TABLE banners ADD COLUMN show_text boolean NOT NULL DEFAULT true;
