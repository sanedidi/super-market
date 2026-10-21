// Package cafe — кафе и рестораны: настройки кафе, цеха, группы меню,
// блюда и заготовки с техкартами, модификаторы, производство заготовок и
// списание продуктов по техкарте при продаже.
//
// Блюдо и заготовка — товары сети (products.kind = dish / prep), поэтому
// касса, цены, фото, ИКПУ и продажи работают с ними как с обычным товаром.
// Figma «Super Market · Кафе и рестораны», план «Кафе и рестораны: план
// реализации», этап 1.
package cafe

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Типы бизнеса сети.
const (
	BusinessStore = "store"
	BusinessCafe  = "cafe"
)

// Виды товара.
const (
	KindGoods = "goods"
	KindDish  = "dish"
	KindPrep  = "prep"
)

// DishCategoryID — служебная категория общего каталога для блюд и заготовок
// (миграция 0068_cafe).
const DishCategoryID = "00000000-0000-0000-0000-0000000caf01"

type Service struct {
	pool *pgxpool.Pool
	now  func() time.Time
}

func NewService(pool *pgxpool.Pool) *Service { return &Service{pool: pool, now: time.Now} }

var errNotCafe = apperr.New(403, "not_cafe", "раздел только для кафе и ресторанов").Uz("boʻlim faqat kafe va restoranlar uchun")

// requireCafe — сеть работает как кафе.
func requireCafe(ctx context.Context, q db.Querier, networkID string) error {
	var bt string
	if err := q.QueryRow(ctx, `SELECT business_type FROM networks WHERE id = $1`, networkID).Scan(&bt); err != nil {
		return err
	}
	if bt != BusinessCafe {
		return errNotCafe
	}
	return nil
}

func (s *Service) read(ctx context.Context, p *identity.Principal) error {
	return requireCafe(ctx, s.pool, p.NetworkID)
}

func (s *Service) manage(ctx context.Context, p *identity.Principal) error {
	if err := p.Require(identity.PermCatalogManage); err != nil {
		return err
	}
	return requireCafe(ctx, s.pool, p.NetworkID)
}

