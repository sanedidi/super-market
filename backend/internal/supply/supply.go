// Package supply — дистрибьюторы и магазины: связи (по коду на месте или по
// запросу), «кому чего не хватает», заказы поставщику, расход дистрибьютора
// и приход по нему у магазина. Figma «SM Дистрибьютор · приложение».
//
// Дистрибьютор — сеть вида distributor с одной точкой (склад-магазин). Его
// товары — store_products этой точки, отпускная цена — цена типа по
// умолчанию (магазин → сеть). Деньги через платформу не идут.
package supply

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"log/slog"
	"math/big"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/finance"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/notify"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

// KindDistributor — вид сети дистрибьютора.
const KindDistributor = "distributor"

// Сторона связи.
const (
	SideStore       = "store"
	SideDistributor = "distributor"
	SideCode        = "code"
)

// Статусы связи.
const (
	LinkRequested    = "requested"
	LinkActive       = "active"
	LinkRejected     = "rejected"
	LinkDisconnected = "disconnected"
)

// Статусы товара/магазина для дистрибьютора.
const (
	StatusOut = "out" // закончилось
	StatusLow = "low" // мало: не хватит до следующей поставки
	StatusOK  = "ok"  // есть
	// StatusUnknown — остаток в магазине не посчитан («Только товары и цены»
	// или «Остальное посчитаю потом»): сколько товара, неизвестно.
	StatusUnknown   = "unknown"
	StatusNoBrand   = "no_brand"   // подключён, но ни одного нашего товара
	StatusNotLinked = "not_linked" // не подключён — данных нет
)

// salesWindowDays — за сколько дней считаются продажи в день.
const salesWindowDays = 28

// reserveDays — запас сверх срока поставки в рекомендации.
const reserveDays = 7

// nearbyRadiusM — неподключённые магазины на карте дистрибьютора.
const nearbyRadiusM = 15000

// searchRadiusM — магазин ищет дистрибьюторов в этом радиусе (и без точки на карте).
const searchRadiusM = 60000

type Service struct {
	pool     *pgxpool.Pool
	inv      *inventory.Service
	fin      *finance.Service
	notifier *notify.Notifier
	log      *slog.Logger
}

func NewService(pool *pgxpool.Pool, inv *inventory.Service, log *slog.Logger) *Service {
	s := &Service{pool: pool, inv: inv, log: log}
	inv.Shipments = hooks{s}
	return s
}

// WithFinance подключает кассы: «Оплатить» агенту из «SM Магазин» и акт
// сверки агента; оплаты контрагенту-агенту ждут его подтверждения.
func (s *Service) WithFinance(fin *finance.Service) *Service {
	s.fin = fin
	fin.Payments = s.PaymentHook()
	return s
}

// WithNotifier — заявки на бренды супер-админам в Telegram.
func (s *Service) WithNotifier(n *notify.Notifier) *Service {
	s.notifier = n
	return s
}

// ------------------------------------------------------------- проверки

func requireDistributor(p *identity.Principal) error {
	if p.NetworkKind != KindDistributor {
		return apperr.Forbidden("раздел только для дистрибьютора").Uz("boʻlim faqat distribyutor uchun")
	}
	return nil
}

func requireStoreSide(p *identity.Principal) error {
	if p.NetworkKind == KindDistributor {
		return apperr.Forbidden("раздел только для магазина").Uz("boʻlim faqat doʻkon uchun")
	}
	return nil
}

// point — точка дистрибьютора: его склад-магазин.
type point struct {
	StoreID     string
	WarehouseID string
	LeadDays    int
	PriceTypeID string
}

// distPoint — точка дистрибьютора networkID. Нет точки — первая настройка не пройдена.
func distPoint(ctx context.Context, q db.Querier, networkID string) (point, error) {
	var pt point
	var wh *string
	err := q.QueryRow(ctx, `
		SELECT s.id, s.default_warehouse_id, n.lead_days, pt.id
		FROM networks n
		JOIN stores s       ON s.network_id = n.id AND s.status = 'active'
		JOIN price_types pt ON pt.network_id = n.id AND pt.is_default
		WHERE n.id = $1 AND n.kind = 'distributor'
		ORDER BY s.created_at LIMIT 1`, networkID).Scan(&pt.StoreID, &wh, &pt.LeadDays, &pt.PriceTypeID)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && wh == nil) {
		return point{}, apperr.Conflict("distributor_setup", "сначала заполните точку склада в первой настройке").Uz("avval birinchi sozlashda ombor manzilini toʻldiring")
	}
	if err != nil {
		return point{}, err
	}
	pt.WarehouseID = *wh
	return pt, nil
}

// priceSQL — отпускная цена товара alias.id у дистрибьютора: цена точки →
// цена сети (тип по умолчанию). Без цены — NULL (товар не заказать).
// $pt — тип цен, $st — точка дистрибьютора.
func priceSQL(alias, pt, st string) string {
	return fmt.Sprintf(`COALESCE(
		(SELECT pr.price FROM prices pr WHERE pr.product_id = %[1]s.id AND pr.price_type_id = %[2]s AND pr.store_id = %[3]s),
		(SELECT pr.price FROM prices pr WHERE pr.product_id = %[1]s.id AND pr.price_type_id = %[2]s AND pr.store_id IS NULL))`, alias, pt, st)
}

