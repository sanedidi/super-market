package pos

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Весы магазина и отправка товаров в весы (Figma «Панель магазина · Весы:
// отправка товаров в весы (любой бренд)», Н1–Н5).
//
// Сервер весы не видит — они в сети магазина. Панель создаёт задание, касса
// Super Market в той же сети забирает его при синхронизации (раз в 10 секунд),
// отправляет товары на весы и сообщает результат. Бренды с драйвером
// (Rongta, Dahua — протокол Dahua по TCP 4001) — «Напрямую», остальные —
// файлом для программы весов.

// Бренды весов; direct — касса отправляет сама.
var scaleBrands = map[string]bool{
	"rongta": true, "dahua": true,
	"kuanyi": false, "cas": false, "massak": false, "shtrih": false, "other": false,
}

func directBrand(b string) bool { return scaleBrands[b] }

// Пределы протокола Dahua: номер — 4 цифры, цена — 6 цифр (целые сумы).
const (
	dahuaMaxPLU   = 9999
	dahuaMaxPrice = 999999
	scaleNameMax  = 36
)

type ScaleDevice struct {
	ID       string  `json:"id"`
	Name     string  `json:"name"`
	Brand    string  `json:"brand"`
	Model    string  `json:"model"`
	Host     string  `json:"host"`
	Port     int     `json:"port"`
	DeviceID *string `json:"device_id"`
	// Касса-отправитель и в сети ли она (последние 2 минуты).
	DeviceName   *string    `json:"device_name"`
	DeviceOnline bool       `json:"device_online"`
	Direct       bool       `json:"direct"`
	CheckAt      *time.Time `json:"check_at"`
	CheckOK      *bool      `json:"check_ok"`
	CheckError   *string    `json:"check_error"`
	// Сколько товаров сейчас в весах и когда отправляли последний раз.
	Items      int        `json:"items"`
	LastSentAt *time.Time `json:"last_sent_at"`
	// Новые и изменённые товары, которых ещё нет в этих весах.
	ToSend int `json:"to_send"`
	// Последнее задание (идёт или закончилось).
	Job *ScaleJob `json:"job"`
}

type ScaleDeviceInput struct {
	StoreID  string  `json:"store_id"`
	Name     string  `json:"name"`
	Brand    string  `json:"brand"`
	Model    string  `json:"model"`
	Host     string  `json:"host"`
	Port     int     `json:"port"`
	DeviceID *string `json:"device_id"`
}

// ScaleFailure — товар, который весы не приняли (или не примут).
type ScaleFailure struct {
	ProductID string `json:"product_id"`
	PLU       int    `json:"plu"`
	Name      string `json:"name"`
	Error     string `json:"error"`
}

type ScaleJob struct {
	ID        string         `json:"id"`
	ScaleID   string         `json:"scale_id"`
	ScaleName string         `json:"scale_name"`
	Kind      string         `json:"kind"`
	Mode      string         `json:"mode"`
	Status    string         `json:"status"`
	Total     int            `json:"total"`
	Sent      int            `json:"sent"`
	Error     *string        `json:"error"`
	Failures  []ScaleFailure `json:"failures"`
	CreatedAt time.Time      `json:"created_at"`
	TakenAt   *time.Time     `json:"taken_at"`
	DoneAt    *time.Time     `json:"done_at"`
}

// scaleGood — товар для весов: номер, название как в весах, цена за кг (целые сумы).
type scaleGood struct {
	ProductID string `json:"product_id"`
	PLU       int    `json:"plu"`
	Name      string `json:"name"`
	Price     int64  `json:"price"`
	// kg — на развес (других весовых единиц весы не знают).
	Unit string `json:"unit"`
}

// ------------------------------------------------------------- проверки

func (s *Service) scaleManager(p *identity.Principal, storeID string) error {
	if err := p.RequireAny(identity.PermStoresManage, identity.PermCatalogManage); err != nil {
		return err
	}
	if !httpx.IsUUID(storeID) || !p.CanAccessStore(storeID) {
		return apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	return nil
}

// scaleOf — магазин весов (и проверка, что весы этой сети и магазин доступен).
func (s *Service) scaleOf(ctx context.Context, p *identity.Principal, scaleID string) (storeID, brand string, err error) {
	err = s.pool.QueryRow(ctx, `SELECT store_id, brand FROM scales WHERE id = $1 AND network_id = $2`, scaleID, p.NetworkID).Scan(&storeID, &brand)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !p.CanAccessStore(storeID)) {
		return "", "", apperr.NotFound("весы не найдены").Uz("tarozi topilmadi")
	}
	return storeID, brand, err
}

func (s *Service) checkScaleInput(ctx context.Context, p *identity.Principal, storeID string, in *ScaleDeviceInput) error {
	in.Name = strings.TrimSpace(in.Name)
	in.Model = strings.TrimSpace(in.Model)
	in.Host = strings.TrimSpace(in.Host)
	if in.Name == "" || len([]rune(in.Name)) > 60 {
		return apperr.Validation("name: название весов — до 60 символов").Uz("name: tarozi nomi — 60 belgigacha")
	}
	if _, ok := scaleBrands[in.Brand]; !ok {
		return apperr.Validation("brand: выберите бренд весов").Uz("brand: tarozi brendini tanlang")
	}
	if len([]rune(in.Model)) > 40 {
		return apperr.Validation("model: до 40 символов").Uz("model: 40 belgigacha")
	}
	if in.Port == 0 {
		in.Port = 4001
	}
	if in.Port < 1 || in.Port > 65535 {
		return apperr.Validation("port: от 1 до 65535").Uz("port: 1 dan 65535 gacha")
	}
	if directBrand(in.Brand) {
		if ip := net.ParseIP(in.Host); ip == nil || ip.To4() == nil {
			return apperr.Validation("host: IP-адрес весов, например 192.168.1.80").Uz("host: tarozining IP-manzili, masalan 192.168.1.80")
		}
	} else if len(in.Host) > 60 {
		return apperr.Validation("host: до 60 символов").Uz("host: 60 belgigacha")
	}
	if in.DeviceID != nil && *in.DeviceID == "" {
		in.DeviceID = nil
	}
	if in.DeviceID != nil {
		var ok bool
		err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pos_devices WHERE id = $1 AND network_id = $2 AND store_id = $3 AND kind = 'pos')`,
			*in.DeviceID, p.NetworkID, storeID).Scan(&ok)
		if err != nil {
			return err
		}
		if !httpx.IsUUID(*in.DeviceID) || !ok {
			return apperr.Validation("device_id: касса этого магазина").Uz("device_id: shu doʻkon kassasi")
		}
	}
	return nil
}

// ------------------------------------------------------------- весы (Н1, Н2)

func (s *Service) ListScales(ctx context.Context, p *identity.Principal, storeID string) ([]ScaleDevice, error) {
	if err := s.storeForPanel(p, storeID); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT s.id, s.name, s.brand, s.model, s.host, s.port, s.device_id, d.name,
		       COALESCE(d.token_hash IS NOT NULL AND d.revoked_at IS NULL AND d.last_seen_at > now() - interval '2 minutes', false),
		       s.check_at, s.check_ok, s.check_error,
		       (SELECT count(*) FROM scale_items i WHERE i.scale_id = s.id)::int,
		       (SELECT max(sent_at) FROM scale_items i WHERE i.scale_id = s.id)
		FROM scales s LEFT JOIN pos_devices d ON d.id = s.device_id
		WHERE s.network_id = $1 AND s.store_id = $2
		ORDER BY s.created_at`, p.NetworkID, storeID)
	if err != nil {
		return nil, err
	}
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (ScaleDevice, error) {
		var d ScaleDevice
		err := r.Scan(&d.ID, &d.Name, &d.Brand, &d.Model, &d.Host, &d.Port, &d.DeviceID, &d.DeviceName, &d.DeviceOnline,
			&d.CheckAt, &d.CheckOK, &d.CheckError, &d.Items, &d.LastSentAt)
		d.Direct = directBrand(d.Brand)
		return d, err
	})
	if err != nil || len(list) == 0 {
		return list, err
	}
	// Без выбранной кассы отправляет любая касса магазина — в сети ли хоть одна.
	var anyOnline bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pos_devices d WHERE d.store_id = $1 AND d.kind = 'pos' AND d.token_hash IS NOT NULL
		AND d.revoked_at IS NULL AND d.last_seen_at > now() - interval '2 minutes')`, storeID).Scan(&anyOnline); err != nil {
		return nil, err
	}
	goods, err := s.scaleGoods(ctx, s.pool, p.NetworkID, storeID, true)
	if err != nil {
		return nil, err
	}
	for i := range list {
		d := &list[i]
		if d.DeviceID == nil {
			d.DeviceOnline = anyOnline
		}
		have, err := s.scaleHave(ctx, s.pool, d.ID)
		if err != nil {
			return nil, err
		}
		d.ToSend = len(diffGoods(goods, have, false))
		if d.Job, err = s.lastJob(ctx, d.ID); err != nil {
			return nil, err
		}
	}
	return list, nil
}

func (s *Service) CreateScale(ctx context.Context, p *identity.Principal, in ScaleDeviceInput) (ScaleDevice, error) {
	if err := s.scaleManager(p, in.StoreID); err != nil {
		return ScaleDevice{}, err
	}
	if err := s.checkScaleInput(ctx, p, in.StoreID, &in); err != nil {
		return ScaleDevice{}, err
	}
	var id string
	err := s.pool.QueryRow(ctx, `INSERT INTO scales (network_id, store_id, name, brand, model, host, port, device_id)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id`,
		p.NetworkID, in.StoreID, in.Name, in.Brand, in.Model, in.Host, in.Port, in.DeviceID).Scan(&id)
	if err != nil {
		return ScaleDevice{}, err
	}
	return s.scaleByID(ctx, p, in.StoreID, id)
}

func (s *Service) UpdateScale(ctx context.Context, p *identity.Principal, id string, in ScaleDeviceInput) (ScaleDevice, error) {
	storeID, _, err := s.scaleOf(ctx, p, id)
	if err != nil {
		return ScaleDevice{}, err
	}
	if err := s.scaleManager(p, storeID); err != nil {
		return ScaleDevice{}, err
	}
	if err := s.checkScaleInput(ctx, p, storeID, &in); err != nil {
		return ScaleDevice{}, err
	}
	_, err = s.pool.Exec(ctx, `UPDATE scales SET name = $2, brand = $3, model = $4, host = $5, port = $6, device_id = $7,
		check_at = CASE WHEN host = $5 AND port = $6 AND brand = $3 THEN check_at END,
		check_ok = CASE WHEN host = $5 AND port = $6 AND brand = $3 THEN check_ok END,
		check_error = CASE WHEN host = $5 AND port = $6 AND brand = $3 THEN check_error END
		WHERE id = $1`, id, in.Name, in.Brand, in.Model, in.Host, in.Port, in.DeviceID)
	if err != nil {
		return ScaleDevice{}, err
	}
	return s.scaleByID(ctx, p, storeID, id)
}

func (s *Service) DeleteScale(ctx context.Context, p *identity.Principal, id string) (map[string]any, error) {
	storeID, _, err := s.scaleOf(ctx, p, id)
	if err != nil {
		return nil, err
	}
	if err := s.scaleManager(p, storeID); err != nil {
		return nil, err
	}
	_, err = s.pool.Exec(ctx, `DELETE FROM scales WHERE id = $1`, id)
	return map[string]any{"deleted": true}, err
}

func (s *Service) scaleByID(ctx context.Context, p *identity.Principal, storeID, id string) (ScaleDevice, error) {
	list, err := s.ListScales(ctx, p, storeID)
	if err != nil {
		return ScaleDevice{}, err
	}
	for _, d := range list {
		if d.ID == id {
			return d, nil
		}
	}
	return ScaleDevice{}, apperr.NotFound("весы не найдены").Uz("tarozi topilmadi")
}

// ------------------------------------------------------ товары для весов

// scaleGoods — весовые товары с номером на весах: номер, название (как
// писать в весы), цена за кг магазина. latin — название латиницей (весы с
// драйвером не печатают кириллицу); нет — как в Super Market (для файла).
func (s *Service) scaleGoods(ctx context.Context, q db.Querier, networkID, storeID string, latin bool) ([]scaleGood, error) {
	priceType, err := catalog.DefaultPriceType(ctx, q, networkID)
	if err != nil {
		return nil, err
	}
	var lang string
	if err := q.QueryRow(ctx, `SELECT scale_name_lang FROM networks WHERE id = $1`, networkID).Scan(&lang); err != nil {
		return nil, err
	}
	rows, err := q.Query(ctx, `
		SELECT p.id, pl.plu,
		       CASE WHEN $4 = 'ru' THEN p.name ELSE COALESCE(NULLIF(p.name_uz, ''), p.name) END,
		       COALESCE(sp.price, np.price, p.base_price)::float8
		FROM products p
		JOIN units u ON u.id = p.unit_id
		JOIN pos_plu pl ON pl.network_id = $1 AND pl.product_id = p.id AND pl.plu IS NOT NULL
		LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = $3 AND sp.store_id = $2
		LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = $3 AND np.store_id IS NULL AND np.network_id = $1
		WHERE (p.network_id IS NULL OR p.network_id = $1) AND p.kind = 'goods' AND u.is_fractional
		ORDER BY pl.plu`, networkID, storeID, priceType, lang)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (scaleGood, error) {
		var g scaleGood
		var price float64
		err := r.Scan(&g.ProductID, &g.PLU, &g.Name, &price)
		g.Price = int64(math.Round(price))
		g.Unit = "kg"
		if latin {
			g.Name = ScaleName(g.Name)
		} else {
			g.Name = cutWords(strings.Join(strings.Fields(g.Name), " "), scaleNameMax)
		}
		return g, err
	})
}

type haveItem struct {
	PLU   int
	Price float64
	Name  string
	At    time.Time
}

// scaleHave — что сейчас в весах.
func (s *Service) scaleHave(ctx context.Context, q db.Querier, scaleID string) (map[string]haveItem, error) {
	rows, err := q.Query(ctx, `SELECT product_id, plu, price::float8, name, sent_at FROM scale_items WHERE scale_id = $1`, scaleID)
	if err != nil {
		return nil, err
	}
	out := map[string]haveItem{}
	for rows.Next() {
		var id string
		var h haveItem
		if err := rows.Scan(&id, &h.PLU, &h.Price, &h.Name, &h.At); err != nil {
			rows.Close()
			return nil, err
		}
		out[id] = h
	}
	return out, rows.Err()
}

// diffGoods — товары, которых нет в весах или у которых поменялся номер или
// цена (и название — byName, если оно известно: «Введено» вручную его не пишет).
func diffGoods(goods []scaleGood, have map[string]haveItem, byName bool) []scaleGood {
	var out []scaleGood
	for _, g := range goods {
		h, ok := have[g.ProductID]
		if !ok || h.PLU != g.PLU || math.Abs(h.Price-float64(g.Price)) > 0.5 || (byName && h.Name != "" && h.Name != g.Name) {
			out = append(out, g)
		}
	}
	return out
}

// ------------------------------------------------- отправить в весы (Н3, Н4)

type ScaleSendInput struct {
	StoreID  string   `json:"store_id"`
	ScaleIDs []string `json:"scale_ids"`
	// changed — новые и изменённые; all — все весовые товары заново.
	Mode string `json:"mode"`
}

func (s *Service) SendToScales(ctx context.Context, p *identity.Principal, in ScaleSendInput) ([]ScaleJob, error) {
	if err := p.RequireAny(identity.PermCatalogManage, identity.PermPricesManage); err != nil {
		return nil, err
	}
	if err := s.storeForPanel(p, in.StoreID); err != nil {
		return nil, err
	}
	if in.Mode == "" {
		in.Mode = "changed"
	}
	if in.Mode != "changed" && in.Mode != "all" {
		return nil, apperr.Validation("mode: changed или all").Uz("mode: changed yoki all")
	}
	if len(in.ScaleIDs) == 0 || len(in.ScaleIDs) > 50 {
		return nil, apperr.Validation("scale_ids: выберите весы").Uz("scale_ids: tarozini tanlang")
	}
	var jobs []ScaleJob
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		goods, err := s.scaleGoods(ctx, tx, p.NetworkID, in.StoreID, true)
		if err != nil {
			return err
		}
		seen := map[string]bool{}
		for _, id := range in.ScaleIDs {
			if seen[id] {
				continue
			}
			seen[id] = true
			if !httpx.IsUUID(id) {
				return apperr.Validation("scale_ids: весы этого магазина").Uz("scale_ids: shu doʻkon tarozilari")
			}
			var brand, name string
			err := tx.QueryRow(ctx, `SELECT brand, name FROM scales WHERE id = $1 AND network_id = $2 AND store_id = $3 FOR UPDATE`,
				id, p.NetworkID, in.StoreID).Scan(&brand, &name)
			if errors.Is(err, pgx.ErrNoRows) {
				return apperr.Validation("scale_ids: весы этого магазина").Uz("scale_ids: shu doʻkon tarozilari")
			}
			if err != nil {
				return err
			}
			if !directBrand(brand) {
				return apperr.Conflict("scale_file", "«"+name+"» загружаются файлом — скачайте файл для программы весов").
					Uz("«" + name + "» fayl orqali yuklanadi — tarozi dasturi uchun faylni yuklab oling")
			}
			items := goods
			if in.Mode == "changed" {
				have, err := s.scaleHave(ctx, tx, id)
				if err != nil {
					return err
				}
				items = diffGoods(goods, have, true)
			}
			// Что весы не примут — сразу в «не отправлено» с причиной.
			send := make([]scaleGood, 0, len(items))
			failures := []ScaleFailure{}
			for _, g := range items {
				switch {
				case g.PLU > dahuaMaxPLU:
					failures = append(failures, ScaleFailure{g.ProductID, g.PLU, g.Name, fmt.Sprintf("номер больше %d — весы его не примут", dahuaMaxPLU)})
				case g.Price > dahuaMaxPrice:
					failures = append(failures, ScaleFailure{g.ProductID, g.PLU, g.Name, "цена больше 999 999 — весы её не примут"})
				case g.Price <= 0:
					failures = append(failures, ScaleFailure{g.ProductID, g.PLU, g.Name, "нет цены"})
				default:
					send = append(send, g)
				}
			}
			// Неотправленное прежнее задание этих весов заменяем новым.
			if _, err := tx.Exec(ctx, `DELETE FROM scale_jobs WHERE scale_id = $1 AND kind = 'send' AND status = 'pending'`, id); err != nil {
				return err
			}
			raw, _ := json.Marshal(send)
			fail, _ := json.Marshal(failures)
			status := "pending"
			if len(send) == 0 {
				status = "done"
			}
			var jobID string
			if err := tx.QueryRow(ctx, `INSERT INTO scale_jobs (network_id, store_id, scale_id, kind, mode, items, total, status, failures, done_at)
				VALUES ($1, $2, $3, 'send', $4, $5, $6, $7, $8, CASE WHEN $7 = 'done' THEN now() END) RETURNING id`,
				p.NetworkID, in.StoreID, id, in.Mode, raw, len(send), status, fail).Scan(&jobID); err != nil {
				return err
			}
			job, err := jobByID(ctx, tx, jobID)
			if err != nil {
				return err
			}
			jobs = append(jobs, job)
		}
		return nil
	})
	return jobs, err
}

// CheckScale — проверить связь: касса подключается к весам и отвечает.
func (s *Service) CheckScale(ctx context.Context, p *identity.Principal, id string) (ScaleJob, error) {
	storeID, brand, err := s.scaleOf(ctx, p, id)
	if err != nil {
		return ScaleJob{}, err
	}
	if err := s.storeForPanel(p, storeID); err != nil {
		return ScaleJob{}, err
	}
	if !directBrand(brand) {
		return ScaleJob{}, apperr.Conflict("scale_file", "эти весы загружаются файлом — связь не проверяется").
			Uz("bu tarozi fayl orqali yuklanadi — aloqa tekshirilmaydi")
	}
	var job ScaleJob
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DELETE FROM scale_jobs WHERE scale_id = $1 AND kind = 'check' AND status = 'pending'`, id); err != nil {
			return err
		}
		var jobID string
		if err := tx.QueryRow(ctx, `INSERT INTO scale_jobs (network_id, store_id, scale_id, kind) VALUES ($1, $2, $3, 'check') RETURNING id`,
			p.NetworkID, storeID, id).Scan(&jobID); err != nil {
			return err
		}
		job, err = jobByID(ctx, tx, jobID)
		return err
	})
	return job, err
}

