package cafe

import (
	"context"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

// Меню кафе для кассы (GET /pos/catalog, поле cafe): группы, цеха, блюда с
// модификаторами, стоп-лист точки. Небольшое — приходит целиком при каждой
// синхронизации; товары (цены, ИКПУ, фото) — в обычном каталоге кассы.

type PosGroup struct {
	ID         string  `json:"id"`
	Name       string  `json:"name"`
	Color      string  `json:"color"`
	Sort       int     `json:"sort"`
	WorkshopID *string `json:"workshop_id"`
}

type PosWorkshop struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Icon        string `json:"icon"`
	IsDefault   bool   `json:"is_default"`
	CookMinutes int    `json:"cook_minutes"`
	TicketPrint string `json:"ticket_print"`
	// Принтер бегунков цеха: none — печатает касса на свой принтер чеков
	// (как и pos), network — касса отправляет на IP:порт в сети кафе.
	PrinterKind  string `json:"printer_kind"`
	PrinterHost  string `json:"printer_host"`
	PrinterPort  int    `json:"printer_port"`
	PrinterPaper int    `json:"printer_paper"`
}

type PosDish struct {
	ProductID string  `json:"product_id"`
	Kind      string  `json:"kind"`
	MenuCode  *int    `json:"menu_code"`
	GroupID   *string `json:"group_id"`
	// Цех, куда уходит блюдо (свой, группы или цех по умолчанию).
	WorkshopID  *string  `json:"workshop_id"`
	ModGroups   []string `json:"modifier_group_ids"`
	Portion     string   `json:"portion"`
	CookMinutes *int     `json:"cook_minutes"`
	// Продаётся в этой точке (иначе плитки нет, но старые чеки работают).
	OnSale bool `json:"on_sale"`
}

type PosModOption struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	NameRu string `json:"name_ru"`
	Price  string `json:"price"`
	Action string `json:"action"`
	Factor string `json:"factor"`
}

type PosModGroup struct {
	ID      string         `json:"id"`
	Name    string         `json:"name"`
	Min     int            `json:"min_select"`
	Max     int            `json:"max_select"`
	Options []PosModOption `json:"options"`
}

type PosMenu struct {
	Mode           string        `json:"mode"`
	ServicePercent string        `json:"service_percent"`
	Groups         []PosGroup    `json:"groups"`
	Workshops      []PosWorkshop `json:"workshops"`
	Dishes         []PosDish     `json:"dishes"`
	ModGroups      []PosModGroup `json:"modifier_groups"`
	// Блюда на стопе в этой точке.
	Stop []string `json:"stop"`
	// Звук на экране кухни при новом заказе.
	KitchenSound bool `json:"kitchen_sound"`
}

// MenuForPOS — меню кафе для кассы точки; nil — сеть не кафе.
func MenuForPOS(ctx context.Context, q db.Querier, networkID, storeID string) (*PosMenu, error) {
	out := &PosMenu{}
	var bt string
	if err := q.QueryRow(ctx, `SELECT business_type, cafe_mode, trim_scale(service_percent)::text, kitchen_sound FROM networks WHERE id = $1`, networkID).
		Scan(&bt, &out.Mode, &out.ServicePercent, &out.KitchenSound); err != nil {
		return nil, err
	}
	if bt != BusinessCafe {
		return nil, nil
	}
	rows, err := q.Query(ctx, `SELECT id, loc(name, name_uz), color, sort, workshop_id FROM menu_groups
		WHERE network_id = $1 AND is_active ORDER BY sort, name`, networkID)
	if err != nil {
		return nil, err
	}
	if out.Groups, err = pgx.CollectRows(rows, pgx.RowToStructByPos[PosGroup]); err != nil {
		return nil, err
	}
	rows, err = q.Query(ctx, `SELECT id, loc(name, name_uz), icon, is_default, cook_minutes, ticket_print,
		printer_kind, printer_host, printer_port, printer_paper FROM workshops
		WHERE network_id = $1 AND is_active ORDER BY is_default DESC, sort, name`, networkID)
	if err != nil {
		return nil, err
	}
	if out.Workshops, err = pgx.CollectRows(rows, pgx.RowToStructByPos[PosWorkshop]); err != nil {
		return nil, err
	}
	rows, err = q.Query(ctx, `
		SELECT p.id, p.kind, p.menu_code, p.menu_group_id,
		       COALESCE(p.workshop_id, g.workshop_id, (SELECT d.id FROM workshops d WHERE d.network_id = p.network_id AND d.is_default)),
		       COALESCE((SELECT array_agg(pm.group_id::text ORDER BY pm.sort, pm.group_id) FROM product_modifier_groups pm
		                 JOIN modifier_groups mg ON mg.id = pm.group_id AND mg.is_active WHERE pm.product_id = p.id), '{}'),
		       p.portion, p.cook_minutes,
		       EXISTS (SELECT 1 FROM store_products sp WHERE sp.store_id = $2 AND sp.product_id = p.id)
		FROM products p LEFT JOIN menu_groups g ON g.id = p.menu_group_id
		WHERE p.network_id = $1 AND p.kind <> 'goods'
		ORDER BY p.menu_code NULLS LAST, p.name`, networkID, storeID)
	if err != nil {
		return nil, err
	}
	if out.Dishes, err = pgx.CollectRows(rows, pgx.RowToStructByPos[PosDish]); err != nil {
		return nil, err
	}
	rows, err = q.Query(ctx, `SELECT id, loc(name, name_uz), min_select, max_select FROM modifier_groups
		WHERE network_id = $1 AND is_active ORDER BY sort, name`, networkID)
	if err != nil {
		return nil, err
	}
	groups, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (PosModGroup, error) {
		var g PosModGroup
		err := r.Scan(&g.ID, &g.Name, &g.Min, &g.Max)
		g.Options = []PosModOption{}
		return g, err
	})
	if err != nil {
		return nil, err
	}
	idx := map[string]int{}
	for i, g := range groups {
		idx[g.ID] = i
	}
	rows, err = q.Query(ctx, `
		SELECT o.group_id, o.id, loc(o.name, o.name_uz), o.name, o.price::text, o.action, COALESCE(trim_scale(o.factor)::text, '')
		FROM modifier_options o JOIN modifier_groups g ON g.id = o.group_id
		WHERE g.network_id = $1 AND g.is_active AND o.is_active ORDER BY o.sort, o.name`, networkID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var gid string
		var o PosModOption
		if err := rows.Scan(&gid, &o.ID, &o.Name, &o.NameRu, &o.Price, &o.Action, &o.Factor); err != nil {
			return nil, err
		}
		if i, ok := idx[gid]; ok {
			groups[i].Options = append(groups[i].Options, o)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	out.ModGroups = groups
	srows, err := q.Query(ctx, `SELECT product_id::text FROM stop_list WHERE store_id = $1`, storeID)
	if err != nil {
		return nil, err
	}
	if out.Stop, err = pgx.CollectRows(srows, pgx.RowTo[string]); err != nil {
		return nil, err
	}
	if out.Stop == nil {
		out.Stop = []string{}
	}
	return out, nil
}
