package cafe

import (
	"context"
	"errors"
	"strconv"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Действия варианта модификатора со складом (см. миграцию 0068_cafe).
const (
	ActionNone   = "none"
	ActionAdd    = "add"
	ActionRemove = "remove"
	ActionFactor = "factor"
)

type ModifierOption struct {
	ID          string  `json:"id"`
	Name        string  `json:"name"`
	NameRu      string  `json:"name_ru"`
	NameUz      string  `json:"name_uz"`
	Price       string  `json:"price"`
	Action      string  `json:"action"`
	ProductID   *string `json:"product_id"`
	ProductName *string `json:"product_name"`
	Qty         *string `json:"qty"`
	Factor      *string `json:"factor"`
	Sort        int     `json:"sort"`
}

type ModifierGroup struct {
	ID        string           `json:"id"`
	Name      string           `json:"name"`
	NameRu    string           `json:"name_ru"`
	NameUz    string           `json:"name_uz"`
	MinSelect int              `json:"min_select"`
	MaxSelect int              `json:"max_select"`
	Required  bool             `json:"required"`
	Sort      int              `json:"sort"`
	DishCount int              `json:"dish_count"`
	Options   []ModifierOption `json:"options"`
}

func listModifierGroups(ctx context.Context, q db.Querier, networkID, id string) ([]ModifierGroup, error) {
	rows, err := q.Query(ctx, `
		SELECT g.id, loc(g.name, g.name_uz), g.name, g.name_uz, g.min_select, g.max_select, g.min_select > 0, g.sort,
		       (SELECT count(*) FROM product_modifier_groups pm WHERE pm.group_id = g.id)::int
		FROM modifier_groups g
		WHERE g.network_id = $1 AND g.is_active AND ($2 = '' OR g.id::text = $2)
		ORDER BY g.sort, g.name`, networkID, id)
	if err != nil {
		return nil, err
	}
	groups, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (ModifierGroup, error) {
		var g ModifierGroup
		err := r.Scan(&g.ID, &g.Name, &g.NameRu, &g.NameUz, &g.MinSelect, &g.MaxSelect, &g.Required, &g.Sort, &g.DishCount)
		g.Options = []ModifierOption{}
		return g, err
	})
	if err != nil || len(groups) == 0 {
		return groups, err
	}
	idx := map[string]int{}
	ids := make([]string, len(groups))
	for i, g := range groups {
		idx[g.ID] = i
		ids[i] = g.ID
	}
	rows, err = q.Query(ctx, `
		SELECT o.group_id, o.id, loc(o.name, o.name_uz), o.name, o.name_uz, o.price::text, o.action, o.product_id,
		       (SELECT loc(p.name, p.name_uz) FROM products p WHERE p.id = o.product_id),
		       trim_scale(o.qty)::text, trim_scale(o.factor)::text, o.sort
		FROM modifier_options o WHERE o.group_id = ANY($1::uuid[]) AND o.is_active
		ORDER BY o.sort, o.name`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var gid string
		var o ModifierOption
		if err := rows.Scan(&gid, &o.ID, &o.Name, &o.NameRu, &o.NameUz, &o.Price, &o.Action, &o.ProductID, &o.ProductName,
			&o.Qty, &o.Factor, &o.Sort); err != nil {
			return nil, err
		}
		g := &groups[idx[gid]]
		g.Options = append(g.Options, o)
	}
	return groups, rows.Err()
}

func (s *Service) ListModifierGroups(ctx context.Context, p *identity.Principal) ([]ModifierGroup, error) {
	if err := s.read(ctx, p); err != nil {
		return nil, err
	}
	return listModifierGroups(ctx, s.pool, p.NetworkID, "")
}

func getModifierGroup(ctx context.Context, q db.Querier, networkID, id string) (ModifierGroup, error) {
	list, err := listModifierGroups(ctx, q, networkID, id)
	if err != nil {
		return ModifierGroup{}, err
	}
	if len(list) == 0 {
		return ModifierGroup{}, apperr.NotFound("группа модификаторов не найдена").Uz("modifikatorlar guruhi topilmadi")
	}
	return list[0], nil
}

type ModifierOptionInput struct {
	// ID — у существующего варианта; без него — новый вариант.
	ID        *string       `json:"id"`
	Name      *string       `json:"name"`
	NameUz    *string       `json:"name_uz"`
	Price     *money.Amount `json:"price"`
	Action    *string       `json:"action"`
	ProductID *string       `json:"product_id"`
	Qty       *money.Qty    `json:"qty"`
	Factor    *money.Qty    `json:"factor"`
}

