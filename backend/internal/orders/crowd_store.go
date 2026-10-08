package orders

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"errors"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// Магазин — точка проверки курьеров «по пути» и выдачи им заказов.

var courierCodeRe = regexp.MustCompile(`^KR-?([0-9]{5})$`)

// normCourierCode принимает «KR-48213», «kr48213» или содержимое QR «sm-courier:KR-48213».
func normCourierCode(raw string) (string, bool) {
	s := strings.ToUpper(strings.TrimSpace(raw))
	s = strings.TrimPrefix(s, "SM-COURIER:")
	s = strings.ReplaceAll(s, " ", "")
	m := courierCodeRe.FindStringSubmatch(s)
	if m == nil {
		return "", false
	}
	return "KR-" + m[1], true
}

// CrowdCourierCard — курьер для продавца: кто пришёл на проверку или за заказом.
type CrowdCourierCard struct {
	UserID     string     `json:"user_id"`
	Code       string     `json:"code"`
	Status     string     `json:"status"`
	Phone      string     `json:"phone"`
	FullName   string     `json:"full_name"`
	Level      string     `json:"level"`
	Delivered  int        `json:"delivered"`
	VerifiedAt *time.Time `json:"verified_at"`
	// Где проверен.
	VerifiedStore *string `json:"verified_store"`
}

func (s *Service) crowdCard(ctx context.Context, where string, arg any) (CrowdCourierCard, error) {
	var c CrowdCourierCard
	err := s.pool.QueryRow(ctx, `
		SELECT cc.user_id, cc.code, cc.status, u.phone, cc.full_name, cc.verified_at, vs.name
		FROM crowd_couriers cc JOIN users u ON u.id = cc.user_id
		LEFT JOIN stores vs ON vs.id = cc.verified_store_id
		WHERE cc.deleted_at IS NULL AND `+where, arg).Scan(&c.UserID, &c.Code, &c.Status, &c.Phone, &c.FullName, &c.VerifiedAt, &c.VerifiedStore)
	if errors.Is(err, pgx.ErrNoRows) {
		return c, apperr.NotFound("курьер с таким кодом не найден").Uz("bunday kodli kuryer topilmadi")
	}
	if err != nil {
		return c, err
	}
	st, err := crowdStats(ctx, s.pool, c.UserID)
	if err != nil {
		return c, err
	}
	cs, err := s.crowdSettings(ctx, s.pool)
	if err != nil {
		return c, err
	}
	c.Delivered = st.Delivered
	c.Level = crowdLevel(cs, c.Status, st, i18n.FromContext(ctx)).Title
	return c, nil
}

// CrowdLookup — продавец сканирует QR курьера или вводит его код.
func (s *Service) CrowdLookup(ctx context.Context, p *identity.Principal, raw string) (CrowdCourierCard, error) {
	if err := p.Require(identity.PermOrdersManage); err != nil {
		return CrowdCourierCard{}, err
	}
	code, ok := normCourierCode(raw)
	if !ok {
		return CrowdCourierCard{}, apperr.Validation("code: код курьера вида KR-12345").Uz("code: KR-12345 koʻrinishidagi kuryer kodi")
	}
	return s.crowdCard(ctx, "cc.code = $1", code)
}

type CrowdVerifyInput struct {
	Code       string `json:"code"`
	StoreID    string `json:"store_id"`
	Decision   string `json:"decision"` // approve или reject
	DocType    string `json:"doc_type"` // passport или id_card
	FullName   string `json:"full_name"`
	BirthDate  string `json:"birth_date"` // YYYY-MM-DD
	DocLast4   string `json:"doc_last4"`
	PhotoMatch bool   `json:"photo_match"`
	DocValid   bool   `json:"doc_valid"`
	Reason     string `json:"reason"`
}

var last4Re = regexp.MustCompile(`^[0-9]{4}$`)

// docHash — отпечаток документа: тот же человек не зарегистрируется дважды.
// Номер целиком не хранится — только последние 4 цифры в хэше с ФИО и датой рождения.
func (s *Service) docHash(docType, fullName, birth, last4 string) []byte {
	m := hmac.New(sha256.New, []byte(s.cfg.Secret+":crowd-doc"))
	m.Write([]byte(docType + "|" + strings.ToUpper(strings.Join(strings.Fields(fullName), " ")) + "|" + birth + "|" + last4))
	return m.Sum(nil)
}