const jobSelect = `SELECT j.id, j.scale_id, s.name, j.kind, j.mode, j.status, j.total, j.sent, j.error, j.failures, j.created_at, j.taken_at, j.done_at
	FROM scale_jobs j JOIN scales s ON s.id = j.scale_id`

func scanJob(r pgx.CollectableRow) (ScaleJob, error) {
	var j ScaleJob
	var fail []byte
	err := r.Scan(&j.ID, &j.ScaleID, &j.ScaleName, &j.Kind, &j.Mode, &j.Status, &j.Total, &j.Sent, &j.Error, &fail, &j.CreatedAt, &j.TakenAt, &j.DoneAt)
	if err == nil {
		_ = json.Unmarshal(fail, &j.Failures)
	}
	if j.Failures == nil {
		j.Failures = []ScaleFailure{}
	}
	return j, err
}

func jobByID(ctx context.Context, q db.Querier, id string) (ScaleJob, error) {
	rows, err := q.Query(ctx, jobSelect+` WHERE j.id = $1`, id)
	if err != nil {
		return ScaleJob{}, err
	}
	return pgx.CollectExactlyOneRow(rows, scanJob)
}

func (s *Service) lastJob(ctx context.Context, scaleID string) (*ScaleJob, error) {
	rows, err := s.pool.Query(ctx, jobSelect+` WHERE j.scale_id = $1 ORDER BY j.created_at DESC LIMIT 1`, scaleID)
	if err != nil {
		return nil, err
	}
	j, err := pgx.CollectExactlyOneRow(rows, scanJob)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return &j, err
}

