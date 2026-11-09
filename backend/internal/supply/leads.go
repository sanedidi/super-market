package supply

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/phone"
	"github.com/sanedidi/super-market/backend/internal/tenant"
)

// Агент добавляет магазин (Figma «SM Агент · Добавить магазин», АМ1–АМ6, и
// «Супер-админ · Заявки агентов на магазины», С1–С3).
//
// Агент вносит магазин, которого ещё нет в Super Market: название, владелец,
// телефон и точка на карте. Магазин закреплён за агентом leadHoldDays дней.
// Супер-админ подключает его (создаёт сеть с заполненными из заявки полями —
// сеть навсегда привязана к агенту) или отклоняет с причиной. С первого
// оплаченного счёта подписки магазина агенту начисляется 50% (billing).

// leadHoldDays — сколько дней магазин закреплён за агентом без подключения.
const leadHoldDays = 30

// leadDuplicateM — ближе этого к магазину или активной заявке добавить нельзя.
const leadDuplicateM = 50

// leadNearbyM — супер-админу показываем магазины и заявки в этом радиусе.
const leadNearbyM = 150

// maxPendingLeads — сколько заявок агента могут одновременно ждать решения.
const maxPendingLeads = 50

// Статусы заявки для приложений. В базе: pending, connected, rejected;
// expired и paid считаются при чтении.
const (
	LeadPending   = "pending"   // ждёт решения супер-админа
	LeadConnected = "connected" // сеть создана, ждём первую оплату
	LeadPaid      = "paid"      // магазин оплатил, агенту начислено
	LeadRejected  = "rejected"  // отклонена с причиной
	LeadExpired   = "expired"   // не подключили за leadHoldDays дней
	leadClosed    = "closed"    // фильтр: отклонённые и с истёкшим сроком
)

// leadStatusSQL — статус заявки l для приложений.
const leadStatusSQL = `(CASE WHEN l.status = 'pending' AND l.expires_at <= now() THEN 'expired'
	WHEN l.status = 'connected' AND l.rewarded_at IS NOT NULL THEN 'paid' ELSE l.status END)`

// activeLeadSQL — заявка l держит магазин: ждёт решения и срок не истёк.
const activeLeadSQL = `(l.status = 'pending' AND l.expires_at > now())`

// StoreLead — заявка агента на магазин.
type StoreLead struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	OwnerName  string     `json:"owner_name"`
	OwnerPhone string     `json:"owner_phone"`
	Address    string     `json:"address"`
	Lat        float64    `json:"lat"`
	Lng        float64    `json:"lng"`
	Status     string     `json:"status"`
	Reason     string     `json:"reason"`
	ExpiresAt  time.Time  `json:"expires_at"`
	CreatedAt  time.Time  `json:"created_at"`
	DecidedAt  *time.Time `json:"decided_at"`
	// Сеть, созданная по заявке.
	NetworkID   *string `json:"network_id"`
	NetworkName string  `json:"network_name"`
	PlanName    string  `json:"plan_name"`
	// Первый неоплаченный счёт подключённого магазина: срок оплаты.
	InvoiceDue *string `json:"invoice_due"`
	// Сумма счёта — только супер-админу (агенту до оплаты сумму не показываем:
	// она зависит от тарифа магазина).
	InvoiceAmount *string `json:"invoice_amount,omitempty"`
	// Первая оплата и начисление агенту.
	PaidAmount   *string    `json:"paid_amount,omitempty"`
	PaidAt       *time.Time `json:"paid_at"`
	RewardAmount *string    `json:"reward_amount"`
	RewardedAt   *time.Time `json:"rewarded_at"`
	// Кто добавил: agent — агент «SM Агент» (50% первой оплаты), rep —
	// продажник Super Market («SM Продажник», на окладе — без начисления).
	Source string  `json:"source"`
	RepID  *string `json:"rep_id,omitempty"`
	// Агент (для супер-админа). У заявки продажника сети агента нет:
	// agent_network_id пустой, agent_name и agent_phone — продажника.
	AgentNetworkID   string `json:"agent_network_id"`
	AgentNetworkName string `json:"agent_network_name"`
	AgentName        string `json:"agent_name"`
	AgentPhone       string `json:"agent_phone"`
	// Карточка супер-админа: сколько магазинов агент подключил и сколько оплатили.
	AgentConnected *int `json:"agent_connected,omitempty"`
	AgentPaid      *int `json:"agent_paid,omitempty"`
	// Магазины и заявки рядом (до leadNearbyM м) — только в карточке супер-админа.
	Nearby []NearbyPlace `json:"nearby,omitempty"`
}