type ModifierGroupInput struct {
	NameInput
	MinSelect *int `json:"min_select"`
	MaxSelect *int `json:"max_select"`
	Sort      *int `json:"sort"`
	// Варианты целиком: кого нет в списке — скрываются (в старых чеках остаются).
	Options *[]ModifierOptionInput `json:"options"`
}

var errModGroupExists = apperr.Conflict("modifier_group_exists", "группа модификаторов с таким названием уже есть").Uz("bunday nomli modifikatorlar guruhi allaqachon bor")

func (s *Service) CreateModifierGroup(ctx context.Context, p *identity.Principal, in ModifierGroupInput) (ModifierGroup, error) {
	return s.saveModifierGroup(ctx, p, "", in)
}

func (s *Service) UpdateModifierGroup(ctx context.Context, p *identity.Principal, id string, in ModifierGroupInput) (ModifierGroup, error) {
	return s.saveModifierGroup(ctx, p, id, in)
}

func (s *Service) saveModifierGroup(ctx context.Context, p *identity.Principal, id string, in ModifierGroupInput) (ModifierGroup, error) {
	if err := s.manage(ctx, p); err != nil {
		return ModifierGroup{}, err
	}
	create := id == ""
	ru, uz, err := names(in.NameInput, create)
	if err != nil {
		return ModifierGroup{}, err
	}
	for _, v := range []*int{in.MinSelect, in.MaxSelect} {
		if v != nil && (*v < 0 || *v > 20) {
			return ModifierGroup{}, apperr.Validation("min_select, max_select: от 0 до 20").Uz("min_select, max_select: 0 dan 20 gacha")
		}
	}
	if create && (in.Options == nil || len(*in.Options) == 0) {
		return ModifierGroup{}, apperr.Validation("options: добавьте хотя бы один вариант").Uz("options: kamida bitta variant qoʻshing")
	}
	var out ModifierGroup
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if create {
			err := tx.QueryRow(ctx, `
				INSERT INTO modifier_groups (network_id, name, name_uz, min_select, max_select, sort)
				VALUES ($1, $2, COALESCE($3, ''), COALESCE($4, 0), COALESCE($5, 0), COALESCE($6, 0)) RETURNING id`,
				p.NetworkID, *ru, uz, in.MinSelect, in.MaxSelect, in.Sort).Scan(&id)
			if db.IsUniqueViolation(err, "modifier_groups_name_key") {
				return errModGroupExists
			}
			if err != nil {
				return mapGroupCheck(err)
			}
		} else {
			tag, err := tx.Exec(ctx, `
				UPDATE modifier_groups SET name = COALESCE($3, name), name_uz = COALESCE($4, name_uz),
				       min_select = COALESCE($5, min_select), max_select = COALESCE($6, max_select), sort = COALESCE($7, sort)
				WHERE network_id = $1 AND id = $2 AND is_active`, p.NetworkID, id, ru, uz, in.MinSelect, in.MaxSelect, in.Sort)
			if db.IsUniqueViolation(err, "modifier_groups_name_key") {
				return errModGroupExists
			}
			if err != nil {
				return mapGroupCheck(err)
			}
			if tag.RowsAffected() == 0 {
				return apperr.NotFound("группа модификаторов не найдена").Uz("modifikatorlar guruhi topilmadi")
			}
		}
		if in.Options != nil {
			if err := setOptions(ctx, tx, p.NetworkID, id, *in.Options); err != nil {
				return err
			}
		}
		var err error
		out, err = getModifierGroup(ctx, tx, p.NetworkID, id)
		return err
	})
	return out, err
}

func mapGroupCheck(err error) error {
	if isCheckViolation(err) {
		return apperr.Validation("max_select: не может быть меньше min_select").Uz("max_select: min_select dan kichik boʻlmasin")
	}
	return err
}