// ScaleJobs — состояние заданий (панель ждёт итог отправки, Н4).
func (s *Service) ScaleJobs(ctx context.Context, p *identity.Principal, storeID string, ids []string) ([]ScaleJob, error) {
	if err := s.storeForPanel(p, storeID); err != nil {
		return nil, err
	}
	if len(ids) == 0 || len(ids) > 50 {
		return nil, apperr.Validation("ids: от 1 до 50 заданий").Uz("ids: 1 dan 50 gacha topshiriq")
	}
	for _, id := range ids {
		if !httpx.IsUUID(id) {
			return nil, apperr.Validation("ids: id задания").Uz("ids: topshiriq id")
		}
	}
	rows, err := s.pool.Query(ctx, jobSelect+` WHERE j.id = ANY ($1::uuid[]) AND j.network_id = $2 AND j.store_id = $3 ORDER BY s.created_at`,
		ids, p.NetworkID, storeID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanJob)
}

// ------------------------------------------------------ весы через файл (Н5)

type ScaleFileRow struct {
	ProductID string `json:"product_id"`
	PLU       int    `json:"plu"`
	// Код в штрихкоде: номер, дополненный нулями до числа цифр сети.
	Code  string `json:"code"`
	Name  string `json:"name"`
	Price int64  `json:"price"`
	Unit  string `json:"unit"`
}

