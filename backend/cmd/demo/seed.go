package main

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	mrand "math/rand/v2"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/config"
	"github.com/sanedidi/super-market/backend/internal/platform/phone"
	"github.com/sanedidi/super-market/backend/internal/server"
)

// Служебный супер-админ, от имени которого создаётся каталог. После seed
// права у него забираются, clean удаляет его совсем.
const demoAdminPhone = "+998900000100"

type seeder struct {
	ctx   context.Context
	pool  *pgxpool.Pool
	c     client
	rnd   *mrand.Rand
	start time.Time
	// Пользователи, существовавшие до seed (их clean не удаляет).
	existed map[string]bool
	phones  []string

	units    map[string]string // шт → id
	products []seededProduct
}

type seededProduct struct {
	id, name, unit, category, topCategory string
	price                                 int
}

func (s *seeder) record(kind, id string) error {
	_, err := s.pool.Exec(s.ctx, `INSERT INTO demo_seed (kind, id) VALUES ($1, $2) ON CONFLICT DO NOTHING`, kind, id)
	return err
}

func seed(ctx context.Context, cfg config.Config, pool *pgxpool.Pool, ownerPhone string) error {
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM demo_seed`).Scan(&n); err != nil {
		return err
	}
	if n > 0 {
		return errors.New("демо-данные уже загружены — сначала выполните demo clean")
	}

	s := &seeder{ctx: ctx, pool: pool, rnd: mrand.New(mrand.NewPCG(2026, 9)), start: time.Now(), existed: map[string]bool{}}

	// Владелец «Baraka Market»: указанный телефон, если он ещё не сотрудник другой сети.
	if ownerPhone != "" {
		ph, err := phone.Normalize(ownerPhone)
		if err != nil {
			return fmt.Errorf("телефон владельца: %w", err)
		}
		var busy bool
		if err := pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM employees e JOIN users u ON u.id = e.user_id WHERE u.phone = $1)`, ph).Scan(&busy); err != nil {
			return err
		}
		if busy {
			fmt.Printf("! %s уже сотрудник другой сети — владельцем Baraka Market будет демо-номер\n", ph)
		} else {
			demoNetworks[0].ownerPhone = ph
			demoNetworks[0].ownerName = "Владелец"
		}
	}
	s.phones = []string{demoAdminPhone}
	for _, nw := range demoNetworks {
		s.phones = append(s.phones, nw.ownerPhone)
	}
	for _, ph := range s.phones {
		var ok bool
		if err := pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM users WHERE phone = $1)`, ph).Scan(&ok); err != nil {
			return err
		}
		s.existed[ph] = ok
	}

	code, err := randomCode()
	if err != nil {
		return err
	}
	local := cfg
	local.DevOTPCode = code
	local.SuperAdminPhones = []string{demoAdminPhone}
	local.TelegramBotToken = ""
	app, err := server.Build(ctx, local, pool, nil, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		return err
	}
	s.c = client{h: app.Handler, code: code, pool: pool, secret: cfg.JWTSecret}
	s.c.reviewPhone, s.c.reviewCode, _ = cfg.Review() // номер проверки принимает только свой код

	// Что бы ни случилось дальше — забрать права и сессии, записать созданных пользователей.
	defer s.finish()

	if err := s.run(); err != nil {
		return fmt.Errorf("%w\nчасть данных могла загрузиться — удалите её командой demo clean", err)
	}
	if err := app.Orders.RefreshPopularity(ctx); err != nil {
		return fmt.Errorf("популярность: %w", err)
	}
	fmt.Println("готово: демо-данные загружены")
	return nil
}

func (s *seeder) finish() {
	ctx := context.Background()
	for _, ph := range s.phones {
		var id string
		if err := s.pool.QueryRow(ctx, `SELECT id FROM users WHERE phone = $1`, ph).Scan(&id); err != nil {
			continue
		}
		if !s.existed[ph] {
			_, _ = s.pool.Exec(ctx, `INSERT INTO demo_seed (kind, id) VALUES ('user', $1) ON CONFLICT DO NOTHING`, id)
		}
		_, _ = s.pool.Exec(ctx, `DELETE FROM sessions WHERE user_id = $1 AND created_at >= $2`, id, s.start)
	}
	_, _ = s.pool.Exec(ctx, `DELETE FROM platform_admins WHERE user_id = (SELECT id FROM users WHERE phone = $1)`, demoAdminPhone)
	_, _ = s.pool.Exec(ctx, `DELETE FROM auth_codes WHERE phone = ANY($1) AND sent_at >= $2`, s.phones, s.start)
}

func randomCode() (string, error) {
	v, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", v.Int64()), nil
}

func (s *seeder) run() error {
	admin, err := s.c.login(demoAdminPhone, identity.AppAdmin)
	if err != nil {
		return err
	}
	if err := s.catalog(admin); err != nil {
		return err
	}
	fmt.Printf("каталог: %d товаров\n", len(s.products))

	var promoForBanner, networkForBanner string
	for i, nw := range demoNetworks {
		promo, netID, err := s.network(admin, nw)
		if err != nil {
			return fmt.Errorf("сеть %s: %w", nw.name, err)
		}
		if i == 0 {
			promoForBanner, networkForBanner = promo, netID
		}
		fmt.Printf("сеть %s: %d магазин(а)\n", nw.name, len(nw.stores))
	}
	return s.banners(admin, promoForBanner, networkForBanner)
}

// ------------------------------------------------------------------ каталог

func (s *seeder) catalog(tok string) error {
	s.units = map[string]string{}
	out, err := s.c.call("GET", "/admin/catalog/units", tok, nil, http.StatusOK)
	if err != nil {
		return err
	}
	for _, u := range items(out) {
		s.units[str(u, "short_name")] = str(u, "id")
	}

	brands := map[string]string{}
	if out, err = s.c.call("GET", "/admin/catalog/brands", tok, nil, http.StatusOK); err != nil {
		return err
	}
	for _, b := range items(out) {
		brands[strings.ToLower(str(b, "name"))] = str(b, "id")
	}
	cats := map[string]string{} // parent|name → id
	if out, err = s.c.call("GET", "/admin/catalog/categories", tok, nil, http.StatusOK); err != nil {
		return err
	}
	for _, c := range items(out) {
		cats[str(c, "parent_id")+"|"+strings.ToLower(str(c, "name"))] = str(c, "id")
	}

	brandID := func(name string) (string, error) {
		if name == "" {
			return "", nil
		}
		if id, ok := brands[strings.ToLower(name)]; ok {
			return id, nil
		}
		b, err := s.c.call("POST", "/admin/catalog/brands", tok, obj{"name": name}, http.StatusCreated)
		if err != nil {
			return "", err
		}
		brands[strings.ToLower(name)] = str(b, "id")
		return str(b, "id"), s.record("brand", str(b, "id"))
	}

	barcode := 0
	var walk func(parent string, list []demoCategory, top string, inherited demoCategory) error
	walk = func(parent string, list []demoCategory, top string, inherited demoCategory) error {
		for i, dc := range list {
			key := parent + "|" + strings.ToLower(dc.name)
			id, ok := cats[key]
			if !ok {
				body := obj{"name": dc.name, "sort": (i + 1) * 10}
				if parent != "" {
					body["parent_id"] = parent
				}
				c, err := s.c.call("POST", "/admin/catalog/categories", tok, body, http.StatusCreated)
				if err != nil {
					return err
				}
				id = str(c, "id")
				cats[key] = id
				if err := s.record("category", id); err != nil {
					return err
				}
			}
			t := top
			if t == "" {
				t = dc.name
			}
			inh := inherited
			if dc.storage != "" {
				inh.storage = dc.storage
			}
			if dc.shelfLife != "" {
				inh.shelfLife = dc.shelfLife
			}
			if dc.desc != "" {
				inh.desc = dc.desc
			}
			for _, dp := range dc.products {
				barcode++
				bid, err := brandID(dp.brand)
				if err != nil {
					return err
				}
				attrs := obj{}
				if dp.nut != nil {
					attrs["nutrition"] = obj{"kcal": dp.nut.kcal, "protein": dp.nut.protein, "fat": dp.nut.fat, "carbs": dp.nut.carbs}
				}
				if inh.storage != "" {
					attrs["storage"] = inh.storage
				}
				if inh.shelfLife != "" {
					attrs["shelf_life"] = inh.shelfLife
				}
				if dp.brand != "" {
					attrs["manufacturer"] = dp.brand
				}
				for k, v := range dp.extra {
					attrs[k] = v
				}
				desc := dp.desc
				if desc == "" {
					desc = inh.desc
				}
				body := obj{
					"name": dp.name, "category_id": id, "unit_id": s.units[dp.unit], "base_price": dp.price,
					"description": desc, "attributes": attrs, "barcodes": []string{ean13(barcode)},
				}
				if bid != "" {
					body["brand_id"] = bid
				}
				code, pr, err := s.c.do("POST", "/admin/products", tok, body)
				if err == nil && code == http.StatusConflict {
					delete(body, "barcodes") // штрихкод уже занят — без него
					code, pr, err = s.c.do("POST", "/admin/products", tok, body)
				}
				if err != nil {
					return err
				}
				if code != http.StatusCreated {
					return fmt.Errorf("товар %s: статус %d: %v", dp.name, code, pr)
				}
				if err := s.record("product", str(pr, "id")); err != nil {
					return err
				}
				s.products = append(s.products, seededProduct{
					id: str(pr, "id"), name: dp.name, unit: dp.unit, category: dc.name, topCategory: t, price: dp.price,
				})
			}
			if err := walk(id, dc.children, t, inh); err != nil {
				return err
			}
		}
		return nil
	}
	return walk("", demoCatalog, "", demoCategory{})
}

// ean13 — внутренний штрихкод магазина (префикс 200) с контрольной цифрой.
func ean13(n int) string {
	base := fmt.Sprintf("2009%08d", n)
	sum := 0
	for i, ch := range base {
		d := int(ch - '0')
		if i%2 == 1 {
			d *= 3
		}
		sum += d
	}
	return base + fmt.Sprint((10-sum%10)%10)
}

// --------------------------------------------------------------- сети

func (s *seeder) network(admin string, nw demoNetwork) (promoID, networkID string, err error) {
	body := obj{"name": nw.name, "kind": nw.kind, "owner_phone": nw.ownerPhone, "owner_name": nw.ownerName}
	net, err := s.c.call("POST", "/admin/networks", admin, body, http.StatusCreated)
	if err != nil {
		return "", "", err
	}
	networkID = str(net, "id")
	if err := s.record("network", networkID); err != nil {
		return "", "", err
	}
	tok, err := s.c.login(nw.ownerPhone, identity.AppStore)
	if err != nil {
		return "", "", err
	}

	// Цены сети: базовая + наценка сети ± небольшой разброс, кратно 100 сум.
	prices := map[string]int{}
	for _, p := range s.products {
		v := p.price
		if nw.markup > 0 {
			pct := nw.markup + s.rnd.IntN(5) - 2
			v = (p.price*(100+pct)/100 + 50) / 100 * 100
		}
		prices[p.id] = v
	}
	if nw.markup > 0 {
		types, err := s.c.call("GET", "/store/price-types", tok, nil, http.StatusOK)
		if err != nil {
			return "", "", err
		}
		var retail string
		for _, t := range items(types) {
			if t["is_default"] == true {
				retail = str(t, "id")
			}
		}
		var lines []obj
		for _, p := range s.products {
			lines = append(lines, obj{"product_id": p.id, "new_price": prices[p.id]})
		}
		doc, err := s.c.call("POST", "/store/price-documents", tok, obj{"price_type_id": retail, "note": "Цены сети", "items": lines}, http.StatusCreated)
		if err != nil {
			return "", "", err
		}
		if _, err := s.c.call("POST", "/store/price-documents/"+str(doc, "id")+"/post", tok, nil, http.StatusOK); err != nil {
			return "", "", err
		}
	}

	var storeIDs []string
	for i, ds := range nw.stores {
		id, err := s.store(tok, ds, i, prices)
		if err != nil {
			return "", "", fmt.Errorf("%s: %w", ds.name, err)
		}
		storeIDs = append(storeIDs, id)
	}

	// Акции: «Скидки недели» на 8 товаров и тематическая неделя.
	now := time.Now()
	pick := s.rnd.Perm(len(s.products))
	var weekly []obj
	for _, i := range pick[:8] {
		p := s.products[i]
		off := 10 + s.rnd.IntN(4)*5 // 10–25%
		weekly = append(weekly, obj{"product_id": p.id, "price": (prices[p.id]*(100-off)/100 + 50) / 100 * 100})
	}
	promo, err := s.c.call("POST", "/store/promotions", tok, obj{
		"name": "Скидки недели", "starts_at": now.Add(-time.Hour), "ends_at": now.Add(14 * 24 * time.Hour), "items": weekly,
	}, http.StatusCreated)
	if err != nil {
		return "", "", err
	}
	theme := map[string]string{"Baraka Market": "Молочные продукты", "Oila Market": "Овощи и фрукты", "Fresh Box": "Напитки"}[nw.name]
	var themed []obj
	for _, p := range s.products {
		if p.topCategory == theme && len(themed) < 10 {
			themed = append(themed, obj{"product_id": p.id, "price": (prices[p.id]*85/100 + 50) / 100 * 100})
		}
	}
	if len(themed) > 0 {
		if _, err := s.c.call("POST", "/store/promotions", tok, obj{
			"name": "Неделя: " + strings.ToLower(theme), "starts_at": now.Add(-time.Hour), "ends_at": now.Add(7 * 24 * time.Hour), "items": themed,
		}, http.StatusCreated); err != nil {
			return "", "", err
		}
	}
	return str(promo, "id"), networkID, nil
}

func (s *seeder) store(tok string, ds demoStore, idx int, prices map[string]int) (string, error) {
	st, err := s.c.call("POST", "/store/stores", tok, obj{
		"name": ds.name, "address": ds.address, "lat": ds.lat, "lng": ds.lng,
		"phone": fmt.Sprintf("+99871200%02d%02d", s.rnd.IntN(100), idx+10),
	}, http.StatusCreated)
	if err != nil {
		return "", err
	}
	id := str(st, "id")

	hours := []obj{} // пусто — круглосуточно
	if ds.opens != ds.closes {
		for d := 0; d < 7; d++ {
			hours = append(hours, obj{"weekday": d, "opens": ds.opens, "closes": ds.closes})
		}
	}
	if _, err := s.c.call("PUT", "/store/stores/"+id+"/delivery", tok, obj{
		"accepts_online": true, "delivery_radius_m": ds.radius, "min_order_amount": 30000,
		"eta_min": ds.etaMin, "eta_max": ds.etaMax, "working_hours": hours,
		"rules": []obj{
			{"type": "free_from", "params": obj{"amount": ds.freeFrom}, "sort": 1},
			{"type": "fixed", "params": obj{"price": ds.fee}, "sort": 2},
		},
	}, http.StatusOK); err != nil {
		return "", err
	}

	whs, err := s.c.call("GET", "/store/warehouses?store_id="+id, tok, nil, http.StatusOK)
	if err != nil {
		return "", err
	}
	if len(items(whs)) == 0 {
		return "", errors.New("у магазина нет склада")
	}
	wh := str(items(whs)[0], "id")

	// Остатки: почти весь каталог, себестоимость ~75% цены.
	type stocked struct {
		p   seededProduct
		qty float64
	}
	var stock []stocked
	var lines []obj
	for _, p := range s.products {
		if s.rnd.IntN(100) < 7 {
			continue // в каждом магазине чего-то нет
		}
		qty := float64(20 + s.rnd.IntN(100))
		if p.unit == "кг" {
			qty = float64(15 + s.rnd.IntN(50))
		}
		cost := prices[p.id] * (70 + s.rnd.IntN(10)) / 100
		lines = append(lines, obj{"product_id": p.id, "qty": qty, "price": cost})
		stock = append(stock, stocked{p, qty})
	}
	doc, err := s.c.call("POST", "/store/inventory/documents", tok, obj{"type": "posting", "warehouse_id": wh, "note": "Начальные остатки", "items": lines}, http.StatusCreated)
	if err != nil {
		return "", err
	}
	if _, err := s.c.call("POST", "/store/inventory/documents/"+str(doc, "id")+"/post", tok, nil, http.StatusOK); err != nil {
		return "", err
	}

	// Кассовые продажи — для отчётов и «хитов».
	methods, err := s.c.call("GET", "/store/finance/payment-methods?store_id="+id, tok, nil, http.StatusOK)
	if err != nil {
		return "", err
	}
	var payIDs []string
	for _, m := range items(methods) {
		payIDs = append(payIDs, str(m, "id"))
	}
	if len(payIDs) == 0 {
		return "", errors.New("нет способов оплаты")
	}
	// Популярные позиции продаются чаще.
	hot := s.rnd.Perm(len(stock))[:min(15, len(stock))]
	sold := map[string]float64{}
	for n := 0; n < 30+s.rnd.IntN(15); n++ {
		var saleItems []obj
		total := 0 // в тийинах
		used := map[string]bool{}
		for k := 0; k < 1+s.rnd.IntN(5); k++ {
			var it stocked
			if s.rnd.IntN(100) < 70 {
				it = stock[hot[s.rnd.IntN(len(hot))]]
			} else {
				it = stock[s.rnd.IntN(len(stock))]
			}
			if used[it.p.id] {
				continue
			}
			q2 := 1 + s.rnd.IntN(3) // количество × 2 (для весовых шаг 0,5)
			qty := float64(q2)
			if it.p.unit == "кг" {
				qty = float64(q2) / 2
			}
			if sold[it.p.id]+qty > it.qty {
				continue
			}
			used[it.p.id] = true
			sold[it.p.id] += qty
			saleItems = append(saleItems, obj{"product_id": it.p.id, "qty": fmt.Sprintf("%.1f", qty)})
			total += int(float64(prices[it.p.id]*100) * qty)
		}
		if len(saleItems) == 0 {
			continue
		}
		if _, err := s.c.call("POST", "/store/sales", tok, obj{
			"client_uid": fmt.Sprintf("demo-%s-%04d", id[:8], n), "store_id": id, "items": saleItems,
			"payments": []obj{{"payment_method_id": payIDs[s.rnd.IntN(len(payIDs))], "amount": fmt.Sprintf("%d.%02d", total/100, total%100)}},
		}, http.StatusCreated); err != nil {
			return "", err
		}
	}
	return id, nil
}

// --------------------------------------------------------------- баннеры

func (s *seeder) banners(admin, promoID, networkID string) error {
	var fruitCat string
	if err := s.pool.QueryRow(s.ctx, `
		SELECT c.id::text FROM categories c JOIN demo_seed d ON d.kind = 'category' AND d.id = c.id::text
		WHERE c.name = 'Овощи и фрукты'`).Scan(&fruitCat); err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	list := []obj{
		{"title": "Доставка бесплатно от 150 000 сум", "subtitle": "Во всех магазинах рядом", "color": "#155EEF", "sort": 10},
		{"title": "Скидки недели до −25%", "subtitle": "Baraka Market", "color": "#FF6A1A", "sort": 20,
			"link_type": "promotion", "link_id": promoID, "network_id": networkID},
	}
	if fruitCat != "" {
		list = append(list, obj{"title": "Свежие овощи и фрукты", "subtitle": "Привезём за 30 минут", "color": "#12B76A", "sort": 30,
			"link_type": "category", "link_id": fruitCat})
	}
	for _, b := range list {
		out, err := s.c.call("POST", "/admin/banners", admin, b, http.StatusCreated)
		if err != nil {
			return err
		}
		if err := s.record("banner", str(out, "id")); err != nil {
			return err
		}
	}
	return nil
}