func setOptions(ctx context.Context, tx pgx.Tx, networkID, groupID string, opts []ModifierOptionInput) error {
	if len(opts) == 0 || len(opts) > 50 {
		return apperr.Validation("options: от 1 до 50 вариантов").Uz("options: 1 dan 50 tagacha variant")
	}
	keep := []string{}
	for i, o := range opts {
		ls := strconv.Itoa(i + 1)
		bad := func(ru, uz string) error {
			return apperr.Validation("options: " + ru + " (вариант " + ls + ")").Uz("options: " + uz + " (" + ls + "-variant)")
		}
		ru, uz, err := names(NameInput{Name: o.Name, NameUz: o.NameUz}, o.ID == nil)
		if err != nil {
			return bad("укажите название", "nomini kiriting")
		}
		action := ActionNone
		if o.Action != nil {
			action = *o.Action
		}
		price := "0"
		if o.Price != nil {
			if !o.Price.Valid() || money.D(string(*o.Price)).Sign() < 0 {
				return bad("неверная доплата", "qoʻshimcha narx notoʻgʻri")
			}
			price = money.D(string(*o.Price)).Money()
		}
		var product, qty, factor *string
		switch action {
		case ActionNone:
		case ActionAdd, ActionRemove:
			if o.ProductID == nil || !httpx.IsUUID(*o.ProductID) {
				return bad("укажите продукт", "mahsulotni kiriting")
			}
			var kind string
			err := tx.QueryRow(ctx, `SELECT kind FROM products WHERE id = $1 AND (network_id IS NULL OR network_id = $2)`,
				*o.ProductID, networkID).Scan(&kind)
			if errors.Is(err, pgx.ErrNoRows) || kind == KindDish {
				return bad("продукт не найден", "mahsulot topilmadi")
			}
			if err != nil {
				return err
			}
			product = o.ProductID
			if action == ActionAdd {
				if o.Qty == nil || !o.Qty.Valid() || money.D(string(*o.Qty)).Sign() <= 0 {
					return bad("укажите, сколько продукта добавить", "qancha mahsulot qoʻshilishini kiriting")
				}
				v := money.D(string(*o.Qty)).Fixed(4)
				qty = &v
			}
		case ActionFactor:
			if o.Factor == nil || !o.Factor.Valid() || money.D(string(*o.Factor)).Sign() <= 0 || money.D(string(*o.Factor)).Cmp(money.D("10")) > 0 {
				return bad("коэффициент порции от 0 до 10", "porsiya koeffitsienti 0 dan 10 gacha")
			}
			v := money.D(string(*o.Factor)).Fixed(3)
			factor = &v
		default:
			return bad("action: none, add, remove или factor", "action: none, add, remove yoki factor")
		}
		if o.ID != nil {
			tag, err := tx.Exec(ctx, `
				UPDATE modifier_options SET name = COALESCE($3, name), name_uz = COALESCE($4, name_uz), price = $5::numeric,
				       action = $6, product_id = $7, qty = $8::numeric, factor = $9::numeric, sort = $10, is_active = true
				WHERE id = $1 AND group_id = $2`, *o.ID, groupID, ru, uz, price, action, product, qty, factor, i)
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 0 {
				return bad("вариант не найден", "variant topilmadi")
			}
			keep = append(keep, *o.ID)
			continue
		}
		var id string
		if err := tx.QueryRow(ctx, `
			INSERT INTO modifier_options (group_id, name, name_uz, price, action, product_id, qty, factor, sort)
			VALUES ($1, $2, COALESCE($3, ''), $4::numeric, $5, $6, $7::numeric, $8::numeric, $9) RETURNING id`,
			groupID, *ru, uz, price, action, product, qty, factor, i).Scan(&id); err != nil {
			return err
		}
		keep = append(keep, id)
	}
	_, err := tx.Exec(ctx, `UPDATE modifier_options SET is_active = false WHERE group_id = $1 AND NOT (id = ANY($2::uuid[]))`, groupID, keep)
	return err
}