// ScaleFile — строки файла для программы весов: изменённые или все.
func (s *Service) ScaleFile(ctx context.Context, p *identity.Principal, scaleID, mode string) ([]ScaleFileRow, error) {
	storeID, _, err := s.scaleOf(ctx, p, scaleID)
	if err != nil {
		return nil, err
	}
	if err := s.storeForPanel(p, storeID); err != nil {
		return nil, err
	}
	goods, err := s.scaleGoods(ctx, s.pool, p.NetworkID, storeID, false)
	if err != nil {
		return nil, err
	}
	if mode != "all" {
		have, err := s.scaleHave(ctx, s.pool, scaleID)
		if err != nil {
			return nil, err
		}
		goods = diffGoods(goods, have, false)
	}
	var digits int
	if err := s.pool.QueryRow(ctx, `SELECT scale_item_digits FROM networks WHERE id = $1`, p.NetworkID).Scan(&digits); err != nil {
		return nil, err
	}
	out := make([]ScaleFileRow, 0, len(goods))
	for _, g := range goods {
		out = append(out, ScaleFileRow{ProductID: g.ProductID, PLU: g.PLU, Code: fmt.Sprintf("%0*d", digits, g.PLU), Name: g.Name, Price: g.Price, Unit: g.Unit})
	}
	return out, nil
}