// NearbyPlace — магазин или чужая заявка рядом с точкой заявки.
type NearbyPlace struct {
	Kind      string  `json:"kind"` // store или lead
	Name      string  `json:"name"`
	Phone     string  `json:"phone"`
	Address   string  `json:"address"`
	DistanceM int     `json:"distance_m"`
	Lat       float64 `json:"lat"`
	Lng       float64 `json:"lng"`
}

const leadSelect = `
	SELECT l.id, l.name, l.owner_name, l.owner_phone, l.address,
	       ST_Y(l.location::geometry), ST_X(l.location::geometry),
	       ` + leadStatusSQL + `, l.reason, l.expires_at, l.created_at, l.decided_at,
	       l.network_id, COALESCE(sn.name, ''), COALESCE(pl.name, ''),
	       fi.due, fi.amount, fp.amount, fp.paid_at, l.reward_amount::text, l.rewarded_at,
	       CASE WHEN l.rep_id IS NOT NULL THEN 'rep' ELSE 'agent' END, l.rep_id::text,
	       COALESCE(an.id::text, ''), COALESCE(an.name, 'Продажник Super Market'),
	       COALESCE(ow.full_name, fr.full_name, ''), COALESCE(ow.phone, fru.phone, '')
	FROM store_leads l
	LEFT JOIN networks an  ON an.id = l.agent_network_id
	LEFT JOIN field_reps fr ON fr.id = l.rep_id
	LEFT JOIN users fru    ON fru.id = fr.user_id
	LEFT JOIN networks sn  ON sn.id = l.network_id
	LEFT JOIN plans pl     ON pl.key = sn.plan_key
	LEFT JOIN LATERAL (
		SELECT e.full_name, u.phone FROM employees e
		JOIN roles r ON r.id = e.role_id AND r.is_owner
		JOIN users u ON u.id = e.user_id
		WHERE e.network_id = an.id ORDER BY e.created_at LIMIT 1) ow ON true
	LEFT JOIN LATERAL (
		SELECT to_char(i.due_date, 'YYYY-MM-DD') AS due, i.amount_uzs::text AS amount
		FROM subscription_invoices i
		WHERE i.network_id = l.network_id AND i.status = 'unpaid' AND l.rewarded_at IS NULL
		ORDER BY i.period LIMIT 1) fi ON true
	LEFT JOIN LATERAL (
		SELECT i.amount_uzs::text AS amount, i.paid_at FROM subscription_invoices i
		WHERE i.id = l.reward_invoice_id) fp ON true`

func scanLead(row pgx.CollectableRow) (StoreLead, error) {
	var l StoreLead
	err := row.Scan(&l.ID, &l.Name, &l.OwnerName, &l.OwnerPhone, &l.Address, &l.Lat, &l.Lng,
		&l.Status, &l.Reason, &l.ExpiresAt, &l.CreatedAt, &l.DecidedAt,
		&l.NetworkID, &l.NetworkName, &l.PlanName,
		&l.InvoiceDue, &l.InvoiceAmount, &l.PaidAmount, &l.PaidAt, &l.RewardAmount, &l.RewardedAt,
		&l.Source, &l.RepID, &l.AgentNetworkID, &l.AgentNetworkName, &l.AgentName, &l.AgentPhone)
	return l, err
}

func getLead(ctx context.Context, q db.Querier, id string) (StoreLead, error) {
	rows, err := q.Query(ctx, leadSelect+` WHERE l.id = $1`, id)
	if err != nil {
		return StoreLead{}, err
	}
	l, err := pgx.CollectExactlyOneRow(rows, scanLead)
	if errors.Is(err, pgx.ErrNoRows) {
		return StoreLead{}, errLeadNotFound()
	}
	return l, err
}

func errLeadNotFound() error {
	return apperr.NotFound("заявка не найдена").Uz("ariza topilmadi")
}

// forAgent убирает из заявки то, что агенту не показываем.
func (l StoreLead) forAgent() StoreLead {
	l.InvoiceAmount, l.PaidAmount = nil, nil
	return l
}

// leadFilterSQL — условие вкладки (пусто — все).
func leadFilterSQL(status string) (string, error) {
	switch status {
	case "":
		return "true", nil
	case LeadPending, LeadConnected, LeadPaid:
		return leadStatusSQL + ` = '` + status + `'`, nil
	case leadClosed:
		return leadStatusSQL + ` IN ('rejected', 'expired')`, nil
	}
	return "", apperr.Validation("status: pending, connected, paid или closed").Uz("status: pending, connected, paid yoki closed")
}