// stockSQL — остаток товара product (выражение) в магазине store (выражение).
func stockSQL(store, product string) string {
	return fmt.Sprintf(`COALESCE((SELECT sum(b.qty_remaining) FROM batches b JOIN warehouses w ON w.id = b.warehouse_id
		WHERE w.store_id = %s AND b.product_id = %s AND b.qty_remaining > 0), 0)`, store, product)
}

// perDaySQL — продажи товара в магазине в день за последние 28 дней (касса и онлайн).
func perDaySQL(store, product string) string {
	return fmt.Sprintf(`COALESCE((SELECT -sum(m.qty) FROM stock_movements m JOIN warehouses w ON w.id = m.warehouse_id
		WHERE w.store_id = %s AND m.product_id = %s AND m.doc_type IN ('sale', 'order') AND m.qty < 0
		  AND m.created_at > now() - interval '%d days'), 0) / %d.0`, store, product, salesWindowDays, salesWindowDays)
}

// statusSQL — статус строки по остатку qty и продажам в день perDay при сроке поставки lead.
func statusSQL(qty, perDay, lead string) string {
	return fmt.Sprintf(`CASE WHEN %[1]s <= 0 THEN 'out'
		WHEN %[2]s > 0 AND %[1]s < %[2]s * (%[3]s + 1) THEN 'low' ELSE 'ok' END`, qty, perDay, lead)
}

// knownStatusSQL — статус товара, если его остаток посчитан (uncounted —
// условие «не посчитан»), иначе unknown.
func knownStatusSQL(uncounted, status string) string {
	return fmt.Sprintf(`CASE WHEN %s THEN 'unknown' ELSE %s END`, uncounted, status)
}

// recommendSQL — сколько привезти: продажи в день × (срок поставки + запас) − остаток,
// вверх до целого; закончившемуся товару без продаж — хотя бы 1.
func recommendSQL(qty, perDay, lead string) string {
	return fmt.Sprintf(`GREATEST(CEIL(GREATEST(%[2]s * (%[3]s + %[4]d), CASE WHEN %[1]s <= 0 THEN 1 ELSE 0 END) - GREATEST(%[1]s, 0)), 0)`,
		qty, perDay, lead, reserveDays)
}

// code4 — случайный код из 4 цифр.
func code4() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(10000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%04d", n.Int64()), nil
}

// ownerEmployee — сотрудник-владелец сети (от его имени создаётся приход у магазина).
func ownerEmployee(ctx context.Context, q db.Querier, networkID string) (string, error) {
	var id string
	err := q.QueryRow(ctx, `
		SELECT e.id FROM employees e JOIN roles r ON r.id = e.role_id
		WHERE e.network_id = $1 AND r.is_owner ORDER BY e.created_at LIMIT 1`, networkID).Scan(&id)
	return id, err
}

// ensureCounterparty — контрагент второй стороны в сети networkID.
// distributorID или storeID — кого заводим (одно из двух).
func ensureCounterparty(ctx context.Context, q db.Querier, networkID string, distributorID, storeID *string) (string, error) {
	var id string
	var err error
	if distributorID != nil {
		err = q.QueryRow(ctx, `SELECT id FROM counterparties WHERE network_id = $1 AND distributor_id = $2`, networkID, *distributorID).Scan(&id)
	} else {
		err = q.QueryRow(ctx, `SELECT id FROM counterparties WHERE network_id = $1 AND store_id = $2`, networkID, *storeID).Scan(&id)
	}
	if err == nil {
		_, err = q.Exec(ctx, `UPDATE counterparties SET is_active = true WHERE id = $1 AND NOT is_active`, id)
		return id, err
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return "", err
	}
	if distributorID != nil {
		err = q.QueryRow(ctx, `
			INSERT INTO counterparties (network_id, name, phone, note, distributor_id)
			SELECT $1, n.name, COALESCE((SELECT s.phone FROM stores s WHERE s.network_id = n.id ORDER BY s.created_at LIMIT 1), ''),
			       'Дистрибьютор в Super Market', n.id
			FROM networks n WHERE n.id = $2
			RETURNING id`, networkID, *distributorID).Scan(&id)
	} else {
		err = q.QueryRow(ctx, `
			INSERT INTO counterparties (network_id, name, phone, note, store_id)
			SELECT $1, s.name, s.phone, 'Магазин в Super Market' || CASE WHEN s.address <> '' THEN ' · ' || s.address ELSE '' END, s.id
			FROM stores s WHERE s.id = $2
			RETURNING id`, networkID, *storeID).Scan(&id)
	}
	return id, err
}

// activeLink — активная связь магазина и дистрибьютора.
func activeLink(ctx context.Context, q db.Querier, storeID, distributorID string) (string, error) {
	var id string
	err := q.QueryRow(ctx, `SELECT id FROM supply_links WHERE store_id = $1 AND distributor_id = $2 AND status = 'active'`,
		storeID, distributorID).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", apperr.Conflict("not_linked", "магазин и дистрибьютор не подключены друг к другу").Uz("doʻkon va distribyutor bir-biriga ulanmagan")
	}
	return id, err
}
