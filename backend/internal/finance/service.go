package finance

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
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

type Service struct {
	pool *pgxpool.Pool
	// Payments — что сделать после оплаты контрагенту (оплата агенту ждёт
	// его подтверждения — пакет supply). nil — ничего.
	Payments PaymentHook
}

func NewService(pool *pgxpool.Pool) *Service { return &Service{pool: pool} }

// PaymentEvent — расход из кассы контрагенту (оплата поставщику).
type PaymentEvent struct {
	OperationID    string
	CounterpartyID string
	CashboxStoreID *string
	AmountUZS      string
	Note           string
}

// PaymentHook вызывается в транзакции кассовой операции.
type PaymentHook interface {
	AfterCounterpartyPayment(ctx context.Context, tx pgx.Tx, p *identity.Principal, ev PaymentEvent) error
}

func trim(p *string) *string {
	if p == nil {
		return nil
	}
	t := strings.TrimSpace(*p)
	return &t
}

func one[T any](rows pgx.Rows, err error, notFound i18n.Text) (T, error) {
	var zero T
	if err != nil {
		return zero, err
	}
	v, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[T])
	if errors.Is(err, pgx.ErrNoRows) {
		return zero, apperr.NotFound(notFound.RU).Uz(notFound.UZ)
	}
	return v, err
}

func many[T any](rows pgx.Rows, err error) ([]T, error) {
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[T])
}

// ------------------------------------------------------------ курс валют

type Rate struct {
	Rate      string    `json:"rate"`
	CreatedAt time.Time `json:"created_at"`
}

func (s *Service) ListRates(ctx context.Context, p *identity.Principal, page httpx.Page) ([]Rate, error) {
	rows, err := s.pool.Query(ctx, `SELECT rate::text, created_at FROM currency_rates WHERE network_id = $1
		ORDER BY created_at DESC, id DESC LIMIT $2 OFFSET $3`, p.NetworkID, page.Limit, page.Offset)
	return many[Rate](rows, err)
}

func (s *Service) SetRate(ctx context.Context, p *identity.Principal, rate money.Rate) (Rate, error) {
	if err := p.Require(identity.PermFinanceManage); err != nil {
		return Rate{}, err
	}
	if rate == "" {
		return Rate{}, apperr.Validation("rate: обязательное поле").Uz("rate: majburiy maydon")
	}
	rows, err := s.pool.Query(ctx, `INSERT INTO currency_rates (network_id, rate, created_by) VALUES ($1, $2::numeric, $3)
		RETURNING rate::text, created_at`, p.NetworkID, string(rate), p.EmployeeID)
	return one[Rate](rows, err, i18n.Text{})
}

// ------------------------------------------------------- типы контрагентов

type CounterpartyType struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	IsActive bool   `json:"is_active"`
}

type NamedInput struct {
	Name     *string `json:"name"`
	IsActive *bool   `json:"is_active"`
}

func (s *Service) ListCounterpartyTypes(ctx context.Context, p *identity.Principal) ([]CounterpartyType, error) {
	rows, err := s.pool.Query(ctx, `SELECT id, name, is_active FROM counterparty_types WHERE network_id = $1 ORDER BY name`, p.NetworkID)
	return many[CounterpartyType](rows, err)
}

func (s *Service) SaveCounterpartyType(ctx context.Context, p *identity.Principal, id string, in NamedInput) (CounterpartyType, error) {
	if err := p.Require(identity.PermCounterpartiesManage); err != nil {
		return CounterpartyType{}, err
	}
	name := trim(in.Name)
	if (id == "" && name == nil) || (name != nil && *name == "") {
		return CounterpartyType{}, apperr.Validation("name: обязательное поле").Uz("name: majburiy maydon")
	}
	var rows pgx.Rows
	var err error
	if id == "" {
		rows, err = s.pool.Query(ctx, `INSERT INTO counterparty_types (network_id, name) VALUES ($1, $2)
			RETURNING id, name, is_active`, p.NetworkID, *name)
	} else {
		rows, err = s.pool.Query(ctx, `UPDATE counterparty_types SET name = COALESCE($3, name), is_active = COALESCE($4, is_active)
			WHERE id = $1 AND network_id = $2 RETURNING id, name, is_active`, id, p.NetworkID, name, in.IsActive)
	}
	t, err := one[CounterpartyType](rows, err, i18n.Text{RU: "тип контрагента не найден", UZ: "kontragent turi topilmadi"})
	if db.IsUniqueViolation(err, "") {
		return t, apperr.Conflict("already_exists", "тип с таким названием уже есть").Uz("bunday nomli tur allaqachon bor")
	}
	return t, err
}

