package start

import (
	"context"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/ai"
	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

// Дерево категорий для подсказок Super Market (товар из каталога ИКПУ, новый
// товар по фото): разделы и подкатегории, проверка ответа модели.

type treeNode struct {
	id, parentID, name, nameUz string
}

type catTree struct {
	nodes []treeNode
	byID  map[string]treeNode
}

func loadTree(ctx context.Context, q db.Querier) (*catTree, error) {
	rows, err := q.Query(ctx, `SELECT id::text, COALESCE(parent_id::text, ''), name, name_uz FROM categories WHERE is_active ORDER BY sort, name`)
	if err != nil {
		return nil, err
	}
	nodes, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (treeNode, error) {
		var n treeNode
		err := r.Scan(&n.id, &n.parentID, &n.name, &n.nameUz)
		return n, err
	})
	if err != nil {
		return nil, err
	}
	t := &catTree{nodes: nodes, byID: map[string]treeNode{}}
	for _, n := range nodes {
		t.byID[n.id] = n
	}
	return t, nil
}

// ref — подкатегория (второй уровень) с разделом; nil — нет такой.
func (t *catTree) ref(id string) *CategoryRef {
	n, ok := t.byID[strings.TrimSpace(id)]
	if !ok || n.parentID == "" {
		return nil
	}
	sec, ok := t.byID[n.parentID]
	if !ok || sec.parentID != "" {
		return nil
	}
	return &CategoryRef{ID: n.id, Section: sec.name, SectionUz: sec.nameUz, Name: n.name, NameUz: n.nameUz}
}

func (t *catTree) sections() []ai.CategoryOption {
	out := []ai.CategoryOption{}
	for _, n := range t.nodes {
		if n.parentID == "" {
			out = append(out, ai.CategoryOption{ID: n.id, Path: n.name, PathUz: n.nameUz})
		}
	}
	return out
}

func (t *catTree) leaves() []ai.CategoryOption {
	out := []ai.CategoryOption{}
	for _, n := range t.nodes {
		if r := t.ref(n.id); r != nil {
			out = append(out, ai.CategoryOption{ID: r.ID, Path: r.Section + " / " + r.Name, PathUz: r.SectionUz + " / " + r.NameUz})
		}
	}
	return out
}

// paths — «Раздел / Подкатегория» для id подкатегорий.
func (t *catTree) paths(ids []string) []string {
	out := []string{}
	for _, id := range ids {
		if r := t.ref(id); r != nil {
			out = append(out, r.Section+" / "+r.Name)
		}
	}
	return out
}

// suggestion — проверенный ответ модели: подкатегория из дерева, до двух
// запасных, иначе — новая подкатегория (в существующем разделе, если он есть).
func (t *catTree) suggestion(match string, alternatives []string, nw *ai.NewCategoryAnswer) *CategorySuggestion {
	out := &CategorySuggestion{Alternatives: []CategoryRef{}}
	out.Category = t.ref(match)
	for _, id := range alternatives {
		r := t.ref(id)
		if r == nil || (out.Category != nil && r.ID == out.Category.ID) || len(out.Alternatives) >= 2 {
			continue
		}
		dup := false
		for _, a := range out.Alternatives {
			dup = dup || a.ID == r.ID
		}
		if !dup {
			out.Alternatives = append(out.Alternatives, *r)
		}
	}
	if out.Category == nil && nw != nil && strings.TrimSpace(nw.Name) != "" {
		nc := &catalog.NewCategory{Name: strings.TrimSpace(nw.Name), NameUz: strings.TrimSpace(nw.NameUz)}
		if sec, ok := t.byID[strings.TrimSpace(nw.ParentID)]; ok && sec.parentID == "" {
			id := sec.id
			nc.ParentID, nc.ParentName, nc.ParentNameUz = &id, sec.name, sec.nameUz
		} else if pn := strings.TrimSpace(nw.ParentName); pn != "" {
			nc.ParentName, nc.ParentNameUz = pn, strings.TrimSpace(nw.ParentNameUz)
			// Раздел с таким названием уже есть — новая подкатегория в нём.
			for _, n := range t.nodes {
				if n.parentID == "" && strings.EqualFold(n.name, pn) {
					id := n.id
					nc.ParentID, nc.ParentName, nc.ParentNameUz = &id, n.name, n.nameUz
					break
				}
			}
		} else {
			nc = nil
		}
		// «Новая» подкатегория уже есть в этом разделе — это совпадение.
		if nc != nil && nc.ParentID != nil {
			for _, n := range t.nodes {
				if n.parentID == *nc.ParentID && strings.EqualFold(n.name, nc.Name) {
					out.Category, nc = t.ref(n.id), nil
					break
				}
			}
		}
		out.New = nc
	}
	if out.Category == nil && out.New == nil && len(out.Alternatives) > 0 {
		first := out.Alternatives[0]
		out.Category, out.Alternatives = &first, out.Alternatives[1:]
	}
	return out
}