// LeadCounts — счётчики вкладок.
type LeadCounts struct {
	All       int `json:"all"`
	Pending   int `json:"pending"`
	Connected int `json:"connected"`
	Paid      int `json:"paid"`
	Closed    int `json:"closed"`
}

const leadCountsSQL = `
	SELECT count(*)::int,
	       count(*) FILTER (WHERE ` + leadStatusSQL + ` = 'pending')::int,
	       count(*) FILTER (WHERE ` + leadStatusSQL + ` = 'connected')::int,
	       count(*) FILTER (WHERE ` + leadStatusSQL + ` = 'paid')::int,
	       count(*) FILTER (WHERE ` + leadStatusSQL + ` IN ('rejected', 'expired'))::int
	FROM store_leads l`

func scanCounts(row pgx.Row) (LeadCounts, error) {
	var c LeadCounts
	err := row.Scan(&c.All, &c.Pending, &c.Connected, &c.Paid, &c.Closed)
	return c, err
}

// ------------------------------------------------------------ агент

// AgentLeads — «Добавленные мной» (АМ5).
type AgentLeads struct {
	Items  []StoreLead `json:"items"`
	Counts LeadCounts  `json:"counts"`
	// Заработано: сумма начислений за оплатившие магазины.
	Earned string `json:"earned"`
}

func (s *Service) AgentLeads(ctx context.Context, p *identity.Principal, status string, page httpx.Page) (AgentLeads, error) {
	if err := requireDistributor(p); err != nil {
		return AgentLeads{}, err
	}
	where, err := leadFilterSQL(status)
	if err != nil {
		return AgentLeads{}, err
	}
	var out AgentLeads
	if out.Counts, err = scanCounts(s.pool.QueryRow(ctx, leadCountsSQL+` WHERE l.agent_network_id = $1`, p.NetworkID)); err != nil {
		return out, err
	}
	if err := s.pool.QueryRow(ctx, `SELECT COALESCE(sum(reward_amount), 0)::numeric(18,2)::text FROM store_leads WHERE agent_network_id = $1`,
		p.NetworkID).Scan(&out.Earned); err != nil {
		return out, err
	}
	rows, err := s.pool.Query(ctx, leadSelect+`
		WHERE l.agent_network_id = $1 AND `+where+`
		ORDER BY l.created_at DESC LIMIT $2 OFFSET $3`, p.NetworkID, page.Limit, page.Offset)
	if err != nil {
		return out, err
	}
	items, err := pgx.CollectRows(rows, scanLead)
	out.Items = make([]StoreLead, 0, len(items))
	for _, l := range items {
		out.Items = append(out.Items, l.forAgent())
	}
	return out, err
}

func (s *Service) AgentLead(ctx context.Context, p *identity.Principal, id string) (StoreLead, error) {
	if err := requireDistributor(p); err != nil {
		return StoreLead{}, err
	}
	if !httpx.IsUUID(id) {
		return StoreLead{}, errLeadNotFound()
	}
	l, err := getLead(ctx, s.pool, id)
	if err != nil {
		return l, err
	}
	if l.AgentNetworkID != p.NetworkID {
		return StoreLead{}, errLeadNotFound()
	}
	return l.forAgent(), nil
}

// LeadInput — «Новый магазин» (АМ2).
type LeadInput struct {
	Name       string   `json:"name"`
	OwnerName  string   `json:"owner_name"`
	OwnerPhone string   `json:"owner_phone"`
	Address    string   `json:"address"`
	Lat        *float64 `json:"lat"`
	Lng        *float64 `json:"lng"`
}