// ------------------------------------------------------------ контрагенты

type Counterparty struct {
	ID       string  `json:"id"`
	TypeID   *string `json:"type_id"`
	TypeName *string `json:"type_name"`
	Name     string  `json:"name"`
	Phone    string  `json:"phone"`
	INN      string  `json:"inn"`
	Note     string  `json:"note"`
	IsActive bool    `json:"is_active"`
	// Баланс в UZS: плюс — мы должны контрагенту, минус — он нам.
	Balance string `json:"balance"`
}

const counterpartySelect = `
	SELECT c.id, c.type_id, t.name, c.name, c.phone, c.inn, c.note, c.is_active,
	       COALESCE((SELECT sum(e.amount) FROM counterparty_entries e WHERE e.counterparty_id = c.id), 0)::text
	FROM counterparties c LEFT JOIN counterparty_types t ON t.id = c.type_id`

// ListCounterparties — контрагенты сети. suppliersOnly — только те, от кого
// приходит товар: без магазинов-клиентов агента (им товар отгружают).
func (s *Service) ListCounterparties(ctx context.Context, p *identity.Principal, q string, suppliersOnly bool, page httpx.Page) ([]Counterparty, error) {
	rows, err := s.pool.Query(ctx, counterpartySelect+`
		WHERE c.network_id = $1 AND ($2 = '' OR c.name ILIKE '%' || $2 || '%' OR c.phone LIKE '%' || $2 || '%')
		  AND (NOT $5 OR c.store_id IS NULL)
		ORDER BY c.name LIMIT $3 OFFSET $4`, p.NetworkID, strings.TrimSpace(q), page.Limit, page.Offset, suppliersOnly)
	return many[Counterparty](rows, err)
}

func (s *Service) GetCounterparty(ctx context.Context, p *identity.Principal, id string) (Counterparty, error) {
	rows, err := s.pool.Query(ctx, counterpartySelect+` WHERE c.network_id = $1 AND c.id = $2`, p.NetworkID, id)
	return one[Counterparty](rows, err, i18n.Text{RU: "контрагент не найден", UZ: "kontragent topilmadi"})
}

type CounterpartyInput struct {
	TypeID   *string `json:"type_id"`
	Name     *string `json:"name"`
	Phone    *string `json:"phone"`
	INN      *string `json:"inn"`
	Note     *string `json:"note"`
	IsActive *bool   `json:"is_active"`
}

func (s *Service) SaveCounterparty(ctx context.Context, p *identity.Principal, id string, in CounterpartyInput) (Counterparty, error) {
	// Нового поставщика заводит и тот, кто принимает приход (сотрудник склада
	// в «SM Сотрудник» — прямо в приходе, как владелец в «SM Магазин»);
	// менять существующих — только с правом «Контрагенты».
	perm := p.Require(identity.PermCounterpartiesManage)
	if id == "" {
		perm = p.RequireAny(identity.PermCounterpartiesManage, identity.PermInventoryManage)
	}
	if err := perm; err != nil {
		return Counterparty{}, err
	}
	name := trim(in.Name)
	if (id == "" && name == nil) || (name != nil && *name == "") {
		return Counterparty{}, apperr.Validation("name: обязательное поле").Uz("name: majburiy maydon")
	}
	if in.TypeID != nil && *in.TypeID != "" && !httpx.IsUUID(*in.TypeID) {
		return Counterparty{}, apperr.Validation("type_id: тип не найден").Uz("type_id: tur topilmadi")
	}
	setType := in.TypeID != nil
	var typeID *string
	if setType && *in.TypeID != "" {
		typeID = in.TypeID
	}
	var err error
	if id == "" {
		err = s.pool.QueryRow(ctx, `
			INSERT INTO counterparties (network_id, type_id, name, phone, inn, note)
			VALUES ($1, $2, $3, COALESCE($4, ''), COALESCE($5, ''), COALESCE($6, '')) RETURNING id`,
			p.NetworkID, typeID, *name, trim(in.Phone), trim(in.INN), trim(in.Note)).Scan(&id)
	} else {
		var tag interface{ RowsAffected() int64 }
		tag, err = s.pool.Exec(ctx, `
			UPDATE counterparties SET
				type_id = CASE WHEN $3 THEN $4::uuid ELSE type_id END,
				name = COALESCE($5, name), phone = COALESCE($6, phone), inn = COALESCE($7, inn),
				note = COALESCE($8, note), is_active = COALESCE($9, is_active)
			WHERE id = $1 AND network_id = $2`,
			id, p.NetworkID, setType, typeID, name, trim(in.Phone), trim(in.INN), trim(in.Note), in.IsActive)
		if err == nil && tag.RowsAffected() == 0 {
			return Counterparty{}, apperr.NotFound("контрагент не найден").Uz("kontragent topilmadi")
		}
	}
	if db.IsForeignKeyViolation(err) {
		return Counterparty{}, apperr.Validation("type_id: тип не найден").Uz("type_id: tur topilmadi")
	}
	if err != nil {
		return Counterparty{}, err
	}
	return s.GetCounterparty(ctx, p, id)
}

