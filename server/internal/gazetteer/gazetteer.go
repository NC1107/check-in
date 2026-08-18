// Package gazetteer resolves a post's coarse "City, Country" location string to
// coordinates entirely offline, embedded in the server binary - this app's whole posture
// is that a self-hosted server phones nobody, and coordinate capture only shipped the day
// this package was written, so every existing check-in (and every one a self-hoster's
// group has ever posted before today) carries only that display string, never a stored
// lat/lng. See data/SOURCE.md for exactly where the embedded dataset comes from, its
// license, and what was trimmed out of the raw GeoNames export to keep it small.
package gazetteer

import (
	"bufio"
	"bytes"
	"compress/gzip"
	_ "embed"
	"strconv"
	"strings"
	"sync"
)

//go:embed data/cities15000.tsv.gz
var citiesGz []byte

//go:embed data/countries.tsv
var countriesRaw string

// entry is one GeoNames city row, trimmed to what Resolve needs.
type entry struct {
	name       string // GeoNames' own display name for this row - never shown to a member
	lat, lng   float64
	population int
}

// index is the parsed, queryable form of the embedded dataset - built once (see load) and
// never mutated afterward, so concurrent Resolve calls need no locking of their own.
type index struct {
	// countryISOByName maps a normalized (see normalizeKey) full country name - "united
	// states", not "US" - to its ISO alpha-2 code. Posts carry full country names (see
	// this package's own doc comment), never codes, so this is the first split every
	// Resolve call makes: which country's cities to even search within.
	countryISOByName map[string]string

	// primary maps "ISO code\x00normalized city name" to every row whose OWN name
	// (GeoNames' `name` or `asciiname` column) folds to that key. Checked before alias -
	// see Resolve's own doc comment for why the two tiers are never merged into one
	// lookup.
	primary map[string][]entry

	// alias maps the same key shape to every row where the match is instead one of its
	// short ASCII alternate names (see data/SOURCE.md) - e.g. GeoNames' own primary name
	// for New York is "New York City", so "New York" only ever resolves via this map.
	// Never contains an alias identical to that row's own primary key; see load.
	alias map[string][]entry
}

var (
	loadOnce sync.Once
	loaded   *index
)

func get() *index {
	loadOnce.Do(func() { loaded = load() })
	return loaded
}

const indexKeySep = "\x00"

func indexKey(iso, normalizedName string) string {
	return iso + indexKeySep + normalizedName
}

// normalizeKey folds a name for comparison: case-insensitive, with runs of internal
// whitespace collapsed to one space. Deliberately the same fold rule
// db.normalizeLocation applies to a post's location string - client-supplied strings (an
// on-device reverse geocoder's output) and GeoNames' own row data vary the same way in
// either direction, "Lisbon, Portugal" against "lisbon,  portugal" among them.
// Duplicated here rather than imported: this package has to stay a leaf dependency (see
// db/places.go, which imports THIS package to do its own resolution) - db importing
// gazetteer and gazetteer importing db back would be a cycle.
func normalizeKey(s string) string {
	return strings.ToLower(strings.Join(strings.Fields(s), " "))
}

