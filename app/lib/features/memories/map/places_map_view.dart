import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../api/models.dart';
import '../../../theme/accent.dart';
import '../../../theme/tokens.dart';
import 'geo.dart';
import 'map_projection.dart';
import 'map_tier.dart';
import 'places_map_painter.dart';
import 'world_outlines.dart';

/// A fixed background for the map canvas itself - distinct from the app's own kBgSurface so
/// "ocean" reads as its own region rather than matching the surrounding card chrome.
const _mapOcean = Color(0xFF0F1B24);
const _mapLand = Color(0xFF23303A);
const _mapOutline = Color(0xFF3A4C58);

/// The fixed height of the map canvas - short enough that it (plus the toggle row above it
/// and the couldn't-place note below) fits comfortably above the fold on a small phone,
/// tall enough that a world map's own aspect ratio (2:1) doesn't get too cramped.
const double kPlacesMapHeight = 240.0;

/// How far a fit-to-points window is padded beyond the group's own tightest bounding
/// window, as a fraction of that window's own larger span - enough that a marker right at
/// the edge of the group's spread isn't drawn flush against the canvas edge.
const double _kRegionPaddingFraction = 0.18;

/// A minimum degrees of padding for [_kRegionPaddingFraction] to fall back to when the
/// group's own bounding window is nearly a point (a handful of degrees) - otherwise a tight
/// cluster near the singlePlace/region tier boundary would barely pad at all.
const double _kRegionMinPaddingDegrees = 3.0;

/// The map view of the Memories surface's "Places" screen - the second way to look at the
/// same [places] the list view already fetched (see _PlacesListView in memories_screen.dart,
/// which owns the fetch and the list/map toggle; this widget is purely a rendering of data
/// it's handed).
///
/// Deliberately gesture-free in v1 (no pinch-to-zoom, no pan): the Memories surface's own
/// close gesture is a horizontal drag anywhere on the surface (see MemoriesSurface's own
/// doc comment), and a map that captured horizontal drags for panning would fight that
/// gesture on every phone that has one. Shipping a static, fitted view is preferable to a
/// map that occasionally swallows the surface's own close swipe.
class PlacesMapView extends StatefulWidget {
  const PlacesMapView({super.key, required this.places, required this.onOpenPlace});

  final List<Place> places;
  final ValueChanged<Place> onOpenPlace;

  @override
  State<PlacesMapView> createState() => _PlacesMapViewState();
}

class _PlacesMapViewState extends State<PlacesMapView> {
  final Future<WorldOutlines> _outlinesFuture = WorldOutlines.load();