func (in *LeadInput) clean() error {
	in.Name, in.OwnerName, in.Address = strings.TrimSpace(in.Name), strings.TrimSpace(in.OwnerName), strings.TrimSpace(in.Address)
	switch {
	case in.Name == "":
		return apperr.Validation("name: название магазина").Uz("name: doʻkon nomi")
	case len([]rune(in.Name)) > 120:
		return apperr.Validation("name: не длиннее 120 символов").Uz("name: 120 belgidan oshmasin")
	case in.OwnerName == "":
		return apperr.Validation("owner_name: имя владельца").Uz("owner_name: egasining ismi")
	case len([]rune(in.OwnerName)) > 100:
		return apperr.Validation("owner_name: не длиннее 100 символов").Uz("owner_name: 100 belgidan oshmasin")
	case len([]rune(in.Address)) > 300:
		return apperr.Validation("address: не длиннее 300 символов").Uz("address: 300 belgidan oshmasin")
	case in.Lat == nil || in.Lng == nil:
		return apperr.Validation("lat/lng: поставьте магазин на карте").Uz("lat/lng: doʻkonni xaritada belgilang")
	case *in.Lat < -90 || *in.Lat > 90 || *in.Lng < -180 || *in.Lng > 180:
		return apperr.Validation("lat/lng: координаты вне диапазона").Uz("lat/lng: koordinatalar ruxsat etilgan oraliqdan tashqarida")
	}
	n, err := phone.Normalize(in.OwnerPhone)
	if err != nil {
		return apperr.Validation("owner_phone: номер в формате +998 XX XXX XX XX").Uz("owner_phone: raqam +998 XX XXX XX XX formatida")
	}
	in.OwnerPhone = n
	return nil
}

// pointSQL — точка из $lat, $lng.
func pointSQL(lat, lng int) string {
	return fmt.Sprintf(`ST_SetSRID(ST_MakePoint($%d::float8, $%d::float8), 4326)::geography`, lng, lat)
}

// errLeadDuplicate — магазин уже в Super Market или закреплён за агентом (АМ3).
func errLeadDuplicate(reason, kind, name string, distance int, mine bool, until *time.Time) error {
	d := map[string]any{"reason": reason, "kind": kind, "name": name, "mine": mine}
	if reason == "nearby" {
		d["distance_m"] = distance
	}
	if until != nil {
		d["until"] = until.Format(time.RFC3339)
	}
	return apperr.Conflict("store_exists", "этот магазин уже в Super Market").Uz("bu doʻkon allaqachon Super Market’da").WithDetails(d)
}

// leadOwner — кто добавляет: сеть агента или продажник (одно из двух).
type leadOwner struct{ networkID, repID string }

// mineSQL — заявка l добавлена этим же агентом или продажником ($a — сеть, $r — продажник).
func mineSQL(a, r int) string {
	return fmt.Sprintf(`COALESCE(l.agent_network_id::text = $%d, false) OR COALESCE(l.rep_id::text = $%d, false)`, a, r)
}

