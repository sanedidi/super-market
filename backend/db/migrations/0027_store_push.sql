-- Push сотрудникам магазина (приложение «SM Магазин»): у устройства и
-- уведомления есть приложение — покупательские push не уходят в приложение
-- магазина и наоборот.
ALTER TABLE devices ADD COLUMN app text NOT NULL DEFAULT 'client' CHECK (app IN ('client', 'store'));
ALTER TABLE notifications_outbox ADD COLUMN app text NOT NULL DEFAULT 'client' CHECK (app IN ('client', 'store'));
CREATE INDEX devices_user_app_idx ON devices (user_id, app);
