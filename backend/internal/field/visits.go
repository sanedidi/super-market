package field

import (
	"context"
	"errors"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/supply"
)

// П4 «Что с этим магазином?» → результат визита. Отметка ставится в точке,
// где стоит продажник, видна всем продажникам навсегда; у магазина копится
// история визитов.

// Причины отказа и программы, которые уже есть у магазина.
var (
	refuseReasons = []string{"expensive", "has_program", "not_interested", "no_trust", "owner_against", "other"}
	programs      = []string{"billz", "regos", "1c", "notebook", "other"}
)

// VisitInput — отметка магазина.
type VisitInput struct {
	// Магазин, который уже отмечен рядом («Это он — обновить»); пусто — новый.
	PlaceID  string   `json:"place_id"`
	Result   string   `json:"result"`
	Lat      *float64 `json:"lat"`
	Lng      *float64 `json:"lng"`
	Accuracy *float64 `json:"accuracy"`
	Name     string   `json:"name"`
	Reason   string   `json:"reason"`
	Program  string   `json:"program"`
	Comment  string   `json:"comment"`
	PhotoURL string   `json:"photo_url"`
	// «Прийти позже»: день (YYYY-MM-DD).
	RemindOn string `json:"remind_on"`
	// «Подключить»: магазин подключается сразу, владелец получает логин и пароль.
	Lead *LeadFields `json:"lead"`
}

// LeadFields — «Новый магазин» (П14): название, владелец, телефон (точка — где
// стоит продажник) и логин владельца; пустой логин придумывается из названия.
type LeadFields struct {
	Name       string `json:"name"`
	OwnerName  string `json:"owner_name"`
	OwnerPhone string `json:"owner_phone"`
	Address    string `json:"address"`
	OwnerLogin string `json:"owner_login"`
}

func (in *VisitInput) clean(today time.Time) error {
	in.Name, in.Comment = strings.TrimSpace(in.Name), strings.TrimSpace(in.Comment)
	in.PhotoURL, in.Reason, in.Program = strings.TrimSpace(in.PhotoURL), strings.TrimSpace(in.Reason), strings.TrimSpace(in.Program)
	switch {
	case in.Lat == nil || in.Lng == nil || *in.Lat < -90 || *in.Lat > 90 || *in.Lng < -180 || *in.Lng > 180:
		return apperr.Validation("lat/lng: нет геопозиции — включите GPS").Uz("lat/lng: geojoylashuv yoʻq — GPS ni yoqing")
	case len([]rune(in.Name)) > 120:
		return apperr.Validation("name: не длиннее 120 символов").Uz("name: 120 belgidan oshmasin")
	case len([]rune(in.Comment)) > 500:
		return apperr.Validation("comment: не длиннее 500 символов").Uz("comment: 500 belgidan oshmasin")
	case len(in.PhotoURL) > 500:
		return apperr.Validation("photo_url: слишком длинная ссылка").Uz("photo_url: havola juda uzun")
	}
	if in.PlaceID != "" && !httpx.IsUUID(in.PlaceID) {
		return errPlaceNotFound()
	}
	switch in.Result {
	case ResultRefused:
		if in.PhotoURL == "" {
			return apperr.Validation("photo_url: сфотографируйте витрину — так другой продажник узнает магазин").Uz("photo_url: vitrinani suratga oling — shunda boshqa agent doʻkonni taniydi")
		}
		if !slices.Contains(refuseReasons, in.Reason) {
			return apperr.Validation("reason: выберите причину отказа").Uz("reason: rad etish sababini tanlang")
		}
		if in.Reason != "has_program" {
			in.Program = ""
		} else if in.Program != "" && !slices.Contains(programs, in.Program) {
			return apperr.Validation("program: неизвестная программа").Uz("program: nomaʼlum dastur")
		}
		in.RemindOn, in.Lead = "", nil
	case ResultLater:
		d, err := time.Parse("2006-01-02", in.RemindOn)
		if err != nil {
			return apperr.Validation("remind_on: выберите день").Uz("remind_on: kunni tanlang")
		}
		if d.Before(today) || d.After(today.AddDate(0, 0, 60)) {
			return apperr.Validation("remind_on: день — от сегодня до 60 дней вперёд").Uz("remind_on: kun — bugundan 60 kungacha")
		}
		in.Reason, in.Program, in.Lead = "", "", nil
	case ResultClosed, ResultOurs:
		in.Reason, in.Program, in.RemindOn, in.Lead = "", "", "", nil
	case ResultLead:
		if in.Lead == nil {
			return apperr.Validation("lead: заполните название, владельца и телефон").Uz("lead: nomi, egasi va telefonni toʻldiring")
		}
		in.Reason, in.Program, in.RemindOn = "", "", ""
		in.Name = strings.TrimSpace(in.Lead.Name)
	default:
		return apperr.Validation("result: lead, refused, closed, later или ours").Uz("result: lead, refused, closed, later yoki ours")
	}
	return nil
}