// ------------------------------------------------------ финансовые причины

type Reason struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Kind     string `json:"kind"`
	IsActive bool   `json:"is_active"`
}

type ReasonInput struct {
	Name     *string `json:"name"`
	Kind     *string `json:"kind"`
	IsActive *bool   `json:"is_active"`
}

func (s *Service) ListReasons(ctx context.Context, p *identity.Principal) ([]Reason, error) {
	rows, err := s.pool.Query(ctx, `SELECT id, name, kind, is_active FROM financial_reasons WHERE network_id = $1 ORDER BY kind, name`, p.NetworkID)
	return many[Reason](rows, err)
}

func (s *Service) SaveReason(ctx context.Context, p *identity.Principal, id string, in ReasonInput) (Reason, error) {
	if err := p.Require(identity.PermFinanceManage); err != nil {
		return Reason{}, err
	}
	name := trim(in.Name)
	if (id == "" && name == nil) || (name != nil && *name == "") {
		return Reason{}, apperr.Validation("name: обязательное поле").Uz("name: majburiy maydon")
	}
	var rows pgx.Rows
	var err error
	if id == "" {
		if in.Kind == nil || (*in.Kind != "income" && *in.Kind != "expense") {
			return Reason{}, apperr.Validation("kind: ожидается income или expense").Uz("kind: income yoki expense boʻlishi kerak")
		}
		rows, err = s.pool.Query(ctx, `INSERT INTO financial_reasons (network_id, name, kind) VALUES ($1, $2, $3)
			RETURNING id, name, kind, is_active`, p.NetworkID, *name, *in.Kind)
	} else {
		if in.Kind != nil {
			return Reason{}, apperr.Validation("kind: вид причины не меняется").Uz("kind: sabab turi oʻzgarmaydi")
		}
		rows, err = s.pool.Query(ctx, `UPDATE financial_reasons SET name = COALESCE($3, name), is_active = COALESCE($4, is_active)
			WHERE id = $1 AND network_id = $2 RETURNING id, name, kind, is_active`, id, p.NetworkID, name, in.IsActive)
	}
	r, err := one[Reason](rows, err, i18n.Text{RU: "причина не найдена", UZ: "sabab topilmadi"})
	if db.IsUniqueViolation(err, "") {
		return r, apperr.Conflict("already_exists", "причина с таким названием уже есть").Uz("bunday nomli sabab allaqachon bor")
	}
	return r, err
}

// ------------------------------------------------------------------ кассы

type Cashbox struct {
	ID        string  `json:"id"`
	StoreID   *string `json:"store_id"`
	StoreName *string `json:"store_name"`
	Name      string  `json:"name"`
	Currency  string  `json:"currency"`
	IsMain    bool    `json:"is_main"`
	IsActive  bool    `json:"is_active"`
	Balance   string  `json:"balance"`
	// cash — наличные (ящик магазина или главная касса), bank — терминал:
	// деньги по карте на счёте, их не сдают.
	Kind string `json:"kind"`
}

const cashboxSelect = `
	SELECT c.id, c.store_id, s.name, c.name, c.currency, c.is_main, c.is_active,
	       COALESCE((SELECT sum(e.amount) FROM cash_entries e WHERE e.cashbox_id = c.id), 0)::text, c.kind
	FROM cashboxes c LEFT JOIN stores s ON s.id = c.store_id`

// Касса видна, если у сотрудника есть доступ к её магазину; главная — только
// тем, кто видит все магазины.
const cashboxVisible = `($2 OR c.store_id = ANY($3::uuid[]))`

