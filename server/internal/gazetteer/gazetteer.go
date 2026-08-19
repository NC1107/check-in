// Package gazetteer resolves a post's coarse "City, Country" location string to
// coordinates entirely offline - this app's whole posture is that a self-hosted server
// phones nobody. Coordinate capture only shipped alongside this feature, so every
// check-in from before that (and every one a self-hoster's group has ever posted) carries
// only that display string, never a stored lat/lng - a real self-hosted group has on the
// order of ten to fifty distinct location strings needing this backfill, ever, since every
// check-in captured since carries its own device coordinates and never touches this
// package at all.
//
// That's why the several-million-row dataset this now carries (see data/SOURCE.md for
// exactly why it has to be that large - a much smaller, population-floored dataset was
// this package's own first version's bug) is NOT loaded into memory: it lives in
// data/places.bin, opened once and read via os.File.ReadAt, binary-searched directly on
// disk. A backfill-only lookup can afford to be slow and rare; it does not need to be in
// RAM, and a self-hosted deployment - where one host commonly runs several instances of
// this app on the same modest box - cannot afford several hundred MB of permanent heap per
// instance just to resolve place names. See db.candidatesCached (internal/db/places.go)
// for the persistent cache in front of this that makes the disk read's latency
// irrelevant in practice: every distinct location is read off disk at most once, ever, no
// matter how many times any viewer opens Places afterward.
//
// places.bin itself is never committed to this repo, and never go:embed'd - see
// data/SOURCE.md for exactly why (a Docker image is one thing; ~90MB of binary blob paid
// by every git clone forever, on top of it, is another) and how it's produced instead: a
// pinned GeoNames download, fetched and packed at Docker BUILD time, never at container
// boot or at any point this app makes a network call of its own.
package gazetteer

import (
	"bytes"
	// Blank: the //go:embed directive below needs this package linked in, but nothing
	// here calls it.
	_ "embed"
	"encoding/binary"
	"hash/fnv"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
)

//go:embed data/countries.tsv
var countriesRaw string

// dataFileName is the plain, directly-seekable dataset gazetteer.go opens with
// os.File.ReadAt - deliberately never go:embed'd. Embedding puts the bytes in the binary,
// which the Go runtime then has to hold in memory the moment anything touches them,
// defeating the entire reason this package reads from disk in the first place.
const dataFileName = "places.bin"

// defaultDataDir resolves to this source file's own data/ directory, not the process's
// working directory (which differs between `go test`, a local `go run`, and the packaged
// binary) - what lets every test in this package, and every package that transitively
// exercises it, find a locally-built dataset with zero extra setup once one exists there
// (see data/SOURCE.md's own "Building it locally" section - this repo never ships one).
// Production overrides this via SetDataPath - see cmd/server/main.go, which points it at
// wherever the Dockerfile bakes the real dataset into the image.
var defaultDataDir = func() string {
	_, thisFile, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(thisFile), "data")
}()

var dataPath = filepath.Join(defaultDataDir, dataFileName)

// SetDataPath overrides where the on-disk dataset lives. Called once, at server startup
// (see cmd/server/main.go), before the first request could possibly trigger a query - this
// package's own lazy sync.Once init means calling it after get() has already run would
// silently have no effect, so callers must not treat this as safe to change at runtime.
func SetDataPath(path string) { dataPath = path }

// normalizeKey folds a name for comparison: case-insensitive, with runs of internal
// whitespace collapsed to one space. Deliberately the same fold rule
// db.normalizeLocation applies to a post's location string - client-supplied strings (an
// on-device reverse geocoder's output) and GeoNames' own row data vary the same way in
// either direction, "Lisbon, Portugal" against "lisbon,  portugal" among them. Also the
// exact fold data/pack_places.py applies (its own normalize_key) before hashing a row's
// own key - the two have to agree byte-for-byte, or a query hashed here would never match
// the row the packer meant it to.
// Duplicated here rather than imported: this package has to stay a leaf dependency (see
// db/places.go, which imports THIS package to do its own resolution) - db importing
// gazetteer and gazetteer importing db back would be a cycle.
func normalizeKey(s string) string {
	return strings.ToLower(strings.Join(strings.Fields(s), " "))
}