// checkLeadDuplicate — такой номер уже есть у магазина или активной заявки,
// или ближе leadDuplicateM м уже есть магазин или активная заявка.
func checkLeadDuplicate(ctx context.Context, q db.Querier, who leadOwner, ownerPhone string, lat, lng float64, exceptID string) error {
	var (
		kind, name string
		mine       bool
		until      *time.Time
	)
	err := q.QueryRow(ctx, `
		SELECT 'store', n.name, false, NULL::timestamptz FROM employees e
		JOIN roles r    ON r.id = e.role_id AND r.is_owner
		JOIN users u    ON u.id = e.user_id
		JOIN networks n ON n.id = e.network_id AND n.kind <> 'distributor'
		WHERE u.phone = $1
		UNION ALL
		SELECT 'store', s.name, false, NULL FROM stores s
		JOIN networks n ON n.id = s.network_id AND n.kind <> 'distributor'
		WHERE s.phone = $1
		UNION ALL
		SELECT 'lead', l.name, `+mineSQL(2, 4)+`, l.expires_at FROM store_leads l
		WHERE l.owner_phone = $1 AND `+activeLeadSQL+` AND l.id::text <> $3
		LIMIT 1`, ownerPhone, who.networkID, exceptID, who.repID).Scan(&kind, &name, &mine, &until)
	if err == nil {
		return errLeadDuplicate("phone", kind, name, 0, mine, until)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	var dist float64
	err = q.QueryRow(ctx, `
		WITH pt AS (SELECT `+pointSQL(3, 4)+` AS g)
		SELECT * FROM (
			SELECT 'store' AS kind, s.name, false AS mine, NULL::timestamptz AS until, ST_Distance(s.location, pt.g) AS d
			FROM stores s JOIN networks n ON n.id = s.network_id AND n.kind <> 'distributor', pt
			WHERE s.location IS NOT NULL AND ST_DWithin(s.location, pt.g, $5)
			UNION ALL
			SELECT 'lead', l.name, `+mineSQL(1, 6)+`, l.expires_at, ST_Distance(l.location, pt.g)
			FROM store_leads l, pt
			WHERE `+activeLeadSQL+` AND l.id::text <> $2 AND ST_DWithin(l.location, pt.g, $5)
		) x ORDER BY d LIMIT 1`, who.networkID, exceptID, lat, lng, leadDuplicateM, who.repID).Scan(&kind, &name, &mine, &until, &dist)
	if err == nil {
		return errLeadDuplicate("nearby", kind, name, int(dist+0.5), mine, until)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	return nil
}

// CreateLead — агент добавляет магазин (АМ2): заявка уходит супер-админу,
// магазин закреплён за агентом leadHoldDays дней.
func (s *Service) CreateLead(ctx context.Context, p *identity.Principal, in LeadInput) (StoreLead, error) {
	if err := requireDistributor(p); err != nil {
		return StoreLead{}, err
	}
	if err := in.clean(); err != nil {
		return StoreLead{}, err
	}
	var id string
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		// Две заявки на один магазин одновременно: проверка дублей под общей блокировкой.
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('store_leads'))`); err != nil {
			return err
		}
		var pending int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM store_leads l WHERE l.agent_network_id = $1 AND `+activeLeadSQL,
			p.NetworkID).Scan(&pending); err != nil {
			return err
		}
		if pending >= maxPendingLeads {
			return apperr.Conflict("too_many_leads", fmt.Sprintf("уже %d заявок ждут решения — дождитесь подключения", pending)).
				Uz(fmt.Sprintf("%d ta ariza qarorni kutmoqda — ulanishini kuting", pending))
		}
		if err := checkLeadDuplicate(ctx, tx, leadOwner{networkID: p.NetworkID}, in.OwnerPhone, *in.Lat, *in.Lng, ""); err != nil {
			return err
		}
		var emp *string
		if p.EmployeeID != "" {
			emp = &p.EmployeeID
		}
		return tx.QueryRow(ctx, `
			INSERT INTO store_leads (agent_network_id, employee_id, name, owner_name, owner_phone, address, location, expires_at)
			VALUES ($1, $2, $3, $4, $5, $6, `+pointSQL(7, 8)+`, now() + make_interval(days => $9))
			RETURNING id`,
			p.NetworkID, emp, in.Name, in.OwnerName, in.OwnerPhone, in.Address, *in.Lat, *in.Lng, leadHoldDays).Scan(&id)
	})
	if err != nil {
		return StoreLead{}, err
	}
	l, err := getLead(ctx, s.pool, id)
	if err == nil {
		s.notifyAdmins(fmt.Sprintf("Агент добавил магазин «%s»\nВладелец: %s, %s\nАгент: %s, %s (%s)\nПодключите в панели супер-админа: Магазины → Заявки агентов.",
			l.Name, l.OwnerName, l.OwnerPhone, l.AgentName, l.AgentPhone, l.AgentNetworkName))
	}
	return l.forAgent(), err
}

// -------------------------------------------------------- супер-админ

// AdminLeads — «Магазины → Заявки агентов» (С1).
type AdminLeads struct {
	Items  []StoreLead `json:"items"`
	Counts LeadCounts  `json:"counts"`
}

func (s *Service) AdminLeads(ctx context.Context, p *identity.Principal, status, q string, page httpx.Page) (AdminLeads, error) {
	if err := requireAdmin(p); err != nil {
		return AdminLeads{}, err
	}
	if status == "" {
		status = LeadPending
	}
	where, err := leadFilterSQL(status)
	if err != nil {
		return AdminLeads{}, err
	}
	var out AdminLeads
	if out.Counts, err = scanCounts(s.pool.QueryRow(ctx, leadCountsSQL)); err != nil {
		return out, err
	}
	order := "l.created_at"
	if status != LeadPending {
		order = "COALESCE(l.rewarded_at, l.decided_at, l.expires_at, l.created_at) DESC"
	}
	rows, err := s.pool.Query(ctx, leadSelect+`
		WHERE `+where+` AND ($1 = '' OR l.name ILIKE '%' || $1 || '%' OR l.owner_name ILIKE '%' || $1 || '%'
		      OR l.owner_phone LIKE '%' || $1 || '%' OR an.name ILIKE '%' || $1 || '%'
		      OR ow.full_name ILIKE '%' || $1 || '%' OR ow.phone LIKE '%' || $1 || '%'
		      OR fr.full_name ILIKE '%' || $1 || '%' OR fru.phone LIKE '%' || $1 || '%')
		ORDER BY `+order+` LIMIT $2 OFFSET $3`, likeArg(q), page.Limit, page.Offset)
	if err != nil {
		return out, err
	}
	out.Items, err = pgx.CollectRows(rows, scanLead)
	if out.Items == nil {
		out.Items = []StoreLead{}
	}
	return out, err
}