type ScaleLoadedInput struct {
	ProductIDs []string `json:"product_ids"`
}

// ScaleLoaded — «Загружено в весы»: файл загрузили программой весов.
func (s *Service) ScaleLoaded(ctx context.Context, p *identity.Principal, scaleID string, in ScaleLoadedInput) (map[string]any, error) {
	if err := p.RequireAny(identity.PermCatalogManage, identity.PermPricesManage); err != nil {
		return nil, err
	}
	storeID, _, err := s.scaleOf(ctx, p, scaleID)
	if err != nil {
		return nil, err
	}
	if err := s.storeForPanel(p, storeID); err != nil {
		return nil, err
	}
	if len(in.ProductIDs) == 0 || len(in.ProductIDs) > 10000 {
		return nil, apperr.Validation("product_ids: от 1 до 10 000 товаров").Uz("product_ids: 1 dan 10 000 gacha mahsulot")
	}
	want := map[string]bool{}
	for _, id := range in.ProductIDs {
		if !httpx.IsUUID(id) {
			return nil, apperr.Validation("product_ids: id товара").Uz("product_ids: mahsulot id")
		}
		want[id] = true
	}
	goods, err := s.scaleGoods(ctx, s.pool, p.NetworkID, storeID, false)
	if err != nil {
		return nil, err
	}
	n := 0
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		for _, g := range goods {
			if !want[g.ProductID] {
				continue
			}
			if err := putScaleItem(ctx, tx, scaleID, g); err != nil {
				return err
			}
			n++
		}
		return nil
	})
	return map[string]any{"loaded": n}, err
}