func errPlaceNotFound() error {
	return apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
}

// sameStoreM — «Это он?»: отмеченный магазин должен быть рядом с продажником.
const sameStoreM = 150

// AddVisit — отметить магазин (П4, П5 и «Новый магазин»).
func (s *Service) AddVisit(ctx context.Context, p *identity.Principal, in VisitInput) (Place, error) {
	if err := requireRep(p); err != nil {
		return Place{}, err
	}
	now := s.now().In(tz)
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	if err := in.clean(today); err != nil {
		return Place{}, err
	}
	var (
		placeID         string
		leadID          *string
		ownerLogin, pwd string
	)
	if in.Result == ResultLead {
		// Логин и временный пароль владельца (П14–П15): логин можно задать
		// самому, пароль — всегда 8 цифр от сервера.
		var err error
		if ownerLogin = identity.NormalizeLogin(in.Lead.OwnerLogin); ownerLogin == "" {
			if ownerLogin, err = identity.SuggestLogin(ctx, s.pool, in.Lead.Name); err != nil {
				return Place{}, err
			}
		}
		if pwd, err = identity.GenerateTempPassword(); err != nil {
			return Place{}, err
		}
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var walkID *string
		if err := tx.QueryRow(ctx, `SELECT id FROM field_walks WHERE rep_id = $1 AND status <> 'ended'`, p.RepID).Scan(&walkID); err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if in.Result == ResultLead {
			id, err := supply.CreateRepLeadTx(ctx, tx, p.RepID, supply.LeadInput{
				Name: in.Lead.Name, OwnerName: in.Lead.OwnerName, OwnerPhone: in.Lead.OwnerPhone,
				Address: in.Lead.Address, Lat: in.Lat, Lng: in.Lng,
			})
			if err != nil {
				return err
			}
			leadID = &id
			// Магазин подключается сразу: сеть, магазин в точке, логин владельца.
			if _, err := supply.ConnectRepLeadTx(ctx, tx, id, p.UserID, supply.ConnectLeadInput{
				Name: in.Lead.Name, OwnerName: in.Lead.OwnerName, OwnerPhone: in.Lead.OwnerPhone,
				OwnerLogin: ownerLogin, OwnerPassword: pwd,
			}); err != nil {
				return err
			}
		}
		var remind *string
		if in.Result == ResultLater {
			remind = &in.RemindOn
		}
		if in.PlaceID != "" {
			var far bool
			err := tx.QueryRow(ctx, `
				SELECT NOT ST_DWithin(location, ST_SetSRID(ST_MakePoint($3::float8, $2::float8), 4326)::geography, $4)
				FROM field_places WHERE id = $1 FOR UPDATE`, in.PlaceID, *in.Lat, *in.Lng, sameStoreM).Scan(&far)
			if errors.Is(err, pgx.ErrNoRows) {
				return errPlaceNotFound()
			}
			if err != nil {
				return err
			}
			if far {
				return apperr.Validation("этот магазин далеко от вас — отметьте как новый").Uz("bu doʻkon sizdan uzoqda — yangi deb belgilang")
			}
			placeID = in.PlaceID
			// Имя и фото магазина не теряются, если в этот раз их не указали.
			if _, err := tx.Exec(ctx, `
				UPDATE field_places SET last_result = $2, last_visit_at = now(), last_rep_id = $3,
				       name = CASE WHEN $4 <> '' THEN $4 ELSE name END,
				       photo_url = CASE WHEN $5 <> '' THEN $5 ELSE photo_url END,
				       remind_on = $6::date, lead_id = COALESCE($7, lead_id), visits = visits + 1
				WHERE id = $1`, placeID, in.Result, p.RepID, in.Name, in.PhotoURL, remind, leadID); err != nil {
				return err
			}
		} else if err := tx.QueryRow(ctx, `
			INSERT INTO field_places (location, name, last_result, last_visit_at, last_rep_id, remind_on, photo_url, lead_id)
			VALUES (ST_SetSRID(ST_MakePoint($2::float8, $1::float8), 4326)::geography, $3, $4, now(), $5, $6::date, $7, $8)
			RETURNING id`, *in.Lat, *in.Lng, in.Name, in.Result, p.RepID, remind, in.PhotoURL, leadID).Scan(&placeID); err != nil {
			return err
		}
		var acc *float32
		if in.Accuracy != nil {
			a := float32(*in.Accuracy)
			acc = &a
		}
		_, err := tx.Exec(ctx, `
			INSERT INTO field_visits (place_id, rep_id, walk_id, result, location, accuracy, name, reason, program, comment, photo_url, remind_on, lead_id)
			VALUES ($1, $2, $3, $4, ST_SetSRID(ST_MakePoint($6::float8, $5::float8), 4326)::geography, $7, $8, $9, $10, $11, $12, $13::date, $14)`,
			placeID, p.RepID, walkID, in.Result, *in.Lat, *in.Lng, acc, in.Name, in.Reason, in.Program, in.Comment, in.PhotoURL, remind, leadID)
		if err != nil {
			return err
		}
		// Флажки «зайти потом» рядом: магазин отметили — флажок закрыт.
		return closeFlagsNearTx(ctx, tx, p.RepID, placeID, *in.Lat, *in.Lng)
	})
	if err != nil {
		return Place{}, err
	}
	if leadID != nil && s.leads != nil {
		s.leads.NotifyRepLead(ctx, *leadID)
	}
	return s.place(ctx, p.RepID, placeID, true)
}