// AdminLead — карточка заявки: статистика агента и что есть рядом.
func (s *Service) AdminLead(ctx context.Context, p *identity.Principal, id string) (StoreLead, error) {
	if err := requireAdmin(p); err != nil {
		return StoreLead{}, err
	}
	if !httpx.IsUUID(id) {
		return StoreLead{}, errLeadNotFound()
	}
	l, err := getLead(ctx, s.pool, id)
	if err != nil {
		return l, err
	}
	var connected, paid int
	who, arg := "agent_network_id", l.AgentNetworkID
	if l.RepID != nil {
		who, arg = "rep_id", *l.RepID
	}
	if err := s.pool.QueryRow(ctx, `
		SELECT count(*) FILTER (WHERE status = 'connected')::int, count(*) FILTER (WHERE rewarded_at IS NOT NULL)::int
		FROM store_leads WHERE `+who+` = $1`, arg).Scan(&connected, &paid); err != nil {
		return l, err
	}
	l.AgentConnected, l.AgentPaid = &connected, &paid
	rows, err := s.pool.Query(ctx, `
		WITH me AS (SELECT location AS g, network_id FROM store_leads WHERE id = $1)
		SELECT * FROM (
			SELECT 'store' AS kind, s.name, s.phone, s.address, round(ST_Distance(s.location, me.g))::int AS d,
			       ST_Y(s.location::geometry) AS lat, ST_X(s.location::geometry) AS lng
			FROM stores s JOIN networks n ON n.id = s.network_id AND n.kind <> 'distributor', me
			WHERE s.location IS NOT NULL AND ST_DWithin(s.location, me.g, $2)
			  AND s.network_id IS DISTINCT FROM me.network_id
			UNION ALL
			SELECT 'lead', l.name, l.owner_phone, l.address, round(ST_Distance(l.location, me.g))::int,
			       ST_Y(l.location::geometry), ST_X(l.location::geometry)
			FROM store_leads l, me
			WHERE l.id <> $1 AND `+activeLeadSQL+` AND ST_DWithin(l.location, me.g, $2)
		) x ORDER BY d LIMIT 5`, id, leadNearbyM)
	l.Nearby, err = collect[NearbyPlace](rows, err)
	return l, err
}

// ConnectLeadInput — «Подключить» (С2): обычное создание сети; название,
// владелец и телефон по умолчанию из заявки.
type ConnectLeadInput = tenant.CreateNetworkInput

// ConnectLead создаёт сеть по заявке, первый магазин — с точкой из заявки,
// и навсегда привязывает сеть к агенту.
func (s *Service) ConnectLead(ctx context.Context, p *identity.Principal, id string, in ConnectLeadInput) (StoreLead, error) {
	if err := requireAdmin(p); err != nil {
		return StoreLead{}, err
	}
	if !httpx.IsUUID(id) {
		return StoreLead{}, errLeadNotFound()
	}
	if in.Kind == "" {
		in.Kind = "single"
	}
	if in.Kind == KindDistributor {
		return StoreLead{}, apperr.Validation("kind: магазин по заявке — одиночный магазин или сеть").Uz("kind: ariza boʻyicha doʻkon — yakka doʻkon yoki tarmoq")
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		_, storeName, agent, err := connectLeadTx(ctx, tx, id, in, p.UserID)
		if err != nil || agent == nil {
			// Заявка продажника: сети агента и начисления нет.
			return err
		}
		return s.pushAgent(ctx, tx, *agent, "lead_connected",
			i18n.Text{RU: fmt.Sprintf("«%s» подключён к Super Market", storeName), UZ: fmt.Sprintf("«%s» Super Market’ga ulandi", storeName)},
			i18n.Text{RU: "Когда магазин оплатит первый счёт, 50% от оплаты придут на ваш баланс.",
				UZ: "Doʻkon birinchi hisobni toʻlaganda, toʻlovning 50% balansingizga tushadi."},
			map[string]string{"lead_id": id})
	})
	if err != nil {
		return StoreLead{}, err
	}
	return s.AdminLead(ctx, p, id)
}

