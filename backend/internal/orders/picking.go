package orders

// Сборка онлайн-заказа в «SM Сотрудник» (Figma «SM Сотрудник», С6–С9):
// «Взять в сборку» закрепляет заказ за сотрудником — второй его не возьмёт;
// каждый товар подтверждается сканом (picked_qty); «Нет на полке?» → «Убрать
// из заказа» (сумма пересчитывается, покупателю — уведомление); собран →
// пакеты → «Передал курьеру». Замены товара нет: товаров без остатка
// покупатель в приложении не видит.

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
	"github.com/sanedidi/super-market/backend/internal/push"
)

// addNote — запись в истории заказа без смены статуса (и без уведомления
// о статусе покупателю).
func addNote(ctx context.Context, q db.Querier, orderID, status, actor, note string) error {
	_, err := q.Exec(ctx, `INSERT INTO order_status_history (order_id, status, actor, note) VALUES ($1, $2, $3, $4)`,
		orderID, status, actor, note)
	return err
}

// checkPicker — заказ собирает другой сотрудник: 409 taken (владелец может
// доделать за сборщика).
func checkPicker(ctx context.Context, tx pgx.Tx, p *identity.Principal, id string) error {
	var picker, name *string
	if err := tx.QueryRow(ctx, `SELECT o.picker_id::text, e.full_name FROM orders o LEFT JOIN employees e ON e.id = o.picker_id
		WHERE o.id = $1`, id).Scan(&picker, &name); err != nil {
		return err
	}
	if picker == nil || *picker == p.EmployeeID || p.IsOwner {
		return nil
	}
	who := ""
	if name != nil {
		who = *name
	}
	return apperr.Conflict("taken", "заказ уже собирает "+who).Uz("buyurtmani " + who + " yigʻyapti").
		WithDetails(map[string]any{"picker_id": *picker, "picker_name": who})
}

