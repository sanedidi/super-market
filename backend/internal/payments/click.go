package payments

import (
	"crypto/md5"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Click SHOP API: Click присылает два запроса (form-urlencoded):
//   Prepare  (action=0) — можно ли оплатить заказ;
//   Complete (action=1) — оплата прошла (или отменена, если error < 0).
// Подпись: md5(click_trans_id + service_id + SECRET_KEY + merchant_trans_id
//              [+ merchant_prepare_id] + amount + action + sign_time).

const (
	clickOK            = 0
	clickSignFailed    = -1
	clickBadAmount     = -2
	clickBadAction     = -3
	clickAlreadyPaid   = -4
	clickOrderNotFound = -5
	clickTxNotFound    = -6
	clickBadRequest    = -8
	clickCancelled     = -9
)

var clickNotes = map[int]string{
	clickOK: "Success", clickSignFailed: "SIGN CHECK FAILED!", clickBadAmount: "Incorrect parameter amount",
	clickBadAction: "Action not found", clickAlreadyPaid: "Already paid", clickOrderNotFound: "Order does not exist",
	clickTxNotFound: "Transaction does not exist", clickBadRequest: "Error in request from click",
	clickCancelled: "Transaction cancelled",
}

type clickRequest struct {
	ClickTransID      string
	ServiceID         string
	ClickPaydocID     string
	MerchantTransID   string // id заказа
	MerchantPrepareID string
	Amount            string
	Action            string
	Error             string
	SignTime          string
	SignString        string
}

func readClick(r *http.Request) clickRequest {
	_ = r.ParseForm()
	f := r.PostForm
	return clickRequest{
		ClickTransID: f.Get("click_trans_id"), ServiceID: f.Get("service_id"), ClickPaydocID: f.Get("click_paydoc_id"),
		MerchantTransID: f.Get("merchant_trans_id"), MerchantPrepareID: f.Get("merchant_prepare_id"),
		Amount: f.Get("amount"), Action: f.Get("action"), Error: f.Get("error"),
		SignTime: f.Get("sign_time"), SignString: f.Get("sign_string"),
	}
}

// ClickSign — подпись запроса Click (экспортирована для тестов).
func ClickSign(secret string, r clickRequest) string {
	s := r.ClickTransID + r.ServiceID + secret + r.MerchantTransID
	if r.Action == "1" {
		s += r.MerchantPrepareID
	}
	s += r.Amount + r.Action + r.SignTime
	sum := md5.Sum([]byte(s))
	return hex.EncodeToString(sum[:])
}

func (s *Service) clickRespond(w http.ResponseWriter, r *http.Request, method string, req clickRequest, code int, extra map[string]any) {
	resp := map[string]any{
		"click_trans_id": req.ClickTransID, "merchant_trans_id": req.MerchantTransID,
		"error": code, "error_note": clickNotes[code],
	}
	for k, v := range extra {
		resp[k] = v
	}
	s.logEvent(r.Context(), ProviderClick, method, req, resp)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(resp)
}

func (s *Service) clickCheck(req clickRequest, action string) int {
	if req.Action != action {
		return clickBadAction
	}
	if req.ClickTransID == "" || req.MerchantTransID == "" || req.Amount == "" || req.SignTime == "" {
		return clickBadRequest
	}
	if req.ServiceID != s.cfg.ClickServiceID {
		return clickBadRequest
	}
	want := ClickSign(s.cfg.ClickSecretKey, req)
	if subtle.ConstantTimeCompare([]byte(want), []byte(req.SignString)) != 1 {
		return clickSignFailed
	}
	return clickOK
}

func amountsEqual(a, b string) bool {
	defer func() { _ = recover() }()
	return money.D(a).Cmp(money.D(b)) == 0
}

// ClickPrepareHandler — POST /payments/click/prepare.
func (s *Service) ClickPrepareHandler(w http.ResponseWriter, r *http.Request) {
	req := readClick(r)
	if code := s.clickCheck(req, "0"); code != clickOK {
		s.clickRespond(w, r, "prepare", req, code, nil)
		return
	}
	var code int
	var prepareID int64
	err := db.InTx(r.Context(), s.pool, func(tx pgx.Tx) error {
		// Повтор prepare с тем же click_trans_id — отдаём тот же prepare id.
		var status string
		err := tx.QueryRow(r.Context(), `SELECT seq, status FROM payments WHERE provider = 'click' AND external_id = $1`,
			req.ClickTransID).Scan(&prepareID, &status)
		if err == nil {
			if status == "cancelled" {
				code = clickCancelled
			}
			return nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if !httpx.IsUUID(req.MerchantTransID) {
			code = clickOrderNotFound
			return nil
		}
		if _, err := tx.Exec(r.Context(), `SELECT 1 FROM orders WHERE id = $1 FOR UPDATE`, req.MerchantTransID); err != nil {
			code = clickOrderNotFound
			return nil
		}
		amount, err := s.orders.PayableAmount(r.Context(), tx, req.MerchantTransID)
		if err != nil {
			var paid bool
			_ = tx.QueryRow(r.Context(), `SELECT EXISTS (SELECT 1 FROM payments WHERE order_id = $1 AND status IN ('paid', 'refund_pending'))`,
				req.MerchantTransID).Scan(&paid)
			code = clickOrderNotFound
			if paid {
				code = clickAlreadyPaid
			}
			return nil
		}
		if !amountsEqual(amount, req.Amount) {
			code = clickBadAmount
			return nil
		}
		data, _ := json.Marshal(map[string]string{"click_paydoc_id": req.ClickPaydocID, "sign_time": req.SignTime})
		return tx.QueryRow(r.Context(), `
			INSERT INTO payments (order_id, provider, amount, external_id, provider_data)
			VALUES ($1, 'click', $2::numeric, $3, $4) RETURNING seq`,
			req.MerchantTransID, amount, req.ClickTransID, data).Scan(&prepareID)
	})
	if err != nil {
		s.log.Error("click prepare", "err", err)
		code = clickBadRequest
	}
	extra := map[string]any{}
	if code == clickOK {
		extra["merchant_prepare_id"] = prepareID
	}
	s.clickRespond(w, r, "prepare", req, code, extra)
}

// ClickCompleteHandler — POST /payments/click/complete.
func (s *Service) ClickCompleteHandler(w http.ResponseWriter, r *http.Request) {
	req := readClick(r)
	if code := s.clickCheck(req, "1"); code != clickOK {
		s.clickRespond(w, r, "complete", req, code, nil)
		return
	}
	var code int
	var confirmID int64
	err := db.InTx(r.Context(), s.pool, func(tx pgx.Tx) error {
		var id, orderID, status, amount string
		err := tx.QueryRow(r.Context(), `
			SELECT id, order_id, status, amount::text, seq FROM payments
			WHERE provider = 'click' AND external_id = $1 AND seq::text = $2 FOR UPDATE`,
			req.ClickTransID, req.MerchantPrepareID).Scan(&id, &orderID, &status, &amount, &confirmID)
		if errors.Is(err, pgx.ErrNoRows) {
			code = clickTxNotFound
			return nil
		}
		if err != nil {
			return err
		}
		if orderID != req.MerchantTransID {
			code = clickTxNotFound
			return nil
		}
		switch status {
		case "paid", "refund_pending", "refunded":
			code = clickAlreadyPaid
			return nil
		case "cancelled":
			code = clickCancelled
			return nil
		}
		if !amountsEqual(amount, req.Amount) {
			code = clickBadAmount
			return nil
		}
		// Click сообщает о неудачной оплате отрицательным error.
		if clickErr, _ := strconv.Atoi(req.Error); clickErr < 0 {
			code = clickCancelled
			_, err := tx.Exec(r.Context(), `UPDATE payments SET status = 'cancelled', cancelled_at = now() WHERE id = $1`, id)
			return err
		}
		if _, err := s.orders.PayableAmount(r.Context(), tx, orderID); err != nil {
			// Заказ истёк или отменён, пока клиент платил.
			code = clickCancelled
			_, err := tx.Exec(r.Context(), `UPDATE payments SET status = 'cancelled', cancelled_at = now() WHERE id = $1`, id)
			return err
		}
		if _, err := tx.Exec(r.Context(), `UPDATE payments SET status = 'paid', paid_at = now() WHERE id = $1`, id); err != nil {
			return err
		}
		return s.orders.MarkPaid(r.Context(), tx, orderID)
	})
	if err != nil {
		s.log.Error("click complete", "err", err)
		code = clickBadRequest
	}
	extra := map[string]any{}
	if code == clickOK {
		extra["merchant_confirm_id"] = confirmID
	}
	s.clickRespond(w, r, "complete", req, code, extra)
}

// ClickRequestForTest собирает запрос Click (для тестов других пакетов).
func ClickRequestForTest(transID, serviceID, orderID, prepareID, amount, action, signTime string) clickRequest {
	return clickRequest{ClickTransID: transID, ServiceID: serviceID, MerchantTransID: orderID,
		MerchantPrepareID: prepareID, Amount: amount, Action: action, SignTime: signTime}
}
