-- Главная приложения из блоков. Витрина бывает трёх уровней: платформа
-- (шаблон для всех), сеть и магазин. Приложение берёт витрину магазина,
-- иначе сети, иначе платформы. blocks — опубликованные блоки по порядку,
-- draft — черновик редактора (появится на этапе 2).
CREATE TABLE home_layouts (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    scope        text        NOT NULL CHECK (scope IN ('platform', 'network', 'store')),
    network_id   uuid        REFERENCES networks (id) ON DELETE CASCADE,
    store_id     uuid        REFERENCES stores (id) ON DELETE CASCADE,
    blocks       jsonb       NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(blocks) = 'array'),
    draft        jsonb       CHECK (draft IS NULL OR jsonb_typeof(draft) = 'array'),
    version      int         NOT NULL DEFAULT 1,
    published_at timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    CHECK ((scope = 'platform' AND network_id IS NULL AND store_id IS NULL)
        OR (scope = 'network' AND network_id IS NOT NULL AND store_id IS NULL)
        OR (scope = 'store' AND store_id IS NOT NULL))
);
CREATE UNIQUE INDEX home_layouts_platform_uq ON home_layouts ((true)) WHERE scope = 'platform';
CREATE UNIQUE INDEX home_layouts_network_uq ON home_layouts (network_id) WHERE scope = 'network';
CREATE UNIQUE INDEX home_layouts_store_uq ON home_layouts (store_id) WHERE scope = 'store';

-- Шаблон платформы = нынешняя главная «Экспресс».
INSERT INTO home_layouts (scope, blocks) VALUES ('platform', '[
  {"id": "a0000000-0000-4000-8000-000000000001", "type": "category_icons", "mode": "auto", "shape": "circle", "show_deals": true},
  {"id": "a0000000-0000-4000-8000-000000000002", "type": "promo", "kind": "free_delivery"},
  {"id": "a0000000-0000-4000-8000-000000000003", "type": "banners", "size": "big", "autoplay": true},
  {"id": "a0000000-0000-4000-8000-000000000004", "type": "shelf", "title": "Хиты недели", "source": "hits", "limit": 6, "view": "grid2", "show_all": true},
  {"id": "a0000000-0000-4000-8000-000000000005", "type": "shelf", "title": "Скидки недели", "source": "discount", "limit": 10, "view": "row", "show_all": true},
  {"id": "a0000000-0000-4000-8000-000000000006", "type": "catalog_sections", "view": "tiles3", "mode": "all", "show_images": true}
]');
