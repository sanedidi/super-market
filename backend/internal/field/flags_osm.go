package field

import (
	"context"
	"regexp"
	"strings"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
)

// Импорт флажков «зайти потом» из OpenStreetMap: продуктовые магазины
// Ташкента с открытой карты (© участники OpenStreetMap, ODbL). Данные
// скачивает браузер супер-админа (Overpass API), сервер решает, что ставить:
// только продуктовые, без сетей, внутри 12 районов, не рядом с уже
// отмеченными магазинами, магазинами Super Market и флажками продажников (15 м).

// osmNearM — ближе к отметке, магазину Super Market или флажку продажника — это та же
// точка (соседние магазины в одном доме ставим: они дальше).
const osmNearM = 15

// maxOSMImport — сколько объектов карты за один запрос.
const maxOSMImport = 5000

// osmFoodShops — продуктовые типы магазинов OSM (shop=…).
var osmFoodShops = map[string]bool{
	"supermarket": true, "convenience": true, "grocery": true, "general": true,
	"food": true, "greengrocer": true, "dairy": true,
}

// osmChains — сети: им Super Market не продаём (у них свои системы).
var osmChains = []*regexp.Regexp{
	regexp.MustCompile(`korzinka|корзинка`),
	regexp.MustCompile(`havas|хавас`),
	regexp.MustCompile(`makro|макро`),
	regexp.MustCompile(`^(olma|олма)(\s|$)`),
	regexp.MustCompile(`carrefour|карфур`),
	regexp.MustCompile(`^(baraka|барака)( market| supermarket| маркет)?$`),
	regexp.MustCompile(`^(baraka market|барака маркет)`),
	regexp.MustCompile(`^(tegen|теген)`),
	regexp.MustCompile(`молочный домик`),
	regexp.MustCompile(`^лукошко`),
	regexp.MustCompile(`^smart$`),
	regexp.MustCompile(`pepsi market`),
	regexp.MustCompile(`family market`),
	regexp.MustCompile(`andalus|андалус`),
	regexp.MustCompile(`прайм тайм|prime time`),
	regexp.MustCompile(`meat boutique`),
	regexp.MustCompile(`^магнит$`),
	regexp.MustCompile(`city market`),
	regexp.MustCompile(`^ergo`),
	regexp.MustCompile(`galmart`),
	regexp.MustCompile(`^bi1$`),
	regexp.MustCompile(`anglesey`),
}

var osmQuotes = strings.NewReplacer(`"`, "", "«", "", "»", "", "'", "", "`", "")

func normName(s string) string {
	return strings.Join(strings.Fields(strings.ToLower(osmQuotes.Replace(s))), " ")
}

// isChain — магазин сети: у объекта карты есть бренд или название сети.
func isChain(name, brand, operator string) bool {
	if strings.TrimSpace(brand) != "" {
		return true
	}
	n, op := normName(name), normName(operator)
	for _, re := range osmChains {
		if re.MatchString(n) || (op != "" && re.MatchString(op)) {
			return true
		}
	}
	return false
}

// OSMShop — объект карты OpenStreetMap.
type OSMShop struct {
	// n123 / w456 — тип и номер объекта OSM.
	ID       string  `json:"id"`
	Lat      float64 `json:"lat"`
	Lng      float64 `json:"lng"`
	Shop     string  `json:"shop"`
	Name     string  `json:"name"`
	Brand    string  `json:"brand"`
	Operator string  `json:"operator"`
}

// OSMImportInput — POST /admin/field/flags/import.
type OSMImportInput struct {
	Items []OSMShop `json:"items"`
	// DryRun — только посчитать, ничего не ставить.
	DryRun bool `json:"dry_run"`
}

// OSMImportResult — сколько чего: поставлено и почему остальные пропущены.
type OSMImportResult struct {
	Received  int  `json:"received"`
	NotFood   int  `json:"not_food"`
	Chains    int  `json:"chains"`
	Outside   int  `json:"outside"`
	Existing  int  `json:"existing"`
	NearPlace int  `json:"near_place"`
	NearStore int  `json:"near_store"`
	NearFlag  int  `json:"near_flag"`
	Created   int  `json:"created"`
	DryRun    bool `json:"dry_run"`
}