func putScaleItem(ctx context.Context, q db.Querier, scaleID string, g scaleGood) error {
	_, err := q.Exec(ctx, `INSERT INTO scale_items (scale_id, product_id, plu, price, name) VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (scale_id, product_id) DO UPDATE SET plu = EXCLUDED.plu, price = EXCLUDED.price, name = EXCLUDED.name, sent_at = now()`,
		scaleID, g.ProductID, g.PLU, g.Price, g.Name)
	return err
}

// ------------------------------------------------------------------- касса

// PosScaleJob — задание кассе: весы и товары (уже в виде для весов).
type PosScaleJob struct {
	ID   string `json:"id"`
	Kind string `json:"kind"`
	// all — сначала очистить весы, потом записать все товары.
	Mode  string      `json:"mode"`
	Scale PosScale    `json:"scale"`
	Items []scaleGood `json:"items"`
}

type PosScale struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Brand string `json:"brand"`
	Host  string `json:"host"`
	Port  int    `json:"port"`
}

// TakeScaleJobs — касса забирает задания своих весов (или весов без
// выбранной кассы). Взятое и брошенное (касса выключилась) через 3 минуты
// может взять другая касса.
func (s *Service) TakeScaleJobs(ctx context.Context, p *identity.Principal) ([]PosScaleJob, error) {
	storeID, err := deviceStoreID(p)
	if err != nil {
		return nil, err
	}
	if p.DeviceKind != KindPOS {
		return []PosScaleJob{}, nil
	}
	rows, err := s.pool.Query(ctx, `
		UPDATE scale_jobs j SET status = 'running', taken_by = $2, taken_at = now()
		FROM scales s
		WHERE s.id = j.scale_id AND j.id IN (
			SELECT j2.id FROM scale_jobs j2 JOIN scales s2 ON s2.id = j2.scale_id
			WHERE j2.store_id = $1 AND (s2.device_id IS NULL OR s2.device_id = $2)
			  AND (j2.status = 'pending' OR (j2.status = 'running' AND (j2.taken_by = $2 OR j2.taken_at < now() - interval '3 minutes')))
			ORDER BY j2.created_at LIMIT 5 FOR UPDATE OF j2 SKIP LOCKED)
		RETURNING j.id, j.kind, j.mode, j.items, s.id, s.name, s.brand, s.host, s.port`, storeID, p.DeviceID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (PosScaleJob, error) {
		var j PosScaleJob
		var raw []byte
		err := r.Scan(&j.ID, &j.Kind, &j.Mode, &raw, &j.Scale.ID, &j.Scale.Name, &j.Scale.Brand, &j.Scale.Host, &j.Scale.Port)
		if err == nil {
			err = json.Unmarshal(raw, &j.Items)
		}
		if j.Items == nil {
			j.Items = []scaleGood{}
		}
		return j, err
	})
}

