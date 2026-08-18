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

// Candidate is one GeoNames row matching a "City, Country" query - what Candidates
// returns, and what Resolve reduces to a single winner.
type Candidate struct {
	Lat, Lng   float64
	Population int
}

// Candidates returns every GeoNames row a "City, Country" display string could mean
// within its country, or nil when nothing matches at all (see the "no match" cases
// below) - unlike Resolve, it never itself picks a winner among more than one candidate
// for the same normalized city name in the same country. Which of several same-named
// places (Arlington, VA vs Arlington, TX) a group actually meant depends on where that
// group's OTHER check-ins are, something only the caller knows - see db/places.go's
// buildPlaces, which disambiguates by proximity to the group's own anchor locations
// rather than by population (Resolve's own, deliberately cruder, policy - see its doc
// comment for exactly why that's wrong for this specifically).
//
// location is split on its LAST comma - "City, Country", the shape every post's location
// string has (content_handlers.go's own doc comment pins this; see this package's own
// header comment for why nothing else is ever stored). A city name that happened to
// contain a comma of its own would break this, but no real "City, Country" string
// produced by on-device reverse geocoding does. No match at all (an unknown country, or
// a place too small for the embedded dataset's population/capital-status bar) returns
// nil, not an error - callers MUST treat that as a normal result: db.Place carries nil
// lat/lng for such a place rather than dropping it or inventing a location.
//
// Matching is tiered, never blended into one flat list: every row whose own GeoNames
// name folds to the query is preferred outright over every row where only an alternate
// name matches - see load's primary/alias split. Returning a merged list of both would
// occasionally let a place's minor historical alternate name (Paterson, NJ's GeoNames
// data files it under the alternate name "Great Falls", after the waterfall the city was
// built around) sit alongside an actual town primarily named that (Great Falls, MT;
// Great Falls, VA) as if they were equally good answers - tiering the two classes of
// match apart is what keeps a real Great Falls check-in from ever being offered Paterson
// as a candidate at all.
func Candidates(location string) []Candidate {
	idx := get()

	comma := strings.LastIndex(location, ",")
	if comma < 0 {
		return nil
	}
	city := normalizeKey(location[:comma])
	country := normalizeKey(location[comma+1:])
	if city == "" || country == "" {
		return nil
	}

	iso, ok := idx.countryISOByName[country]
	if !ok {
		return nil
	}

	key := indexKey(iso, city)
	entries := idx.primary[key]
	if len(entries) == 0 {
		entries = idx.alias[key]
	}
	if len(entries) == 0 {
		return nil
	}

	candidates := make([]Candidate, len(entries))
	for i, e := range entries {
		candidates[i] = Candidate{Lat: e.lat, Lng: e.lng, Population: e.population}
	}
	return candidates
}

// Resolve turns a post's "City, Country" display string into ONE set of coordinates, or
// reports ok=false when Candidates found nothing at all - never a guess in that sense.
// When more than one candidate matches, this breaks the tie toward the most populous:
// a deterministic default, but the WRONG one whenever a group's real place is the
// smaller of two same-named cities (Arlington, VA is real and much-visited by a
// Washington-area group, but Arlington, TX is the larger city GeoNames-wide) - db.Place
// does not call this for an ambiguous name for exactly that reason, preferring
// buildPlaces' own proximity-to-the-group's-other-places disambiguation instead (see
// Candidates' own doc comment). Resolve is kept as the population-only baseline: the
// right answer when there is truly no better signal (db.buildPlaces' own last-resort
// fallback), and useful on its own for exercising the raw dataset in tests.
func Resolve(location string) (lat, lng float64, ok bool) {
	candidates := Candidates(location)
	if len(candidates) == 0 {
		return 0, 0, false
	}
	best := candidates[0]
	for _, c := range candidates[1:] {
		if c.Population > best.Population {
			best = c
		}
	}
	return best.Lat, best.Lng, true
}