// fnv1a64 hashes s with the exact algorithm data/pack_places.py's own fnv1a64 implements
// in Python (verified directly against each other, not just by matching a spec) - the key
// every row in places.bin is sorted and binary-searched by, in place of the row's own name
// text (see this package's own doc comment for why the text itself is never stored at
// all). Go's stdlib hash/fnv already implements this; wrapped in a named function so every
// call site names what it's doing rather than repeating the New64a/Write/Sum64 dance.
//
// On collisions: see pack_places.py's own doc comment for the same consideration from the
// packing side - two different normalized keys landing on the same 64-bit hash would be
// indistinguishable at query time, since there is no stored text left to disambiguate them
// with. Deliberately accepted: at 64 bits of hash space against this dataset's own row
// count (order 10 million), the birthday-bound probability of even one such collision
// anywhere in the whole table is on the order of 1 in 300,000, and the practical effect of
// one occurring would be two real, unrelated places occasionally sharing a match - not a
// systemic failure.
func fnv1a64(s string) uint64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(s)) // hash.Hash.Write never actually returns an error
	return h.Sum64()
}

// header is places.bin's own fixed-size, fixed-offset preamble (see data/pack_places.py's
// HEADER_FORMAT and data/SOURCE.md's "Format" section) - read once with a single ReadAt at
// file offset 0 and kept in memory for the life of the process (a few dozen bytes), never
// the data the offsets inside it point at.
//
// The dataset is one flat table, sorted and binary-searched by a 64-bit hash of each row's
// own normalized "ISO\x00name" key (hashesOffset/entryIndicesOffset/flagsOffset, keyCount
// rows) - a primary name and every one of its alternate names each contribute their own
// row, tagged PRIMARY or ALIAS (see readFlag), pointing at a shared, deduplicated entries
// table (latOffset/lngOffset/populationOffset, entryCount rows) rather than each carrying
// a copy of the coordinates. Column-major throughout (all hashes contiguous, then all
// entry indices, then all flags, then all lat, ...) rather than one record per row: a
// binary search only ever needs to read the hash column until it finds a match, so keeping
// that column tightly packed on its own is what keeps a search from reading bytes it
// doesn't need.
type header struct {
	keyCount                                      uint32
	hashesOffset, entryIndicesOffset, flagsOffset int64

	// entryCount itself is never read back out - every entry is only ever reached by an
	// explicit index off a matched key row (candidateAt, allZeroPopulation), never
	// iterated in bulk - but the field still has to be parsed out of the header to land
	// correctly on the fields that follow it.
	latOffset, lngOffset, populationOffset int64
}

// magic identifies data/pack_places.py's current binary format - a version guard, not a
// checksum: a file written by an older or newer packer is rejected outright (see
// readHeader) rather than parsed under the wrong layout.
var magic = [4]byte{'P', 'L', 'C', '3'}

const headerSize = 60

func readHeader(f *os.File) (header, error) {
	buf := make([]byte, headerSize)
	if _, err := f.ReadAt(buf, 0); err != nil {
		return header{}, err
	}
	r := bytes.NewReader(buf)

	var gotMagic [4]byte
	if err := binary.Read(r, binary.LittleEndian, &gotMagic); err != nil {
		return header{}, err
	}
	if gotMagic != magic {
		return header{}, errBadMagic{}
	}

	var h header
	var hashesOffset, entryIndicesOffset, flagsOffset uint64
	var entryCount uint32 // unused past this parse - see the header struct's own doc comment
	var latOffset, lngOffset, populationOffset uint64
	fields := []any{
		&h.keyCount,
		&hashesOffset, &entryIndicesOffset, &flagsOffset,
		&entryCount,
		&latOffset, &lngOffset, &populationOffset,
	}
	for _, f := range fields {
		if err := binary.Read(r, binary.LittleEndian, f); err != nil {
			return header{}, err
		}
	}
	h.hashesOffset, h.entryIndicesOffset, h.flagsOffset = int64(hashesOffset), int64(entryIndicesOffset), int64(flagsOffset)
	h.latOffset, h.lngOffset, h.populationOffset = int64(latOffset), int64(lngOffset), int64(populationOffset)
	return h, nil
}