// DeleteModifierGroup скрывает группу и отвязывает её от блюд.
func (s *Service) DeleteModifierGroup(ctx context.Context, p *identity.Principal, id string) error {
	if err := s.manage(ctx, p); err != nil {
		return err
	}
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE modifier_groups SET is_active = false, name = left(name, 48) || ' (' || left(id::text, 8) || ')'
			WHERE network_id = $1 AND id = $2 AND is_active`, p.NetworkID, id)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.NotFound("группа модификаторов не найдена").Uz("modifikatorlar guruhi topilmadi")
		}
		_, err = tx.Exec(ctx, `DELETE FROM product_modifier_groups WHERE group_id = $1`, id)
		return err
	})
}

func setModifierGroups(ctx context.Context, tx pgx.Tx, networkID, productID string, groupIDs []string) error {
	if _, err := tx.Exec(ctx, `DELETE FROM product_modifier_groups WHERE product_id = $1`, productID); err != nil {
		return err
	}
	seen := map[string]bool{}
	for i, g := range groupIDs {
		if !httpx.IsUUID(g) || seen[g] {
			return apperr.Validation("modifier_group_ids: группа не найдена или повторяется").Uz("modifier_group_ids: guruh topilmadi yoki takrorlanadi")
		}
		seen[g] = true
		tag, err := tx.Exec(ctx, `
			INSERT INTO product_modifier_groups (product_id, group_id, sort)
			SELECT $1, id, $3 FROM modifier_groups WHERE id = $2 AND network_id = $4 AND is_active`, productID, g, i, networkID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.Validation("modifier_group_ids: группа не найдена").Uz("modifier_group_ids: guruh topilmadi")
		}
	}
	return nil
}

// ---------------------------------------------------------- для продажи

// ChosenModifier — вариант, выбранный в строке чека.
type ChosenModifier struct {
	OptionID string `json:"option_id"`
	Qty      int    `json:"qty"` // 0 — одна штука
}

// ResolvedModifier — выбранный вариант с данными на момент продажи.
type ResolvedModifier struct {
	OptionID  string
	Name      string
	Qty       int
	Price     money.Dec
	Action    string
	ProductID string
	AddQty    money.Dec
	Factor    money.Dec
}

// ResolveModifiers проверяет модификаторы строки чека. strict (продажа не с
// кассы) — варианты только из групп блюда, обязательные группы выбраны,
// не больше max_select. С кассы продажа уже случилась (могла пройти без
// интернета по старому меню) — принимаем любой вариант сети.
func ResolveModifiers(ctx context.Context, q db.Querier, networkID, productID, productName string, chosen []ChosenModifier, strict bool) ([]ResolvedModifier, error) {
	if len(chosen) > 30 {
		return nil, apperr.Validation("modifiers: не больше 30 в строке").Uz("modifiers: qatorda 30 tadan koʻp boʻlmasin")
	}
	out := make([]ResolvedModifier, 0, len(chosen))
	perGroup := map[string]int{}
	seen := map[string]bool{}
	bad := apperr.Validation("modifiers: вариант не найден у «" + productName + "»").Uz("modifiers: «" + productName + "» uchun variant topilmadi")
	for _, c := range chosen {
		if !httpx.IsUUID(c.OptionID) || seen[c.OptionID] || c.Qty < 0 || c.Qty > 20 {
			return nil, bad
		}
		seen[c.OptionID] = true
		qty := c.Qty
		if qty == 0 {
			qty = 1
		}
		var r ResolvedModifier
		var groupID, price string
		var product, addQty, factor *string
		var linked, active bool
		err := q.QueryRow(ctx, `
			SELECT o.group_id, loc(o.name, o.name_uz), o.price::text, o.action, o.product_id, o.qty::text, o.factor::text,
			       EXISTS (SELECT 1 FROM product_modifier_groups pm WHERE pm.product_id = $3 AND pm.group_id = o.group_id),
			       o.is_active AND g.is_active
			FROM modifier_options o JOIN modifier_groups g ON g.id = o.group_id
			WHERE o.id = $1 AND g.network_id = $2`, c.OptionID, networkID, productID).
			Scan(&groupID, &r.Name, &price, &r.Action, &product, &addQty, &factor, &linked, &active)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, bad
		}
		if err != nil {
			return nil, err
		}
		if strict && (!linked || !active) {
			return nil, bad
		}
		r.OptionID, r.Qty, r.Price = c.OptionID, qty, money.D(price)
		if product != nil {
			r.ProductID = *product
		}
		if addQty != nil {
			r.AddQty = money.D(*addQty)
		}
		if factor != nil {
			r.Factor = money.D(*factor)
		}
		perGroup[groupID]++
		out = append(out, r)
	}
	if !strict {
		return out, nil
	}
	rows, err := q.Query(ctx, `
		SELECT g.id, loc(g.name, g.name_uz), g.min_select, g.max_select
		FROM product_modifier_groups pm JOIN modifier_groups g ON g.id = pm.group_id
		WHERE pm.product_id = $1 AND g.is_active`, productID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id, name string
		var minSel, maxSel int
		if err := rows.Scan(&id, &name, &minSel, &maxSel); err != nil {
			return nil, err
		}
		n := perGroup[id]
		if n < minSel {
			return nil, apperr.Validation("modifiers: у «" + productName + "» выберите «" + name + "»").Uz("modifiers: «" + productName + "» uchun «" + name + "» ni tanlang").
				WithDetails(map[string]any{"product_id": productID, "group_id": id, "min_select": minSel})
		}
		if maxSel > 0 && n > maxSel {
			return nil, apperr.Validation("modifiers: в «" + name + "» можно выбрать не больше " + strconv.Itoa(maxSel)).Uz("modifiers: «" + name + "» da " + strconv.Itoa(maxSel) + " tadan koʻp tanlab boʻlmaydi").
				WithDetails(map[string]any{"product_id": productID, "group_id": id, "max_select": maxSel})
		}
	}
	return out, rows.Err()
}
