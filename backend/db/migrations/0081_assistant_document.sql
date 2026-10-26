-- Помощник: черновик документа, над которым идёт работа в чате (приход со
-- слов владельца) — попадает в контекст модели, как текущая накладная.
ALTER TABLE assistant_chats ADD COLUMN document_id uuid REFERENCES stock_documents (id) ON DELETE SET NULL;
