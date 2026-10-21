package pos

import (
	"net/http"
	"strconv"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/cafe"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/events"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Кухня кафе на устройствах: экран кухни, экран выдачи, касса кафе
// (состояние экранов и принтеров цехов). Логика — в пакете cafe.

// WithKitchen подключает экраны кухни и ожидание событий магазина.
func (m *Module) WithKitchen(svc *cafe.Service, hub *events.Hub) *Module {
	m.kitchen, m.hub = svc, hub
	return m
}

func (m *Module) kitchenRoutes(r chi.Router) {
	if m.kitchen == nil {
		return
	}
	r.Get("/pos/kitchen/board", m.kitchenBoard)
	r.Post("/pos/kitchen/orders/{id}/action", m.kitchenAction)
	r.Post("/pos/kitchen/items/{id}/done", m.kitchenItemDone)
	r.Get("/pos/kitchen/display", m.kitchenDisplay)
	r.Put("/pos/kitchen/stop", m.kitchenStop)
	r.Get("/pos/kitchen/wait", m.kitchenWait)
	r.Get("/pos/kitchen/status", m.kitchenStatus)
	r.Post("/pos/kitchen/printers", m.kitchenPrinters)
}

func (m *Module) kitchenBoard(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (cafe.KitchenBoard, error) {
		return m.kitchen.Board(r.Context(), pr(r))
	})
}

func (m *Module) kitchenAction(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in cafe.KitchenActionInput) (cafe.KitchenBoard, error) {
		return m.kitchen.Act(r.Context(), pr(r), id, in)
	})
}

func (m *Module) kitchenItemDone(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in cafe.ItemDoneInput) (cafe.KitchenBoard, error) {
		return m.kitchen.ItemDone(r.Context(), pr(r), id, in)
	})
}

func (m *Module) kitchenDisplay(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (cafe.DisplayBoard, error) {
		return m.kitchen.Display(r.Context(), pr(r))
	})
}

func (m *Module) kitchenStop(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in cafe.KitchenStopInput) (map[string][]string, error) {
		stop, err := m.kitchen.KitchenStop(r.Context(), pr(r), in)
		return map[string][]string{"stop": stop}, err
	})
}

// kitchenWait — длинный запрос: ответ, как только версия событий магазина
// станет больше v, или через ~25 секунд с текущей версией.
func (m *Module) kitchenWait(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (map[string]int64, error) {
		var after int64
		if v := r.URL.Query().Get("v"); v != "" {
			n, err := strconv.ParseInt(v, 10, 64)
			if err != nil || n < 0 {
				return nil, apperr.Validation("v: версия из прошлого ответа").Uz("v: oldingi javobdagi versiya")
			}
			after = n
		}
		v, err := m.kitchen.Wait(r.Context(), pr(r), m.hub, after)
		return map[string]int64{"version": v}, err
	})
}

func (m *Module) kitchenStatus(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (cafe.KitchenStatus, error) {
		return m.kitchen.Status(r.Context(), pr(r))
	})
}

func (m *Module) kitchenPrinters(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in []cafe.PrinterReport) (map[string]bool, error) {
		return map[string]bool{"ok": true}, m.kitchen.ReportPrinters(r.Context(), pr(r), in)
	})
}