type errBadMagic struct{}

func (errBadMagic) Error() string { return "gazetteer: places.bin has an unrecognised format" }

// index is this package's single, process-lifetime handle on the on-disk dataset - built
// once (see load) and never mutated afterward, so concurrent Resolve/Candidates calls need
// no locking of their own beyond what os.File.ReadAt already guarantees (documented safe
// for concurrent use, unlike Read, which shares a file cursor).
type index struct {
	// countryISOByName maps a normalized (see normalizeKey) full country name - "united
	// states", not "US" - to its ISO alpha-2 code. Posts carry full country names (see
	// this package's own doc comment), never codes, so this is the first split every
	// Resolve/Candidates call makes: which country's places to even search within. Small
	// (a couple hundred rows, from the still-embedded data/countries.tsv) - an ordinary Go
	// map is the right tool here, unlike the city-scale table in places.bin.
	countryISOByName map[string]string

	// f is the open places.bin handle, held for the life of the process. ok is false when
	// it (or its header) couldn't be opened/parsed at all - see load's own doc comment for
	// what that degrades to.
	f  *os.File
	h  header
	ok bool
}

var (
	loadOnce sync.Once
	loaded   *index
)

func get() *index {
	loadOnce.Do(func() { loaded = load() })
	return loaded
}

// load parses the embedded countries table and opens places.bin, once, at first use. A
// missing or malformed dataset (wrong CHECKIN_GAZETTEER_PATH, a partial deploy, or a fresh
// checkout that has never built one locally - see data/SOURCE.md) degrades to an index
// that answers every Resolve/Candidates call with "no match" rather than panicking or
// blocking startup - never bring the whole server down over map data - but does log once
// with an actionable hint, since a missing on-disk file is a realistic misconfiguration
// (or, in local dev, an expected first-time state) worth surfacing rather than leaving
// silent.
func load() *index {
	idx := &index{countryISOByName: make(map[string]string, 260)}

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

	f, err := os.Open(dataPath)
	if err != nil {
		log.Printf("gazetteer: could not open %s: %v - place names will not resolve. "+
			"See internal/gazetteer/data/SOURCE.md to build one locally.", dataPath, err)
		return idx
	}
	h, err := readHeader(f)
	if err != nil {
		log.Printf("gazetteer: could not read %s: %v - place names will not resolve", dataPath, err)
		_ = f.Close()
		return idx
	}
	idx.f, idx.h, idx.ok = f, h, true
	return idx
}

// coordScale matches data/pack_places.py's own COORD_SCALE: lat/lng are stored as
// fixed-point int32, scaled by this many units per degree - GeoNames' own 5-decimal-place
// precision exactly, so this round-trips bit-for-bit to the same float64
// strconv.ParseFloat would give the original decimal string (see pack_places.py's own doc
// comment - verified directly against every pinned coordinate in gazetteer_test.go).
const coordScale = 100_000.0

func fixedToFloat(v int32) float64 { return float64(v) / coordScale }

func (idx *index) readUint64At(offset int64, i uint32) (uint64, error) {
	var buf [8]byte
	if _, err := idx.f.ReadAt(buf[:], offset+int64(i)*8); err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint64(buf[:]), nil
}

func (idx *index) readUint32At(offset int64, i uint32) (uint32, error) {
	var buf [4]byte
	if _, err := idx.f.ReadAt(buf[:], offset+int64(i)*4); err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint32(buf[:]), nil
}

func (idx *index) readInt32At(offset int64, i uint32) (int32, error) {
	v, err := idx.readUint32At(offset, i)
	return int32(v), err
}

