# Data source

`world_outlines.bin` is derived from Natural Earth's 1:110m "admin 0 countries" dataset
(public domain, no attribution required - see
https://www.naturalearthdata.com/about/terms-of-use/), downloaded 2026-08-18 from
`https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_admin_0_countries.geojson`
(177 country features).

This backs the Memories map view's world outlines - a stylised, self-contained rendering of
where the group has checked in, drawn with a `CustomPainter` from this bundled asset rather
than fetched tile-by-tile from a map provider. The app makes zero external network calls in
normal operation and the underlying place data is only ever city-level, so a street-level
tile map would draw a precision the data doesn't have; a simplified outline is the honest
projection for what this app actually knows.

## License

Natural Earth data is public domain. No attribution is legally required; this note exists
so a future update to the dataset knows where the original came from.

## What was kept, and why

The raw GeoJSON is ~820 KB and carries around 130 metadata columns this feature has no use
for (nine languages' worth of localized names, seven different map-coloring schemes, a
dozen country-code variants per foreign administration's own convention, ...) on top of
each country's actual outline geometry. None of that belongs in the app bundle, so
`pack_world.py` (checked in alongside this file, but not part of the Flutter build - a
one-off transform to run again if Natural Earth publishes an update) keeps only the
geometry itself:

  - every ring (exterior boundary and interior hole alike, e.g. Lesotho's hole in South
    Africa, San Marino's and the Vatican's in Italy) of every country polygon, simplified
    with Douglas-Peucker at a 0.1° tolerance (`SIMPLIFY_TOLERANCE_DEG` in the script) -
    invisible at the size this ever renders on a phone screen, since 110m-scale data is
    already coarse to begin with
  - each ring's points, quantized to 0.01° (~1.1 km at the equator - far finer than this
    ever needs) and delta-encoded as zigzag varints against the previous point, since
    consecutive points on a simplified coastline are almost always close together

Rings are stored flat, with no per-country identity and no tag for which rings are holes:
`world_outlines.dart`'s parser doesn't need either. Painting every ring from every country
into one `Path` with an even-odd fill rule reproduces every hole correctly for free,
regardless of which specific rings are holes or which country they belonged to - the map
view fits its own view to the group's places by their coordinates, not by picking out
individual countries, so no per-ring country lookup is needed at render time either.

Every coordinate in this file is Natural Earth's own reported value - nothing here was
hand-drawn, approximated, or synthesised.

## Format

A flat, uncompressed, LEB128-varint-packed binary (parsed by `world_outlines.dart`):

```
ringCount: varint
for each ring:
  pointCount: varint
  for each point:
    dx: zigzag-varint  (delta from the previous point's x, in 0.01° units; first point's
                         delta is from (0, 0))
    dy: zigzag-varint  (delta from the previous point's y, same units)
```

`x` is longitude, `y` is latitude, both scaled by 100 and rounded to the nearest integer
before delta-encoding. A ring's first and last point are the same location but only stored
once - every ring is implicitly closed.

## Size

`world_outlines.bin` is 22,868 bytes (~22.3 KB) - well under the "well under 200 KB" target,
with a wide margin for a future re-pack at a finer tolerance if country shapes ever need to
read more precisely than this cut.
