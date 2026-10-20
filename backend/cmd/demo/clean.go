package main

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/platform/purge"
)

// clean удаляет всё, что создал seed: сети целиком (магазины, склады,
// документы, продажи, заказы, акции…), баннеры, товары, категории, бренды
// и демо-пользователей. Товар или категорию, которыми уже пользуются
// настоящие данные, не удаляем: товар выключаем, категорию оставляем.
func clean(ctx context.Context, pool *pgxpool.Pool) error {
	ids := map[string][]string{}
	rows, err := pool.Query(ctx, `SELECT kind, id FROM demo_seed ORDER BY created_at`)
	if err != nil {
		return err
	}
	for rows.Next() {
		var k, id string
		if err := rows.Scan(&k, &id); err != nil {
			return err
		}
		ids[k] = append(ids[k], id)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if len(ids) == 0 {
		fmt.Println("демо-данных нет")
		return nil
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	d, err := newDeleter(ctx, tx)
	if err != nil {
		return err
	}

	// 0. Курьеры «по пути», проверенные в демо-магазинах, остаются (их
	// удалит шаг 1б, если их создал review): иначе удаление магазина
	// потянуло бы за собой курьера и всё, что на него ссылается.
	if _, err := tx.Exec(ctx, `
		UPDATE crowd_couriers SET verified_store_id = NULL
		WHERE verified_store_id IN (SELECT id FROM stores WHERE network_id::text = ANY($1))`, ids["network"]); err != nil {
		return err
	}
	// 1. Сети со всеми зависимыми данными — как удаление сети супер-админом:
	// одобренные товары центральной базы, данные других сетей и курьеры «по
	// пути» остаются.
	for _, id := range ids["network"] {
		rows, err := tx.Query(ctx, `SELECT id::text FROM stores WHERE network_id::text = $1`, id)
		if err != nil {
			return err
		}
		stores, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			return err
		}
		p, err := purge.New(ctx, tx, purge.NetworkScope(id, stores))
		if err != nil {
			return err
		}
		if err := p.Remove("networks", []string{"id"}, []string{id}); err != nil {
			return fmt.Errorf("сеть %s: %w", id, err)
		}
	}
	// 1б. Что добавил review (сотрудники, роли и логин курьера обычно уже
	// удалены вместе с сетью).
	if err := d.cleanReview(ids); err != nil {
		return fmt.Errorf("review: %w", err)
	}
	// 2. Баннеры.
	if _, err := tx.Exec(ctx, `DELETE FROM banners WHERE id::text = ANY($1)`, ids["banner"]); err != nil {
		return err
	}
	// 3. Товары: сначала «мягкие» ссылки, потом сам товар.
	kept := 0
	for _, t := range []string{"favorites", "product_popularity", "promotion_items", "prices", "price_document_items"} {
		if _, err := tx.Exec(ctx, fmt.Sprintf(`DELETE FROM %s WHERE product_id::text = ANY($1)`, t), ids["product"]); err != nil {
			return err
		}
	}
	for _, id := range ids["product"] {
		ok, err := d.try(`DELETE FROM products WHERE id::text = $1`, id)
		if err != nil {
			return err
		}
		if !ok {
			kept++
			if _, err := tx.Exec(ctx, `UPDATE products SET is_active = false WHERE id::text = $1`, id); err != nil {
				return err
			}
		}
	}
	// 4. Категории (сначала вложенные) и бренды — если ими никто не пользуется.
	cats := ids["category"]
	for i := len(cats) - 1; i >= 0; i-- {
		if _, err := d.try(`DELETE FROM categories WHERE id::text = $1`, cats[i]); err != nil {
			return err
		}
	}
	for _, id := range ids["brand"] {
		if _, err := d.try(`DELETE FROM brands WHERE id::text = $1`, id); err != nil {
			return err
		}
	}
	// 5. Пользователи, которых создал seed.
	for _, id := range ids["user"] {
		for _, t := range []string{"sessions", "platform_admins", "customers", "favorites", "customer_addresses"} {
			if _, err := tx.Exec(ctx, fmt.Sprintf(`DELETE FROM %s WHERE user_id::text = $1`, t), id); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `DELETE FROM auth_codes WHERE phone = (SELECT phone FROM users WHERE id::text = $1)`, id); err != nil {
			return err
		}
		if _, err := d.try(`DELETE FROM users WHERE id::text = $1`, id); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(ctx, `DELETE FROM demo_seed`); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	fmt.Printf("готово: удалено сетей %d, товаров %d, баннеров %d\n", len(ids["network"]), len(ids["product"])-kept, len(ids["banner"]))
	if n := len(ids["review_employee"]) + len(ids["review_courier"]) + len(ids["review_crowd"]); n > 0 {
		fmt.Println("демо-доступ для проверки приложений удалён (сотрудник, курьер магазина, курьер «по пути»)")
	}
	if kept > 0 {
		fmt.Printf("! %d товаров уже есть в настоящих продажах или заказах — они выключены, а не удалены\n", kept)
	}
	return nil
}

// cleanReview удаляет то, что создал demo review: логин и запись штатного
// курьера, сотрудника для проверки и его логин в «SM Магазин», его роль, курьера «по пути», адрес и
// профиль покупателя. Сам пользователь удаляется, только если его создал
// review (kind = user).
func (d *deleter) cleanReview(ids map[string][]string) error {
	logins := append(append([]string{}, ids["review_courier_login"]...), ids["review_courier"]...)
	logins = append(append(logins, ids["review_store_login"]...), ids["review_employee"]...)
	if _, err := d.tx.Exec(d.ctx, `DELETE FROM employee_logins WHERE employee_id::text = ANY($1)`, logins); err != nil {
		return err
	}
	employees := append(append([]string{}, ids["review_employee"]...), ids["review_courier"]...)
	if err := d.remove("employees", []string{"id"}, employees, nil); err != nil {
		return err
	}
	if err := d.remove("roles", []string{"id"}, ids["review_role"], nil); err != nil {
		return err
	}
	if _, err := d.tx.Exec(d.ctx, `DELETE FROM customer_addresses WHERE id::text = ANY($1)`, ids["review_address"]); err != nil {
		return err
	}
	for _, id := range ids["review_crowd"] {
		ok, err := d.try(`DELETE FROM crowd_couriers WHERE user_id::text = $1`, id)
		if err != nil {
			return err
		}
		if !ok {
			// Есть настоящие заказы или начисления — обезличить, как при удалении аккаунта.
			if _, err := d.tx.Exec(d.ctx, `
				UPDATE crowd_couriers SET deleted_at = now(), full_name = '', birth_date = NULL, doc_hash = NULL,
				       status = 'unverified', verified_at = NULL, verified_store_id = NULL,
				       online = false, dest = NULL, dest_title = '', location = NULL, located_at = NULL
				WHERE user_id::text = $1`, id); err != nil {
				return err
			}
		}
		if _, err := d.tx.Exec(d.ctx, `UPDATE sessions SET revoked_at = now() WHERE user_id::text = $1 AND app = 'crowd' AND revoked_at IS NULL`, id); err != nil {
			return err
		}
	}
	for _, id := range ids["review_customer"] {
		if _, err := d.tx.Exec(d.ctx, `DELETE FROM favorites WHERE user_id::text = $1`, id); err != nil {
			return err
		}
		if _, err := d.try(`DELETE FROM customers WHERE user_id::text = $1`, id); err != nil {
			return err
		}
	}
	return nil
}

// deleter — обёртка над purge: демо-данные изолированы, поэтому «свои» все
// строки, кроме курьеров «по пути» (их убирает cleanReview, если их создал review).
type deleter struct {
	ctx context.Context
	tx  pgx.Tx
	p   *purge.Deleter
}

func newDeleter(ctx context.Context, tx pgx.Tx) (*deleter, error) {
	p, err := purge.New(ctx, tx, purge.Scope{Keep: map[string]bool{"crowd_couriers": true}})
	if err != nil {
		return nil, err
	}
	return &deleter{ctx: ctx, tx: tx, p: p}, nil
}

func (d *deleter) remove(table string, cols, vals []string, _ []string) error {
	return d.p.Remove(table, cols, vals)
}

func (d *deleter) try(sql string, args ...any) (bool, error) { return d.p.Try(sql, args...) }
