-- Версии приложений в сторах (Figma «Обновление приложения», ОБ1, и «Супер-админ ·
-- Версии приложений»): супер-админ вписывает версию, которую выложил в App Store
-- или Google Play, — у кого версия старее, приложение при запуске показывает
-- шторку «Есть обновление» с «Что нового» и ссылкой на стор.

CREATE TABLE app_versions (
    app        text        NOT NULL CHECK (app IN ('client', 'store', 'courier', 'agent')),
    platform   text        NOT NULL CHECK (platform IN ('ios', 'android')),
    -- Последняя версия в сторе, «0.9.2»; '' — проверка выключена.
    latest     text        NOT NULL DEFAULT '' CHECK (latest = '' OR latest ~ '^[0-9]{1,4}(\.[0-9]{1,4}){0,3}$'),
    store_url  text        NOT NULL DEFAULT '' CHECK (length(store_url) <= 500),
    -- «Что нового» — по строке на пункт.
    notes_ru   text        NOT NULL DEFAULT '' CHECK (length(notes_ru) <= 2000),
    notes_uz   text        NOT NULL DEFAULT '' CHECK (length(notes_uz) <= 2000),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (app, platform)
);