// ImportOSMFlags — флажки «зайти потом» на продуктовые магазины с карты.
func (s *Service) ImportOSMFlags(ctx context.Context, p *identity.Principal, in OSMImportInput) (OSMImportResult, error) {
	if err := requireAdmin(p); err != nil {
		return OSMImportResult{}, err
	}
	out := OSMImportResult{Received: len(in.Items), DryRun: in.DryRun}
	if len(in.Items) == 0 || len(in.Items) > maxOSMImport {
		return out, apperr.Validation("items: от 1 до 5000 магазинов за раз").Uz("items: bir martada 1 dan 5000 tagacha doʻkon")
	}
	ds, err := s.Districts(ctx, p)
	if err != nil {
		return out, err
	}
	var polys []Polygon
	for _, d := range ds.Items {
		if len(d.Boundary) >= 3 {
			polys = append(polys, d.Boundary)
		}
	}
	if len(polys) == 0 {
		return out, apperr.Conflict("no_districts", "сначала задайте границы районов").Uz("avval tumanlar chegarasini belgilang")
	}
	var (
		ids, names, shops []string
		lats, lngs        []float64
		seen              = map[string]bool{}
	)
	for _, it := range in.Items {
		it.ID, it.Shop = strings.TrimSpace(it.ID), strings.TrimSpace(it.Shop)
		if it.ID == "" || len(it.ID) > 32 || seen[it.ID] {
			continue
		}
		seen[it.ID] = true
		if !osmFoodShops[it.Shop] {
			out.NotFood++
			continue
		}
		if isChain(it.Name, it.Brand, it.Operator) {
			out.Chains++
			continue
		}
		inside := false
		for _, pl := range polys {
			if pl.contains(it.Lat, it.Lng) {
				inside = true
				break
			}
		}
		if !inside {
			out.Outside++
			continue
		}
		name := strings.TrimSpace(it.Name)
		if r := []rune(name); len(r) > 120 {
			name = string(r[:120])
		}
		ids, names, shops = append(ids, it.ID), append(names, name), append(shops, it.Shop)
		lats, lngs = append(lats, it.Lat), append(lngs, it.Lng)
	}
	if len(ids) == 0 {
		return out, nil
	}
	// Рядом уже есть отметка магазина, магазин Super Market или флажок продажника — не ставим.
	err = s.pool.QueryRow(ctx, `
		WITH src AS (
			SELECT t.osm_id, t.name, t.shop, ST_SetSRID(ST_MakePoint(t.lng, t.lat), 4326)::geography AS loc
			FROM unnest($1::text[], $2::text[], $3::text[], $4::float8[], $5::float8[]) AS t(osm_id, name, shop, lat, lng)
		), c AS (
			SELECT src.*,
			       EXISTS (SELECT 1 FROM field_flags f WHERE f.osm_id = src.osm_id) AS existing,
			       EXISTS (SELECT 1 FROM field_places p WHERE ST_DWithin(p.location, src.loc, $6)) AS near_place,
			       EXISTS (SELECT 1 FROM stores st JOIN networks n ON n.id = st.network_id
			               WHERE st.location IS NOT NULL AND st.status = 'active' AND n.status = 'active' AND n.kind <> 'distributor'
			                 AND ST_DWithin(st.location, src.loc, $6)) AS near_store,
			       EXISTS (SELECT 1 FROM field_flags f WHERE f.status = 'open' AND f.source = 'rep' AND ST_DWithin(f.location, src.loc, $7)) AS near_flag
			FROM src
		), ins AS (
			INSERT INTO field_flags (source, osm_id, location, name, shop)
			SELECT 'osm', osm_id, loc, name, shop FROM c
			WHERE NOT $8 AND NOT (existing OR near_place OR near_store OR near_flag)
			ON CONFLICT (osm_id) WHERE osm_id IS NOT NULL DO NOTHING
			RETURNING 1
		)
		SELECT count(*) FILTER (WHERE existing)::int,
		       count(*) FILTER (WHERE NOT existing AND near_place)::int,
		       count(*) FILTER (WHERE NOT existing AND NOT near_place AND near_store)::int,
		       count(*) FILTER (WHERE NOT existing AND NOT near_place AND NOT near_store AND near_flag)::int,
		       CASE WHEN $8 THEN count(*) FILTER (WHERE NOT (existing OR near_place OR near_store OR near_flag))::int
		            ELSE (SELECT count(*)::int FROM ins) END
		FROM c`, ids, names, shops, lats, lngs, osmNearM, osmNearM, in.DryRun).
		Scan(&out.Existing, &out.NearPlace, &out.NearStore, &out.NearFlag, &out.Created)
	return out, err
}