// CrowdVerify — продавец сверил документ и подтверждает личность курьера (или отказывает).
func (s *Service) CrowdVerify(ctx context.Context, p *identity.Principal, in CrowdVerifyInput) (CrowdCourierCard, error) {
	if err := p.Require(identity.PermOrdersManage); err != nil {
		return CrowdCourierCard{}, err
	}
	code, ok := normCourierCode(in.Code)
	if !ok {
		return CrowdCourierCard{}, apperr.Validation("code: код курьера вида KR-12345").Uz("code: KR-12345 koʻrinishidagi kuryer kodi")
	}
	if !httpx.IsUUID(in.StoreID) || !p.CanAccessStore(in.StoreID) {
		return CrowdCourierCard{}, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	var enabled bool
	err := s.pool.QueryRow(ctx, `SELECT crowd_enabled AND network_has_feature(network_id, 'crowd') FROM stores WHERE id = $1 AND network_id = $2`, in.StoreID, p.NetworkID).Scan(&enabled)
	if errors.Is(err, pgx.ErrNoRows) {
		return CrowdCourierCard{}, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	if err != nil {
		return CrowdCourierCard{}, err
	}
	if !enabled {
		return CrowdCourierCard{}, apperr.Conflict("crowd_disabled", "магазин не подключён к доставке «по пути»").Uz("doʻkon «yoʻl-yoʻlakay» yetkazib berishga ulanmagan")
	}
	if in.DocType != "passport" && in.DocType != "id_card" {
		return CrowdCourierCard{}, apperr.Validation("doc_type: passport или id_card").Uz("doc_type: passport yoki id_card")
	}
	reason := strings.TrimSpace(in.Reason)
	if len([]rune(reason)) > 500 {
		return CrowdCourierCard{}, apperr.Validation("reason: не длиннее 500 символов").Uz("reason: 500 belgidan oshmasin")
	}
	card, err := s.crowdCard(ctx, "cc.code = $1", code)
	if err != nil {
		return card, err
	}
	switch card.Status {
	case "blocked":
		return card, apperr.Conflict("crowd_blocked", "курьер заблокирован — обратитесь в поддержку Super Market").Uz("kuryer bloklangan — Super Market qoʻllab-quvvatlash xizmatiga murojaat qiling")
	case "active":
		return card, apperr.Conflict("already_verified", "личность курьера уже подтверждена").Uz("kuryer shaxsi allaqachon tasdiqlangan")
	}

	var (
		fullName string
		birth    *time.Time
		hash     []byte
	)
	switch in.Decision {
	case "reject":
		if reason == "" {
			return card, apperr.Validation("reason: укажите причину отказа").Uz("reason: rad etish sababini kiriting")
		}
	case "approve":
		fullName = strings.Join(strings.Fields(in.FullName), " ")
		if len([]rune(fullName)) < 5 || len([]rune(fullName)) > 120 {
			return card, apperr.Validation("full_name: ФИО как в документе").Uz("full_name: F.I.Sh. hujjatdagidek")
		}
		b, err := time.Parse("2006-01-02", in.BirthDate)
		if err != nil {
			return card, apperr.Validation("birth_date: дата рождения ГГГГ-ММ-ДД").Uz("birth_date: tugʻilgan sana YYYY-MM-DD")
		}
		now := s.now().In(tashkent)
		adult := time.Date(b.Year()+18, b.Month(), b.Day(), 0, 0, 0, 0, tashkent)
		if now.Before(adult) {
			return card, apperr.Validation("курьером можно стать только с 18 лет").Uz("kuryer boʻlish faqat 18 yoshdan mumkin")
		}
		if b.Year() < 1920 {
			return card, apperr.Validation("birth_date: проверьте дату рождения").Uz("birth_date: tugʻilgan sanani tekshiring")
		}
		birth = &b
		if !last4Re.MatchString(in.DocLast4) {
			return card, apperr.Validation("doc_last4: последние 4 цифры номера документа").Uz("doc_last4: hujjat raqamining oxirgi 4 ta raqami")
		}
		if !in.PhotoMatch || !in.DocValid {
			return card, apperr.Validation("отметьте, что фото совпадает и документ действителен").Uz("rasm mos kelishini va hujjat haqiqiyligini belgilang")
		}
		hash = s.docHash(in.DocType, fullName, in.BirthDate, in.DocLast4)
	default:
		return card, apperr.Validation("decision: approve или reject").Uz("decision: approve yoki reject")
	}

	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		result := "approved"
		if in.Decision == "reject" {
			result = "rejected"
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO courier_verifications (courier_id, network_id, store_id, employee_id, doc_type, full_name, birth_date, doc_hash, result, reason)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
			card.UserID, p.NetworkID, in.StoreID, p.EmployeeID, in.DocType, fullName, birth, hash, result, reason); err != nil {
			return err
		}
		if in.Decision == "reject" {
			return nil
		}
		_, err := tx.Exec(ctx, `
			UPDATE crowd_couriers SET status = 'active', full_name = $2, birth_date = $3, doc_hash = $4,
			       verified_at = now(), verified_store_id = $5
			WHERE user_id = $1 AND status = 'unverified'`, card.UserID, fullName, birth, hash, in.StoreID)
		if db.IsUniqueViolation(err, "crowd_couriers_doc_idx") {
			return apperr.Conflict("doc_used", "этот документ уже подтверждён у другого курьера").Uz("bu hujjat allaqachon boshqa kuryerda tasdiqlangan")
		}
		return err
	})
	if err != nil {
		return card, err
	}
	return s.crowdCard(ctx, "cc.user_id = $1", card.UserID)
}

