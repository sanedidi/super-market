package supply

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/push"
)

// codeTTL — сколько живёт код «Договориться на месте».
const codeTTL = 10 * time.Minute

// Link — связь магазина и дистрибьютора, как её видит одна из сторон.
type Link struct {
	ID            string     `json:"id"`
	StoreID       string     `json:"store_id"`
	StoreName     string     `json:"store_name"`
	DistributorID string     `json:"distributor_id"`
	Distributor   string     `json:"distributor_name"`
	Status        string     `json:"status"`
	RequestedBy   string     `json:"requested_by"`
	Message       string     `json:"message"`
	EndedBy       string     `json:"ended_by"`
	CreatedAt     time.Time  `json:"created_at"`
	AcceptedAt    *time.Time `json:"accepted_at"`
	// Ждёт ответа от того, кто смотрит (запрос пришёл от второй стороны).
	WaitsForMe bool `json:"waits_for_me"`
}

const linkSelect = `
	SELECT l.id, l.store_id, s.name, l.distributor_id, n.name, l.status, l.requested_by, l.message, l.ended_by,
	       l.created_at, l.accepted_at
	FROM supply_links l
	JOIN stores s   ON s.id = l.store_id
	JOIN networks n ON n.id = l.distributor_id`

func scanLink(side string) pgx.RowToFunc[Link] {
	return func(row pgx.CollectableRow) (Link, error) {
		var l Link
		err := row.Scan(&l.ID, &l.StoreID, &l.StoreName, &l.DistributorID, &l.Distributor, &l.Status, &l.RequestedBy,
			&l.Message, &l.EndedBy, &l.CreatedAt, &l.AcceptedAt)
		l.WaitsForMe = l.Status == LinkRequested && l.RequestedBy != side
		return l, err
	}
}

func getLink(ctx context.Context, q db.Querier, side, id string) (Link, error) {
	rows, err := q.Query(ctx, linkSelect+` WHERE l.id = $1`, id)
	if err != nil {
		return Link{}, err
	}
	l, err := pgx.CollectExactlyOneRow(rows, scanLink(side))
	if errors.Is(err, pgx.ErrNoRows) {
		return Link{}, apperr.NotFound("связь не найдена").Uz("aloqa topilmadi")
	}
	return l, err
}

