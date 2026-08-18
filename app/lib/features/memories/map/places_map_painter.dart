import 'package:flutter/material.dart';

import '../../../api/models.dart';
import 'map_projection.dart';

/// One marker's already-computed screen layout - center and radius in canvas pixels, plus
/// the [Place] it stands for, so a tap handler positioned at the same [center]/[radius]
/// (see PlacesMapView's own Stack of invisible tap targets) knows which place it opened.
/// A plain record: structural equality falls out for free, which is all
/// [PlacesMapPainter.shouldRepaint] needs.
typedef MarkerLayout = ({Place place, Offset center, double radius});

/// Paints the world outline asset (clipped/projected into whatever [lngWindow]/[latWindow]
/// the map view fit to the group's own places) plus one dot per [markers] entry, sized and
/// colored per its own [MarkerLayout] - home-area places filled solid in [accent], trip
/// places drawn in a muted version of it, so the two read differently at a glance per the
/// brief. Tap handling is NOT this painter's job - see PlacesMapView's own overlay of
/// invisible [GestureDetector]s positioned at these same marker centers.
class PlacesMapPainter extends CustomPainter {
  const PlacesMapPainter({
    required this.rings,
    required this.lngWindow,
    required this.latWindow,
    required this.markers,
    required this.landColor,
    required this.outlineColor,
    required this.accent,
    required this.accentMuted,
  });

  final List<List<Offset>> rings;
  final LngWindow lngWindow;
  final LatWindow latWindow;
  final List<MarkerLayout> markers;
  final Color landColor;
  final Color outlineColor;
  final Color accent;
  final Color accentMuted;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..fillType = PathFillType.evenOdd;
    for (final ring in rings) {
      if (ring.isEmpty) continue;
      Offset project(Offset lngLat) => projectLatLng(
          lat: lngLat.dy, lng: lngLat.dx, lngWindow: lngWindow, latWindow: latWindow, size: size);
      final first = project(ring.first);
      path.moveTo(first.dx, first.dy);
      for (var i = 1; i < ring.length; i++) {
        final pt = project(ring[i]);
        path.lineTo(pt.dx, pt.dy);
      }
      path.close();
    }
    canvas.drawPath(path, Paint()..color = landColor);
    canvas.drawPath(
      path,
      Paint()
        ..color = outlineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.75,
    );

    final ringPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final marker in markers) {
      final color = marker.place.homeArea ? accent : accentMuted;
      canvas.drawCircle(marker.center, marker.radius, Paint()..color = color);
      canvas.drawCircle(marker.center, marker.radius, ringPaint);
    }
  }

  @override
  bool shouldRepaint(covariant PlacesMapPainter oldDelegate) {
    return oldDelegate.rings != rings ||
        oldDelegate.lngWindow != lngWindow ||
        oldDelegate.latWindow != latWindow ||
        oldDelegate.markers != markers ||
        oldDelegate.landColor != landColor ||
        oldDelegate.outlineColor != outlineColor ||
        oldDelegate.accent != accent ||
        oldDelegate.accentMuted != accentMuted;
  }
}