func (s *Service) place(ctx context.Context, me, id string, history bool) (Place, error) {
	if !httpx.IsUUID(id) {
		return Place{}, errPlaceNotFound()
	}
	rows, err := s.pool.Query(ctx, `SELECT `+placeCols(2)+placeJoins+` WHERE p.id = $1`, id, me)
	if err != nil {
		return Place{}, err
	}
	pl, err := pgx.CollectExactlyOneRow(rows, scanPlace)
	if errors.Is(err, pgx.ErrNoRows) {
		return Place{}, errPlaceNotFound()
	}
	if err != nil || !history {
		return pl, err
	}
	rows, err = s.pool.Query(ctx, `SELECT `+visitCols(2)+`
		FROM field_visits v JOIN field_reps fr ON fr.id = v.rep_id
		WHERE v.place_id = $1 ORDER BY v.created_at DESC LIMIT 50`, id, me)
	if err != nil {
		return pl, err
	}
	pl.History, err = pgx.CollectRows(rows, scanVisit)
	if pl.History == nil {
		pl.History = []Visit{}
	}
	if err != nil || me == "" {
		return pl, err
	}
	if netID, err := s.myConnectedNetwork(ctx, me, id); err != nil || netID == "" {
		return pl, err
	} else if pl.Owner, err = identity.GetOwnerLogin(ctx, s.pool, netID); err != nil {
		return pl, err
	}
	return pl, nil
}

