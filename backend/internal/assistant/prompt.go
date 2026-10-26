package assistant

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/invoices"
)

// promptContext — что модель должна знать о магазине и разговоре.
type promptContext struct {
	Today     string   `json:"today"`
	Store     string   `json:"store"`
	Lang      string   `json:"ui_lang"`
	Suppliers []string `json:"suppliers"`
	// Stores — магазины сети {id, name}; текущий — Store/StoreID.
	StoreID string              `json:"store_id"`
	Stores  []map[string]string `json:"stores,omitempty"`
	Scan    *scanContext        `json:"current_scan,omitempty"`
	Recent  []recentMessage     `json:"recent_messages"`
	Message string              `json:"owner_message,omitempty"`
	Hints   map[string]string   `json:"hints,omitempty"`
}

type scanContext struct {
	ID       string            `json:"id"`
	Supplier string            `json:"supplier"`
	Number   string            `json:"number"`
	Total    string            `json:"total"`
	Lines    int               `json:"lines"`
	Open     []scanLineContext `json:"lines_need_answer"`
}

type scanLineContext struct {
	Line  int    `json:"line"`
	Name  string `json:"name"`
	Qty   string `json:"qty"`
	Unit  string `json:"unit"`
	State string `json:"state"` // missing — товар не найден; pack — блоки или штуки?; check — проверить цену
	Pack  string `json:"pack_guess,omitempty"`
}

type recentMessage struct {
	Role string `json:"role"`
	Text string `json:"text"`
}

// buildPrompt — контекст для модели: магазин, поставщики, текущая накладная,
// последние реплики и само сообщение.
func (s *Service) buildPrompt(ctx context.Context, p *identity.Principal, storeID, lang, text string, sc *invoices.Scan) (string, error) {
	pc := promptContext{Today: s.now().In(tashkent).Format("2006-01-02"), Lang: lang, Suppliers: []string{}, Recent: []recentMessage{}, Message: text}
	pc.StoreID = storeID
	_ = s.pool.QueryRow(ctx, `SELECT name FROM stores WHERE id = $1`, storeID).Scan(&pc.Store)
	if srows, err := s.pool.Query(ctx, `SELECT id, name FROM stores WHERE network_id = $1 AND is_active ORDER BY name LIMIT 20`, p.NetworkID); err == nil {
		for srows.Next() {
			var id, name string
			if srows.Scan(&id, &name) == nil && p.CanAccessStore(id) {
				pc.Stores = append(pc.Stores, map[string]string{"id": id, "name": name})
			}
		}
		srows.Close()
	}
	rows, err := s.pool.Query(ctx, `SELECT name FROM counterparties WHERE network_id = $1 AND is_active ORDER BY name LIMIT 30`, p.NetworkID)
	if err != nil {
		return "", err
	}
	for rows.Next() {
		var n string
		if rows.Scan(&n) == nil {
			pc.Suppliers = append(pc.Suppliers, n)
		}
	}
	rows.Close()
	rows, err = s.pool.Query(ctx, `
		SELECT role, CASE WHEN role = 'owner' AND transcript IS NOT NULL THEN transcript ELSE text END
		FROM assistant_messages WHERE store_id = $1 AND employee_id = $2 AND status = 'done' AND role <> 'system' AND text <> ''
		ORDER BY created_at DESC LIMIT 10`, storeID, p.EmployeeID)
	if err != nil {
		return "", err
	}
	for rows.Next() {
		var m recentMessage
		if rows.Scan(&m.Role, &m.Text) == nil {
			if r := []rune(m.Text); len(r) > 300 {
				m.Text = string(r[:300]) + "…"
			}
			pc.Recent = append([]recentMessage{m}, pc.Recent...)
		}
	}
	rows.Close()
	if sc != nil && sc.Status == invoices.StatusReady {
		c := &scanContext{ID: sc.ID, Supplier: sc.SupplierName, Number: sc.InvoiceNumber, Total: sc.LinesTotal, Lines: len(sc.Lines), Open: []scanLineContext{}}
		if sc.CounterpartyName != nil {
			c.Supplier = *sc.CounterpartyName
		}
		for _, l := range sc.Lines {
			if l.State == "missing" || l.State == "pack" || l.State == "check" {
				lc := scanLineContext{Line: l.Line, Name: l.Name, Qty: l.Qty, Unit: l.Unit, State: l.State}
				if l.State == "pack" {
					lc.Pack = l.Pack
				}
				c.Open = append(c.Open, lc)
			}
		}
		pc.Scan = c
	}
	b, err := json.Marshal(pc)
	if err != nil {
		return "", err
	}
	var sb strings.Builder
	sb.WriteString("Контекст (JSON):\n")
	sb.Write(b)
	if text == "" {
		sb.WriteString("\n\nСообщение владельца — во вложенном аудио.")
	} else {
		sb.WriteString(fmt.Sprintf("\n\nСообщение владельца: %q", text))
	}
	return sb.String(), nil
}

var tashkent = time.FixedZone("Asia/Tashkent", 5*60*60)