func (idx *index) readFlagAt(i uint32) (byte, error) {
	var buf [1]byte
	if _, err := idx.f.ReadAt(buf[:], idx.h.flagsOffset+int64(i)); err != nil {
		return 0, err
	}
	return buf[0], nil
}

// flagPrimary/flagAlias match data/pack_places.py's own FLAG_PRIMARY/FLAG_ALIAS exactly -
// see Candidates' own doc comment for why a row still needs to carry this even though its
// name text doesn't.
const (
	flagAlias   byte = 0
	flagPrimary byte = 1
)

// lookupResult is the entry indices for one hash's matching rows, already split by
// [flagPrimary]/[flagAlias] - see Candidates' own doc comment for how the two are used
// differently.
type lookupResult struct {
	primary, alias []uint32
}

// lookup binary-searches the hash column for hash, then linearly scans the (typically
// tiny - even "Arlington, United States" is only a few dozen rows) contiguous run of
// matching rows to split them by tier - see this file's own top-of-file doc comment for
// why this reads a handful of small ranges off disk rather than probing an in-memory map.
// An empty result (not an error) is an ordinary "not found"; a non-nil error means a real
// I/O problem reading the file itself, which Candidates treats as "no match" too (see its
// own doc comment) rather than serving a wrong answer built from a half-read comparison.
func (idx *index) lookup(hash uint64) (lookupResult, error) {
	lo, hi := uint32(0), idx.h.keyCount
	for lo < hi {
		mid := lo + (hi-lo)/2
		h, err := idx.readUint64At(idx.h.hashesOffset, mid)
		if err != nil {
			return lookupResult{}, err
		}
		if h < hash {
			lo = mid + 1
		} else {
			hi = mid
		}
	}

	var result lookupResult
	for i := lo; i < idx.h.keyCount; i++ {
		h, err := idx.readUint64At(idx.h.hashesOffset, i)
		if err != nil {
			return lookupResult{}, err
		}
		if h != hash {
			break
		}
		entryIdx, err := idx.readUint32At(idx.h.entryIndicesOffset, i)
		if err != nil {
			return lookupResult{}, err
		}
		flag, err := idx.readFlagAt(i)
		if err != nil {
			return lookupResult{}, err
		}
		if flag == flagPrimary {
			result.primary = append(result.primary, entryIdx)
		} else {
			result.alias = append(result.alias, entryIdx)
		}
	}
	return result, nil
}

// Candidate is one GeoNames row matching a "City, Country" query - what Candidates
// returns, and what Resolve reduces to a single winner. Deliberately carries no name:
// nothing ever needs the gazetteer's own name for a place back - a post's location string
// is what the client already sent and what the UI already shows, and this package only
// ever MATCHES against a name, never returns one (see this package's own doc comment for
// why that's also why places.bin stores no name text at all).
type Candidate struct {
	Lat, Lng   float64
	Population int
}

func (idx *index) candidateAt(entryIdx uint32) (Candidate, error) {
	latRaw, err := idx.readInt32At(idx.h.latOffset, entryIdx)
	if err != nil {
		return Candidate{}, err
	}
	lngRaw, err := idx.readInt32At(idx.h.lngOffset, entryIdx)
	if err != nil {
		return Candidate{}, err
	}
	popRaw, err := idx.readInt32At(idx.h.populationOffset, entryIdx)
	if err != nil {
		return Candidate{}, err
	}
	return Candidate{Lat: fixedToFloat(latRaw), Lng: fixedToFloat(lngRaw), Population: int(popRaw)}, nil
}

func (idx *index) candidatesOf(entryIndices []uint32) ([]Candidate, error) {
	out := make([]Candidate, len(entryIndices))
	for i, e := range entryIndices {
		c, err := idx.candidateAt(e)
		if err != nil {
			return nil, err
		}
		out[i] = c
	}
	return out, nil
}