// EnsureDefaults — у кафе есть цех «Кухня» по умолчанию. Вызывается при
// создании сети-кафе и при смене типа сети на «кафе».
func EnsureDefaults(ctx context.Context, tx pgx.Tx, networkID string) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO workshops (network_id, name, name_uz, is_default)
		SELECT $1, 'Кухня', 'Oshxona', true
		WHERE NOT EXISTS (SELECT 1 FROM workshops WHERE network_id = $1 AND is_default)
		ON CONFLICT DO NOTHING`, networkID)
	return err
}

// ---------------------------------------------------------------- настройки

type Settings struct {
	BusinessType   string `json:"business_type"`
	CafeMode       string `json:"cafe_mode"`
	ServicePercent string `json:"service_percent"`
	// Кухня (П7 «Заказы на кухне», «Экран выдачи»).
	KitchenSound       bool `json:"kitchen_sound"`
	DisplayShowCooking bool `json:"display_show_cooking"`
	DisplayHideMinutes int  `json:"display_hide_minutes"`
}

type SettingsInput struct {
	CafeMode           *string       `json:"cafe_mode"`
	ServicePercent     *money.Amount `json:"service_percent"`
	KitchenSound       *bool         `json:"kitchen_sound"`
	DisplayShowCooking *bool         `json:"display_show_cooking"`
	DisplayHideMinutes *int          `json:"display_hide_minutes"`
}

// GetSettings — тип бизнеса виден всем сетям (панель строит меню по нему).
func (s *Service) GetSettings(ctx context.Context, p *identity.Principal) (Settings, error) {
	var out Settings
	err := s.pool.QueryRow(ctx, `SELECT business_type, cafe_mode, trim_scale(service_percent)::text,
		kitchen_sound, display_show_cooking, display_hide_minutes FROM networks WHERE id = $1`,
		p.NetworkID).Scan(&out.BusinessType, &out.CafeMode, &out.ServicePercent,
		&out.KitchenSound, &out.DisplayShowCooking, &out.DisplayHideMinutes)
	return out, err
}

func (s *Service) UpdateSettings(ctx context.Context, p *identity.Principal, in SettingsInput) (Settings, error) {
	if err := p.Require(identity.PermStoresManage); err != nil {
		return Settings{}, err
	}
	if err := s.read(ctx, p); err != nil {
		return Settings{}, err
	}
	if in.CafeMode != nil && *in.CafeMode != "counter" && *in.CafeMode != "tables" && *in.CafeMode != "both" {
		return Settings{}, apperr.Validation("cafe_mode: ожидается counter, tables или both").Uz("cafe_mode: counter, tables yoki both boʻlishi kerak")
	}
	var pct *string
	if in.ServicePercent != nil {
		v := money.D(string(*in.ServicePercent))
		if !in.ServicePercent.Valid() || v.Sign() < 0 || v.Cmp(money.D("30")) > 0 {
			return Settings{}, apperr.Validation("service_percent: от 0 до 30").Uz("service_percent: 0 dan 30 gacha")
		}
		x := v.Money()
		pct = &x
	}
	if in.DisplayHideMinutes != nil && (*in.DisplayHideMinutes < 1 || *in.DisplayHideMinutes > 120) {
		return Settings{}, apperr.Validation("display_hide_minutes: от 1 до 120").Uz("display_hide_minutes: 1 dan 120 gacha")
	}
	if err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `UPDATE networks SET cafe_mode = COALESCE($2, cafe_mode),
			service_percent = COALESCE($3::numeric, service_percent), kitchen_sound = COALESCE($4, kitchen_sound),
			display_show_cooking = COALESCE($5, display_show_cooking), display_hide_minutes = COALESCE($6, display_hide_minutes)
			WHERE id = $1`, p.NetworkID, in.CafeMode, pct, in.KitchenSound, in.DisplayShowCooking, in.DisplayHideMinutes); err != nil {
			return err
		}
		return bumpNetwork(ctx, tx, p.NetworkID)
	}); err != nil {
		return Settings{}, err
	}
	return s.GetSettings(ctx, p)
}

// --------------------------------------------------------------------- цеха

type Workshop struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	NameRu     string `json:"name_ru"`
	NameUz     string `json:"name_uz"`
	Sort       int    `json:"sort"`
	IsDefault  bool   `json:"is_default"`
	IsActive   bool   `json:"is_active"`
	GroupCount int    `json:"group_count"`
	DishCount  int    `json:"dish_count"`
	// Значок, норма по умолчанию, мин, и когда печатать бегунок.
	Icon        string `json:"icon"`
	CookMinutes int    `json:"cook_minutes"`
	TicketPrint string `json:"ticket_print"`
	// Группы меню цеха (id и названия по порядку).
	GroupIDs   []string `json:"group_ids"`
	GroupNames []string `json:"group_names"`
	// Принтер бегунков: none — касса печатает на свой принтер, network — по
	// сети. Состояние присылает касса: ok (nil — ещё не печатала), сколько
	// бегунков ждут, когда отвечала; test_at — запрошен «Тест печати».
	PrinterKind    string     `json:"printer_kind"`
	PrinterHost    string     `json:"printer_host"`
	PrinterPort    int        `json:"printer_port"`
	PrinterPaper   int        `json:"printer_paper"`
	PrinterOK      *bool      `json:"printer_ok"`
	PrinterPending int        `json:"printer_pending"`
	PrinterSeenAt  *time.Time `json:"printer_seen_at"`
	PrinterTestAt  *time.Time `json:"printer_test_at"`
}

const workshopSelect = `
	SELECT w.id, loc(w.name, w.name_uz), w.name, w.name_uz, w.sort, w.is_default, w.is_active,
	       (SELECT count(*) FROM menu_groups g WHERE g.network_id = w.network_id AND g.is_active
	         AND (g.workshop_id = w.id OR (g.workshop_id IS NULL AND w.is_default)))::int,
	       (SELECT count(*) FROM products p
	         LEFT JOIN menu_groups g ON g.id = p.menu_group_id
	         WHERE p.network_id = w.network_id AND p.kind = 'dish' AND p.is_active
	           AND COALESCE(p.workshop_id, g.workshop_id, (SELECT d.id FROM workshops d WHERE d.network_id = w.network_id AND d.is_default)) = w.id)::int,
	       w.icon, w.cook_minutes, w.ticket_print,
	       COALESCE((SELECT array_agg(g.id::text ORDER BY g.sort, g.name) FROM menu_groups g
	                 WHERE g.network_id = w.network_id AND g.is_active AND (g.workshop_id = w.id OR (g.workshop_id IS NULL AND w.is_default))), '{}'),
	       COALESCE((SELECT array_agg(loc(g.name, g.name_uz) ORDER BY g.sort, g.name) FROM menu_groups g
	                 WHERE g.network_id = w.network_id AND g.is_active AND (g.workshop_id = w.id OR (g.workshop_id IS NULL AND w.is_default))), '{}'),
	       w.printer_kind, w.printer_host, w.printer_port, w.printer_paper, w.printer_ok, w.printer_pending,
	       w.printer_seen_at, w.printer_test_at
	FROM workshops w`

type NameInput struct {
	Name   *string `json:"name"`
	NameUz *string `json:"name_uz"`
}

// names — русское и узбекское название; одно из них обязательно при создании.
func names(in NameInput, create bool) (ru, uz *string, err error) {
	t := func(p *string) *string {
		if p == nil {
			return nil
		}
		v := strings.TrimSpace(*p)
		return &v
	}
	ru, uz = t(in.Name), t(in.NameUz)
	if ru != nil && *ru == "" && uz != nil && *uz != "" {
		ru = uz
	}
	if create && (ru == nil || *ru == "") {
		if uz == nil || *uz == "" {
			return nil, nil, apperr.Validation("name: обязательное поле").Uz("name: majburiy maydon")
		}
		ru = uz
	}
	if ru != nil && (*ru == "" || len([]rune(*ru)) > 60) {
		return nil, nil, apperr.Validation("name: от 1 до 60 символов").Uz("name: 1 dan 60 gacha belgi")
	}
	if uz != nil && len([]rune(*uz)) > 60 {
		return nil, nil, apperr.Validation("name_uz: до 60 символов").Uz("name_uz: 60 belgigacha")
	}
	return ru, uz, nil
}

func (s *Service) ListWorkshops(ctx context.Context, p *identity.Principal) ([]Workshop, error) {
	if err := s.read(ctx, p); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, workshopSelect+` WHERE w.network_id = $1 AND w.is_active ORDER BY w.is_default DESC, w.sort, w.name`, p.NetworkID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Workshop])
}

func getWorkshop(ctx context.Context, q db.Querier, networkID, id string) (Workshop, error) {
	rows, err := q.Query(ctx, workshopSelect+` WHERE w.network_id = $1 AND w.id = $2`, networkID, id)
	if err != nil {
		return Workshop{}, err
	}
	w, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Workshop])
	if errors.Is(err, pgx.ErrNoRows) {
		return w, apperr.NotFound("цех не найден").Uz("sex topilmadi")
	}
	return w, err
}

type WorkshopInput struct {
	NameInput
	Sort        *int    `json:"sort"`
	Icon        *string `json:"icon"`
	CookMinutes *int    `json:"cook_minutes"`
	TicketPrint *string `json:"ticket_print"`
	// GroupIDs — группы меню, которые переезжают в этот цех (П7б «Новый цех»).
	GroupIDs *[]string `json:"group_ids"`
	// Принтер бегунков цеха (П7в «Подключить принтер»).
	PrinterKind  *string `json:"printer_kind"`
	PrinterHost  *string `json:"printer_host"`
	PrinterPort  *int    `json:"printer_port"`
	PrinterPaper *int    `json:"printer_paper"`
}

var errWorkshopExists = apperr.Conflict("workshop_exists", "цех с таким названием уже есть").Uz("bunday nomli sex allaqachon bor")

var workshopIcons = map[string]bool{"fire": true, "bakery": true, "bar": true, "soup": true, "grill": true, "salad": true, "pizza": true, "cafe": true}

func (in WorkshopInput) validate() error {
	if in.Icon != nil && !workshopIcons[*in.Icon] {
		return apperr.Validation("icon: неизвестный значок").Uz("icon: nomaʼlum belgi")
	}
	if in.CookMinutes != nil && (*in.CookMinutes < 1 || *in.CookMinutes > 600) {
		return apperr.Validation("cook_minutes: от 1 до 600").Uz("cook_minutes: 1 dan 600 gacha")
	}
	if in.TicketPrint != nil && *in.TicketPrint != "always" && *in.TicketPrint != "offline" && *in.TicketPrint != "never" {
		return apperr.Validation("ticket_print: ожидается always, offline или never").Uz("ticket_print: always, offline yoki never boʻlishi kerak")
	}
	if in.PrinterKind != nil && *in.PrinterKind != "none" && *in.PrinterKind != "network" {
		return apperr.Validation("printer_kind: ожидается none или network").Uz("printer_kind: none yoki network boʻlishi kerak")
	}
	if in.PrinterHost != nil {
		h := strings.TrimSpace(*in.PrinterHost)
		if len(h) > 100 || strings.ContainsAny(h, " /\\") {
			return apperr.Validation("printer_host: IP-адрес принтера, например 192.168.1.40").Uz("printer_host: printer IP manzili, masalan 192.168.1.40")
		}
		*in.PrinterHost = h
	}
	if in.PrinterKind != nil && *in.PrinterKind == "network" && (in.PrinterHost == nil || *in.PrinterHost == "") {
		return apperr.Validation("printer_host: укажите IP-адрес принтера").Uz("printer_host: printer IP manzilini kiriting")
	}
	if in.PrinterPort != nil && (*in.PrinterPort < 1 || *in.PrinterPort > 65535) {
		return apperr.Validation("printer_port: от 1 до 65535 (обычно 9100)").Uz("printer_port: 1 dan 65535 gacha (odatda 9100)")
	}
	if in.PrinterPaper != nil && *in.PrinterPaper != 58 && *in.PrinterPaper != 80 {
		return apperr.Validation("printer_paper: 58 или 80 мм").Uz("printer_paper: 58 yoki 80 mm")
	}
	return nil
}

func (s *Service) CreateWorkshop(ctx context.Context, p *identity.Principal, in WorkshopInput) (Workshop, error) {
	if err := s.manage(ctx, p); err != nil {
		return Workshop{}, err
	}
	ru, uz, err := names(in.NameInput, true)
	if err != nil {
		return Workshop{}, err
	}
	if err := in.validate(); err != nil {
		return Workshop{}, err
	}
	var out Workshop
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var id string
		err := tx.QueryRow(ctx, `
			INSERT INTO workshops (network_id, name, name_uz, sort, icon, cook_minutes, ticket_print,
			                       printer_kind, printer_host, printer_port, printer_paper)
			VALUES ($1, $2, COALESCE($3, ''), COALESCE($4, 0), COALESCE($5, 'fire'), COALESCE($6, 15), COALESCE($7, 'offline'),
			        COALESCE($8, 'none'), COALESCE($9, ''), COALESCE($10, 9100), COALESCE($11, 80)) RETURNING id`,
			p.NetworkID, *ru, uz, in.Sort, in.Icon, in.CookMinutes, in.TicketPrint,
			in.PrinterKind, in.PrinterHost, in.PrinterPort, in.PrinterPaper).Scan(&id)
		if db.IsUniqueViolation(err, "workshops_name_key") {
			return errWorkshopExists
		}
		if err != nil {
			return err
		}
		if err := moveGroups(ctx, tx, p.NetworkID, id, in.GroupIDs); err != nil {
			return err
		}
		if err := bumpNetwork(ctx, tx, p.NetworkID); err != nil {
			return err
		}
		out, err = getWorkshop(ctx, tx, p.NetworkID, id)
		return err
	})
	return out, err
}

func moveGroups(ctx context.Context, tx pgx.Tx, networkID, workshopID string, groupIDs *[]string) error {
	if groupIDs == nil {
		return nil
	}
	for _, g := range *groupIDs {
		if !httpx.IsUUID(g) {
			return apperr.Validation("group_ids: группа меню не найдена").Uz("group_ids: menyu guruhi topilmadi")
		}
	}
	tag, err := tx.Exec(ctx, `UPDATE menu_groups SET workshop_id = $3 WHERE network_id = $1 AND id = ANY($2::uuid[])`,
		networkID, *groupIDs, workshopID)
	if err != nil {
		return err
	}
	if int(tag.RowsAffected()) != len(*groupIDs) {
		return apperr.Validation("group_ids: группа меню не найдена").Uz("group_ids: menyu guruhi topilmadi")
	}
	return nil
}

func (s *Service) UpdateWorkshop(ctx context.Context, p *identity.Principal, id string, in WorkshopInput) (Workshop, error) {
	if err := s.manage(ctx, p); err != nil {
		return Workshop{}, err
	}
	ru, uz, err := names(in.NameInput, false)
	if err != nil {
		return Workshop{}, err
	}
	if err := in.validate(); err != nil {
		return Workshop{}, err
	}
	var out Workshop
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE workshops SET name = COALESCE($3, name), name_uz = COALESCE($4, name_uz), sort = COALESCE($5, sort),
			icon = COALESCE($6, icon), cook_minutes = COALESCE($7, cook_minutes), ticket_print = COALESCE($8, ticket_print),
			printer_kind = COALESCE($9, printer_kind), printer_host = COALESCE($10, printer_host),
			printer_port = COALESCE($11, printer_port), printer_paper = COALESCE($12, printer_paper),
			printer_ok = CASE WHEN $9 IS DISTINCT FROM NULL OR $10 IS DISTINCT FROM NULL OR $11 IS DISTINCT FROM NULL THEN NULL ELSE printer_ok END
			WHERE network_id = $1 AND id = $2 AND is_active`, p.NetworkID, id, ru, uz, in.Sort, in.Icon, in.CookMinutes, in.TicketPrint,
			in.PrinterKind, in.PrinterHost, in.PrinterPort, in.PrinterPaper)
		if db.IsUniqueViolation(err, "workshops_name_key") {
			return errWorkshopExists
		}
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.NotFound("цех не найден").Uz("sex topilmadi")
		}
		// Группы, которые сняли с цеха, возвращаются в цех по умолчанию.
		if in.GroupIDs != nil {
			if _, err := tx.Exec(ctx, `UPDATE menu_groups SET workshop_id = NULL WHERE network_id = $1 AND workshop_id = $2 AND NOT (id::text = ANY($3::text[]))`,
				p.NetworkID, id, *in.GroupIDs); err != nil {
				return err
			}
		}
		if err := moveGroups(ctx, tx, p.NetworkID, id, in.GroupIDs); err != nil {
			return err
		}
		if err := bumpNetwork(ctx, tx, p.NetworkID); err != nil {
			return err
		}
		out, err = getWorkshop(ctx, tx, p.NetworkID, id)
		return err
	})
	return out, err
}

