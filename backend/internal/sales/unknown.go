package sales

import (
	"context"
	"errors"
	"regexp"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

// KindUnknown — служебный товар сети «Неизвестный товар»: на него ссылаются
// строки чеков, которые касса пробила по штрихкоду, которого нет ни в
// магазине, ни в Super Market (штрихкод и название — в строке).
const KindUnknown = "unknown"

// UnknownCategoryID — служебная категория для него (миграция 0073).
const UnknownCategoryID = "00000000-0000-0000-0000-00000000c0de"

// Штрихкод — как в product_barcodes.
var unknownBarcodeRe = regexp.MustCompile(`^[0-9A-Za-z-]{4,32}$`)

// UnknownProduct — id «Неизвестного товара» сети; нет — создаётся (не в
// продаже, без остатков, в каталогах и на кассе как товар его нет).
func UnknownProduct(ctx context.Context, q db.Querier, networkID string) (string, error) {
	var id string
	err := q.QueryRow(ctx, `SELECT id FROM products WHERE network_id = $1 AND kind = 'unknown'`, networkID).Scan(&id)
	if err == nil {
		return id, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return "", err
	}
	if _, err := q.Exec(ctx, `
		INSERT INTO products (network_id, proposed_by, name, name_uz, category_id, unit_id, base_price, moderation_status, kind, is_active, vat_rate)
		SELECT $1, $1, 'Неизвестный товар', 'Nomaʼlum mahsulot', $2, u.id, 0, 'approved', 'unknown', false, 0
		FROM units u WHERE NOT u.is_fractional ORDER BY (u.short_name = 'шт') DESC, u.name LIMIT 1
		ON CONFLICT (network_id) WHERE kind = 'unknown' DO NOTHING`, networkID, UnknownCategoryID); err != nil {
		return "", err
	}
	err = q.QueryRow(ctx, `SELECT id FROM products WHERE network_id = $1 AND kind = 'unknown'`, networkID).Scan(&id)
	return id, err
}