type ScaleJobResult struct {
	// Принятые весами товары.
	DoneIDs  []string       `json:"done_ids"`
	Failures []ScaleFailure `json:"failures"`
	// Не удалось вообще (нет связи с весами и т. п.); пусто — всё прошло.
	Error string `json:"error"`
	// Касса очистила весы перед записью («Все весовые»).
	Cleared bool `json:"cleared"`
}

// ScaleJobDone — касса сообщает итог: что весы приняли, что нет, связь.
func (s *Service) ScaleJobDone(ctx context.Context, p *identity.Principal, id string, in ScaleJobResult) (map[string]any, error) {
	storeID, err := deviceStoreID(p)
	if err != nil {
		return nil, err
	}
	in.Error = cutRunes(strings.TrimSpace(in.Error), 300)
	if len(in.DoneIDs) > 10000 || len(in.Failures) > 10000 {
		return nil, apperr.Validation("слишком много товаров").Uz("mahsulotlar juda koʻp")
	}
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var scaleID, kind, mode, status string
		var raw, fail []byte
		err := tx.QueryRow(ctx, `SELECT scale_id, kind, mode, status, items, failures FROM scale_jobs WHERE id = $1 AND store_id = $2 FOR UPDATE`,
			id, storeID).Scan(&scaleID, &kind, &mode, &status, &raw, &fail)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.NotFound("задание не найдено").Uz("topshiriq topilmadi")
		}
		if err != nil {
			return err
		}
		if status == "done" || status == "failed" {
			return nil // ответ уже пришёл (повтор после потерянного ответа)
		}
		var items []scaleGood
		_ = json.Unmarshal(raw, &items)
		var failures []ScaleFailure
		_ = json.Unmarshal(fail, &failures)
		done := map[string]bool{}
		for _, pid := range in.DoneIDs {
			done[pid] = true
		}
		// «Все весовые»: касса очистила весы — в них только то, что записалось сейчас.
		if kind == "send" && mode == "all" && in.Cleared {
			if _, err := tx.Exec(ctx, `DELETE FROM scale_items WHERE scale_id = $1`, scaleID); err != nil {
				return err
			}
		}
		sent := 0
		for _, g := range items {
			if !done[g.ProductID] {
				continue
			}
			if err := putScaleItem(ctx, tx, scaleID, g); err != nil {
				return err
			}
			sent++
		}
		for _, f := range in.Failures {
			f.Error = cutRunes(f.Error, 200)
			f.Name = cutRunes(f.Name, 80)
			failures = append(failures, f)
		}
		newStatus := "done"
		var errText *string
		if in.Error != "" {
			newStatus = "failed"
			errText = &in.Error
		}
		failRaw, _ := json.Marshal(failures)
		if _, err := tx.Exec(ctx, `UPDATE scale_jobs SET status = $2, sent = $3, error = $4, failures = $5, done_at = now() WHERE id = $1`,
			id, newStatus, sent, errText, failRaw); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE scales SET check_at = now(), check_ok = $2, check_error = $3 WHERE id = $1`, scaleID, in.Error == "", errText)
		return err
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{"ok": true}, nil
}

// --------------------------------------------- статусы «На весах» по весам

// applyScaleStatus — у магазина есть весы в списке: «введено», если номер и
// цена совпадают во всех весах; ни в одних — «новый»; иначе «изменён».
func (s *Service) applyScaleStatus(ctx context.Context, storeID string, items []ScaleItem) error {
	rows, err := s.pool.Query(ctx, `SELECT s.id, i.product_id, i.plu, i.price::float8, i.sent_at
		FROM scales s LEFT JOIN scale_items i ON i.scale_id = s.id WHERE s.store_id = $1`, storeID)
	if err != nil {
		return err
	}
	scales := map[string]bool{}
	have := map[string][]haveItem{}
	for rows.Next() {
		var sid string
		var pid *string
		var plu *int
		var price *float64
		var at *time.Time
		if err := rows.Scan(&sid, &pid, &plu, &price, &at); err != nil {
			rows.Close()
			return err
		}
		scales[sid] = true
		if pid != nil {
			have[*pid] = append(have[*pid], haveItem{PLU: *plu, Price: *price, At: *at})
		}
	}
	if err := rows.Err(); err != nil || len(scales) == 0 {
		return err
	}
	for i := range items {
		it := &items[i]
		if it.PLU == nil {
			continue
		}
		price, _ := strconv.ParseFloat(it.Price, 64)
		hs := have[it.ProductID]
		match := 0
		var last *time.Time
		for _, h := range hs {
			if h.PLU == *it.PLU && math.Abs(h.Price-math.Round(price)) <= 0.5 {
				match++
				if last == nil || h.At.After(*last) {
					at := h.At
					last = &at
				}
			}
		}
		switch {
		case match == len(scales):
			it.Status, it.EnteredAt = "entered", last
		case len(hs) == 0:
			it.Status, it.EnteredAt = "new", nil
		default:
			it.Status = "changed"
		}
	}
	return nil
}

// enteredToScales — «Введено» вручную: эти товары теперь во всех весах магазина.
func enteredToScales(ctx context.Context, q db.Querier, storeID string, ids []string) error {
	_, err := q.Exec(ctx, `
		INSERT INTO scale_items (scale_id, product_id, plu, price, name)
		SELECT s.id, se.product_id, se.plu, round(se.price), '' FROM scales s
		JOIN scale_entries se ON se.store_id = s.store_id
		WHERE s.store_id = $1 AND se.product_id = ANY ($2::uuid[])
		ON CONFLICT (scale_id, product_id) DO UPDATE SET plu = EXCLUDED.plu, price = EXCLUDED.price, sent_at = now()`, storeID, ids)
	return err
}

// -------------------------------------------------------------- названия

// ScaleName — название для весов: латиница (кириллицу — транслитом), только
// печатные ASCII, без лишних пробелов, не длиннее 36 символов.
func ScaleName(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r < 128 {
			if unicode.IsPrint(r) {
				b.WriteRune(r)
			} else {
				b.WriteByte(' ')
			}
			continue
		}
		if t, ok := translit[unicode.ToLower(r)]; ok {
			if unicode.IsUpper(r) && t != "" {
				rs := []rune(t)
				t = string(unicode.ToUpper(rs[0])) + string(rs[1:])
			}
			b.WriteString(t)
			continue
		}
		switch r {
		case 'ʻ', 'ʼ', '‘', '’', '`', '´':
			b.WriteByte('\'')
		case '«', '»', '“', '”', '„':
			b.WriteByte('"')
		case '–', '—', '−':
			b.WriteByte('-')
		case '№':
			b.WriteString("N")
		default:
			b.WriteByte(' ')
		}
	}
	return cutWords(strings.Join(strings.Fields(b.String()), " "), scaleNameMax)
}

