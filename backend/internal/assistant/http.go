package assistant

import (
	"errors"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"path"
	"strings"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/ai"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/plans"
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

// Routes:
//
//	GET  /store/assistant/messages?store_id=&after=   — чат (after — только новее)
//	POST /store/assistant/messages                     — JSON {store_id, text, images, action}
//	                                                     или multipart: store_id, text, audio (файл)
//	GET  /store/assistant/today?store_id=              — что помощник сделал сегодня
func (m *Module) Routes(r chi.Router) {
	r.Route("/store/assistant", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore), m.auth.Feature(plans.FeatureAssistant))
		r.Get("/messages", m.list)
		r.Post("/messages", m.send)
		r.Get("/today", m.today)
	})
}

func pr(r *http.Request) *identity.Principal { return identity.FromContext(r.Context()) }

func (m *Module) list(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Messages, error) {
		q := r.URL.Query()
		return m.svc.List(r.Context(), pr(r), q.Get("store_id"), q.Get("after"))
	})
}

func (m *Module) today(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Journal, error) {
		return m.svc.Today(r.Context(), pr(r), r.URL.Query().Get("store_id"))
	})
}

// audioMIME — тип голосового из браузера (MediaRecorder: audio/webm;codecs=opus,
// Safari — audio/mp4) без параметров.
func audioMIME(ct string) string {
	mt, _, err := mime.ParseMediaType(ct)
	if err != nil || !strings.HasPrefix(mt, "audio/") {
		return ""
	}
	return mt
}

// audioByName — тип по расширению, если клиент прислал файл без типа
// (Flutter: application/octet-stream).
func audioByName(name string) string {
	switch strings.ToLower(path.Ext(name)) {
	case ".wav":
		return "audio/wav"
	case ".m4a", ".mp4":
		return "audio/mp4"
	case ".aac":
		return "audio/aac"
	case ".webm":
		return "audio/webm"
	case ".ogg", ".opus":
		return "audio/ogg"
	case ".mp3":
		return "audio/mp3"
	case ".flac":
		return "audio/flac"
	}
	return ""
}

func (m *Module) send(w http.ResponseWriter, r *http.Request) {
	if !strings.HasPrefix(r.Header.Get("Content-Type"), "multipart/") {
		httpx.RespondBody(w, r, m.log, http.StatusAccepted, "", func(_ string, in SendInput) (SendResult, error) {
			return m.svc.Send(r.Context(), pr(r), in)
		})
		return
	}
	httpx.Respond(w, r, m.log, http.StatusAccepted, func() (SendResult, error) {
		r.Body = http.MaxBytesReader(w, r.Body, MaxAudio+1<<20)
		if err := r.ParseMultipartForm(1 << 20); err != nil {
			var tooBig *http.MaxBytesError
			if errors.As(err, &tooBig) {
				return SendResult{}, apperr.Validation("audio: голосовое не больше 8 МБ").Uz("audio: ovozli xabar 8 MB dan oshmasin")
			}
			return SendResult{}, apperr.Validation("multipart: не удалось прочитать форму").Uz("multipart: formani oʻqib boʻlmadi")
		}
		in := SendInput{StoreID: r.FormValue("store_id"), Text: r.FormValue("text"), Kind: r.FormValue("kind")}
		f, hdr, err := r.FormFile("audio")
		if err == nil {
			defer f.Close()
			data, err := io.ReadAll(io.LimitReader(f, MaxAudio+1))
			if err != nil {
				return SendResult{}, apperr.Validation("audio: не удалось прочитать файл").Uz("audio: faylni oʻqib boʻlmadi")
			}
			mt := audioMIME(hdr.Header.Get("Content-Type"))
			if mt == "" {
				mt = audioByName(hdr.Filename)
			}
			if mt == "" {
				return SendResult{}, apperr.Validation("audio: ожидается аудио (wav, m4a, aac, webm, ogg, mp3)").Uz("audio: audio kutilmoqda (wav, m4a, aac, webm, ogg, mp3)")
			}
			in.Audio = &ai.Part{MIME: mt, Data: data}
		}
		return m.svc.Send(r.Context(), pr(r), in)
	})
}