// DeleteWorkshop — цех скрывается, его группы и блюда переходят в «Кухню».
func (s *Service) DeleteWorkshop(ctx context.Context, p *identity.Principal, id string) error {
	if err := s.manage(ctx, p); err != nil {
		return err
	}
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var isDefault bool
		err := tx.QueryRow(ctx, `SELECT is_default FROM workshops WHERE network_id = $1 AND id = $2 AND is_active FOR UPDATE`,
			p.NetworkID, id).Scan(&isDefault)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.NotFound("цех не найден").Uz("sex topilmadi")
		}
		if err != nil {
			return err
		}
		if isDefault {
			return apperr.Conflict("default_workshop", "цех по умолчанию удалить нельзя").Uz("asosiy sexni oʻchirib boʻlmaydi")
		}
		if _, err := tx.Exec(ctx, `UPDATE menu_groups SET workshop_id = NULL WHERE workshop_id = $1`, id); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE products SET workshop_id = NULL WHERE workshop_id = $1`, id); err != nil {
			return err
		}
		// Экран кухни этого цеха начинает показывать все цеха.
		if _, err := tx.Exec(ctx, `UPDATE pos_devices SET workshop_id = NULL WHERE workshop_id = $1`, id); err != nil {
			return err
		}
		if err := bumpNetwork(ctx, tx, p.NetworkID); err != nil {
			return err
		}
		// Название освобождаем: можно снова создать цех с тем же именем.
		_, err = tx.Exec(ctx, `UPDATE workshops SET is_active = false, name = left(name, 48) || ' (' || left(id::text, 8) || ')' WHERE id = $1`, id)
		return err
	})
}

// ------------------------------------------------------------- группы меню

type MenuGroup struct {
	ID           string  `json:"id"`
	Name         string  `json:"name"`
	NameRu       string  `json:"name_ru"`
	NameUz       string  `json:"name_uz"`
	Color        string  `json:"color"`
	Sort         int     `json:"sort"`
	WorkshopID   *string `json:"workshop_id"`
	WorkshopName *string `json:"workshop_name"`
	DishCount    int     `json:"dish_count"`
}

const groupSelect = `
	SELECT g.id, loc(g.name, g.name_uz), g.name, g.name_uz, g.color, g.sort, g.workshop_id,
	       (SELECT loc(w.name, w.name_uz) FROM workshops w WHERE w.id = g.workshop_id),
	       (SELECT count(*) FROM products p WHERE p.menu_group_id = g.id AND p.is_active)::int
	FROM menu_groups g`

type MenuGroupInput struct {
	NameInput
	Color      *string                `json:"color"`
	Sort       *int                   `json:"sort"`
	WorkshopID httpx.Optional[string] `json:"workshop_id"`
}

var errGroupExists = apperr.Conflict("menu_group_exists", "группа с таким названием уже есть").Uz("bunday nomli guruh allaqachon bor")

func (s *Service) ListMenuGroups(ctx context.Context, p *identity.Principal) ([]MenuGroup, error) {
	if err := s.read(ctx, p); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, groupSelect+` WHERE g.network_id = $1 AND g.is_active ORDER BY g.sort, g.name`, p.NetworkID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[MenuGroup])
}

func getGroup(ctx context.Context, q db.Querier, networkID, id string) (MenuGroup, error) {
	rows, err := q.Query(ctx, groupSelect+` WHERE g.network_id = $1 AND g.id = $2`, networkID, id)
	if err != nil {
		return MenuGroup{}, err
	}
	g, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[MenuGroup])
	if errors.Is(err, pgx.ErrNoRows) {
		return g, apperr.NotFound("группа меню не найдена").Uz("menyu guruhi topilmadi")
	}
	return g, err
}

func checkWorkshop(ctx context.Context, q db.Querier, networkID string, id *string) error {
	if id == nil {
		return nil
	}
	var ok bool
	if httpx.IsUUID(*id) {
		if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM workshops WHERE id = $1 AND network_id = $2 AND is_active)`,
			*id, networkID).Scan(&ok); err != nil {
			return err
		}
	}
	if !ok {
		return apperr.Validation("workshop_id: цех не найден").Uz("workshop_id: sex topilmadi")
	}
	return nil
}

