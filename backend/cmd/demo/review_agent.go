package main

import (
	"errors"
	"fmt"
	"net/http"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
)

// Демо-агент для проверки «SM Агент» в App Store / Google Play.
//
// Номер из REVIEW_AGENT_LOGIN становится владельцем дистрибьютора
// reviewAgentName: бренд Coca-Cola, склад рядом с «Baraka Market», товар на
// складе с отпускной ценой, связь с магазинами демо-сети и новый заказ от
// магазина. Проверяющий входит по номеру и постоянному коду (SMS не нужно) и
// сразу видит магазины, кому чего не хватает, заказ и склад. Повторный запуск
// ничего не задваивает.

const (
	reviewAgentName  = "Fayz Distribution (демо)"
	reviewAgentOwner = "Агент для проверки"
	reviewAgentBrand = "Coca-Cola"
	// reviewAgentLinks — сколько магазинов демо-сети подключены к агенту.
	reviewAgentLinks = 2
)

// agent настраивает демо-агента для номера ph. Номер не должен работать в
// настоящей сети: магазин или чужой дистрибьютор review не меняет.
func (r *reviewer) agent(creds *reviewCreds, ph, code string) error {
	var (
		netID, kind string
		ours        bool
	)
	err := r.pool.QueryRow(r.ctx, `
		SELECT n.id::text, n.kind, EXISTS (SELECT 1 FROM demo_seed d WHERE d.kind = 'network' AND d.id = n.id::text)
		FROM employees e JOIN users u ON u.id = e.user_id JOIN networks n ON n.id = e.network_id
		WHERE u.phone = $1 ORDER BY e.created_at LIMIT 1`, ph).Scan(&netID, &kind, &ours)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		netID = ""
	case err != nil:
		return err
	case kind != "distributor" || !ours:
		return fmt.Errorf("%s уже работает в сети, которая не демо-агент, — укажите в REVIEW_AGENT_LOGIN другой номер", ph)
	}
	admin, err := r.c.login(demoAdminPhone, identity.AppAdmin)
	if err != nil {
		return err
	}
	if netID == "" {
		net, err := r.c.call("POST", "/admin/networks", admin, obj{
			"name": reviewAgentName, "kind": "distributor", "owner_phone": ph, "owner_name": reviewAgentOwner,
		}, http.StatusCreated)
		if err != nil {
			return err
		}
		netID = str(net, "id")
		if err := r.record("network", netID); err != nil {
			return err
		}
		fmt.Printf("агент: создан «%s»\n", reviewAgentName)
	} else {
		fmt.Printf("агент: «%s» уже есть\n", reviewAgentName)
	}
	tok, err := r.c.storeSession(ph)
	if err != nil {
		return err
	}

	// Бренд из каталога — у агента сразу открыты магазины.
	var brandID string
	if err := r.pool.QueryRow(r.ctx, `SELECT id::text FROM brands WHERE lower(name) = lower($1) ORDER BY is_active DESC LIMIT 1`,
		reviewAgentBrand).Scan(&brandID); err != nil {
		return fmt.Errorf("бренд %s в каталоге: %w (выполните demo seed)", reviewAgentBrand, err)
	}
	if _, err := r.c.call("POST", "/store/supply/brands", tok, obj{"brand_ids": []string{brandID}}, http.StatusOK); err != nil {
		return err
	}

	// Склад — точка агента рядом с первым магазином демо-сети (зона 15 км).
	st := r.stores[0]
	points, err := r.c.call("GET", "/store/stores", tok, nil, http.StatusOK)
	if err != nil {
		return err
	}
	if len(items(points)) == 0 {
		if _, err := r.c.call("POST", "/store/stores", tok, obj{
			"name": "Склад Fayz — Чиланзар", "address": "Чиланзар, 7-й квартал", "lat": st.lat + 0.008, "lng": st.lng - 0.006,
		}, http.StatusCreated); err != nil {
			return err
		}
	}
	whs, err := r.c.call("GET", "/store/supply/warehouses", tok, nil, http.StatusOK)
	if err != nil {
		return err
	}
	if len(items(whs)) == 0 {
		return errors.New("у агента нет склада")
	}
	wh := str(items(whs)[0], "id")

	// Товары бренда: приход на склад и отпускная цена — один раз.
	rows, err := r.pool.Query(r.ctx, `
		SELECT p.id::text, COALESCE((SELECT max(pr.price) FROM prices pr WHERE pr.product_id = p.id), 10000)::int
		FROM products p WHERE p.brand_id = $1 AND p.network_id IS NULL AND p.is_active ORDER BY p.name LIMIT 6`, brandID)
	if err != nil {
		return err
	}
	type good struct {
		id    string
		price int
	}
	goods, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (good, error) {
		var g good
		return g, row.Scan(&g.id, &g.price)
	})
	if err != nil {
		return err
	}
	if len(goods) == 0 {
		return fmt.Errorf("в каталоге нет товаров бренда %s — выполните demo seed", reviewAgentBrand)
	}
	var stocked bool
	if err := r.pool.QueryRow(r.ctx, `SELECT EXISTS (SELECT 1 FROM stock_documents WHERE network_id::text = $1 AND type = 'income')`,
		netID).Scan(&stocked); err != nil {
		return err
	}
	if !stocked {
		maker, err := r.c.call("POST", "/store/finance/counterparties", tok, obj{"name": "Coca-Cola Içecek Özbekistan"}, http.StatusCreated)
		if err != nil {
			return err
		}
		lines := make([]obj, 0, len(goods))
		prices := make([]obj, 0, len(goods))
		for _, g := range goods {
			// Закупка у производителя на 15% ниже отпускной цены для магазинов; отпускная — на 10% ниже розницы.
			sell := g.price * 90 / 100 / 100 * 100
			lines = append(lines, obj{"product_id": g.id, "qty": 240, "price": sell * 85 / 100})
			prices = append(prices, obj{"product_id": g.id, "new_price": sell})
		}
		doc, err := r.c.call("POST", "/store/inventory/documents", tok, obj{
			"type": "income", "warehouse_id": wh, "counterparty_id": str(maker, "id"), "items": lines,
		}, http.StatusCreated)
		if err != nil {
			return err
		}
		if _, err := r.c.call("POST", "/store/inventory/documents/"+str(doc, "id")+"/post", tok, nil, http.StatusOK); err != nil {
			return err
		}
		types, err := r.c.call("GET", "/store/price-types", tok, nil, http.StatusOK)
		if err != nil {
			return err
		}
		pd, err := r.c.call("POST", "/store/price-documents", tok, obj{"price_type_id": str(items(types)[0], "id"), "items": prices}, http.StatusCreated)
		if err != nil {
			return err
		}
		if _, err := r.c.call("POST", "/store/price-documents/"+str(pd, "id")+"/post", tok, nil, http.StatusOK); err != nil {
			return err
		}
		fmt.Printf("агент: на складе %d товаров %s\n", len(goods), reviewAgentBrand)
	}

	// Связь с магазинами демо-сети: код агента → «Подключить» у магазина.
	for i, s := range r.stores {
		if i >= reviewAgentLinks {
			break
		}
		var linked bool
		if err := r.pool.QueryRow(r.ctx, `
			SELECT EXISTS (SELECT 1 FROM supply_links l WHERE l.distributor_id::text = $1 AND l.store_id::text = $2 AND l.status = 'active')`,
			netID, s.id).Scan(&linked); err != nil {
			return err
		}
		if linked {
			continue
		}
		c, err := r.c.call("POST", "/store/supply/stores/"+s.id+"/code", tok, nil, http.StatusCreated)
		if err != nil {
			return err
		}
		if _, err := r.c.call("POST", "/store/suppliers/connect", r.owner, obj{"store_id": s.id, "code": str(c, "code")}, http.StatusOK); err != nil {
			return err
		}
	}

	// Новый заказ от магазина — проверяющий может принять, собрать и доставить.
	var open bool
	if err := r.pool.QueryRow(r.ctx, `
		SELECT EXISTS (SELECT 1 FROM supply_orders o WHERE o.network_id::text = $1 AND o.status = 'new')`, netID).Scan(&open); err != nil {
		return err
	}
	if !open {
		sup, err := r.c.call("GET", "/store/suppliers?store_id="+st.id, r.owner, nil, http.StatusOK)
		if err != nil {
			return err
		}
		var distID string
		for _, x := range items(sup) {
			if str(x, "id") == netID || str(x, "name") == reviewAgentName {
				distID = str(x, "id")
			}
		}
		if distID == "" {
			return fmt.Errorf("магазин не видит агента среди поставщиков: %v", sup)
		}
		lines := []obj{{"product_id": goods[0].id, "qty": 24}}
		if len(goods) > 1 {
			lines = append(lines, obj{"product_id": goods[1].id, "qty": 12})
		}
		if _, err := r.c.call("POST", "/store/supplier-orders", r.owner, obj{"store_id": st.id, "distributor_id": distID, "items": lines},
			http.StatusCreated); err != nil {
			return err
		}
		fmt.Println("агент: новый заказ от магазина", demoNetworks[0].stores[0].name)
	}
	creds.agentPhone, creds.agentCode, creds.agentNetwork = ph, code, reviewAgentName
	return nil
}