// allZeroPopulation reports whether every one of entryIndices has population 0 - see
// Candidates' own doc comment for the one case this gates.
func (idx *index) allZeroPopulation(entryIndices []uint32) (bool, error) {
	for _, e := range entryIndices {
		pop, err := idx.readInt32At(idx.h.populationOffset, e)
		if err != nil {
			return false, err
		}
		if pop != 0 {
			return false, nil
		}
	}
	return true, nil
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
// produced by on-device reverse geocoding does. No match at all (an unknown country, a
// name this dataset genuinely has no row for at all, or a real I/O error reading the
// file - see index.lookup's own doc comment) returns nil, not an error - callers MUST
// treat that as a normal result: db.Place carries nil lat/lng for such a place rather than
// dropping it or inventing a location.
//
// Matching is tiered, never blended into one flat list, with one deliberate exception:
// every row whose own GeoNames name folds to the query is preferred outright over every
// row where only an alternate name matches - see data/pack_places.py's PRIMARY/ALIAS
// row tag. Returning a merged list of both would usually let a place's minor historical
// alternate name (Paterson, NJ's GeoNames data files it under the alternate name "Great
// Falls", after the waterfall the city was built around) sit alongside an actual town
// primarily named that (Great Falls, MT; Great Falls, VA) as if they were equally good
// answers - tiering the two classes of match apart is what keeps a real Great Falls
// check-in from ever being offered Paterson as a candidate at all.
//
// The exception: since this package's dataset carries every real GeoNames populated
// place regardless of population (see data/SOURCE.md for why - the alternative, any
// population floor at all, silently drops the small towns this app's own check-ins
// actually come from), a query's PRIMARY tier can now consist entirely of population-0
// rows that merely happen to share a name with someplace far more significant - GeoNames
// itself files six different, unconnected, population-0 rural crossroads across the US
// primarily named "New York", while the real New York City is only reachable through this
// same query via the alias tier ("New York City" is its own primary name). Trusting the
// primary tier unconditionally in that shape would make a group's real "New York, United
// States" check-in resolve to an obscure Missouri crossroads and never even offer NYC as
// an option. So: primary tier wins outright UNLESS every one of its own rows has
// population exactly 0 AND the alias tier has at least one row to add - in that specific
// case only, both tiers are combined into one candidate pool instead, on the premise that
// a primary match this uniformly obscure has no real claim to precedence over a
// well-known place reachable only via its alias, and the caller's OWN disambiguation
// (buildPlaces' proximity-to-anchor, see its doc comment) is far better equipped than a
// population-blind tier rule to pick correctly between them. This never fires for Great
// Falls: MT's own row carries a real, nonzero population, so the primary tier is never
// "entirely zero" there and Paterson's alias is correctly never even considered.
func Candidates(location string) []Candidate {
	idx := get()
	if !idx.ok {
		return nil
	}
	candidates, err := idx.candidates(location)
	if err != nil {
		return nil
	}
	return candidates
}

func (idx *index) candidates(location string) ([]Candidate, error) {
	comma := strings.LastIndex(location, ",")
	if comma < 0 {
		return nil, nil
	}
	city := normalizeKey(location[:comma])
	country := normalizeKey(location[comma+1:])
	if city == "" || country == "" {
		return nil, nil
	}

	iso, ok := idx.countryISOByName[country]
	if !ok {
		return nil, nil
	}

	hash := fnv1a64(iso + "\x00" + city)
	matches, err := idx.lookup(hash)
	if err != nil {
		return nil, err
	}

	switch {
	case len(matches.primary) == 0:
		if len(matches.alias) == 0 {
			return nil, nil
		}
		return idx.candidatesOf(matches.alias)
	case len(matches.alias) == 0:
		return idx.candidatesOf(matches.primary)
	default:
		allZero, err := idx.allZeroPopulation(matches.primary)
		if err != nil {
			return nil, err
		}
		if !allZero {
			return idx.candidatesOf(matches.primary)
		}
		merged := make([]uint32, 0, len(matches.primary)+len(matches.alias))
		merged = append(merged, matches.primary...)
		merged = append(merged, matches.alias...)
		return idx.candidatesOf(merged)
	}
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
