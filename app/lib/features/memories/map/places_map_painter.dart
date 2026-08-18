import 'package:flutter/material.dart';

import '../../../api/models.dart';
import 'map_labels.dart';
import 'map_projection.dart';

/// One marker's already-computed screen layout - center and radius in canvas pixels, plus
/// the [Place] it stands for, so a tap handler positioned at the same [center]/[radius]
/// (see PlacesMapView's own Stack of invisible tap targets) knows which place it opened.
/// A plain record: structural equality falls out for free, which is all
/// [PlacesMapPainter.shouldRepaint] needs.
typedef MarkerLayout = ({Place place, Offset center, double radius});

/// The maximum width, in logical pixels, a marker's own label is allowed to lay out at -
/// past this it's truncated with an ellipsis rather than sprawling across the map and
/// making collision detection (see map_labels.dart) nearly guaranteed for anything nearby.
const double kMapLabelMaxWidth = 120.0;

const double _kMapLabelFontSize = 11.0;
const double _kMapLabelHaloPadding = 3.0;

/// Paints the map's own outline layer(s) (clipped/projected into whatever
/// [lngWindow]/[latWindow] the map view is currently showing - the fitted tier window, or
/// a live pan/zoom transform of it, see PlacesMapView) plus one dot per [markers] entry,
/// sized and colored per its own [MarkerLayout] - home-area places filled solid in
/// [accent], trip places drawn in a muted version of it, so the two read differently at a
/// glance per the brief. Tap handling is NOT this painter's job - see PlacesMapView's own
/// overlay of invisible [GestureDetector]s positioned at these same marker centers.
class PlacesMapPainter extends CustomPainter {
  const PlacesMapPainter({
    required this.rings,
    required this.borderRings,
    required this.lngWindow,
    required this.latWindow,
    required this.markers,
    required this.landColor,
    required this.outlineColor,
    required this.borderColor,
    required this.accent,
    required this.accentMuted,
    required this.showLabels,
    required this.labelColor,
    required this.labelHaloColor,
  });

  /// Filled AND stroked - country outlines (either tier's own asset, see
  /// PlacesMapView's own asset selection).
  final List<List<Offset>> rings;

  /// Stroked only, never filled - region/local tier's own admin-1 (state/province)
  /// boundaries. Empty at the world tier, which carries no such layer at all - see
  /// region_outlines.dart's own doc comment for why these paint differently from [rings].
  final List<List<Offset>> borderRings;

  final LngWindow lngWindow;
  final LatWindow latWindow;
  final List<MarkerLayout> markers;
  final Color landColor;
  final Color outlineColor;
  final Color borderColor;
  final Color accent;
  final Color accentMuted;

  /// Whether to draw a text label next to each marker at all - false at the world tier,
  /// where "at tight zoom the labels carry the meaning, not the coastline" (the brief this
  /// implements) doesn't apply: a world-scale view has no tight zoom, and a couple dozen
  /// labels crowded across a flattened globe would read as worse clutter than the plain
  /// dots already do on their own. See map_labels.dart's own layoutMarkerLabels for the
  /// placement/collision rule this defers to when true.
  final bool showLabels;
  final Color labelColor;
  final Color labelHaloColor;

  Path _pathFor(List<List<Offset>> ringSet, Size size) {
    final path = Path()..fillType = PathFillType.evenOdd;
    Offset project(Offset lngLat) => projectLatLng(
        lat: lngLat.dy, lng: lngLat.dx, lngWindow: lngWindow, latWindow: latWindow, size: size);
    for (final ring in ringSet) {
      if (ring.isEmpty) continue;
      final first = project(ring.first);
      path.moveTo(first.dx, first.dy);
      for (var i = 1; i < ring.length; i++) {
        final pt = project(ring[i]);
        path.lineTo(pt.dx, pt.dy);
      }
      path.close();
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final landPath = _pathFor(rings, size);
    canvas.drawPath(landPath, Paint()..color = landColor);
    canvas.drawPath(
      landPath,
      Paint()
        ..color = outlineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.75,
    );

    if (borderRings.isNotEmpty) {
      final borderPath = _pathFor(borderRings, size);
      canvas.drawPath(
        borderPath,
        Paint()
          ..color = borderColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5,
      );
    }

    final ringPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final marker in markers) {
      final color = marker.place.homeArea ? accent : accentMuted;
      canvas.drawCircle(marker.center, marker.radius, Paint()..color = color);
      canvas.drawCircle(marker.center, marker.radius, ringPaint);
    }

    if (showLabels) _paintLabels(canvas, size);
  }

  void _paintLabels(Canvas canvas, Size size) {
    final style = TextStyle(
      color: labelColor,
      fontSize: _kMapLabelFontSize,
      fontWeight: FontWeight.w600,
    );
    final painters = <String, TextPainter>{};
    TextPainter painterFor(String text) => painters.putIfAbsent(
        text,
        () => TextPainter(
              text: TextSpan(text: text, style: style),
              textDirection: TextDirection.ltr,
              maxLines: 1,
              ellipsis: '…',
            )..layout(maxWidth: kMapLabelMaxWidth));

    final subjects = [
      for (final m in markers) (text: m.place.location, center: m.center, radius: m.radius),
    ];
    final placements = layoutMarkerLabels(
      subjects,
      (text) => painterFor(text).size,
      canvasSize: size,
    );

    for (final placement in placements) {
      final painter = painterFor(subjects[placement.markerIndex].text);
      final haloRect = (placement.textOrigin & painter.size).inflate(_kMapLabelHaloPadding);
      canvas.drawRRect(
        RRect.fromRectAndRadius(haloRect, const Radius.circular(4)),
        Paint()..color = labelHaloColor,
      );
      painter.paint(canvas, placement.textOrigin);
    }
  }

  @override
  bool shouldRepaint(covariant PlacesMapPainter oldDelegate) {
    return oldDelegate.rings != rings ||
        oldDelegate.borderRings != borderRings ||
        oldDelegate.lngWindow != lngWindow ||
        oldDelegate.latWindow != latWindow ||
        oldDelegate.markers != markers ||
        oldDelegate.landColor != landColor ||
        oldDelegate.outlineColor != outlineColor ||
        oldDelegate.borderColor != borderColor ||
        oldDelegate.accent != accent ||
        oldDelegate.accentMuted != accentMuted ||
        oldDelegate.showLabels != showLabels ||
        oldDelegate.labelColor != labelColor ||
        oldDelegate.labelHaloColor != labelHaloColor;
  }
}
