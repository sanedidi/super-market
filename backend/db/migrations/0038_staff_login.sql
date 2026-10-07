-- Вход в панель магазина и в «SM Магазин» по логину и паролю вместо кода
-- из Telegram. Логины курьеров становятся общими логинами сотрудников:
-- одна запись на сотрудника, по ней он входит и в приложение курьера, и в
-- панель магазина (если есть доступ).
--
-- Логин и временный пароль владельца задаёт супер-админ, сотрудникам —
-- владелец или менеджер с правом «Роли и сотрудники». Пока пароль временный
-- (must_change_password), в панели открыт только экран смены пароля.
ALTER TABLE courier_logins RENAME TO employee_logins;
ALTER TABLE employee_logins RENAME CONSTRAINT courier_logins_pkey TO employee_logins_pkey;
ALTER TABLE employee_logins RENAME CONSTRAINT courier_logins_login_key TO employee_logins_login_key;
ALTER INDEX courier_logins_network_idx RENAME TO employee_logins_network_idx;

ALTER TABLE employee_logins ADD COLUMN must_change_password boolean NOT NULL DEFAULT false;
