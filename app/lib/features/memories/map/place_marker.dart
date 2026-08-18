import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../api/models.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/auth_image.dart';

/// The smallest and largest a place node is drawn, in logical pixels.
///
/// A node carries the place's own cover photo, so the floor is set by how small a face or a
/// landscape stays recognisable rather than by how small a dot could be, and the ceiling by
/// how much of a phone-width map one node may cover before it hides the map under it.
const double kPlaceNodeMinDiameter = 38.0;
const double kPlaceNodeMaxDiameter = 58.0;

/// Diameter for a place with [postCount] posts, against the busiest place in the same
/// group.
///
/// Scaled on the square root of the ratio, not the ratio itself: a node is a disc, so
/// matching AREA to the count is what actually reads as "twice as much happened here".
/// Linear diameter would make a place with ten times the posts look a hundred times
/// heavier.
double placeNodeDiameter(int postCount, int maxPostCount) {
  if (maxPostCount <= 1) return kPlaceNodeMinDiameter;
  final ratio = (postCount.clamp(1, maxPostCount)) / maxPostCount;
  return kPlaceNodeMinDiameter + (kPlaceNodeMaxDiameter - kPlaceNodeMinDiameter) * math.sqrt(ratio);
}

/// One place drawn on the map as its own cover photo in a circle.
///
/// A photo rather than a coloured dot because the point of the map is which places the
/// group's pictures came from - a dot makes the viewer tap to find out, a thumbnail tells
/// them at a glance.
class PlacePhotoNode extends StatelessWidget {
  const PlacePhotoNode({
    super.key,
    required this.place,
    required this.diameter,
    required this.accent,
    required this.onTap,
  });

  final Place place;
  final double diameter;
  final Color accent;

  /// Handled by the node itself rather than by the cluster layer's own onMarkerTap: the
  /// layer's hit-testing works off the marker's declared box, so a circular node reports
  /// taps in its corners that visibly missed it, and a tap that lands on the widget is the
  /// thing a viewer actually means.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: place.location,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: 0.92), width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: ClipOval(
            child: place.coverMediaId != null
                ? AuthImage(mediaId: place.coverMediaId!, groupId: place.groupId)
                : Container(
                    color: accent.withValues(alpha: 0.85),
                    child: const Icon(Icons.place, size: 18, color: Colors.white),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Several nearby places collapsed into one node, with a count.
///
/// Shows the busiest member's own cover photo underneath rather than a flat swatch, so a
/// cluster still reads as "pictures from around here" and stays visually continuous with
/// the individual nodes it splits into when zoomed.
class PlaceClusterNode extends StatelessWidget {
  const PlaceClusterNode({
    super.key,
    required this.places,
    required this.diameter,
    required this.accent,
  });

  final List<Place> places;
  final double diameter;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final lead = places.reduce((a, b) => b.postCount > a.postCount ? b : a);
    return Semantics(
      button: true,
      label: '${places.length} places',
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.92), width: 2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipOval(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (lead.coverMediaId != null)
                AuthImage(mediaId: lead.coverMediaId!, groupId: lead.groupId)
              else
                Container(color: accent.withValues(alpha: 0.85)),
              Container(color: Colors.black.withValues(alpha: 0.45)),
              Center(
                child: Text(
                  '${places.length}',
                  style: const TextStyle(
                    color: kFgPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
