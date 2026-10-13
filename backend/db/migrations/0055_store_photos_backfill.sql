-- Нормализация фото для магазина — старые фото: товары «Начала работы»,
-- снятые до нормализации, Super Market тоже делает чистыми сам, понемногу и в
-- лимите тарифа (новые фото магазина идут вперёд старых, см. ai.BackfillReserve).
-- backfill — задание на старое фото.
ALTER TABLE photo_jobs ADD COLUMN backfill boolean NOT NULL DEFAULT false;
CREATE INDEX photo_jobs_backfill_idx ON photo_jobs (network_id) WHERE backfill AND status IN ('queued', 'processing');
