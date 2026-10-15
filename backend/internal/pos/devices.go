// Package pos — касса: устройства и их активация, вход кассира по ПИНу,
// каталог для работы без интернета, смены и наличные в ящике. Сами продажи
// и возвраты проводит пакет sales — касса передаёт туда смену и чек,
// подписанный фискальным модулем.
package pos

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/debts"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/plans"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/sales"
)

type Service struct {
	pool  *pgxpool.Pool
	sales *sales.Service
	debts *debts.Service
	now   func() time.Time
}

func NewService(pool *pgxpool.Pool, salesSvc *sales.Service) *Service {
	return &Service{pool: pool, sales: salesSvc, now: time.Now}
}

// WithDebts подключает долги покупателей (продажа в долг и погашение на кассе).
func (s *Service) WithDebts(d *debts.Service) *Service {
	s.debts = d
	return s
}

// Код активации живёт сутки: владелец создаёт кассу в панели и вводит код
// на устройстве.
const activationTTL = 24 * time.Hour

type Device struct {
	ID          string     `json:"id"`
	StoreID     string     `json:"store_id"`
	StoreName   string     `json:"store_name"`
	Name        string     `json:"name"`
	Status      string     `json:"status"` // waiting — ждёт активации, active, revoked
	ActivatedAt *time.Time `json:"activated_at"`
	LastSeenAt  *time.Time `json:"last_seen_at"`
	AppVersion  string     `json:"app_version"`
	CreatedAt   time.Time  `json:"created_at"`
	// Показываются один раз — сразу после создания кода.
	ActivationCode    string     `json:"activation_code,omitempty"`
	ActivationExpires *time.Time `json:"activation_expires,omitempty"`
	// Открытая смена на этой кассе.
	OpenShiftID *string `json:"open_shift_id"`
	// Касса в телефоне сотрудника (приложение «SM Магазин»): в лимит тарифа не входит.
	Phone bool `json:"phone"`
}

const deviceSelect = `
	SELECT d.id, d.store_id, st.name, d.name,
	       CASE WHEN d.revoked_at IS NOT NULL THEN 'revoked' WHEN d.token_hash IS NOT NULL THEN 'active' ELSE 'waiting' END,
	       d.activated_at, d.last_seen_at, d.app_version, d.created_at, d.activation_expires,
	       (SELECT sh.id FROM pos_shifts sh WHERE sh.device_id = d.id AND sh.closed_at IS NULL),
	       d.employee_id IS NOT NULL
	FROM pos_devices d JOIN stores st ON st.id = d.store_id`

func scanDevice(r pgx.CollectableRow) (Device, error) {
	var d Device
	err := r.Scan(&d.ID, &d.StoreID, &d.StoreName, &d.Name, &d.Status, &d.ActivatedAt, &d.LastSeenAt,
		&d.AppVersion, &d.CreatedAt, &d.ActivationExpires, &d.OpenShiftID, &d.Phone)
	return d, err
}

func (s *Service) ListDevices(ctx context.Context, p *identity.Principal, storeID string) ([]Device, error) {
	if storeID != "" && !httpx.IsUUID(storeID) {
		return nil, apperr.Validation("store_id: неверный id").Uz("store_id: id notoʻgʻri")
	}
	rows, err := s.pool.Query(ctx, deviceSelect+`
		WHERE d.network_id = $1 AND ($2 OR d.store_id = ANY($3::uuid[])) AND ($4 = '' OR d.store_id::text = $4)
		ORDER BY d.revoked_at IS NOT NULL, st.name, d.name`, p.NetworkID, p.SeesAllStores(), p.StoreIDs, storeID)
	if err != nil {
		return nil, err
	}
	items, err := pgx.CollectRows(rows, scanDevice)
	for i := range items {
		if items[i].Status != "waiting" {
			items[i].ActivationExpires = nil
		}
	}
	return items, err
}

func (s *Service) getDevice(ctx context.Context, p *identity.Principal, id string) (Device, error) {
	if !httpx.IsUUID(id) {
		return Device{}, apperr.NotFound("касса не найдена").Uz("kassa topilmadi")
	}
	rows, err := s.pool.Query(ctx, deviceSelect+` WHERE d.id = $1 AND d.network_id = $2`, id, p.NetworkID)
	if err != nil {
		return Device{}, err
	}
	d, err := pgx.CollectExactlyOneRow(rows, scanDevice)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !p.CanAccessStore(d.StoreID)) {
		return Device{}, apperr.NotFound("касса не найдена").Uz("kassa topilmadi")
	}
	return d, err
}

type DeviceInput struct {
	StoreID string `json:"store_id"`
	Name    string `json:"name"`
}