  @override
  Widget build(BuildContext context) {
    final located = [
      for (final p in widget.places)
        if (p.lat != null && p.lng != null) p,
    ];
    final unlocated = [
      for (final p in widget.places)
        if (p.lat == null || p.lng == null) p,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (located.isEmpty) _cannotPlotAnyState(context) else _placedState(context, located),
        if (unlocated.isNotEmpty) ...[
          const SizedBox(height: 10),
          _unlocatedNote(context, unlocated),
        ],
      ],
    );
  }

  Widget _placedState(BuildContext context, List<Place> located) {
    final points = [for (final p in located) (lat: p.lat!, lng: p.lng!)];
    final tier = decideMapTier(points);
    if (tier == MapTier.singlePlace) return _singlePlaceState(context, located);
    return _map(context, located, tier);
  }

  Widget _map(BuildContext context, List<Place> located, MapTier tier) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: kPlacesMapHeight,
        color: _mapOcean,
        child: FutureBuilder<WorldOutlines>(
          future: _outlinesFuture,
          builder: (context, snapshot) {
            final outlines = snapshot.data;
            if (outlines == null) {
              return Center(child: CircularProgressIndicator(color: context.accent));
            }
            return LayoutBuilder(
              builder: (context, constraints) => _mapCanvas(
                context,
                located,
                tier,
                outlines,
                Size(constraints.maxWidth, constraints.maxHeight),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _mapCanvas(
      BuildContext context, List<Place> located, MapTier tier, WorldOutlines outlines, Size size) {
    final LngWindow lngWindow;
    final LatWindow latWindow;
    if (tier == MapTier.world) {
      lngWindow = const LngWindow(west: -180, spanDegrees: 360);
      latWindow = const LatWindow(south: -85, north: 85);
    } else {
      var lngW = computeLngWindow(located.map((p) => p.lng!).toList());
      var latW = computeLatWindow(located.map((p) => p.lat!).toList());
      final padding = math.max(
          math.max(lngW.spanDegrees, latW.spanDegrees) * _kRegionPaddingFraction,
          _kRegionMinPaddingDegrees);
      lngW = lngW.padded(padding);
      latW = latW.padded(padding);
      lngWindow = lngW;
      latWindow = latW;
    }

    final maxPostCount = located.map((p) => p.postCount).fold(1, math.max);
    final rawCenters = [
      for (final p in located)
        projectLatLng(
            lat: p.lat!, lng: p.lng!, lngWindow: lngWindow, latWindow: latWindow, size: size)
    ];
    final radii = [for (final p in located) markerRadius(p.postCount, maxPostCount)];
    final centers = nudgeOverlappingMarkers(rawCenters, radii);
    final markers = [
      for (var i = 0; i < located.length; i++)
        (place: located[i], center: centers[i], radius: radii[i]),
    ];

    final accent = context.accent;
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: PlacesMapPainter(
              rings: outlines.rings,
              lngWindow: lngWindow,
              latWindow: latWindow,
              markers: markers,
              landColor: _mapLand,
              outlineColor: _mapOutline,
              accent: accent,
              accentMuted: accent.withValues(alpha: 0.55),
            ),
          ),
        ),
        for (final m in markers) _markerTapTarget(m),
      ],
    );
  }

  /// An invisible tap target centered on [marker]'s own painted circle, padded a little
  /// beyond its radius so a small marker is still comfortably tappable. Stacked in the same
  /// order the markers were nudged into (see nudgeOverlappingMarkers), so a marker drawn on
  /// top (later in the list) also wins ties for taps that land in its own padded square -
  /// the "let the larger one win, smaller still tappable" handling the brief calls out:
  /// a smaller marker peeking out from behind a larger one still has its own square, and
  /// only the region the two squares actually overlap ever favors whichever is drawn later.
  Widget _markerTapTarget(MarkerLayout m) {
    const tapPadding = 8.0;
    final side = (m.radius + tapPadding) * 2;
    return Positioned(
      left: m.center.dx - m.radius - tapPadding,
      top: m.center.dy - m.radius - tapPadding,
      width: side,
      height: side,
      child: Semantics(
        button: true,
        label: m.place.location,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onOpenPlace(m.place),
        ),
      ),
    );
  }

  Widget _singlePlaceState(BuildContext context, List<Place> located) {
    final single = located.length == 1;
    final headline = single
        ? 'Every check-in has been in ${located.single.location}.'
        : "You've all stuck close together so far.";
    return Container(
      height: kPlacesMapHeight,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: kBgSurface,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.place_outlined, size: 36, color: context.accent),
            const SizedBox(height: 12),
            Text(headline,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(color: kFgPrimary, fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 6),
            const Text("A map isn't much use until your group starts spreading out.",
                textAlign: TextAlign.center, style: TextStyle(color: kFgMuted, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _cannotPlotAnyState(BuildContext context) {
    return Container(
      height: kPlacesMapHeight,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: kBgSurface,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.public_off_outlined, size: 36, color: kFgMuted),
            SizedBox(height: 12),
            Text("None of your group's places could be placed on a map yet.",
                textAlign: TextAlign.center,
                style: TextStyle(color: kFgSecondary, fontSize: 14, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  /// The honest surfacing [Place.lat]/[Place.lng]'s own doc comment requires: a place with
  /// no resolved coordinates never silently vanishes just because a map exists now - it's
  /// still visible in the list view (see _PlacesListView), and here in map mode its name is
  /// named explicitly rather than only being absent from the canvas above.
  Widget _unlocatedNote(BuildContext context, List<Place> unlocated) {
    final names = unlocated.map((p) => p.location).join(', ');
    return Text(
      "Couldn't place on the map: $names",
      style: const TextStyle(color: kFgMuted, fontSize: 12),
    );
  }
}
