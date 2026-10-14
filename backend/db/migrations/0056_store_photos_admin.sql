-- Фото магазинов — результаты для супер-админа (Figma «Супер-админ · Фото
-- магазинов — результаты»): список фото с причинами, повтор временных ошибок
-- Gemini, «Повторить» и «Переделать».
--   retry_at    — временная ошибка (лимит запросов, сбой Google): задание ждёт
--                 повтора до этого времени;
--   error_code  — причина для группировки «Почему не вышло» (rate_limit,
--                 unavailable, timeout, auth, model, refused, unreadable,
--                 not_found, stale, save, other); у skipped — пусто;
--   cost_usd    — сколько стоило фото (по прайсу Google), model — чем делали;
--   finished_at — когда задание закончилось (done / failed / skipped);
--   replaces    — «Переделать»: ключ прежнего фото Super Market, новое встаёт
--                 на его место;
--   log         — история: [{at, kind, text}], kind — queued, error, retry,
--                 done, failed, skipped.
ALTER TABLE photo_jobs
    ADD COLUMN retry_at    timestamptz,
    ADD COLUMN error_code  text          NOT NULL DEFAULT '' CHECK (length(error_code) <= 30),
    ADD COLUMN cost_usd    numeric(10,4) CHECK (cost_usd >= 0),
    ADD COLUMN model       text          NOT NULL DEFAULT '' CHECK (length(model) <= 200),
    ADD COLUMN finished_at timestamptz,
    ADD COLUMN replaces    text          NOT NULL DEFAULT '',
    ADD COLUMN log         jsonb         NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(log) = 'array');

CREATE INDEX photo_jobs_created_idx ON photo_jobs (created_at DESC);

-- Задания, сделанные до этой миграции.
UPDATE photo_jobs SET finished_at = updated_at WHERE status IN ('done', 'failed', 'skipped');
UPDATE photo_jobs SET error_code = CASE
        WHEN error LIKE '%превышен лимит%' OR error LIKE '%(429)%' THEN 'rate_limit'
        WHEN error LIKE '%временно недоступен%' THEN 'unavailable'
        WHEN error LIKE '%не ответил вовремя%' OR error LIKE '%подключиться%' THEN 'timeout'
        WHEN error LIKE '%ключ не подходит%' THEN 'auth'
        WHEN error LIKE '%модель недоступна%' OR error LIKE '%не выбрана модель%' THEN 'model'
        WHEN error LIKE '%отказался%' OR error LIKE '%не нарисовал%' OR error LIKE '%пустой ответ%' THEN 'refused'
        WHEN error LIKE '%не читается%' THEN 'unreadable'
        WHEN error LIKE '%не найдено в хранилище%' THEN 'not_found'
        WHEN error LIKE '%не успели%' THEN 'stale'
        WHEN error LIKE '%сохранить%' THEN 'save'
        ELSE 'other' END
WHERE status = 'failed';
UPDATE photo_jobs SET log = jsonb_build_array(jsonb_build_object('at', created_at, 'kind', 'queued', 'text', ''))
    || CASE WHEN status IN ('done', 'failed', 'skipped')
            THEN jsonb_build_array(jsonb_build_object('at', updated_at, 'kind', status, 'text', error))
            ELSE '[]'::jsonb END;