// checkStore — магазин для дистрибьютора: активный, не дистрибьютор.
func checkStore(ctx context.Context, q db.Querier, storeID string) (storeNetworkID string, err error) {
	if !httpx.IsUUID(storeID) {
		return "", apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	err = q.QueryRow(ctx, `
		SELECT s.network_id FROM stores s JOIN networks n ON n.id = s.network_id
		WHERE s.id = $1 AND s.status = 'active' AND n.status = 'active' AND n.kind <> 'distributor'`, storeID).Scan(&storeNetworkID)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	return storeNetworkID, err
}

// checkDistributor — активный дистрибьютор с точкой.
func checkDistributor(ctx context.Context, q db.Querier, id string) error {
	if !httpx.IsUUID(id) {
		return apperr.NotFound("дистрибьютор не найден").Uz("distribyutor topilmadi")
	}
	var ok bool
	err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM networks WHERE id = $1 AND kind = 'distributor' AND status = 'active')`, id).Scan(&ok)
	if err == nil && !ok {
		return apperr.NotFound("дистрибьютор не найден").Uz("distribyutor topilmadi")
	}
	return err
}

// ------------------------------------------------------ сторона дистрибьютора

// LinkCode — код и QR для «Договориться на месте».
type LinkCode struct {
	Code      string    `json:"code"`
	QR        string    `json:"qr"`
	ExpiresAt time.Time `json:"expires_at"`
}

// CreateCode — дистрибьютор у магазина: код на 10 минут. Владелец магазина
// вводит его в «SM Магазин» (Поставщики → Подключить по коду).
func (s *Service) CreateCode(ctx context.Context, p *identity.Principal, storeID string) (LinkCode, error) {
	if err := requireDistributor(p); err != nil {
		return LinkCode{}, err
	}
	if err := p.Require(identity.PermOrdersManage); err != nil {
		return LinkCode{}, err
	}
	var out LinkCode
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := distPoint(ctx, tx, p.NetworkID); err != nil {
			return err
		}
		if _, err := checkStore(ctx, tx, storeID); err != nil {
			return err
		}
		var active bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM supply_links WHERE store_id = $1 AND distributor_id = $2 AND status = 'active')`,
			storeID, p.NetworkID).Scan(&active); err != nil {
			return err
		}
		if active {
			return apperr.Conflict("already_linked", "магазин уже подключил вас").Uz("doʻkon sizni allaqachon ulagan")
		}
		// Прежние коды этого дистрибьютора для магазина больше не действуют.
		if _, err := tx.Exec(ctx, `UPDATE supply_link_codes SET used_at = now() WHERE store_id = $1 AND distributor_id = $2 AND used_at IS NULL`,
			storeID, p.NetworkID); err != nil {
			return err
		}
		for range 20 {
			code, err := code4()
			if err != nil {
				return err
			}
			var busy bool
			if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM supply_link_codes WHERE store_id = $1 AND code = $2 AND used_at IS NULL AND expires_at > now())`,
				storeID, code).Scan(&busy); err != nil {
				return err
			}
			if busy {
				continue
			}
			out = LinkCode{Code: code, QR: "smlink:" + code, ExpiresAt: time.Now().Add(codeTTL).UTC().Truncate(time.Second)}
			_, err = tx.Exec(ctx, `INSERT INTO supply_link_codes (distributor_id, store_id, code, created_by, expires_at) VALUES ($1, $2, $3, $4, $5)`,
				p.NetworkID, storeID, code, p.EmployeeID, out.ExpiresAt)
			return err
		}
		return apperr.Conflict("code_busy", "не удалось выдать код — попробуйте ещё раз").Uz("kod berib boʻlmadi — yana urinib koʻring")
	})
	return out, err
}

// RequestInput — запрос на подключение.
type RequestInput struct {
	StoreID string `json:"store_id"` // для магазина: какой магазин сети
	Message string `json:"message"`
}

// request — общая часть запроса от любой стороны. Если вторая сторона уже
// просила подключиться — связь сразу становится активной.
func (s *Service) request(ctx context.Context, tx pgx.Tx, storeID, storeNetworkID, distributorID, side, message string) (string, bool, error) {
	message = strings.TrimSpace(message)
	if len([]rune(message)) > 500 {
		return "", false, apperr.Validation("message: не длиннее 500 символов").Uz("message: 500 belgidan oshmasin")
	}
	var id, status, by string
	err := tx.QueryRow(ctx, `SELECT id, status, requested_by FROM supply_links WHERE store_id = $1 AND distributor_id = $2 FOR UPDATE`,
		storeID, distributorID).Scan(&id, &status, &by)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		err = tx.QueryRow(ctx, `
			INSERT INTO supply_links (store_id, store_network_id, distributor_id, status, requested_by, message)
			VALUES ($1, $2, $3, 'requested', $4, $5) RETURNING id`,
			storeID, storeNetworkID, distributorID, side, message).Scan(&id)
		return id, false, err
	case err != nil:
		return "", false, err
	case status == LinkActive:
		return "", false, apperr.Conflict("already_linked", "вы уже подключены").Uz("siz allaqachon ulangansiz")
	case status == LinkRequested && by != side:
		_, err = tx.Exec(ctx, `UPDATE supply_links SET status = 'active', accepted_at = now(), ended_by = '' WHERE id = $1`, id)
		return id, true, err
	default:
		_, err = tx.Exec(ctx, `
			UPDATE supply_links SET status = 'requested', requested_by = $2, message = $3, ended_by = '', accepted_at = NULL
			WHERE id = $1`, id, side, message)
		return id, false, err
	}
}

// RequestStore — дистрибьютор просит магазин подключить его.
func (s *Service) RequestStore(ctx context.Context, p *identity.Principal, storeID string, in RequestInput) (Link, error) {
	if err := requireDistributor(p); err != nil {
		return Link{}, err
	}
	if err := p.Require(identity.PermOrdersManage); err != nil {
		return Link{}, err
	}
	var id string
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := distPoint(ctx, tx, p.NetworkID); err != nil {
			return err
		}
		storeNet, err := checkStore(ctx, tx, storeID)
		if err != nil {
			return err
		}
		var accepted bool
		id, accepted, err = s.request(ctx, tx, storeID, storeNet, p.NetworkID, SideDistributor, in.Message)
		if err != nil {
			return err
		}
		var name string
		if err := tx.QueryRow(ctx, `SELECT name FROM networks WHERE id = $1`, p.NetworkID).Scan(&name); err != nil {
			return err
		}
		if accepted {
			return push.EnqueueStaff(ctx, tx, storeID, identity.PermInventoryManage, "supply_link_active",
				i18n.Text{RU: "Поставщик подключён", UZ: "Yetkazib beruvchi ulandi"},
				i18n.Text{RU: name + " принял ваш запрос — можно заказывать", UZ: name + " soʻrovingizni qabul qildi — buyurtma berish mumkin"},
				map[string]string{"link_id": id})
		}
		return push.EnqueueStaff(ctx, tx, storeID, identity.PermInventoryManage, "supply_link_request",
			i18n.Text{RU: "Запрос от поставщика", UZ: "Yetkazib beruvchidan soʻrov"},
			i18n.Text{RU: name + " хочет стать вашим поставщиком", UZ: name + " yetkazib beruvchingiz boʻlmoqchi"},
			map[string]string{"link_id": id})
	})
	if err != nil {
		return Link{}, err
	}
	return getLink(ctx, s.pool, SideDistributor, id)
}

// DistributorLinks — запросы и связи дистрибьютора (status — фильтр).
func (s *Service) DistributorLinks(ctx context.Context, p *identity.Principal, status string, page httpx.Page) ([]Link, error) {
	if err := requireDistributor(p); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, linkSelect+`
		WHERE l.distributor_id = $1 AND ($2 = '' OR l.status = $2)
		ORDER BY (l.status = 'requested' AND l.requested_by <> 'distributor') DESC, l.updated_at DESC
		LIMIT $3 OFFSET $4`, p.NetworkID, status, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanLink(SideDistributor))
}

// answer — принять или отклонить запрос второй стороны.
func (s *Service) answer(ctx context.Context, p *identity.Principal, side, id string, accept bool) (Link, error) {
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var storeID, distID, status, by string
		err := tx.QueryRow(ctx, `SELECT store_id, distributor_id, status, requested_by FROM supply_links WHERE id = $1 FOR UPDATE`, id).
			Scan(&storeID, &distID, &status, &by)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.NotFound("запрос не найден").Uz("soʻrov topilmadi")
		}
		if err != nil {
			return err
		}
		if (side == SideDistributor && distID != p.NetworkID) || (side == SideStore && !p.CanAccessStore(storeID)) {
			return apperr.NotFound("запрос не найден").Uz("soʻrov topilmadi")
		}
		if side == SideStore {
			var net string
			if err := tx.QueryRow(ctx, `SELECT network_id FROM stores WHERE id = $1`, storeID).Scan(&net); err != nil || net != p.NetworkID {
				return apperr.NotFound("запрос не найден").Uz("soʻrov topilmadi")
			}
		}
		if status != LinkRequested || by == side {
			return apperr.Conflict("not_waiting", "этот запрос не ждёт вашего ответа").Uz("bu soʻrov sizning javobingizni kutmayapti")
		}
		if accept {
			_, err = tx.Exec(ctx, `UPDATE supply_links SET status = 'active', accepted_at = now() WHERE id = $1`, id)
		} else {
			_, err = tx.Exec(ctx, `UPDATE supply_links SET status = 'rejected', ended_by = $2 WHERE id = $1`, id, side)
		}
		if err != nil {
			return err
		}
		return s.notifyAnswer(ctx, tx, side, storeID, distID, id, accept)
	})
	if err != nil {
		return Link{}, err
	}
	return getLink(ctx, s.pool, side, id)
}

func (s *Service) notifyAnswer(ctx context.Context, tx pgx.Tx, side, storeID, distID, linkID string, accept bool) error {
	var storeName, distName string
	if err := tx.QueryRow(ctx, `SELECT s.name, n.name FROM stores s, networks n WHERE s.id = $1 AND n.id = $2`, storeID, distID).
		Scan(&storeName, &distName); err != nil {
		return err
	}
	data := map[string]string{"link_id": linkID, "store_id": storeID}
	if side == SideStore { // ответил магазин — сообщаем дистрибьютору
		pt, err := distPoint(ctx, tx, distID)
		if err != nil {
			return nil //nolint:nilerr // у дистрибьютора нет точки — уведомлять некуда
		}
		if accept {
			return push.EnqueueStaff(ctx, tx, pt.StoreID, identity.PermOrdersManage, "supply_link_active",
				i18n.Text{RU: "Магазин подключил вас", UZ: "Doʻkon sizni uladi"},
				i18n.Text{RU: storeName + " — теперь видны остатки и заказы", UZ: storeName + " — endi qoldiqlar va buyurtmalar koʻrinadi"}, data)
		}
		return push.EnqueueStaff(ctx, tx, pt.StoreID, identity.PermOrdersManage, "supply_link_rejected",
			i18n.Text{RU: "Магазин отклонил запрос", UZ: "Doʻkon soʻrovni rad etdi"},
			i18n.Text{RU: storeName, UZ: storeName}, data)
	}
	if accept {
		return push.EnqueueStaff(ctx, tx, storeID, identity.PermInventoryManage, "supply_link_active",
			i18n.Text{RU: "Поставщик подключён", UZ: "Yetkazib beruvchi ulandi"},
			i18n.Text{RU: distName + " — можно заказывать", UZ: distName + " — buyurtma berish mumkin"}, data)
	}
	return push.EnqueueStaff(ctx, tx, storeID, identity.PermInventoryManage, "supply_link_rejected",
		i18n.Text{RU: "Поставщик отклонил запрос", UZ: "Yetkazib beruvchi soʻrovni rad etdi"},
		i18n.Text{RU: distName, UZ: distName}, data)
}

// AnswerAsDistributor — дистрибьютор принимает или отклоняет запрос магазина.
func (s *Service) AnswerAsDistributor(ctx context.Context, p *identity.Principal, id string, accept bool) (Link, error) {
	if err := requireDistributor(p); err != nil {
		return Link{}, err
	}
	if err := p.Require(identity.PermOrdersManage); err != nil {
		return Link{}, err
	}
	return s.answer(ctx, p, SideDistributor, id, accept)
}

// disconnect — одна из сторон отключается. Заказы, которые ещё не собраны,
// отменяются.
func (s *Service) disconnect(ctx context.Context, tx pgx.Tx, side, storeID, distID string) error {
	tag, err := tx.Exec(ctx, `
		UPDATE supply_links SET status = 'disconnected', ended_by = $3
		WHERE store_id = $1 AND distributor_id = $2 AND status IN ('active', 'requested')`, storeID, distID, side)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.Conflict("not_linked", "вы не подключены").Uz("siz ulanmagansiz")
	}
	_, err = tx.Exec(ctx, `
		UPDATE supply_orders SET status = 'cancelled', reject_reason = 'Связь отключена'
		WHERE store_id = $1 AND network_id = $2 AND status IN ('new', 'accepted')`, storeID, distID)
	return err
}

// DisconnectStore — дистрибьютор отключается от магазина.
func (s *Service) DisconnectStore(ctx context.Context, p *identity.Principal, storeID string) error {
	if err := requireDistributor(p); err != nil {
		return err
	}
	if err := p.Require(identity.PermOrdersManage); err != nil {
		return err
	}
	if !httpx.IsUUID(storeID) {
		return apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		return s.disconnect(ctx, tx, SideDistributor, storeID, p.NetworkID)
	})
}

// ---------------------------------------------------------- сторона магазина

// ConnectInput — подключить дистрибьютора по коду, который он показал.
type ConnectInput struct {
	StoreID string `json:"store_id"`
	Code    string `json:"code"`
}

// storeOfNetwork — магазин сети сотрудника, к которому у него есть доступ.
func storeOfNetwork(ctx context.Context, q db.Querier, p *identity.Principal, storeID string) error {
	if !httpx.IsUUID(storeID) || !p.CanAccessStore(storeID) {
		return apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	var ok bool
	if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM stores WHERE id = $1 AND network_id = $2)`, storeID, p.NetworkID).Scan(&ok); err != nil {
		return err
	}
	if !ok {
		return apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	return nil
}