type CrowdHandoverInput struct {
	Code string `json:"code"`
}

// normPickup принимает «7K4», «1051 · 7K4» или QR «sm-pickup:1051:7K4».
func normPickup(raw string) string {
	parts := strings.FieldsFunc(strings.ToUpper(raw), func(r rune) bool {
		return (r < '0' || r > '9') && (r < 'A' || r > 'Z')
	})
	if len(parts) == 0 {
		return ""
	}
	return parts[len(parts)-1]
}

// CrowdHandover — магазин выдал заказ курьеру «по пути»: код совпал — заказ «в пути».
func (s *Service) CrowdHandover(ctx context.Context, p *identity.Principal, id string, in CrowdHandoverInput) (Order, error) {
	if err := p.Require(identity.PermOrdersManage); err != nil {
		return Order{}, err
	}
	o, err := s.StoreGet(ctx, p, id)
	if err != nil {
		return Order{}, err
	}
	if o.CrowdCourierID == nil {
		return Order{}, apperr.Conflict("no_crowd_courier", "заказ не взял курьер «по пути»").Uz("buyurtmani «yoʻl-yoʻlakay» kuryer olmagan")
	}
	code := normPickup(in.Code)
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := lockOrder(ctx, tx, id, StatusPicked); err != nil {
			return err
		}
		var want *string
		if err := tx.QueryRow(ctx, `SELECT pickup_code FROM orders WHERE id = $1`, id).Scan(&want); err != nil {
			return err
		}
		if want == nil || code != *want {
			return apperr.Validation("код выдачи не совпадает с заказом — проверьте курьера").Uz("topshirish kodi buyurtmaga mos emas — kuryerni tekshiring")
		}
		if _, err := tx.Exec(ctx, `UPDATE orders SET status = 'delivering', picked_up_at = now(), crowd_pickup_until = NULL WHERE id = $1`, id); err != nil {
			return err
		}
		if err := updateCrowdETA(ctx, tx, id); err != nil {
			return err
		}
		return addHistory(ctx, tx, id, StatusDelivering, "store:"+p.EmployeeID, "Выдан курьеру по пути")
	})
	if err != nil {
		return Order{}, err
	}
	return s.StoreGet(ctx, p, id)
}

