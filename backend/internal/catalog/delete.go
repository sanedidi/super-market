package catalog

import (
	"context"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// Удаление в каталоге (Figma «Веб-панели · удаление»): удаляем, только если
// запись нигде не используется, иначе 409 in_use — «Отключите вместо удаления».

// DeleteDict — бренд, категория, цвет или единица.
func (s *Service) DeleteDict(ctx context.Context, kind, id string) error {
	d, ok := dicts[kind]
	if !ok {
		return apperr.NotFound("справочник не найден").Uz("maʼlumotnoma topilmadi")
	}
	rs, rsUz := []rune(d.title), []rune(d.titleUz)
	title := i18n.Text{RU: strings.ToUpper(string(rs[0])) + string(rs[1:]), UZ: strings.ToUpper(string(rsUz[0])) + string(rsUz[1:])}
	return db.Remove(ctx, s.pool, title, true, `DELETE FROM `+d.table+` WHERE id = $1`, id)
}

// deleteProduct — товар и его настройки (цены, избранное, PLU, акции);
// если товар уже в остатках, продажах или документах — 409.
// networkID пустой — супер-админ (все сети).
func (s *Service) deleteProduct(ctx context.Context, networkID, id string) error {
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var net *string
		if err := tx.QueryRow(ctx, `SELECT network_id::text FROM products WHERE id = $1 FOR UPDATE`, id).Scan(&net); err != nil {
			if err == pgx.ErrNoRows {
				return apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
			}
			return err
		}
		if networkID != "" && (net == nil || *net != networkID) {
			return apperr.Forbidden("удалить можно только свой товар — товар общего каталога удаляет супер-админ").Uz("faqat oʻz mahsulotingizni oʻchirish mumkin — umumiy katalog mahsulotini super-admin oʻchiradi")
		}
		var nf *string
		if networkID != "" {
			nf = &networkID
		}
		for _, q := range []string{
			`DELETE FROM prices WHERE product_id = $1 AND ($2::uuid IS NULL OR network_id = $2)`,
			`DELETE FROM pos_plu WHERE product_id = $1 AND ($2::uuid IS NULL OR network_id = $2)`,
			`DELETE FROM promotion_items i USING promotions p
			  WHERE i.promotion_id = p.id AND i.product_id = $1 AND ($2::uuid IS NULL OR p.network_id = $2)`,
		} {
			if _, err := tx.Exec(ctx, q, id, nf); err != nil {
				return err
			}
		}
		for _, q := range []string{
			`DELETE FROM favorites WHERE product_id = $1`,
			`DELETE FROM product_popularity WHERE product_id = $1`,
		} {
			if _, err := tx.Exec(ctx, q, id); err != nil {
				return err
			}
		}
		return db.Remove(ctx, tx, i18n.Text{RU: "Товар", UZ: "Mahsulot"}, true, `DELETE FROM products WHERE id = $1`, id)
	})
}

func (s *Service) AdminDeleteProduct(ctx context.Context, id string) error {
	return s.deleteProduct(ctx, "", id)
}

func (s *Service) StoreDeleteProduct(ctx context.Context, pr *identity.Principal, id string) error {
	if err := pr.Require(identity.PermCatalogManage); err != nil {
		return err
	}
	return s.deleteProduct(ctx, pr.NetworkID, id)
}

func (s *Service) DeletePriceType(ctx context.Context, pr *identity.Principal, id string) error {
	if err := pr.Require(identity.PermCatalogManage); err != nil {
		return err
	}
	var def bool
	if err := s.pool.QueryRow(ctx, `SELECT is_default FROM price_types WHERE id = $1 AND network_id = $2`, id, pr.NetworkID).Scan(&def); err == nil && def {
		return apperr.Conflict("default_price_type", "Тип цен по умолчанию удалить нельзя — сначала сделайте основным другой").Uz("Asosiy narx turini oʻchirib boʻlmaydi — avval boshqasini asosiy qiling")
	}
	return db.Remove(ctx, s.pool, i18n.Text{RU: "Тип цен", UZ: "Narx turi"}, true, `DELETE FROM price_types WHERE id = $1 AND network_id = $2`, id, pr.NetworkID)
}

// DeletePriceDoc — только черновик; проведённая установка цен остаётся в истории.
func (s *Service) DeletePriceDoc(ctx context.Context, pr *identity.Principal, id string) error {
	if err := pr.Require(identity.PermPricesManage); err != nil {
		return err
	}
	var status string
	if err := s.pool.QueryRow(ctx, `SELECT status FROM price_documents WHERE id = $1 AND network_id = $2`, id, pr.NetworkID).Scan(&status); err == nil && status != "draft" {
		return apperr.Conflict("document_posted", "Проведённый документ удалить нельзя — он уже изменил цены").Uz("Oʻtkazilgan hujjatni oʻchirib boʻlmaydi — u narxlarni allaqachon oʻzgartirgan")
	}
	return db.Remove(ctx, s.pool, i18n.Text{RU: "Документ", UZ: "Hujjat"}, false, `DELETE FROM price_documents WHERE id = $1 AND network_id = $2 AND status = 'draft'`, id, pr.NetworkID)
}

func (s *Service) DeletePromotion(ctx context.Context, pr *identity.Principal, id string) error {
	if err := pr.Require(identity.PermPricesManage); err != nil {
		return err
	}
	return db.Remove(ctx, s.pool, i18n.Text{RU: "Акция", UZ: "Aksiya"}, true, `DELETE FROM promotions WHERE id = $1 AND network_id = $2`, id, pr.NetworkID)
}

// DeleteBanner — баннер платформы (супер-админ) или свой баннер сети.
func (s *Service) DeleteBanner(ctx context.Context, networkID *string, id string) error {
	return db.Remove(ctx, s.pool, i18n.Text{RU: "Баннер", UZ: "Banner"}, true,
		`DELETE FROM banners WHERE id = $1 AND network_id IS NOT DISTINCT FROM $2::uuid`, id, networkID)
}

func (m *Module) deleteDict(w http.ResponseWriter, r *http.Request) {
	httpx.Delete(w, r, m.log, func(id string) error { return m.svc.DeleteDict(r.Context(), chi.URLParam(r, "kind"), id) })
}

func (m *Module) adminDeleteProduct(w http.ResponseWriter, r *http.Request) {
	httpx.Delete(w, r, m.log, func(id string) error { return m.svc.AdminDeleteProduct(r.Context(), id) })
}

func (m *Module) adminDeleteBanner(w http.ResponseWriter, r *http.Request) {
	httpx.Delete(w, r, m.log, func(id string) error { return m.svc.DeleteBanner(r.Context(), nil, id) })
}

func (m *Module) storeDeleteBanner(w http.ResponseWriter, r *http.Request) {
	httpx.Delete(w, r, m.log, func(id string) error {
		n := pr(r).NetworkID
		return m.svc.DeleteBanner(r.Context(), &n, id)
	})
}

func (m *Module) storeDel(fn func(context.Context, *identity.Principal, string) error) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		httpx.Delete(w, r, m.log, func(id string) error { return fn(r.Context(), pr(r), id) })
	}
}
