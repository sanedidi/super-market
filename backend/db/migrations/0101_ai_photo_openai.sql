-- «ИИ для фото» (Figma «ИИ для фото», Ф3): третий способ — OpenAI (модели
-- GPT Image, images/edits) рядом с Gemini API и Vertex AI. quality — качество
-- картинки OpenAI: low | medium | high (у Gemini не используется).
ALTER TABLE ai_photo_settings DROP CONSTRAINT IF EXISTS ai_photo_settings_mode_check;
ALTER TABLE ai_photo_settings ADD CONSTRAINT ai_photo_settings_mode_check CHECK (mode IN ('gemini', 'vertex', 'openai'));
ALTER TABLE ai_photo_settings ADD COLUMN IF NOT EXISTS quality text NOT NULL DEFAULT 'medium'
    CHECK (quality IN ('low', 'medium', 'high'));