// ConnectByCode — магазин вводит код дистрибьютора: связь сразу активна.
func (s *Service) ConnectByCode(ctx context.Context, p *identity.Principal, in ConnectInput) (Link, error) {
	if err := requireStoreSide(p); err != nil {
		return Link{}, err
	}
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return Link{}, err
	}
	code := strings.TrimPrefix(strings.TrimSpace(in.Code), "smlink:")
	var id string
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if err := storeOfNetwork(ctx, tx, p, in.StoreID); err != nil {
			return err
		}
		var codeID, distID string
		err := tx.QueryRow(ctx, `
			SELECT id, distributor_id FROM supply_link_codes
			WHERE store_id = $1 AND code = $2 AND used_at IS NULL AND expires_at > now()
			ORDER BY created_at DESC LIMIT 1 FOR UPDATE`, in.StoreID, code).Scan(&codeID, &distID)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Validation("code: неверный или просроченный код — попросите показать новый").Uz("code: kod notoʻgʻri yoki muddati oʻtgan — yangisini koʻrsatishni soʻrang")
		}
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE supply_link_codes SET used_at = now() WHERE id = $1`, codeID); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `
			INSERT INTO supply_links (store_id, store_network_id, distributor_id, status, requested_by, accepted_at)
			VALUES ($1, $2, $3, 'active', 'code', now())
			ON CONFLICT (store_id, distributor_id) DO UPDATE
			SET status = 'active', requested_by = 'code', accepted_at = COALESCE(CASE WHEN supply_links.status = 'active' THEN supply_links.accepted_at END, now()), ended_by = ''
			RETURNING id`, in.StoreID, p.NetworkID, distID).Scan(&id); err != nil {
			return err
		}
		return s.notifyAnswer(ctx, tx, SideStore, in.StoreID, distID, id, true)
	})
	if err != nil {
		return Link{}, err
	}
	return getLink(ctx, s.pool, SideStore, id)
}

// RequestDistributor — магазин просит дистрибьютора стать его поставщиком.
func (s *Service) RequestDistributor(ctx context.Context, p *identity.Principal, distributorID string, in RequestInput) (Link, error) {
	if err := requireStoreSide(p); err != nil {
		return Link{}, err
	}
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return Link{}, err
	}
	var id string
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if err := storeOfNetwork(ctx, tx, p, in.StoreID); err != nil {
			return err
		}
		if err := checkDistributor(ctx, tx, distributorID); err != nil {
			return err
		}
		pt, err := distPoint(ctx, tx, distributorID)
		if err != nil {
			return apperr.NotFound("дистрибьютор ещё не готов принимать заказы").Uz("distribyutor hali buyurtma qabul qilishga tayyor emas")
		}
		var accepted bool
		id, accepted, err = s.request(ctx, tx, in.StoreID, p.NetworkID, distributorID, SideStore, in.Message)
		if err != nil {
			return err
		}
		var storeName string
		if err := tx.QueryRow(ctx, `SELECT name FROM stores WHERE id = $1`, in.StoreID).Scan(&storeName); err != nil {
			return err
		}
		data := map[string]string{"link_id": id, "store_id": in.StoreID}
		if accepted {
			return push.EnqueueStaff(ctx, tx, pt.StoreID, identity.PermOrdersManage, "supply_link_active",
				i18n.Text{RU: "Магазин подключил вас", UZ: "Doʻkon sizni uladi"},
				i18n.Text{RU: storeName + " принял ваш запрос", UZ: storeName + " soʻrovingizni qabul qildi"}, data)
		}
		return push.EnqueueStaff(ctx, tx, pt.StoreID, identity.PermOrdersManage, "supply_link_request",
			i18n.Text{RU: "Запрос от магазина", UZ: "Doʻkondan soʻrov"},
			i18n.Text{RU: storeName + " хочет заказывать у вас", UZ: storeName + " sizdan buyurtma bermoqchi"}, data)
	})
	if err != nil {
		return Link{}, err
	}
	return getLink(ctx, s.pool, SideStore, id)
}

// AnswerAsStore — магазин принимает или отклоняет запрос дистрибьютора.
func (s *Service) AnswerAsStore(ctx context.Context, p *identity.Principal, id string, accept bool) (Link, error) {
	if err := requireStoreSide(p); err != nil {
		return Link{}, err
	}
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return Link{}, err
	}
	return s.answer(ctx, p, SideStore, id, accept)
}

// DisconnectDistributor — магазин отключает поставщика.
func (s *Service) DisconnectDistributor(ctx context.Context, p *identity.Principal, distributorID, storeID string) error {
	if err := requireStoreSide(p); err != nil {
		return err
	}
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return err
	}
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if err := storeOfNetwork(ctx, tx, p, storeID); err != nil {
			return err
		}
		if !httpx.IsUUID(distributorID) {
			return apperr.NotFound("поставщик не найден").Uz("yetkazib beruvchi topilmadi")
		}
		return s.disconnect(ctx, tx, SideStore, storeID, distributorID)
	})
}