// CrowdStoreRelease — магазин снимает курьера «по пути» (не пришёл, другой курьер).
func (s *Service) CrowdStoreRelease(ctx context.Context, p *identity.Principal, id string) (Order, error) {
	if err := p.Require(identity.PermOrdersManage); err != nil {
		return Order{}, err
	}
	o, err := s.StoreGet(ctx, p, id)
	if err != nil {
		return Order{}, err
	}
	if o.CrowdCourierID == nil {
		return Order{}, apperr.Conflict("no_crowd_courier", "заказ не взял курьер «по пути»").Uz("buyurtmani «yoʻl-yoʻlakay» kuryer olmagan")
	}
	courier := *o.CrowdCourierID
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := lockOrder(ctx, tx, id, StatusPicked); err != nil {
			return err
		}
		if err := clearCrowd(ctx, tx, id, "store:"+p.EmployeeID, "Магазин снял курьера по пути"); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO courier_incidents (courier_id, order_id, kind, note) VALUES ($1, $2, 'other', 'Снят магазином до выдачи')`,
			courier, id)
		return err
	})
	if err != nil {
		return Order{}, err
	}
	return s.StoreGet(ctx, p, id)
}

// StoreCrowdBonus — курьер, которого проверил магазин, и бонус за него.
type StoreCrowdBonus struct {
	CourierID  string    `json:"courier_id"`
	Name       string    `json:"name"`
	Code       string    `json:"code"`
	StoreName  string    `json:"store_name"`
	VerifiedAt time.Time `json:"verified_at"`
	Deliveries int       `json:"deliveries"` // засчитано в бонус
	Credited   string    `json:"credited"`
	Pending    string    `json:"pending"`
}

type StoreCrowdBonuses struct {
	CreditedMonth string            `json:"credited_month"`
	Pending       string            `json:"pending"`
	Verified      int               `json:"verified"`
	PerDelivery   string            `json:"per_delivery"`
	MaxDeliveries int               `json:"max_deliveries"`
	Items         []StoreCrowdBonus `json:"items"`
}

// StoreCrowdBonuses — бонусы сети (или магазина) за проверенных курьеров.
func (s *Service) StoreCrowdBonuses(ctx context.Context, p *identity.Principal, storeID string) (StoreCrowdBonuses, error) {
	r := StoreCrowdBonuses{Items: []StoreCrowdBonus{}}
	if err := p.Require(identity.PermOrdersManage); err != nil {
		return r, err
	}
	if storeID != "" && (!httpx.IsUUID(storeID) || !p.CanAccessStore(storeID)) {
		return r, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	cs, err := s.crowdSettings(ctx, s.pool)
	if err != nil {
		return r, err
	}
	r.PerDelivery, r.MaxDeliveries = cs.StoreBonus, cs.StoreBonusCount
	const scope = `v.network_id = $1 AND ($2 OR v.store_id = ANY($3::uuid[])) AND ($4 = '' OR v.store_id::text = $4)`
	month := time.Now().In(tashkent)
	month = time.Date(month.Year(), month.Month(), 1, 0, 0, 0, 0, tashkent)
	err = s.pool.QueryRow(ctx, `
		SELECT COALESCE(sum(b.amount) FILTER (WHERE b.status = 'credited' AND b.credited_at >= $5), 0)::numeric(18,2)::text,
		       COALESCE(sum(b.amount) FILTER (WHERE b.status = 'pending'), 0)::numeric(18,2)::text
		FROM store_crowd_bonuses b
		WHERE b.network_id = $1 AND ($2 OR b.store_id = ANY($3::uuid[])) AND ($4 = '' OR b.store_id::text = $4)`,
		p.NetworkID, p.SeesAllStores(), p.StoreIDs, storeID, month).Scan(&r.CreditedMonth, &r.Pending)
	if err != nil {
		return r, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT cc.user_id, cc.full_name, cc.code, s.name, v.created_at,
		       (SELECT count(*) FROM store_crowd_bonuses b WHERE b.courier_id = cc.user_id AND b.store_id = v.store_id AND b.status <> 'cancelled')::int,
		       COALESCE((SELECT sum(amount) FROM store_crowd_bonuses b WHERE b.courier_id = cc.user_id AND b.store_id = v.store_id AND b.status = 'credited'), 0)::numeric(18,2)::text,
		       COALESCE((SELECT sum(amount) FROM store_crowd_bonuses b WHERE b.courier_id = cc.user_id AND b.store_id = v.store_id AND b.status = 'pending'), 0)::numeric(18,2)::text
		FROM courier_verifications v
		JOIN crowd_couriers cc ON cc.user_id = v.courier_id AND cc.verified_store_id = v.store_id
		JOIN stores s ON s.id = v.store_id
		WHERE v.result = 'approved' AND `+scope+`
		ORDER BY v.created_at DESC LIMIT 200`, p.NetworkID, p.SeesAllStores(), p.StoreIDs, storeID)
	if err != nil {
		return r, err
	}
	if r.Items, err = pgx.CollectRows(rows, pgx.RowToStructByPos[StoreCrowdBonus]); err != nil {
		return r, err
	}
	r.Verified = len(r.Items)
	return r, nil
}
