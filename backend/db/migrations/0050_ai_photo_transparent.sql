-- «ИИ для фото» → Фон: Прозрачный. Gemini кладёт товар на ровный пурпурный
-- фон, сервер вырезает его и сохраняет PNG с прозрачностью.
ALTER TABLE ai_photo_settings DROP CONSTRAINT IF EXISTS ai_photo_settings_background_check;
ALTER TABLE ai_photo_settings ADD CONSTRAINT ai_photo_settings_background_check
    CHECK (background IN ('white', 'light', 'transparent'));