// cutWords — не длиннее n символов, по возможности не разрывая слово.
func cutWords(s string, n int) string {
	rs := []rune(s)
	if len(rs) <= n {
		return s
	}
	cut := string(rs[:n])
	if rs[n] != ' ' {
		if i := strings.LastIndexByte(cut, ' '); i > len(cut)/2 {
			cut = cut[:i]
		}
	}
	return strings.TrimSpace(cut)
}

var translit = map[rune]string{
	'а': "a", 'б': "b", 'в': "v", 'г': "g", 'д': "d", 'е': "e", 'ё': "yo", 'ж': "j", 'з': "z", 'и': "i",
	'й': "y", 'к': "k", 'л': "l", 'м': "m", 'н': "n", 'о': "o", 'п': "p", 'р': "r", 'с': "s", 'т': "t",
	'у': "u", 'ф': "f", 'х': "x", 'ц': "ts", 'ч': "ch", 'ш': "sh", 'щ': "sh", 'ъ': "", 'ы': "i", 'ь': "",
	'э': "e", 'ю': "yu", 'я': "ya", 'ў': "o'", 'қ': "q", 'ғ': "g'", 'ҳ': "h",
}

func cutRunes(s string, n int) string {
	rs := []rune(s)
	if len(rs) <= n {
		return s
	}
	return strings.TrimSpace(string(rs[:n]))
}
