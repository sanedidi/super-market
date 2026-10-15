package identity

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/phone"
	"github.com/sanedidi/super-market/backend/internal/platform/token"
)

// Вход и регистрация в «SM Агент» по номеру телефона и коду из SMS.
//
// Агент работает с токеном приложения магазина (app = store, сеть вида
// distributor). Номер уже агент — сразу сессия. Номер новый — короткий
// «билет регистрации» (подписанный токен с номером): с ним приложение
// проходит шаги «Как вас зовут» и «Ваш бренд», регистрация создаёт сеть.

// AppAgent — канал кода для «SM Агент» (код по SMS).
const AppAgent = "agent"

// appAgentRegister — вид токена «билет регистрации».
const appAgentRegister = "agent_register"

// agentTicketTTL — сколько живёт билет регистрации.
const agentTicketTTL = 30 * time.Minute

var (
	errAgentTicket = apperr.Unauthorized("регистрация устарела — введите номер ещё раз").Uz("roʻyxatdan oʻtish eskirdi — raqamni qaytadan kiriting")
	// ErrAgentStoreEmployee — номер уже сотрудник магазина.
	ErrAgentStoreEmployee = apperr.Conflict("store_employee",
		"этот номер — сотрудник магазина. Войдите в «SM Магазин» или зарегистрируйтесь агентом на другой номер").
		Uz("bu raqam doʻkon xodimi. «SM Doʻkon» ilovasiga kiring yoki agent sifatida boshqa raqamdan roʻyxatdan oʻting")
)

// AgentVerifyResult — ответ на код: вход (Tokens) или регистрация (Ticket).
type AgentVerifyResult struct {
	Status string  `json:"status"` // login | register
	Tokens *Tokens `json:"tokens,omitempty"`
	Ticket string  `json:"ticket,omitempty"`
	Phone  string  `json:"phone"`
}

// AgentVerify проверяет код и входит в «SM Агент» или выдаёт билет регистрации.
func (s *Service) AgentVerify(ctx context.Context, rawPhone, code, userAgent string) (AgentVerifyResult, error) {
	ph, err := phone.Normalize(rawPhone)
	if err != nil {
		return AgentVerifyResult{}, apperr.Validation("неверный номер телефона").Uz("telefon raqami notoʻgʻri")
	}
	if err := s.checkCode(ctx, ph, code); err != nil {
		return AgentVerifyResult{}, err
	}
	var (
		userID, kind    string
		active, netLive bool
	)
	err = s.pool.QueryRow(ctx, `
		SELECT u.id, n.kind, e.status = 'active', n.status = 'active'
		FROM users u
		JOIN employees e ON e.user_id = u.id
		JOIN networks n  ON n.id = e.network_id
		WHERE u.phone = $1`, ph).Scan(&userID, &kind, &active, &netLive)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		ticket, err := s.signer.Sign(token.Claims{UserID: ph, App: appAgentRegister}, agentTicketTTL)
		if err != nil {
			return AgentVerifyResult{}, err
		}
		return AgentVerifyResult{Status: "register", Ticket: ticket, Phone: ph}, nil
	case err != nil:
		return AgentVerifyResult{}, err
	case kind != "distributor":
		return AgentVerifyResult{}, ErrAgentStoreEmployee
	case !active || !netLive:
		return AgentVerifyResult{}, errStoreNoAccess
	}
	t, err := s.IssueSession(ctx, userID, AppStore, userAgent)
	if err != nil {
		return AgentVerifyResult{}, err
	}
	return AgentVerifyResult{Status: "login", Tokens: &t, Phone: ph}, nil
}

// AgentTicket проверяет билет регистрации и возвращает номер (E.164).
func (s *Service) AgentTicket(ticket string) (string, error) {
	c, err := s.signer.Verify(ticket)
	if err != nil || c.App != appAgentRegister || c.UserID == "" {
		return "", errAgentTicket
	}
	return c.UserID, nil
}

// IssueSession открывает сессию пользователю в приложении app (после
// регистрации агента или входа по коду).
func (s *Service) IssueSession(ctx context.Context, userID, app, userAgent string) (Tokens, error) {
	var sessionID, refresh string
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var err error
		sessionID, refresh, err = s.createSession(ctx, tx, userID, app, userAgent)
		return err
	})
	if err != nil {
		return Tokens{}, err
	}
	s.rememberLang(ctx, userID, app)
	return s.tokens(userID, sessionID, app, refresh)
}

// errAgentRegistered — номер уже зарегистрирован (повторная отправка формы).
var errAgentRegistered = apperr.New(http.StatusConflict, "already_registered", "этот номер уже зарегистрирован — войдите по коду").
	Uz("bu raqam allaqachon roʻyxatdan oʻtgan — kod orqali kiring")

// ErrAgentRegistered — для пакета supply.
func ErrAgentRegistered() error { return errAgentRegistered }
