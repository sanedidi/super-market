package identity

import (
	"context"
	"crypto/rand"
	"fmt"
	"math/big"

	"github.com/jackc/pgx/v5"
)

// crowdUser — курьер «по пути» входит по телефону: при первом входе
// создаётся пользователь и профиль курьера (нужно согласие с условиями).
func crowdUser(ctx context.Context, tx pgx.Tx, ph string, terms bool) (string, error) {
	var userID string
	if err := tx.QueryRow(ctx, `
		INSERT INTO users (phone) VALUES ($1)
		ON CONFLICT (phone) DO UPDATE SET phone = EXCLUDED.phone
		RETURNING id`, ph).Scan(&userID); err != nil {
		return "", err
	}
	var status string
	err := tx.QueryRow(ctx, `SELECT status FROM crowd_couriers WHERE user_id = $1`, userID).Scan(&status)
	switch {
	case err == nil:
		if status == "blocked" {
			return "", ErrCrowdBlocked
		}
		if terms {
			_, err = tx.Exec(ctx, `UPDATE crowd_couriers SET terms_accepted_at = now() WHERE user_id = $1`, userID)
		}
		return userID, err
	case err != pgx.ErrNoRows:
		return "", err
	}
	if !terms {
		return "", errTermsRequired
	}
	// Код курьера для продавца: KR-xxxxx; при совпадении — другой.
	for range 20 {
		n, err := rand.Int(rand.Reader, big.NewInt(90000))
		if err != nil {
			return "", err
		}
		code := fmt.Sprintf("KR-%05d", n.Int64()+10000)
		tag, err := tx.Exec(ctx, `
			INSERT INTO crowd_couriers (user_id, code, terms_accepted_at) VALUES ($1, $2, now())
			ON CONFLICT (code) DO NOTHING`, userID, code)
		if err != nil {
			return "", err
		}
		if tag.RowsAffected() == 1 {
			return userID, nil
		}
	}
	return "", fmt.Errorf("не удалось выдать код курьера")
}
