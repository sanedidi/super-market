// Package push — уведомления покупателям: очередь (notifications_outbox),
// отправка в Firebase Cloud Messaging и запасной канал — Telegram-бот.
//
// Событие кладёт запись в очередь в своей транзакции (EnqueueOrderStatus),
// воркер отправляет её после коммита (Dispatcher) и повторяет при ошибке.
package push

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

type orderText struct{ title, body string }

// Тексты по статусу заказа: %d — номер заказа, %s — магазин.
var orderTexts = map[string]map[string]orderText{
	"ru": {
		"paid":       {"Заказ №%d оплачен", "Ждём, когда «%s» примет заказ"},
		"accepted":   {"Заказ №%d принят", "«%s» начинает собирать ваш заказ"},
		"picked":     {"Заказ №%d собран", "Скоро передадим его курьеру"},
		"delivering": {"Заказ №%d в пути", "Курьер уже едет к вам"},
		"delivered":  {"Заказ №%d доставлен", "Спасибо за покупку в «%s»!"},
		"cancelled":  {"Заказ №%d отменён", "Если заказ был оплачен, деньги вернутся на карту"},
		"expired":    {"Заказ №%d не оплачен", "Время на оплату истекло, заказ отменён"},
	},
	"uz": {
		"paid":       {"Buyurtma №%d to‘landi", "«%s» buyurtmani qabul qilishini kutyapmiz"},
		"accepted":   {"Buyurtma №%d qabul qilindi", "«%s» buyurtmangizni yig‘ishni boshladi"},
		"picked":     {"Buyurtma №%d yig‘ildi", "Tez orada kuryerga topshiramiz"},
		"delivering": {"Buyurtma №%d yo‘lda", "Kuryer sizga qarab kelmoqda"},
		"delivered":  {"Buyurtma №%d yetkazildi", "«%s»dan xarid qilganingiz uchun rahmat!"},
		"cancelled":  {"Buyurtma №%d bekor qilindi", "Agar to‘lov qilingan bo‘lsa, pul kartangizga qaytariladi"},
		"expired":    {"Buyurtma №%d to‘lanmadi", "To‘lov vaqti tugadi, buyurtma bekor qilindi"},
	},
}

// OrderStatusTitle — заголовок уведомления (для тестов и превью).
func OrderStatusTitle(lang, status string, number int64) (string, bool) {
	t, ok := orderTexts[lang][status]
	if !ok {
		return "", false
	}
	return fmt.Sprintf(t.title, number), true
}

func format(s, store string) string {
	if !strings.Contains(s, "%s") {
		return s
	}
	return fmt.Sprintf(s, store)
}

// EnqueueOrderStatus ставит в очередь уведомление покупателю о новом статусе
// заказа. Вызывается в транзакции, которая меняет статус. Если покупатель
// выключил уведомления о заказах или удалил аккаунт — ничего не делает.
func EnqueueOrderStatus(ctx context.Context, q db.Querier, orderID, status string) error {
	if _, ok := orderTexts["ru"][status]; !ok {
		return nil
	}
	var (
		userID, store, lang string
		number              int64
		enabled             bool
	)
	err := q.QueryRow(ctx, `
		SELECT o.customer_id, o.number, s.name, COALESCE(c.language, 'ru'),
		       COALESCE(c.notify_orders AND c.deleted_at IS NULL, false)
		FROM orders o
		JOIN stores s ON s.id = o.store_id
		LEFT JOIN customers c ON c.user_id = o.customer_id
		WHERE o.id = $1`, orderID).Scan(&userID, &number, &store, &lang, &enabled)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !enabled) {
		return nil
	}
	if err != nil {
		return err
	}
	t, ok := orderTexts[lang][status]
	if !ok {
		t = orderTexts["ru"][status]
	}
	_, err = q.Exec(ctx, `
		INSERT INTO notifications_outbox (user_id, kind, title, body, data)
		VALUES ($1, 'order_status', $2, $3, jsonb_build_object('type', 'order', 'order_id', $4::text, 'status', $5::text))`,
		userID, fmt.Sprintf(t.title, number), format(t.body, store), orderID, status)
	return err
}

// Enqueue ставит в очередь произвольное уведомление покупателю (семья и
// др.). Удалённым аккаунтам не отправляется.
func Enqueue(ctx context.Context, q db.Querier, userID, kind, title, body string, data map[string]string) error {
	if data == nil {
		data = map[string]string{}
	}
	js, err := json.Marshal(data)
	if err != nil {
		return err
	}
	_, err = q.Exec(ctx, `
		INSERT INTO notifications_outbox (user_id, kind, title, body, data)
		SELECT c.user_id, $2, $3, $4, $5::jsonb FROM customers c WHERE c.user_id = $1::uuid AND c.deleted_at IS NULL`,
		userID, kind, title, body, string(js))
	return err
}