// connectLeadTx создаёт сеть по заявке и первый магазин в точке заявки и
// помечает заявку подключённой. Пустые название, владелец и телефон — из
// заявки. Возвращает сеть, название магазина и сеть агента (nil — заявка
// продажника).
func connectLeadTx(ctx context.Context, tx pgx.Tx, id string, in ConnectLeadInput, decidedBy string) (netID, storeName string, agent *string, err error) {
	var (
		status, name, ownerName, ownerPhone, address string
		expired                                      bool
		lat, lng                                     float64
	)
	err = tx.QueryRow(ctx, `
		SELECT status, expires_at <= now(), name, owner_name, owner_phone, address,
		       ST_Y(location::geometry), ST_X(location::geometry), agent_network_id
		FROM store_leads WHERE id = $1 FOR UPDATE`, id).
		Scan(&status, &expired, &name, &ownerName, &ownerPhone, &address, &lat, &lng, &agent)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", nil, errLeadNotFound()
	}
	if err != nil {
		return "", "", nil, err
	}
	if status != LeadPending {
		return "", "", nil, apperr.Conflict("request_closed", "по заявке уже есть решение").Uz("ariza boʻyicha qaror allaqachon bor")
	}
	if expired {
		return "", "", nil, apperr.Conflict("lead_expired", "срок заявки истёк — магазин снова свободен, агент может добавить его заново").
			Uz("ariza muddati tugagan — doʻkon yana boʻsh, agent uni qayta qoʻshishi mumkin")
	}
	if strings.TrimSpace(in.Name) == "" {
		in.Name = name
	}
	if strings.TrimSpace(in.OwnerName) == "" {
		in.OwnerName = ownerName
	}
	if strings.TrimSpace(in.OwnerPhone) == "" {
		in.OwnerPhone = ownerPhone
	}
	if netID, err = tenant.CreateNetworkTx(ctx, tx, in); err != nil {
		return "", "", nil, err
	}
	storeName = strings.TrimSpace(in.Name)
	if _, err = tenant.CreateStoreTx(ctx, tx, netID, tenant.StoreInput{
		Name: &storeName, Address: &address, Phone: &ownerPhone, Lat: &lat, Lng: &lng,
	}); err != nil {
		return "", "", nil, err
	}
	var by *string
	if decidedBy != "" {
		by = &decidedBy
	}
	_, err = tx.Exec(ctx, `
		UPDATE store_leads SET status = 'connected', network_id = $2, reason = '', decided_at = now(), decided_by = $3
		WHERE id = $1`, id, netID, by)
	return netID, storeName, agent, err
}

// ConnectRepLeadTx — продажник «SM Продажник» сам подключает магазин по
// своей заявке (в той же транзакции, что и отметка визита): одиночный
// магазин, тариф по умолчанию с пробным периодом, логин и временный пароль
// владельца — из in. Возвращает сеть.
func ConnectRepLeadTx(ctx context.Context, tx pgx.Tx, leadID, repUserID string, in ConnectLeadInput) (string, error) {
	in.Kind, in.PlanKey, in.BusinessType = "single", "", ""
	netID, _, _, err := connectLeadTx(ctx, tx, leadID, in, repUserID)
	return netID, err
}

// RejectLead — «Отклонить» с причиной (её увидит агент); магазин сразу свободен.
func (s *Service) RejectLead(ctx context.Context, p *identity.Principal, id, reason string) (StoreLead, error) {
	if err := requireAdmin(p); err != nil {
		return StoreLead{}, err
	}
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return StoreLead{}, apperr.Validation("reason: укажите причину — её увидит агент").Uz("reason: sababni yozing — uni agent koʻradi")
	}
	if len([]rune(reason)) > 500 {
		return StoreLead{}, apperr.Validation("reason: не длиннее 500 символов").Uz("reason: 500 belgidan oshmasin")
	}
	if !httpx.IsUUID(id) {
		return StoreLead{}, errLeadNotFound()
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var (
			agent *string
			name  string
		)
		err := tx.QueryRow(ctx, `
			UPDATE store_leads SET status = 'rejected', reason = $2, decided_at = now(), decided_by = $3
			WHERE id = $1 AND status = 'pending' RETURNING agent_network_id, name`, id, reason, p.UserID).Scan(&agent, &name)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Conflict("request_closed", "по заявке уже есть решение или она не найдена").Uz("ariza boʻyicha qaror bor yoki u topilmadi")
		}
		if err != nil {
			return err
		}
		if agent == nil {
			return nil
		}
		return s.pushAgent(ctx, tx, *agent, "lead_rejected",
			i18n.Text{RU: fmt.Sprintf("Заявка на «%s» отклонена", name), UZ: fmt.Sprintf("«%s» arizasi rad etildi", name)},
			i18n.Text{RU: "Причина: " + reason, UZ: "Sabab: " + reason},
			map[string]string{"lead_id": id})
	})
	if err != nil {
		return StoreLead{}, err
	}
	return s.AdminLead(ctx, p, id)
}