func checkColor(c *string) error {
	if c == nil || *c == "" {
		return nil
	}
	if len(*c) != 7 || (*c)[0] != '#' || strings.Trim(strings.ToLower((*c)[1:]), "0123456789abcdef") != "" {
		return apperr.Validation("color: ожидается #RRGGBB").Uz("color: #RRGGBB boʻlishi kerak")
	}
	return nil
}

func (s *Service) CreateMenuGroup(ctx context.Context, p *identity.Principal, in MenuGroupInput) (MenuGroup, error) {
	if err := s.manage(ctx, p); err != nil {
		return MenuGroup{}, err
	}
	ru, uz, err := names(in.NameInput, true)
	if err != nil {
		return MenuGroup{}, err
	}
	if err := checkColor(in.Color); err != nil {
		return MenuGroup{}, err
	}
	ws := in.WorkshopID.Or()
	if err := checkWorkshop(ctx, s.pool, p.NetworkID, ws); err != nil {
		return MenuGroup{}, err
	}
	var id string
	err = s.pool.QueryRow(ctx, `
		INSERT INTO menu_groups (network_id, name, name_uz, color, sort, workshop_id)
		VALUES ($1, $2, COALESCE($3, ''), COALESCE($4, ''), COALESCE($5, 0), $6) RETURNING id`,
		p.NetworkID, *ru, uz, in.Color, in.Sort, ws).Scan(&id)
	if db.IsUniqueViolation(err, "menu_groups_name_key") {
		return MenuGroup{}, errGroupExists
	}
	if err != nil {
		return MenuGroup{}, err
	}
	return getGroup(ctx, s.pool, p.NetworkID, id)
}

