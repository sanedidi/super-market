package identity

import (
	"context"
	"crypto/rand"
	"fmt"
	"math/big"

	"github.com/jackc/pgx/v5"
)

// ReleasePhone освобождает номер удалённого аккаунта, если у пользователя не
// осталось других ролей: покупателя, курьера «по пути», сотрудника или
// супер-админа. Номер меняется на +999…, имя стирается, привязка к боту и
// коды входа удаляются — новый вход с этим номером создаст новый аккаунт.
// Если роль осталась, номер нужен для входа и не трогается.
func ReleasePhone(ctx context.Context, tx pgx.Tx, userID string) error {
	var keep bool
	if err := tx.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM employees WHERE user_id = $1)
		    OR EXISTS (SELECT 1 FROM platform_admins WHERE user_id = $1)
		    OR EXISTS (SELECT 1 FROM customers WHERE user_id = $1 AND deleted_at IS NULL)
		    OR EXISTS (SELECT 1 FROM crowd_couriers WHERE user_id = $1 AND deleted_at IS NULL)`, userID).Scan(&keep); err != nil {
		return err
	}
	if keep {
		return nil
	}
	tomb, err := tombstonePhone()
	if err != nil {
		return err
	}
	for _, q := range []string{
		`DELETE FROM telegram_links WHERE phone = (SELECT phone FROM users WHERE id = $1)`,
		`DELETE FROM auth_codes WHERE phone = (SELECT phone FROM users WHERE id = $1)`,
	} {
		if _, err := tx.Exec(ctx, q, userID); err != nil {
			return err
		}
	}
	_, err = tx.Exec(ctx, `UPDATE users SET full_name = '', phone = $2 WHERE id = $1`, userID, tomb)
	return err
}

// tombstonePhone — номер вида +999…: код +999 не выдаётся ни одной стране.
func tombstonePhone() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("+999%012d", n.Int64()), nil
}