// myConnectedNetwork — сеть магазина, который подключил продажник me
// (пусто — магазин не подключён или его подключил не он).
func (s *Service) myConnectedNetwork(ctx context.Context, me, placeID string) (string, error) {
	var netID string
	err := s.pool.QueryRow(ctx, `
		SELECT sl.network_id::text FROM field_places p
		JOIN store_leads sl ON sl.id = p.lead_id
		WHERE p.id = $1 AND sl.rep_id::text = $2 AND sl.status = 'connected' AND sl.network_id IS NOT NULL`,
		placeID, me).Scan(&netID)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return netID, err
}

// NewOwnerPassword — «Новый пароль» / «Сбросить пароль» (П16–П17): новый
// временный пароль владельцу магазина, который подключил этот продажник.
// Старый пароль перестаёт работать, все входы владельца закрываются.
func (s *Service) NewOwnerPassword(ctx context.Context, p *identity.Principal, placeID string) (Place, error) {
	if err := requireRep(p); err != nil {
		return Place{}, err
	}
	if !httpx.IsUUID(placeID) {
		return Place{}, errPlaceNotFound()
	}
	netID, err := s.myConnectedNetwork(ctx, p.RepID, placeID)
	if err != nil {
		return Place{}, err
	}
	if netID == "" {
		return Place{}, apperr.Forbidden("пароль меняет продажник, который подключил этот магазин").Uz("parolni shu doʻkonni ulagan agent oʻzgartiradi")
	}
	owner, err := identity.GetOwnerLogin(ctx, s.pool, netID)
	if err != nil {
		return Place{}, err
	}
	if owner == nil {
		return Place{}, apperr.NotFound("у владельца нет логина — напишите в поддержку").Uz("egasining logini yoʻq — qoʻllab-quvvatlash xizmatiga yozing")
	}
	if _, err := identity.SetOwnerLogin(ctx, s.pool, netID, identity.LoginInput{Login: owner.Login, GeneratePassword: true}); err != nil {
		return Place{}, err
	}
	return s.place(ctx, p.RepID, placeID, true)
}

// Place — карточка магазина с историей визитов.
func (s *Service) Place(ctx context.Context, p *identity.Principal, id string) (Place, error) {
	me := ""
	switch {
	case p != nil && p.App == identity.AppField && p.RepID != "":
		me = p.RepID
	case requireAdmin(p) != nil:
		return Place{}, requireRep(p)
	}
	return s.place(ctx, me, id, true)
}

// MyPlaces — «Мои магазины»: где продажник был, последние сверху.
// result — фильтр по последнему результату (пусто — все).
func (s *Service) MyPlaces(ctx context.Context, p *identity.Principal, result string, page httpx.Page) ([]Place, error) {
	if err := requireRep(p); err != nil {
		return nil, err
	}
	if result != "" && !slices.Contains([]string{ResultLead, ResultRefused, ResultClosed, ResultLater, ResultOurs}, result) {
		return nil, apperr.Validation("result: lead, refused, closed, later или ours").Uz("result: lead, refused, closed, later yoki ours")
	}
	rows, err := s.pool.Query(ctx, `SELECT `+placeCols(1)+placeJoins+`
		WHERE p.id IN (SELECT place_id FROM field_visits WHERE rep_id::text = $1)
		  AND ($2 = '' OR p.last_result = $2)
		ORDER BY p.last_visit_at DESC LIMIT $3 OFFSET $4`, p.RepID, result, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, scanPlace)
	if out == nil {
		out = []Place{}
	}
	return out, err
}

// reminders — «Прийти позже», день которых наступил (или наступит завтра).
func (s *Service) reminders(ctx context.Context, repID string) ([]Place, error) {
	rows, err := s.pool.Query(ctx, `SELECT `+placeCols(1)+placeJoins+`
		WHERE p.last_rep_id::text = $1 AND p.last_result = 'later' AND p.remind_on <= `+todaySQL+` + 1
		ORDER BY p.remind_on, p.last_visit_at LIMIT 20`, repID)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, scanPlace)
	if out == nil {
		out = []Place{}
	}
	return out, err
}