// load parses the embedded countries table and gzip-compressed cities table into an
// in-memory index, once, at first use. A malformed embedded dataset (which would mean the
// binary itself is broken, not something a request retry or config change could fix)
// degrades to an empty index rather than panicking - every Resolve call then honestly
// reports ok=false, which is the correct failure mode for a places feature: never bring
// the whole server down over map data.
func load() *index {
	idx := &index{
		countryISOByName: make(map[string]string, 260),
		primary:          make(map[string][]entry, 34000),
		alias:            make(map[string][]entry, 34000),
	}

	for _, line := range strings.Split(countriesRaw, "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}
		iso, name, ok := strings.Cut(line, "\t")
		iso, name = strings.TrimSpace(iso), strings.TrimSpace(name)
		if !ok || iso == "" || name == "" {
			continue
		}
		idx.countryISOByName[normalizeKey(name)] = iso
	}

	r, err := gzip.NewReader(bytes.NewReader(citiesGz))
	if err != nil {
		return idx
	}
	defer r.Close()

	scanner := bufio.NewScanner(r)
	// Longer than the default 64KiB line buffer would ever need to be for this file, but
	// cheap insurance against a future re-pack widening a row past that.
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		cols := strings.Split(line, "\t")
		if len(cols) != 6 {
			continue
		}
		name, iso := cols[0], cols[1]
		lat, errLat := strconv.ParseFloat(cols[2], 64)
		lng, errLng := strconv.ParseFloat(cols[3], 64)
		population, _ := strconv.Atoi(cols[4])
		if errLat != nil || errLng != nil || name == "" || iso == "" {
			continue
		}
		e := entry{name: name, lat: lat, lng: lng, population: population}

		primaryKey := normalizeKey(name)
		key := indexKey(iso, primaryKey)
		idx.primary[key] = append(idx.primary[key], e)

		if cols[5] == "" {
			continue
		}
		for _, alias := range strings.Split(cols[5], "|") {
			aliasKey := normalizeKey(alias)
			if aliasKey == "" || aliasKey == primaryKey {
				continue
			}
			key := indexKey(iso, aliasKey)
			idx.alias[key] = append(idx.alias[key], e)
		}
	}
	return idx
}

// Resolve turns a post's "City, Country" display string into coordinates, or reports
// ok=false when it can't - never a guess. Unmatched is the expected outcome for most of a
// group's history (a village too small for GeoNames' 15,000-population/capital bar, a
// country name this build's country table doesn't carry, a typo a reverse geocoder never
// actually produces) and callers MUST treat it as a normal result, not an error: db.Place
// returns such a place with nil lat/lng rather than dropping it or inventing a location -
// see db/places.go's own doc comment.
//
// location is split on its LAST comma - "City, Country", the shape every post's location
// string has (content_handlers.go's own doc comment pins this; see this package's own
// header comment for why nothing else is ever stored). A city name that happened to
// contain a comma of its own would break this, but no real "City, Country" string
// produced by on-device reverse geocoding does.
//
// Matching is tiered, never blended into one flat lookup: every row whose own GeoNames
// name folds to the query is preferred outright over every row where only an alternate
// name matches - see load's primary/alias split. Skipping straight to a merged
// population-ranked list of both would occasionally let a place's minor historical
// alternate name (Paterson, NJ's GeoNames data files it under the alternate name "Great
// Falls", after the waterfall the city was built around) outrank an actual town primarily
// named that (Great Falls, MT; Great Falls, VA) on population alone - tiering the two
// classes of match apart is what keeps a real Great Falls check-in from resolving to
// Paterson.
//
// Within whichever tier matches, more than one same-named place in the same country is a
// genuine, common ambiguity ("Arlington, United States" is both Arlington, VA and
// Arlington, TX) that this package cannot resolve from a display string alone - there is
// no more context in "Arlington, United States" to disambiguate with. The tie always
// breaks toward the larger population: not a guess about which one a given post actually
// meant, but a deterministic, defensible default (the place someone unqualified means by
// a bare city name is, on average, the one more people would also mean) applied the same
// way every time, documented here rather than left to map iteration order.
func Resolve(location string) (lat, lng float64, ok bool) {
	idx := get()

	comma := strings.LastIndex(location, ",")
	if comma < 0 {
		return 0, 0, false
	}
	city := normalizeKey(location[:comma])
	country := normalizeKey(location[comma+1:])
	if city == "" || country == "" {
		return 0, 0, false
	}

	iso, ok := idx.countryISOByName[country]
	if !ok {
		return 0, 0, false
	}

	key := indexKey(iso, city)
	candidates := idx.primary[key]
	if len(candidates) == 0 {
		candidates = idx.alias[key]
	}
	if len(candidates) == 0 {
		return 0, 0, false
	}

	best := candidates[0]
	for _, c := range candidates[1:] {
		if c.population > best.population {
			best = c
		}
	}
	return best.lat, best.lng, true
}