func (s *Service) ListCashboxes(ctx context.Context, p *identity.Principal) ([]Cashbox, error) {
	rows, err := s.pool.Query(ctx, cashboxSelect+` WHERE c.network_id = $1 AND `+cashboxVisible+`
		ORDER BY c.is_main DESC, s.name, c.name`, p.NetworkID, p.SeesAllStores(), p.StoreIDs)
	return many[Cashbox](rows, err)
}

func (s *Service) getCashbox(ctx context.Context, q db.Querier, p *identity.Principal, id string) (Cashbox, error) {
	rows, err := q.Query(ctx, cashboxSelect+` WHERE c.network_id = $1 AND `+cashboxVisible+` AND c.id = $4`,
		p.NetworkID, p.SeesAllStores(), p.StoreIDs, id)
	return one[Cashbox](rows, err, i18n.Text{RU: "касса не найдена", UZ: "kassa topilmadi"})
}

type CashboxInput struct {
	StoreID  *string `json:"store_id"`
	Name     *string `json:"name"`
	Currency *string `json:"currency"`
	IsActive *bool   `json:"is_active"`
}

// SaveCashbox: новая касса магазина (например, долларовая) или правка.
func (s *Service) SaveCashbox(ctx context.Context, p *identity.Principal, id string, in CashboxInput) (Cashbox, error) {
	if err := p.Require(identity.PermFinanceManage); err != nil {
		return Cashbox{}, err
	}
	name := trim(in.Name)
	if (id == "" && name == nil) || (name != nil && *name == "") {
		return Cashbox{}, apperr.Validation("name: обязательное поле").Uz("name: majburiy maydon")
	}
	if id == "" {
		currency := "UZS"
		if in.Currency != nil {
			currency = *in.Currency
		}
		if currency != "UZS" && currency != "USD" {
			return Cashbox{}, apperr.Validation("currency: ожидается UZS или USD").Uz("currency: UZS yoki USD boʻlishi kerak")
		}
		var err error
		if in.StoreID == nil {
			// Главная долларовая касса сети.
			if !p.SeesAllStores() {
				return Cashbox{}, apperr.Forbidden("главные кассы доступны только при доступе ко всем магазинам").Uz("asosiy kassalar faqat barcha doʻkonlarga ruxsat boʻlganda mavjud")
			}
			err = s.pool.QueryRow(ctx, `INSERT INTO cashboxes (network_id, name, currency, is_main) VALUES ($1, $2, $3, true) RETURNING id`,
				p.NetworkID, *name, currency).Scan(&id)
			if db.IsUniqueViolation(err, "cashboxes_one_main") {
				return Cashbox{}, apperr.Conflict("main_exists", "главная касса в этой валюте уже есть").Uz("bu valyutada asosiy kassa allaqachon bor")
			}
		} else {
			if !httpx.IsUUID(*in.StoreID) || !p.CanAccessStore(*in.StoreID) {
				return Cashbox{}, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
			}
			err = s.pool.QueryRow(ctx, `INSERT INTO cashboxes (network_id, store_id, name, currency) VALUES ($1, $2, $3, $4) RETURNING id`,
				p.NetworkID, *in.StoreID, *name, currency).Scan(&id)
			if db.IsForeignKeyViolation(err) {
				return Cashbox{}, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
			}
		}
		if err != nil {
			return Cashbox{}, err
		}
		return s.getCashbox(ctx, s.pool, p, id)
	}

	if in.StoreID != nil || in.Currency != nil {
		return Cashbox{}, apperr.Validation("магазин и валюта кассы не меняются").Uz("kassaning doʻkoni va valyutasi oʻzgarmaydi")
	}
	if _, err := s.getCashbox(ctx, s.pool, p, id); err != nil {
		return Cashbox{}, err
	}
	if _, err := s.pool.Exec(ctx, `UPDATE cashboxes SET name = COALESCE($3, name), is_active = COALESCE($4, is_active)
		WHERE id = $1 AND network_id = $2`, id, p.NetworkID, name, in.IsActive); err != nil {
		return Cashbox{}, err
	}
	return s.getCashbox(ctx, s.pool, p, id)
}

// ---------------------------------------------------------- способы оплаты

type PaymentMethod struct {
	ID          string  `json:"id"`
	Name        string  `json:"name"`
	CashboxID   string  `json:"cashbox_id"`
	CashboxName string  `json:"cashbox_name"`
	StoreID     *string `json:"store_id"`
	IsActive    bool    `json:"is_active"`
}