// CreateDevice заводит кассу в магазине и сразу выдаёт код активации.
func (s *Service) CreateDevice(ctx context.Context, p *identity.Principal, in DeviceInput) (Device, error) {
	if err := p.Require(identity.PermStoresManage); err != nil {
		return Device{}, err
	}
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" || len([]rune(in.Name)) > 60 {
		return Device{}, apperr.Validation("name: название кассы, до 60 символов").Uz("name: kassa nomi, 60 belgigacha")
	}
	if !httpx.IsUUID(in.StoreID) || !p.CanAccessStore(in.StoreID) {
		return Device{}, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	var ok bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM stores WHERE id = $1 AND network_id = $2)`,
		in.StoreID, p.NetworkID).Scan(&ok); err != nil {
		return Device{}, err
	}
	if !ok {
		return Device{}, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	var id string
	if err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		// Сколько касс можно — по тарифу сети (блокировка сети — от гонки двух запросов).
		if _, err := tx.Exec(ctx, `SELECT 1 FROM networks WHERE id = $1 FOR UPDATE`, p.NetworkID); err != nil {
			return err
		}
		if err := plans.CheckAdd(ctx, tx, p.NetworkID, plans.LimitRegisters); err != nil {
			return err
		}
		return tx.QueryRow(ctx, `INSERT INTO pos_devices (network_id, store_id, name) VALUES ($1, $2, $3) RETURNING id`,
			p.NetworkID, in.StoreID, in.Name).Scan(&id)
	}); err != nil {
		return Device{}, err
	}
	return s.NewCode(ctx, p, id)
}

// NewCode выдаёт новый код активации (старый перестаёт действовать). Если
// касса уже была активирована, её токен действует до активации по новому коду.
func (s *Service) NewCode(ctx context.Context, p *identity.Principal, id string) (Device, error) {
	if err := p.Require(identity.PermStoresManage); err != nil {
		return Device{}, err
	}
	d, err := s.getDevice(ctx, p, id)
	if err != nil {
		return Device{}, err
	}
	if d.Status == "revoked" {
		return Device{}, apperr.Conflict("device_revoked", "касса отключена — создайте новую").Uz("kassa oʻchirilgan — yangisini yarating")
	}
	code, err := newActivationCode()
	if err != nil {
		return Device{}, err
	}
	expires := s.now().Add(activationTTL)
	if _, err := s.pool.Exec(ctx, `UPDATE pos_devices SET activation_hash = $2, activation_expires = $3 WHERE id = $1`,
		id, hashSecret(normalizeCode(code)), expires); err != nil {
		return Device{}, err
	}
	d, err = s.getDevice(ctx, p, id)
	d.ActivationCode, d.ActivationExpires = code, &expires
	return d, err
}

// RevokeDevice отключает кассу: её токен больше не принимается.
func (s *Service) RevokeDevice(ctx context.Context, p *identity.Principal, id string) (Device, error) {
	if err := p.Require(identity.PermStoresManage); err != nil {
		return Device{}, err
	}
	if _, err := s.getDevice(ctx, p, id); err != nil {
		return Device{}, err
	}
	if _, err := s.pool.Exec(ctx, `UPDATE pos_devices SET revoked_at = COALESCE(revoked_at, now()), activation_hash = NULL,
		token_hash = NULL WHERE id = $1`, id); err != nil {
		return Device{}, err
	}
	return s.getDevice(ctx, p, id)
}

type ActivateInput struct {
	Code       string `json:"code"`
	AppVersion string `json:"app_version"`
}

type Activation struct {
	Token string `json:"token"`
	// Кто и где: показываем на кассе после активации.
	DeviceID    string `json:"device_id"`
	DeviceName  string `json:"device_name"`
	StoreID     string `json:"store_id"`
	StoreName   string `json:"store_name"`
	NetworkName string `json:"network_name"`
}

// Activate меняет код активации на постоянный токен устройства.
func (s *Service) Activate(ctx context.Context, in ActivateInput) (Activation, error) {
	code := normalizeCode(in.Code)
	if len(code) != codeLen {
		return Activation{}, apperr.Validation("code: введите код из панели магазина").Uz("code: doʻkon panelidagi kodni kiriting")
	}
	token, err := randomToken()
	if err != nil {
		return Activation{}, err
	}
	var a Activation
	err = s.pool.QueryRow(ctx, `
		UPDATE pos_devices d SET token_hash = $2, activation_hash = NULL, activation_expires = NULL,
		       activated_at = now(), app_version = left($3, 40)
		FROM stores st, networks n
		WHERE d.activation_hash = $1 AND d.activation_expires > now() AND d.revoked_at IS NULL
		  AND st.id = d.store_id AND n.id = d.network_id AND n.status = 'active'
		RETURNING d.id, d.name, st.id, st.name, n.name`,
		hashSecret(code), hashSecret(token), strings.TrimSpace(in.AppVersion)).Scan(
		&a.DeviceID, &a.DeviceName, &a.StoreID, &a.StoreName, &a.NetworkName)
	if errors.Is(err, pgx.ErrNoRows) {
		return Activation{}, apperr.New(400, "activation_invalid", "код неверный или устарел — создайте новый в панели магазина").Uz("kod notoʻgʻri yoki eskirgan — doʻkon panelida yangisini yarating")
	}
	a.Token = token
	return a, err
}

// ----------------------------------------------------------- секреты

// Код без похожих символов (0/O, 1/I/L): его вводят руками на кассе.
const (
	codeAlphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
	codeLen      = 8
)

func newActivationCode() (string, error) {
	b := make([]byte, codeLen)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	out := make([]byte, 0, codeLen+1)
	for i, x := range b {
		if i == codeLen/2 {
			out = append(out, '-')
		}
		out = append(out, codeAlphabet[int(x)%len(codeAlphabet)])
	}
	return string(out), nil
}

func normalizeCode(c string) string {
	c = strings.ToUpper(strings.TrimSpace(c))
	return strings.NewReplacer("-", "", " ", "").Replace(c)
}

const tokenPrefix = "pd_"

func randomToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return tokenPrefix + base64.RawURLEncoding.EncodeToString(b), nil
}

func hashSecret(s string) []byte {
	h := sha256.Sum256([]byte(s))
	return h[:]
}
