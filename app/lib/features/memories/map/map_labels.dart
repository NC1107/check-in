import 'package:flutter/material.dart' show Offset, Rect, Size;

/// One marker's own text, center and radius - exactly the subset of PlacesMapPainter's own
/// `MarkerLayout` [layoutMarkerLabels] needs, kept as its own lightweight type here (rather
/// than importing `MarkerLayout` from places_map_painter.dart) so this file never depends
/// on the painter, the `Place` model, or Flutter's rendering layer beyond the bare geometry
/// types above - the whole point of keeping this a pure, independently testable function.
typedef LabelSubject = ({String text, Offset center, double radius});

/// Where one marker's own label ends up, or that it was dropped entirely - see
/// [layoutMarkerLabels]'s own doc comment for when that happens.
typedef LabelPlacement = ({int markerIndex, Offset textOrigin});

/// The gap, in logical pixels, between a marker's own drawn edge and its label's near
/// side - enough that a label never reads as touching the dot it names.
const double kMapLabelGap = 4.0;

/// Decides which of [markers] get a text label drawn next to them, and exactly where -
/// "A dot with no name is not a map" (the brief this implements), but a map whose labels
/// have piled into unreadable mush is worse than one with fewer, legible names on it. So:
///
///  1. Markers are considered busiest-first (largest [LabelSubject.radius], the same
///     "matters more to this group" signal the marker's own size already encodes - see
///     geo.dart's markerRadius) - a place with more check-ins gets first claim on the
///     space near it.
///  2. Each marker's own label is placed immediately to the right of its dot, vertically
///     centered on it, sized by [measure] (injected rather than this function calling
///     into a real TextPainter itself, so the whole placement/collision algorithm stays a
///     pure function directly testable with fixed, fake text sizes - see
///     map_labels_test.dart).
///  3. A candidate label is dropped (not placed at all, not shrunk, not moved to some
///     other side of the dot) when its own rectangle would overlap any label already
///     placed by an earlier, higher-priority marker in this same pass, OR would spill
///     outside [canvasSize] - "dropping a label for a tiny place beats overlapping text"
///     is the brief's own rule, and a dot the label would otherwise still mark is still on
///     the map even with no name next to it (see PlacesMapPainter, which always draws
///     every marker's own dot regardless of whether this returns a label for it).
///
/// Returns one [LabelPlacement] per marker that got a label, in no particular order -
/// callers that need "does marker i have a label" should build their own lookup (see
/// PlacesMapPainter's own use of this).
List<LabelPlacement> layoutMarkerLabels(
  List<LabelSubject> markers,
  Size Function(String text) measure, {
  required Size canvasSize,
}) {
  // Ties (equal radius - two places with the same post count) break toward the earlier
  // marker in the input order, for full determinism independent of whether List.sort
  // happens to be stable for a given Dart/Flutter version.
  final order = List<int>.generate(markers.length, (i) => i)
    ..sort((a, b) {
      final byRadius = markers[b].radius.compareTo(markers[a].radius);
      return byRadius != 0 ? byRadius : a.compareTo(b);
    });

  final placements = <LabelPlacement>[];
  final occupied = <Rect>[];

  for (final i in order) {
    final marker = markers[i];
    final size = measure(marker.text);
    final origin = Offset(
      marker.center.dx + marker.radius + kMapLabelGap,
      marker.center.dy - size.height / 2,
    );
    final rect = origin & size;

    if (rect.right > canvasSize.width || rect.bottom > canvasSize.height || rect.top < 0) {
      continue;
    }
    if (occupied.any((r) => r.overlaps(rect))) {
      continue;
    }
    occupied.add(rect);
    placements.add((markerIndex: i, textOrigin: origin));
  }

  return placements;
}