// Take — «Взять в сборку»: новый (оплаченный) заказ сразу принимается,
// принятый — переходит в сборку; заказ закрепляется за сотрудником.
func (s *Service) Take(ctx context.Context, p *identity.Principal, id string) (Order, error) {
	if err := p.Require(identity.PermOrdersManage); err != nil {
		return Order{}, err
	}
	if _, err := s.StoreGet(ctx, p, id); err != nil {
		return Order{}, err
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		o, err := lockOrder(ctx, tx, id, StatusPaid, StatusAccepted, StatusPicking)
		if err != nil {
			return err
		}
		if err := checkPicker(ctx, tx, p, id); err != nil {
			return err
		}
		actor := "store:" + p.EmployeeID
		if o.Status == StatusPaid {
			if _, err := tx.Exec(ctx, `UPDATE orders SET status = 'accepted', accepted_at = now() WHERE id = $1`, id); err != nil {
				return err
			}
			if err := addHistory(ctx, tx, id, StatusAccepted, actor, ""); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE orders SET status = 'picking', picker_id = $2,
			picking_started_at = COALESCE(picking_started_at, now()) WHERE id = $1`, id, p.EmployeeID); err != nil {
			return err
		}
		if o.Status != StatusPicking {
			return addHistory(ctx, tx, id, StatusPicking, actor, "")
		}
		return nil
	})
	if err != nil {
		return Order{}, err
	}
	return s.StoreGet(ctx, p, id)
}

// PickLineInput — сколько товара строки уже собрано (скан или нажатие в
// списке; весовой — по наклейке весов). 0 — снять отметку.
type PickLineInput struct {
	Qty money.Qty `json:"qty"`
}

// PickLine — отметить, сколько товара строки собрано (не больше, чем в заказе).
func (s *Service) PickLine(ctx context.Context, p *identity.Principal, id string, line int, in PickLineInput) (Order, error) {
	if err := p.Require(identity.PermOrdersManage); err != nil {
		return Order{}, err
	}
	if !in.Qty.Valid() || money.D(string(in.Qty)).Sign() < 0 {
		return Order{}, apperr.Validation("qty: количество от 0").Uz("qty: miqdor 0 dan")
	}
	if _, err := s.StoreGet(ctx, p, id); err != nil {
		return Order{}, err
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := lockOrder(ctx, tx, id, StatusPicking); err != nil {
			return err
		}
		if err := checkPicker(ctx, tx, p, id); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `UPDATE order_items SET picked_qty = LEAST($3::numeric, qty) WHERE order_id = $1 AND line = $2`,
			id, line, string(in.Qty))
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.NotFound("строка заказа не найдена").Uz("buyurtma qatori topilmadi")
		}
		_, err = tx.Exec(ctx, `UPDATE orders SET picker_id = COALESCE(picker_id, $2), picking_started_at = COALESCE(picking_started_at, now())
			WHERE id = $1`, id, p.EmployeeID)
		return err
	})
	if err != nil {
		return Order{}, err
	}
	return s.StoreGet(ctx, p, id)
}

// RemoveLineInput — «Убрать из заказа». ZeroStock — «На складе больше нет»:
// остаток товара на складе заказа обнуляется (пересчёт проводится сразу,
// нужно право «Склад»), и покупатели перестают его видеть.
type RemoveLineInput struct {
	ZeroStock bool `json:"zero_stock"`
}

// RemoveLineResult — заказ после правки; ZeroStocked — остаток обнулён.
type RemoveLineResult struct {
	Order       Order `json:"order"`
	ZeroStocked bool  `json:"zero_stocked"`
}

// RemoveLine — товара нет на полке: строка уходит из заказа, сумма
// пересчитывается, покупателю — уведомление. Пока только у заказов с оплатой
// наличными курьеру: возврат части оплаты картой ещё не поддерживается.
func (s *Service) RemoveLine(ctx context.Context, p *identity.Principal, id string, line int, in RemoveLineInput) (RemoveLineResult, error) {
	var res RemoveLineResult
	if err := p.Require(identity.PermOrdersManage); err != nil {
		return res, err
	}
	if _, err := s.StoreGet(ctx, p, id); err != nil {
		return res, err
	}
	var productID, productName, qty, warehouseID string
	var customerID *string
	var number int64
	var newTotal string
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		o, err := lockOrder(ctx, tx, id, StatusAccepted, StatusPicking)
		if err != nil {
			return err
		}
		if err := checkPicker(ctx, tx, p, id); err != nil {
			return err
		}
		var provider string
		var lines int
		if err := tx.QueryRow(ctx, `SELECT o.payment_provider, o.number, o.customer_id::text,
			(SELECT count(*) FROM order_items i WHERE i.order_id = o.id)::int FROM orders o WHERE o.id = $1`, id).
			Scan(&provider, &number, &customerID, &lines); err != nil {
			return err
		}
		if provider != CashOnDelivery {
			return apperr.Conflict("card_paid", "заказ оплачен картой — убрать товар пока нельзя: позвоните покупателю или отмените заказ").
				Uz("buyurtma karta bilan toʻlangan — mahsulotni olib tashlab boʻlmaydi: xaridorga qoʻngʻiroq qiling yoki buyurtmani bekor qiling")
		}
		var price, total string
		err = tx.QueryRow(ctx, `SELECT i.product_id, loc(pr.name, pr.name_uz), trim_scale(i.qty)::text, i.price::text, i.total::text
			FROM order_items i JOIN products pr ON pr.id = i.product_id WHERE i.order_id = $1 AND i.line = $2`, id, line).
			Scan(&productID, &productName, &qty, &price, &total)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.NotFound("строка заказа не найдена").Uz("buyurtma qatori topilmadi")
		}
		if err != nil {
			return err
		}
		if lines <= 1 {
			return apperr.Conflict("last_line", "это последний товар заказа — отмените заказ").
				Uz("bu buyurtmadagi oxirgi mahsulot — buyurtmani bekor qiling")
		}
		warehouseID = o.WarehouseID
		if _, err := tx.Exec(ctx, `INSERT INTO order_removed_items (order_id, line, product_id, qty, price, total, employee_id)
			VALUES ($1, $2, $3, $4::numeric, $5::numeric, $6::numeric, $7)`, id, line, productID, qty, price, total, p.EmployeeID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM order_items WHERE order_id = $1 AND line = $2`, id, line); err != nil {
			return err
		}
		// Резерв — по товару заказа; тот же товар другой строкой остаётся в резерве.
		if _, err := tx.Exec(ctx, `
			WITH left_qty AS (SELECT COALESCE(sum(qty), 0) AS q FROM order_items WHERE order_id = $1 AND product_id = $2)
			UPDATE stock_reservations r SET qty = l.q FROM left_qty l WHERE r.order_id = $1 AND r.product_id = $2 AND l.q > 0`, id, productID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM stock_reservations r WHERE r.order_id = $1 AND r.product_id = $2
			AND NOT EXISTS (SELECT 1 FROM order_items i WHERE i.order_id = $1 AND i.product_id = $2)`, id, productID); err != nil {
			return err
		}
		var oldTotal string
		if err := tx.QueryRow(ctx, `SELECT total::text FROM orders WHERE id = $1`, id).Scan(&oldTotal); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `
			WITH t AS (
				SELECT COALESCE(sum(total), 0) AS sub,
				       COALESCE(sum(CASE WHEN regular_price > price THEN round(regular_price * qty, 2) - total ELSE 0 END), 0) AS disc
				FROM order_items WHERE order_id = $1)
			UPDATE orders o SET subtotal = t.sub, discount = t.disc, total = t.sub + o.delivery_fee
			FROM t WHERE o.id = $1 RETURNING o.total::text`, id).Scan(&newTotal); err != nil {
			return err
		}
		// Деньги заказа в балансе сети (если есть) — по новой сумме.
		if money.D(oldTotal).Sign() > 0 {
			if _, err := tx.Exec(ctx, `UPDATE balance_entries SET amount = CASE WHEN kind = 'order' THEN $2::numeric
				ELSE round(amount * $2::numeric / $3::numeric, 2) END
				WHERE order_id = $1 AND kind IN ('order', 'commission') AND status = 'pending'`, id, newTotal, oldTotal); err != nil {
				return err
			}
		}
		note := fmt.Sprintf("убран товар «%s» × %s — нет на полке", productName, qty)
		if err := addNote(ctx, tx, id, o.Status, "store:"+p.EmployeeID, note); err != nil {
			return err
		}
		if customerID == nil {
			return nil
		}
		return push.Enqueue(ctx, tx, *customerID, "order_status",
			i18n.Text{RU: fmt.Sprintf("Заказ №%d изменён", number), UZ: fmt.Sprintf("Buyurtma №%d oʻzgardi", number)},
			i18n.Text{
				RU: fmt.Sprintf("«%s» не оказалось в магазине — убрали из заказа. Новая сумма: %s сум", productName, push.Sum(newTotal)),
				UZ: fmt.Sprintf("«%s» doʻkonda qolmagan ekan — buyurtmadan olib tashladik. Yangi summa: %s soʻm", productName, push.Sum(newTotal)),
			},
			map[string]string{"type": "order", "order_id": id})
	})
	if err != nil {
		return res, err
	}
	if in.ZeroStock && p.Can(identity.PermInventoryManage) {
		if err := s.zeroStock(ctx, p, warehouseID, productID); err != nil {
			s.log.Warn("zero stock after removal", "order", id, "product", productID, "err", err)
		} else {
			res.ZeroStocked = true
		}
	}
	res.Order, err = s.StoreGet(ctx, p, id)
	return res, err
}

// zeroStock — «На складе больше нет»: инвентаризация одного товара с
// фактом 0, проводится сразу.
func (s *Service) zeroStock(ctx context.Context, p *identity.Principal, warehouseID, productID string) error {
	inv := inventory.NewService(s.pool)
	note := "Нет на полке при сборке заказа"
	items := []inventory.ItemInput{{ProductID: productID, Qty: money.Qty("0")}}
	doc, err := inv.Create(ctx, p, inventory.Input{Type: inventory.TypeInventory, WarehouseID: &warehouseID, Note: &note, Items: &items})
	if err != nil {
		return err
	}
	if _, err := inv.Post(ctx, p, doc.ID); err != nil {
		_ = inv.Delete(context.WithoutCancel(ctx), p, doc.ID)
		return err
	}
	return nil
}

// Handed — «Передал курьеру»: отметка в истории; курьер подтверждает у себя,
// что забрал заказ.
func (s *Service) Handed(ctx context.Context, p *identity.Principal, id string) (Order, error) {
	if err := p.Require(identity.PermOrdersManage); err != nil {
		return Order{}, err
	}
	if _, err := s.StoreGet(ctx, p, id); err != nil {
		return Order{}, err
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		o, err := lockOrder(ctx, tx, id, StatusPicked, StatusDelivering)
		if err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `UPDATE orders SET handed_at = now() WHERE id = $1 AND handed_at IS NULL`, id)
		if err != nil || tag.RowsAffected() == 0 {
			return err
		}
		return addNote(ctx, tx, id, o.Status, "store:"+p.EmployeeID, "передал курьеру")
	})
	if err != nil {
		return Order{}, err
	}
	return s.StoreGet(ctx, p, id)
}
