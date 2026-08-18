# Data source

Two separate outline assets, picked by [MapTier][map_tier.dart] (see
places_map_view.dart): a coarse world-tier layer, and a much finer region/local-tier
layer that also carries state/province boundaries. A single tolerance can't serve both
zoom levels well - 1:110m country shapes read as a shapeless blob once a whole view spans
fifty miles instead of the whole globe, but that same fine a layer would be many times
larger than the world tier actually needs.

## World tier: `world_outlines.bin`

Derived from Natural Earth's 1:110m "admin 0 countries" dataset (public domain, no
attribution required - see
https://www.naturalearthdata.com/about/terms-of-use/), downloaded 2026-08-18 from
`https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_admin_0_countries.geojson`
(177 country features), packed by `pack_world.py` with `SIMPLIFY_TOLERANCE_DEG = 0.1`
(~11km between vertices - fine for a globe-scale view, not for anything tighter).

## Region/local tier: `region_outlines.bin`

Derived from Natural Earth's 1:50m "admin 0 countries" (242 features) AND "admin 1 states
provinces" (294 features) datasets, same license, downloaded 2026-08-18 from
`https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_50m_admin_0_countries.geojson`
and `.../ne_50m_admin_1_states_provinces.geojson`, packed by `pack_region.py` with
`SIMPLIFY_TOLERANCE_DEG = 0.005` (~550m between vertices) - close to where simplification
stops removing anything beyond what the 1:50m source data is already coarse about, chosen
empirically against nearby tolerances (0.05 down to 0.001 degrees) for the best detail
this dataset can actually offer within budget (see "Size" below).

1:10m source data (both layers) was also evaluated and rejected: even at a coarser
tolerance than region_outlines.bin's own, it alone would run past 1 MB - the extra detail
at the scale this ever renders on a phone screen isn't worth roughly 4x the asset size.

Administrative-1 boundaries (US states, etc.) exist so a regional view shows real state
lines instead of one shapeless national coastline once a group's places are tightly
clustered within a country - see places_map_painter.dart for why these paint stroke-only,
never filled, and world_outlines.dart's/region_outlines.dart's own doc comments for why
this is a genuinely separate asset from the world tier rather than one file serving both
badly.

This backs the Memories map view's outlines - a stylised, self-contained rendering of
where the group has checked in, drawn with a `CustomPainter` from these bundled assets
rather than fetched tile-by-tile from a map provider. The app makes zero external network
calls in normal operation and the underlying place data is only ever city-level, so a
street-level tile map would draw a precision the data doesn't have; a simplified outline
is the honest projection for what this app actually knows.

## License

Natural Earth data is public domain. No attribution is legally required; this note exists
so a future update to either dataset knows where the original came from.

## What was kept, and why

Both raw GeoJSON exports carry around 130 metadata columns this feature has no use for
(nine languages' worth of localized names, seven different map-coloring schemes, a dozen
country-code variants per foreign administration's own convention, ...) on top of each
feature's actual outline geometry. None of that belongs in the app bundle, so
`pack_world.py`/`pack_region.py` (checked in alongside this file, but not part of the
Flutter build - one-off transforms to run again if Natural Earth publishes an update)
keep only the geometry itself:

  - every ring (exterior boundary and interior hole alike, e.g. Lesotho's hole in South
    Africa, San Marino's and the Vatican's in Italy) of every polygon, simplified with
    Douglas-Peucker at each layer's own tolerance (see above)
  - each ring's points, quantized to 0.001° (~110 m at the equator) and delta-encoded as
    zigzag varints against the previous point, since consecutive points on a simplified
    boundary are almost always close together - the shared codec both pack scripts use is
    `outline_codec.py`

Rings are stored flat within each group, with no per-country/per-state identity and no
tag for which rings are holes: neither `world_outlines.dart` nor `region_outlines.dart`'s
parser needs either. Painting every ring from a filled group into one `Path` with an
even-odd fill rule reproduces every hole correctly for free, regardless of which specific
rings are holes or which feature they belonged to - the map view fits its own view to the
group's places by their coordinates, not by picking out individual countries or states,
so no per-ring identity lookup is needed at render time either.

Every coordinate in either file is Natural Earth's own reported value - nothing here was
hand-drawn, approximated, or synthesised.

## Format

Both files are flat, uncompressed, LEB128-varint-packed binaries, sharing one per-ring
encoding (`OutlineReader` in outline_codec.dart; `write_varint`/`zigzag_encode` in
outline_codec.py):

```
ring:
  pointCount: varint
  for each point:
    dx: zigzag-varint  (delta from the previous point's x, in 0.001° units; first point's
                         delta is from (0, 0))
    dy: zigzag-varint  (delta from the previous point's y, same units)

ringGroup:
  ringCount: varint
  ringCount x ring
```

`world_outlines.bin` is exactly one `ringGroup`. `region_outlines.bin` is a
`groupCount: varint` (always 2) followed by that many `ringGroup`s - admin-0 first, then
admin-1 - which is what lets `region_outlines.dart`'s parser hand the painter two
independently-styled ring lists from one file instead of needing two separate assets.

`x` is longitude, `y` is latitude, both scaled by `outline_codec.py`'s own `SCALE` and
rounded to the nearest integer before delta-encoding. A ring's first and last point are the
same location but only stored once - every ring is implicitly closed.

That scale is defined in exactly two places - `outline_codec.py` and `outline_codec.dart`'s
`kOutlineCoordinateScale` - and they must agree. A mismatch does not fail to parse; it
draws every coastline in the world at the wrong size. `test/map_assets_test.dart` guards
that by range-checking the real shipped assets rather than an in-memory buffer.

It was originally 100 (0.01°, ~1.1 km). Both layers are simplified at a finer tolerance
than that, so the coarser grid was discarding detail already paid for and snapping every
coastline onto a ~1.1 km lattice - which read as visibly angular, wrong-looking geometry
once the map became zoomable. 1000 costs about 40% more bytes for 10x the precision.

## Admin-1 coverage

Natural Earth's 1:50m admin-1 layer covers only **9 countries**: the United States, Russia,
China, India, Canada, Brazil, Australia, Indonesia and South Africa. A group anywhere else
sees country outlines with no internal state/province lines, which degrades cleanly - those
nine are the geographically large countries where an internal boundary is what tells you
where you are; a country small enough to be missing from the layer is small enough to
recognise from its own outline.

The 1:10m layer does cover all 253 (4,596 features), but packs to 1.57 MB against 444 KB
and carries ~9x the points to decode and draw on every map open. Not worth it until a real
group is actually somewhere the 50m layer leaves blank.

## Size

  - `world_outlines.bin`: 32,099 bytes (~31 KB).
  - `region_outlines.bin`: 443,721 bytes (~433 KB) - 87,360 points across the admin-0
    rings, 61,804 points across the admin-1 rings.
  - Combined: 475,820 bytes (~465 KB), still under the ~600 KB total asset budget for this
    feature after the 10x precision increase.