func (s *Service) UpdateMenuGroup(ctx context.Context, p *identity.Principal, id string, in MenuGroupInput) (MenuGroup, error) {
	if err := s.manage(ctx, p); err != nil {
		return MenuGroup{}, err
	}
	ru, uz, err := names(in.NameInput, false)
	if err != nil {
		return MenuGroup{}, err
	}
	if err := checkColor(in.Color); err != nil {
		return MenuGroup{}, err
	}
	if in.WorkshopID.Set {
		if err := checkWorkshop(ctx, s.pool, p.NetworkID, in.WorkshopID.Value); err != nil {
			return MenuGroup{}, err
		}
	}
	tag, err := s.pool.Exec(ctx, `
		UPDATE menu_groups SET name = COALESCE($3, name), name_uz = COALESCE($4, name_uz), color = COALESCE($5, color),
		       sort = COALESCE($6, sort), workshop_id = CASE WHEN $7 THEN $8::uuid ELSE workshop_id END
		WHERE network_id = $1 AND id = $2 AND is_active`,
		p.NetworkID, id, ru, uz, in.Color, in.Sort, in.WorkshopID.Set, in.WorkshopID.Value)
	if db.IsUniqueViolation(err, "menu_groups_name_key") {
		return MenuGroup{}, errGroupExists
	}
	if err != nil {
		return MenuGroup{}, err
	}
	if tag.RowsAffected() == 0 {
		return MenuGroup{}, apperr.NotFound("группа меню не найдена").Uz("menyu guruhi topilmadi")
	}
	return getGroup(ctx, s.pool, p.NetworkID, id)
}

// DeleteMenuGroup — группу можно удалить, только когда в ней нет блюд.
func (s *Service) DeleteMenuGroup(ctx context.Context, p *identity.Principal, id string) error {
	if err := s.manage(ctx, p); err != nil {
		return err
	}
	var n int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM products WHERE menu_group_id = $1 AND is_active`, id).Scan(&n); err != nil {
		return err
	}
	if n > 0 {
		return apperr.Conflict("menu_group_not_empty", "в группе есть блюда — перенесите их в другую группу").Uz("guruhda taomlar bor — ularni boshqa guruhga oʻtkazing").
			WithDetails(map[string]any{"dish_count": n})
	}
	tag, err := s.pool.Exec(ctx, `UPDATE menu_groups SET is_active = false, name = left(name, 48) || ' (' || left(id::text, 8) || ')'
		WHERE network_id = $1 AND id = $2 AND is_active`, p.NetworkID, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.NotFound("группа меню не найдена").Uz("menyu guruhi topilmadi")
	}
	_, err = s.pool.Exec(ctx, `UPDATE products SET menu_group_id = NULL WHERE menu_group_id = $1`, id)
	return err
}
