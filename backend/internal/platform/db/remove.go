package db

import (
	"context"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
)

// Remove удаляет запись: sql — DELETE с условием на id и сеть.
// Ничего не удалено — 404. На запись ссылаются документы или другие
// записи (внешний ключ) — 409 in_use: историю не теряем; deactivate —
// у записи есть «Отключить», веб предложит его вместо удаления.
func Remove(ctx context.Context, q Querier, what string, deactivate bool, sql string, args ...any) error {
	tag, err := q.Exec(ctx, sql, args...)
	if IsForeignKeyViolation(err) {
		msg := what + " уже используется в документах или других записях — удалить нельзя, чтобы не потерять историю."
		if deactivate {
			msg += " Отключите вместо удаления."
		}
		return apperr.Conflict("in_use", msg).WithDetails(map[string]any{"deactivate": deactivate})
	}
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.NotFound("запись не найдена")
	}
	return nil
}
