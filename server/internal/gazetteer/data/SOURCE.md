# Data source

`cities15000.tsv.gz` is derived from GeoNames' `cities15000.zip` export (every populated
place with more than 15,000 people, or a national/first-order administrative capital -
about 34,100 rows worldwide), downloaded 2026-08-18 from
`https://download.geonames.org/export/dump/cities15000.zip`.

`countries.tsv` is derived from GeoNames' `countryInfo.txt`, downloaded the same day from
`https://download.geonames.org/export/dump/countryInfo.txt` - trimmed to just the ISO
alpha-2 code and the full English country name (252 rows), which is what turns a post's
"City, Country" string into a country to search within.

## License

GeoNames' data is licensed under the [Creative Commons Attribution 4.0
License](https://creativecommons.org/licenses/by/4.0/), which requires attribution.
Attribution: place data (c) GeoNames.org contributors, CC BY 4.0.

## What was kept, and why

The raw `cities15000.txt` export is ~8.4 MB and carries columns this feature has no use
for (feature codes, elevation, admin subdivision codes, a modification date, ...) plus an
`alternatenames` column that alone runs to several MB of transliterations in dozens of
scripts. None of that belongs in a Docker image for a self-hosted group chat app, so
`pack_cities.py` (checked in alongside this file, but not part of the Go build - a one-off
transform to run again whenever GeoNames publishes an update) trimmed each row to exactly
what `Resolve` needs to turn "City, Country" into coordinates:

  - the city's ASCII name (its primary match key)
  - its original-script name too, when that differs (Lisbon's GeoNames name IS "Lisbon",
    so it contributes nothing extra there - but plenty of rows only have a non-ASCII
    primary name)
  - its ISO alpha-2 country
  - lat/lng
  - population (the deterministic tiebreak when more than one same-named place exists in
    the same country - see gazetteer.go's own doc comment)
  - up to 12 additional short, ASCII, non-abbreviation alternate names, so a common
    English exonym GeoNames files under `alternatenames` rather than under `name` (e.g.
    "New York" for the row GeoNames calls "New York City") still resolves. All-caps
    entries (airport/rail/postal codes like "NYC", "LIS") are dropped outright rather
    than merely deprioritized - real GeoNames data, but not a shape a phone's on-device
    reverse geocoder ever actually produces, and keeping them crowded out genuine short
    exonyms in the length-sorted shortlist.

Every coordinate in this file is GeoNames' own reported value for that place - nothing
here was hand-typed, approximated, or guessed. A place this dataset has no row for (or
whose row failed the population/capital-status bar cities15000 applies) simply has no
resolution; see gazetteer.go's `Resolve` for how that comes back (ok=false, not a guess).

Gzipped, the trimmed file is ~1.3 MB - the "few hundred KB to a couple MB" a Docker image
can absorb without issue, nowhere close to the ~300 MB an unfiltered planet-wide GeoNames
dump would cost.
