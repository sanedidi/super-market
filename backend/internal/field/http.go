package field

import (
	"log/slog"
	"net/http"
	"strconv"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

type Module struct {
	svc  *Service
	auth *identity.Authenticator
	log  *slog.Logger
}

func NewModule(svc *Service, auth *identity.Authenticator, log *slog.Logger) *Module {
	return &Module{svc: svc, auth: auth, log: log}
}

func (m *Module) Routes(r chi.Router) {
	// «SM Продажник».
	r.Route("/field", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppField))
		r.Get("/me", m.me)
		r.Post("/walks", m.startWalk)
		r.Get("/walks/{id}", m.getWalk)
		r.Post("/walks/{id}/points", m.addPoints)
		r.Post("/walks/{id}/pause", m.pause)
		r.Post("/walks/{id}/resume", m.resume)
		r.Post("/walks/{id}/finish", m.finish)
		r.Get("/map", m.repMap)
		r.Get("/white-zone", m.whiteZone)
		r.Get("/places", m.myPlaces)
		r.Get("/places/near", m.nearPlaces)
		r.Get("/places/{id}", m.place)
		r.Post("/visits", m.addVisit)
	})
	// Супер-админ: «Продажники».
	r.Route("/admin/field", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppAdmin))
		r.Get("/live", m.live)
		r.Get("/map", m.adminMap)
		r.Get("/reps", m.reps)
		r.Post("/reps", m.createRep)
		r.Patch("/reps/{id}", m.updateRep)
		r.Get("/reps/{id}/day", m.repDay)
		r.Get("/places/{id}", m.adminPlace)
		r.Get("/districts", m.districts)
		r.Put("/districts/{id}/boundary", m.setBoundary)
		r.Post("/districts/{id}/reset", m.resetCoverage)
	})
}

func pr(r *http.Request) *identity.Principal { return identity.FromContext(r.Context()) }

func (m *Module) me(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Me, error) { return m.svc.Me(r.Context(), pr(r)) })
}

func (m *Module) startWalk(w http.ResponseWriter, r *http.Request) {
	var in StartInput
	if r.ContentLength != 0 {
		if err := httpx.Decode(r, &in); err != nil {
			httpx.Fail(w, r, m.log, err)
			return
		}
	}
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Walk, error) { return m.svc.StartWalk(r.Context(), pr(r), in) })
}

func (m *Module) getWalk(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Walk, error) { return m.svc.GetWalk(r.Context(), pr(r), id) })
}

func (m *Module) addPoints(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in PointsInput) (PointsResult, error) {
		return m.svc.AddPoints(r.Context(), pr(r), id, in)
	})
}

func (m *Module) pause(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Walk, error) { return m.svc.PauseWalk(r.Context(), pr(r), id) })
}

func (m *Module) resume(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Walk, error) { return m.svc.ResumeWalk(r.Context(), pr(r), id) })
}

func (m *Module) finish(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Summary, error) { return m.svc.FinishWalk(r.Context(), pr(r), id) })
}

func (m *Module) repMap(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (MapData, error) {
		b, err := ParseBBox(r.URL.Query().Get)
		if err != nil {
			return MapData{}, err
		}
		return m.svc.RepMap(r.Context(), pr(r), b)
	})
}

func (m *Module) adminMap(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (MapData, error) {
		b, err := ParseBBox(r.URL.Query().Get)
		if err != nil {
			return MapData{}, err
		}
		return m.svc.AdminMap(r.Context(), pr(r), b)
	})
}

func latLng(r *http.Request) (float64, float64, error) {
	lat, err1 := strconv.ParseFloat(r.URL.Query().Get("lat"), 64)
	lng, err2 := strconv.ParseFloat(r.URL.Query().Get("lng"), 64)
	if err1 != nil || err2 != nil || lat < -90 || lat > 90 || lng < -180 || lng > 180 {
		return 0, 0, apperr.Validation("lat/lng: нет геопозиции").Uz("lat/lng: geojoylashuv yoʻq")
	}
	return lat, lng, nil
}

// whiteZoneResult — {"hint": null}, если рядом всё обойдено.
type whiteZoneResult struct {
	Hint *Hint `json:"hint"`
}

func (m *Module) whiteZone(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (whiteZoneResult, error) {
		lat, lng, err := latLng(r)
		if err != nil {
			return whiteZoneResult{}, err
		}
		h, err := m.svc.WhiteZone(r.Context(), pr(r), lat, lng)
		return whiteZoneResult{Hint: h}, err
	})
}

func (m *Module) nearPlaces(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Place], error) {
		lat, lng, err := latLng(r)
		if err != nil {
			return httpx.List[Place]{}, err
		}
		items, err := m.svc.NearPlaces(r.Context(), pr(r), lat, lng)
		return httpx.List[Place]{Items: items}, err
	})
}

func (m *Module) myPlaces(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Place], error) {
		items, err := m.svc.MyPlaces(r.Context(), pr(r), r.URL.Query().Get("result"), httpx.PageFrom(r))
		return httpx.List[Place]{Items: items}, err
	})
}

func (m *Module) place(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Place, error) { return m.svc.Place(r.Context(), pr(r), id) })
}

func (m *Module) addVisit(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in VisitInput) (Place, error) {
		return m.svc.AddVisit(r.Context(), pr(r), in)
	})
}

func (m *Module) live(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Live, error) { return m.svc.Live(r.Context(), pr(r)) })
}

func (m *Module) reps(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Rep], error) {
		items, err := m.svc.Reps(r.Context(), pr(r))
		return httpx.List[Rep]{Items: items}, err
	})
}

func (m *Module) createRep(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in RepInput) (Rep, error) {
		return m.svc.CreateRep(r.Context(), pr(r), in)
	})
}

func (m *Module) updateRep(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in RepInput) (Rep, error) {
		return m.svc.UpdateRep(r.Context(), pr(r), id, in)
	})
}

func (m *Module) repDay(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Day, error) {
		return m.svc.RepDay(r.Context(), pr(r), id, r.URL.Query().Get("date"))
	})
}

func (m *Module) adminPlace(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Place, error) { return m.svc.AdminPlace(r.Context(), pr(r), id) })
}

func (m *Module) districts(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Districts, error) { return m.svc.Districts(r.Context(), pr(r)) })
}

func (m *Module) setBoundary(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in BoundaryInput) (District, error) {
		return m.svc.SetBoundary(r.Context(), pr(r), id, in)
	})
}

func (m *Module) resetCoverage(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (District, error) {
		return m.svc.ResetCoverage(r.Context(), pr(r), id)
	})
}
