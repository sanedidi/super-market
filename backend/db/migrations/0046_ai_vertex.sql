-- ИИ-сервис: третий вариант подключения — Google Vertex AI (Gemini).
-- Ключ — JSON сервисного аккаунта (сервер сам получает OAuth-токен) или
-- API-ключ Vertex AI; base_url — адрес проекта и региона
-- (https://aiplatform.googleapis.com/v1/projects/PROJECT/locations/global).

ALTER TABLE ai_settings DROP CONSTRAINT IF EXISTS ai_settings_provider_check;
ALTER TABLE ai_settings ADD CONSTRAINT ai_settings_provider_check
    CHECK (provider IN ('openai', 'anthropic', 'vertex'));