// AgentRewards — «Тарифы и счета → Агентам» (С3): подключённые по заявкам
// магазины, их первая оплата и начисление агенту.
type AgentRewards struct {
	Items []StoreLead `json:"items"`
	// Начислено агентам в текущем месяце (по Ташкенту).
	EarnedMonth string `json:"earned_month"`
	// Подключены и ещё не оплатили.
	Waiting int `json:"waiting"`
}

func (s *Service) AgentRewards(ctx context.Context, p *identity.Principal, page httpx.Page) (AgentRewards, error) {
	if err := requireAdmin(p); err != nil {
		return AgentRewards{}, err
	}
	var out AgentRewards
	if err := s.pool.QueryRow(ctx, `
		SELECT COALESCE(sum(reward_amount) FILTER (WHERE rewarded_at >= date_trunc('month', now() AT TIME ZONE 'Asia/Tashkent') AT TIME ZONE 'Asia/Tashkent'), 0)::numeric(18,2)::text,
		       count(*) FILTER (WHERE status = 'connected' AND rewarded_at IS NULL)::int
		FROM store_leads WHERE agent_network_id IS NOT NULL`).Scan(&out.EarnedMonth, &out.Waiting); err != nil {
		return out, err
	}
	rows, err := s.pool.Query(ctx, leadSelect+`
		WHERE l.status = 'connected' AND l.agent_network_id IS NOT NULL
		ORDER BY l.rewarded_at DESC NULLS FIRST, l.decided_at DESC LIMIT $1 OFFSET $2`, page.Limit, page.Offset)
	if err != nil {
		return out, err
	}
	out.Items, err = pgx.CollectRows(rows, scanLead)
	if out.Items == nil {
		out.Items = []StoreLead{}
	}
	return out, err
}

// ------------------------------------------------------- продажник

// CreateRepLeadTx — продажник «SM Продажник» отмечает магазин «Подключить»:
// та же заявка, что у агента (дубли по тем же правилам), но без сети агента
// и без начисления 50%. Вызывается в транзакции отметки визита.
func CreateRepLeadTx(ctx context.Context, tx pgx.Tx, repID string, in LeadInput) (string, error) {
	if err := in.clean(); err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('store_leads'))`); err != nil {
		return "", err
	}
	var pending int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM store_leads l WHERE l.rep_id = $1 AND `+activeLeadSQL,
		repID).Scan(&pending); err != nil {
		return "", err
	}
	if pending >= maxPendingLeads {
		return "", apperr.Conflict("too_many_leads", fmt.Sprintf("уже %d заявок ждут решения — дождитесь подключения", pending)).
			Uz(fmt.Sprintf("%d ta ariza qarorni kutmoqda — ulanishini kuting", pending))
	}
	if err := checkLeadDuplicate(ctx, tx, leadOwner{repID: repID}, in.OwnerPhone, *in.Lat, *in.Lng, ""); err != nil {
		return "", err
	}
	var id string
	err := tx.QueryRow(ctx, `
		INSERT INTO store_leads (rep_id, name, owner_name, owner_phone, address, location, expires_at)
		VALUES ($1, $2, $3, $4, $5, `+pointSQL(6, 7)+`, now() + make_interval(days => $8))
		RETURNING id`,
		repID, in.Name, in.OwnerName, in.OwnerPhone, in.Address, *in.Lat, *in.Lng, leadHoldDays).Scan(&id)
	return id, err
}

// NotifyRepLead — супер-админам: продажник подключил магазин и выдал
// владельцу логин (после коммита).
func (s *Service) NotifyRepLead(ctx context.Context, id string) {
	l, err := getLead(ctx, s.pool, id)
	if err != nil {
		return
	}
	s.notifyAdmins(fmt.Sprintf("Продажник подключил магазин «%s»\nВладелец: %s, %s\nПродажник: %s, %s\nЛогин владельцу выдан на месте. Магазин — в Магазины → Заявки агентов.",
		l.Name, l.OwnerName, l.OwnerPhone, l.AgentName, l.AgentPhone))
}
