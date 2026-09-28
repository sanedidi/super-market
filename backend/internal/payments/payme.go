package payments

import (
	"context"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Payme Merchant API: Payme вызывает наш адрес методами JSON-RPC.
// Суммы — в тийинах, время — миллисекунды Unix.
//
// Состояния транзакции Payme: 1 — создана, 2 — проведена,
// -1 — отменена до проведения, -2 — отменена после проведения (возврат).

type paymeRequest struct {
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
	ID     any             `json:"id"`
}

type paymeError struct {
	Code    int               `json:"code"`
	Message map[string]string `json:"message"`
	Data    string            `json:"data,omitempty"`
}

func perr(code int, ru, data string) *paymeError {
	return &paymeError{Code: code, Message: map[string]string{"ru": ru, "uz": ru, "en": ru}, Data: data}
}

var (
	errPaymeAuth         = perr(-32504, "Недостаточно привилегий", "")
	errPaymeParse        = perr(-32700, "Ошибка разбора JSON", "")
	errPaymeMethod       = perr(-32601, "Метод не найден", "")
	errPaymeAmount       = perr(-31001, "Неверная сумма", "amount")
	errPaymeOrder        = perr(-31050, "Заказ не найден или уже оплачен", "order_id")
	errPaymeBusy         = perr(-31099, "Заказ ожидает оплаты в другой транзакции", "order_id")
	errPaymeNotFound     = perr(-31003, "Транзакция не найдена", "")
	errPaymeCannot       = perr(-31008, "Невозможно выполнить операцию", "")
	errPaymeCannotCancel = perr(-31007, "Заказ уже выполнен, отмена невозможна", "")
	errPaymeInternal     = perr(-32400, "Системная ошибка", "")
)

// PaymeHandler — точка входа для Payme (POST /payments/payme).
func (s *Service) PaymeHandler(w http.ResponseWriter, r *http.Request) {
	var req paymeRequest
	respond := func(result any, perr *paymeError) {
		resp := map[string]any{"jsonrpc": "2.0", "id": req.ID}
		if perr != nil {
			resp["error"] = perr
		} else {
			resp["result"] = result
		}
		s.logEvent(r.Context(), ProviderPayme, req.Method, req, resp)
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(resp)
	}

	if !s.paymeAuthorized(r) {
		respond(nil, errPaymeAuth)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil || json.Unmarshal(body, &req) != nil {
		respond(nil, errPaymeParse)
		return
	}
	result, perr := s.paymeDispatch(r.Context(), req)
	respond(result, perr)
}

func (s *Service) paymeAuthorized(r *http.Request) bool {
	raw, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Basic ")
	if !ok || s.cfg.PaymeKey == "" {
		return false
	}
	decoded, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		return false
	}
	_, key, ok := strings.Cut(string(decoded), ":")
	return ok && subtle.ConstantTimeCompare([]byte(key), []byte(s.cfg.PaymeKey)) == 1
}

type paymeParams struct {
	ID      string            `json:"id"`
	Time    int64             `json:"time"`
	Amount  int64             `json:"amount"`
	Account map[string]string `json:"account"`
	Reason  *int              `json:"reason"`
	From    int64             `json:"from"`
	To      int64             `json:"to"`
}

func (s *Service) paymeDispatch(ctx context.Context, req paymeRequest) (any, *paymeError) {
	var p paymeParams
	if len(req.Params) > 0 {
		if err := json.Unmarshal(req.Params, &p); err != nil {
			return nil, errPaymeParse
		}
	}
	var result any
	var pe *paymeError
	var err error
	switch req.Method {
	case "CheckPerformTransaction":
		result, pe, err = s.paymeCheckPerform(ctx, p)
	case "CreateTransaction":
		result, pe, err = s.paymeCreate(ctx, p)
	case "PerformTransaction":
		result, pe, err = s.paymePerform(ctx, p)
	case "CancelTransaction":
		result, pe, err = s.paymeCancel(ctx, p)
	case "CheckTransaction":
		result, pe, err = s.paymeCheck(ctx, p)
	case "GetStatement":
		result, pe, err = s.paymeStatement(ctx, p)
	default:
		return nil, errPaymeMethod
	}
	if err != nil {
		s.log.Error("payme", "method", req.Method, "err", err)
		return nil, errPaymeInternal
	}
	return result, pe
}

// checkOrder: заказ ждёт оплаты и сумма совпадает (в тийинах).
func (s *Service) paymeCheckOrder(ctx context.Context, q db.Querier, p paymeParams) (string, *paymeError, error) {
	orderID := p.Account["order_id"]
	if !httpx.IsUUID(orderID) {
		return "", errPaymeOrder, nil
	}
	amount, err := s.orders.PayableAmount(ctx, q, orderID)
	if err != nil {
		return "", errPaymeOrder, nil
	}
	if money.D(amount).Mul(money.D("100")).Fixed(0) != money.D(itoa64(p.Amount)).Fixed(0) {
		return "", errPaymeAmount, nil
	}
	return orderID, nil, nil
}

func (s *Service) paymeCheckPerform(ctx context.Context, p paymeParams) (any, *paymeError, error) {
	if _, pe, err := s.paymeCheckOrder(ctx, s.pool, p); pe != nil || err != nil {
		return nil, pe, err
	}
	return map[string]bool{"allow": true}, nil, nil
}

type paymeTx struct {
	ID          string
	OrderID     string
	Status      string
	Data        paymeData
	AmountTiyin int64
}

type paymeData struct {
	Time        int64             `json:"time"`
	CreateTime  int64             `json:"create_time"`
	PerformTime int64             `json:"perform_time"`
	CancelTime  int64             `json:"cancel_time"`
	State       int               `json:"state"`
	Reason      *int              `json:"reason"`
	Account     map[string]string `json:"account"`
}

func (s *Service) paymeFind(ctx context.Context, q db.Querier, externalID string, lock bool) (*paymeTx, error) {
	sql := `SELECT id, order_id, status, provider_data, (amount * 100)::bigint FROM payments WHERE provider = 'payme' AND external_id = $1`
	if lock {
		sql += " FOR UPDATE"
	}
	var t paymeTx
	var raw []byte
	err := q.QueryRow(ctx, sql, externalID).Scan(&t.ID, &t.OrderID, &t.Status, &raw, &t.AmountTiyin)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	err = json.Unmarshal(raw, &t.Data)
	return &t, err
}

func (s *Service) nowMs() int64 { return s.now().UnixMilli() }

func (s *Service) saveData(ctx context.Context, tx pgx.Tx, id, status string, d paymeData) error {
	raw, _ := json.Marshal(d)
	_, err := tx.Exec(ctx, `UPDATE payments SET status = $2, provider_data = $3,
		paid_at = CASE WHEN $2 = 'paid' AND paid_at IS NULL THEN now() ELSE paid_at END,
		cancelled_at = CASE WHEN $2 = 'cancelled' THEN now() ELSE cancelled_at END,
		refunded_at = CASE WHEN $2 = 'refunded' THEN now() ELSE refunded_at END
		WHERE id = $1`, id, status, raw)
	return err
}

func (s *Service) paymeCreate(ctx context.Context, p paymeParams) (any, *paymeError, error) {
	var result any
	var pe *paymeError
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		t, err := s.paymeFind(ctx, tx, p.ID, true)
		if err != nil {
			return err
		}
		if t != nil {
			if t.Data.State != 1 {
				pe = errPaymeCannot
				return nil
			}
			if s.nowMs()-t.Data.Time > s.cfg.PaymeTimeout.Milliseconds() {
				reason := 4
				t.Data.State, t.Data.CancelTime, t.Data.Reason = -1, s.nowMs(), &reason
				pe = errPaymeCannot
				return s.saveData(ctx, tx, t.ID, "cancelled", t.Data)
			}
			result = map[string]any{"create_time": t.Data.CreateTime, "transaction": t.ID, "state": 1}
			return nil
		}

		// Блокируем заказ, чтобы по нему не создали две транзакции одновременно.
		if !httpx.IsUUID(p.Account["order_id"]) {
			pe = errPaymeOrder
			return nil
		}
		if _, err := tx.Exec(ctx, `SELECT 1 FROM orders WHERE id = $1 FOR UPDATE`, p.Account["order_id"]); err != nil {
			return err
		}
		orderID, cpe, err := s.paymeCheckOrder(ctx, tx, p)
		if cpe != nil || err != nil {
			pe = cpe
			return err
		}
		var busy bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM payments WHERE order_id = $1 AND status = 'created' AND provider = 'payme')`,
			orderID).Scan(&busy); err != nil {
			return err
		}
		if busy {
			pe = errPaymeBusy
			return nil
		}
		d := paymeData{Time: p.Time, CreateTime: s.nowMs(), State: 1, Account: p.Account}
		raw, _ := json.Marshal(d)
		var id string
		if err := tx.QueryRow(ctx, `
			INSERT INTO payments (order_id, provider, amount, external_id, provider_data)
			VALUES ($1, 'payme', $2::numeric / 100, $3, $4) RETURNING id`,
			orderID, itoa64(p.Amount), p.ID, raw).Scan(&id); err != nil {
			return err
		}
		result = map[string]any{"create_time": d.CreateTime, "transaction": id, "state": 1}
		return nil
	})
	return result, pe, err
}

func (s *Service) paymePerform(ctx context.Context, p paymeParams) (any, *paymeError, error) {
	var result any
	var pe *paymeError
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		t, err := s.paymeFind(ctx, tx, p.ID, true)
		if err != nil {
			return err
		}
		if t == nil {
			pe = errPaymeNotFound
			return nil
		}
		switch t.Data.State {
		case 1:
			if s.nowMs()-t.Data.Time > s.cfg.PaymeTimeout.Milliseconds() {
				reason := 4
				t.Data.State, t.Data.CancelTime, t.Data.Reason = -1, s.nowMs(), &reason
				pe = errPaymeCannot
				return s.saveData(ctx, tx, t.ID, "cancelled", t.Data)
			}
			if _, err := s.orders.PayableAmount(ctx, tx, t.OrderID); err != nil {
				pe = errPaymeCannot
				return nil
			}
			t.Data.State, t.Data.PerformTime = 2, s.nowMs()
			if err := s.saveData(ctx, tx, t.ID, "paid", t.Data); err != nil {
				return err
			}
			if err := s.orders.MarkPaid(ctx, tx, t.OrderID); err != nil {
				return err
			}
		case 2:
		default:
			pe = errPaymeCannot
			return nil
		}
		result = map[string]any{"transaction": t.ID, "perform_time": t.Data.PerformTime, "state": 2}
		return nil
	})
	return result, pe, err
}

func (s *Service) paymeCancel(ctx context.Context, p paymeParams) (any, *paymeError, error) {
	var result any
	var pe *paymeError
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		t, err := s.paymeFind(ctx, tx, p.ID, true)
		if err != nil {
			return err
		}
		if t == nil {
			pe = errPaymeNotFound
			return nil
		}
		switch t.Data.State {
		case 1:
			t.Data.State, t.Data.CancelTime, t.Data.Reason = -1, s.nowMs(), p.Reason
			if err := s.saveData(ctx, tx, t.ID, "cancelled", t.Data); err != nil {
				return err
			}
		case 2:
			ok, err := s.orders.CanRefund(ctx, tx, t.OrderID)
			if err != nil {
				return err
			}
			if !ok {
				pe = errPaymeCannotCancel
				return nil
			}
			t.Data.State, t.Data.CancelTime, t.Data.Reason = -2, s.nowMs(), p.Reason
			if err := s.saveData(ctx, tx, t.ID, "refunded", t.Data); err != nil {
				return err
			}
			if err := s.orders.Refunded(ctx, tx, t.OrderID); err != nil {
				return err
			}
		}
		result = map[string]any{"transaction": t.ID, "cancel_time": t.Data.CancelTime, "state": t.Data.State}
		return nil
	})
	return result, pe, err
}

func (s *Service) paymeCheck(ctx context.Context, p paymeParams) (any, *paymeError, error) {
	t, err := s.paymeFind(ctx, s.pool, p.ID, false)
	if err != nil {
		return nil, nil, err
	}
	if t == nil {
		return nil, errPaymeNotFound, nil
	}
	return map[string]any{
		"create_time": t.Data.CreateTime, "perform_time": t.Data.PerformTime, "cancel_time": t.Data.CancelTime,
		"transaction": t.ID, "state": t.Data.State, "reason": t.Data.Reason,
	}, nil, nil
}

func (s *Service) paymeStatement(ctx context.Context, p paymeParams) (any, *paymeError, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT external_id, id, (amount * 100)::bigint, provider_data FROM payments
		WHERE provider = 'payme' AND (provider_data ->> 'time')::bigint BETWEEN $1 AND $2
		ORDER BY (provider_data ->> 'time')::bigint`, p.From, p.To)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	list := []map[string]any{}
	for rows.Next() {
		var ext, id string
		var amount int64
		var raw []byte
		if err := rows.Scan(&ext, &id, &amount, &raw); err != nil {
			return nil, nil, err
		}
		var d paymeData
		_ = json.Unmarshal(raw, &d)
		list = append(list, map[string]any{
			"id": ext, "time": d.Time, "amount": amount, "account": d.Account,
			"create_time": d.CreateTime, "perform_time": d.PerformTime, "cancel_time": d.CancelTime,
			"transaction": id, "state": d.State, "reason": d.Reason,
		})
	}
	return map[string]any{"transactions": list}, nil, rows.Err()
}

func itoa64(n int64) string { return strconv.FormatInt(n, 10) }