type PaymentMethodInput struct {
	Name      *string `json:"name"`
	CashboxID *string `json:"cashbox_id"`
	IsActive  *bool   `json:"is_active"`
}

const paymentMethodSelect = `
	SELECT m.id, m.name, m.cashbox_id, c.name, c.store_id, m.is_active
	FROM payment_methods m JOIN cashboxes c ON c.id = m.cashbox_id`

func (s *Service) ListPaymentMethods(ctx context.Context, p *identity.Principal, storeID string) ([]PaymentMethod, error) {
	rows, err := s.pool.Query(ctx, paymentMethodSelect+`
		WHERE m.network_id = $1 AND ($2 OR c.store_id = ANY($3::uuid[])) AND ($4 = '' OR c.store_id::text = $4)
		ORDER BY c.name, m.name`, p.NetworkID, p.SeesAllStores(), p.StoreIDs, storeID)
	return many[PaymentMethod](rows, err)
}

func (s *Service) SavePaymentMethod(ctx context.Context, p *identity.Principal, id string, in PaymentMethodInput) (PaymentMethod, error) {
	if err := p.Require(identity.PermFinanceManage); err != nil {
		return PaymentMethod{}, err
	}
	name := trim(in.Name)
	if (id == "" && name == nil) || (name != nil && *name == "") {
		return PaymentMethod{}, apperr.Validation("name: обязательное поле").Uz("name: majburiy maydon")
	}
	if in.CashboxID != nil {
		if !httpx.IsUUID(*in.CashboxID) {
			return PaymentMethod{}, apperr.Validation("cashbox_id: касса не найдена").Uz("cashbox_id: kassa topilmadi")
		}
		if _, err := s.getCashbox(ctx, s.pool, p, *in.CashboxID); err != nil {
			return PaymentMethod{}, apperr.Validation("cashbox_id: касса не найдена").Uz("cashbox_id: kassa topilmadi")
		}
	}
	var err error
	if id == "" {
		if in.CashboxID == nil {
			return PaymentMethod{}, apperr.Validation("cashbox_id: обязательное поле").Uz("cashbox_id: majburiy maydon")
		}
		err = s.pool.QueryRow(ctx, `INSERT INTO payment_methods (network_id, name, cashbox_id) VALUES ($1, $2, $3) RETURNING id`,
			p.NetworkID, *name, *in.CashboxID).Scan(&id)
	} else {
		var tag interface{ RowsAffected() int64 }
		tag, err = s.pool.Exec(ctx, `UPDATE payment_methods SET name = COALESCE($3, name), cashbox_id = COALESCE($4, cashbox_id),
			is_active = COALESCE($5, is_active) WHERE id = $1 AND network_id = $2`, id, p.NetworkID, name, in.CashboxID, in.IsActive)
		if err == nil && tag.RowsAffected() == 0 {
			return PaymentMethod{}, apperr.NotFound("способ оплаты не найден").Uz("toʻlov usuli topilmadi")
		}
	}
	if db.IsUniqueViolation(err, "") {
		return PaymentMethod{}, apperr.Conflict("already_exists", "у кассы уже есть способ оплаты с таким названием").Uz("kassada bunday nomli toʻlov usuli allaqachon bor")
	}
	if err != nil {
		return PaymentMethod{}, err
	}
	rows, err := s.pool.Query(ctx, paymentMethodSelect+` WHERE m.id = $1`, id)
	return one[PaymentMethod](rows, err, i18n.Text{RU: "способ оплаты не найден", UZ: "toʻlov usuli topilmadi"})
}

// PaymentMethodCashbox — касса и валюта способа оплаты (для продаж).
func PaymentMethodCashbox(ctx context.Context, q db.Querier, networkID, methodID string) (cashboxID, currency string, storeID *string, err error) {
	var active bool
	err = q.QueryRow(ctx, `
		SELECT c.id, c.currency, c.store_id, m.is_active AND c.is_active
		FROM payment_methods m JOIN cashboxes c ON c.id = m.cashbox_id
		WHERE m.id = $1 AND m.network_id = $2`, methodID, networkID).Scan(&cashboxID, &currency, &storeID, &active)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !active) {
		err = apperr.Validation("payment_method_id: способ оплаты не найден или отключён").Uz("payment_method_id: toʻlov usuli topilmadi yoki oʻchirilgan")
	}
	return
}
