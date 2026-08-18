import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../api/models.dart';
import '../../../theme/accent.dart';
import '../../../theme/tokens.dart';
import 'geo.dart';
import 'map_projection.dart';
import 'map_tier.dart';
import 'map_transform.dart';
import 'places_map_painter.dart';
import 'region_outlines.dart';
import 'world_outlines.dart';

/// A fixed background for the map canvas itself - distinct from the app's own kBgSurface so
/// "ocean" reads as its own region rather than matching the surrounding card chrome.
const _mapOcean = Color(0xFF0F1B24);
const _mapLand = Color(0xFF23303A);
const _mapOutline = Color(0xFF3A4C58);

/// Admin-1 (state/province) boundary color - a step brighter than [_mapOutline] so a
/// state line reads as its own distinct layer rather than blending into the coastline.
const _mapBorder = Color(0xFF52707E);

const _mapLabelColor = Color(0xFFE9F1F4);

/// The fixed height of the map canvas - short enough that it (plus the toggle row above it
/// and the couldn't-place note below) fits comfortably above the fold on a small phone,
/// tall enough that a world map's own aspect ratio (2:1) doesn't get too cramped.
const double kPlacesMapHeight = 240.0;

/// How far a fit-to-points window is padded beyond the group's own tightest bounding
/// window, as a fraction of that window's own larger span - enough that a marker right at
/// the edge of the group's spread isn't drawn flush against the canvas edge.
const double _kRegionPaddingFraction = 0.18;

/// A minimum degrees of padding for [_kRegionPaddingFraction] to fall back to when the
/// group's own bounding window is nearly a point - otherwise a tight cluster near the
/// singlePlace/region tier boundary would barely pad at all. Deliberately small: a real
/// group's own region-tier spread is very often a single metro area or a handful of
/// neighbouring counties (a few degrees at most - see map_tier.dart's own doc comment on
/// why region is the common real case, not the rare one), and the old 3.0° floor padded a
/// spread that tight to nearly four times its own width, rendering it as a tiny cluster
/// lost in the middle of a needlessly wide fitted view.
const double _kRegionMinPaddingDegrees = 0.5;

/// Above this effective span (degrees, the larger of the current window's own lng/lat
/// span), the map uses the coarse world-tier outline asset with no admin-1 boundaries and
/// no labels; at or below it, the finer region/local asset (see region_outlines.dart),
/// admin-1 boundaries, and place labels. This is a property of the CURRENT view, not the
/// group's own static [MapTier] classification: pan/zoom (see map_transform.dart) lets a
/// world-tier view zoom in past this threshold too, at which point it switches to the
/// finer layer exactly as if the group's own places had fit a region view from the start -
/// see _mapCanvas. Chosen comfortably above the widest a real region-tier fitted view ever
/// gets (a few tens of degrees) and comfortably below "still basically the whole world".
const double kMapFineDetailMaxSpanDegrees = 45.0;

/// The map view of the Memories surface's "Places" screen - the second way to look at the
/// same [places] the list view already fetched (see _PlacesListView in memories_screen.dart,
/// which owns the fetch and the list/map toggle; this widget is purely a rendering of data
/// it's handed).
///
/// Supports pinch-to-zoom and drag-to-pan (see map_transform.dart for the transform maths,
/// and _onScaleStart/_onScaleUpdate/_onScaleEnd below for how a live gesture drives it) -
/// clamped so a viewer can never zoom out past the whole world or pan past either pole, and
/// always recoverable via a double-tap or the small reset button (see _resetButton). The
/// Memories surface's own close gesture is ALSO a horizontal drag anywhere on the surface
/// (see MemoriesSurface's own doc comment) - the explicit rule that keeps the two from
/// fighting is that the surface's own drag-to-close is suppressed entirely while this view
/// is the one showing (see MemoriesHubController.mapViewActive and
/// _MemoriesSurfaceContentState's own doc comment in memories_screen.dart), never a gesture-
/// arena trick here. The header's close (X) button and the Android back button are both
/// unaffected either way, so the surface always stays closable.
///
/// The equivalent problem exists on the vertical axis too, against a different ancestor:
/// _PlacesListView's own map-mode slot used to wrap this whole widget in a
/// SingleChildScrollView (for a long couldn't-place-on-map note to scroll into view on a
/// short screen). A Scrollable's own drag recognizer competes for vertical drags exactly
/// like the surface's did for horizontal ones, so this widget is no longer inside one at
/// all - see build()'s own doc comment for how it keeps that overflow protection without
/// ever putting the map canvas itself inside a scrollable.
class PlacesMapView extends StatefulWidget {
  const PlacesMapView({super.key, required this.places, required this.onOpenPlace});

  final List<Place> places;
  final ValueChanged<Place> onOpenPlace;

  @override
  State<PlacesMapView> createState() => _PlacesMapViewState();
}

class _PlacesMapViewState extends State<PlacesMapView> {
  // widget.places never changes under this State - see PlacesMapView's own doc comment:
  // _PlacesListView remounts (a fresh ValueKey) on every group switch, so this only ever
  // has to reflect one fixed payload for its whole lifetime, computed once rather than
  // recomputed on every build/gesture-driven setState.
  late final List<Place> _located = [
    for (final p in widget.places)
      if (p.lat != null && p.lng != null) p,
  ];
  late final List<Place> _unlocated = [
    for (final p in widget.places)
      if (p.lat == null || p.lng == null) p,
  ];
  late final MapTier _tier = decideMapTier([for (final p in _located) (lat: p.lat!, lng: p.lng!)]);

  late final LngWindow _baseLngWindow;
  late final LatWindow _baseLatWindow;

  /// The live pan/zoom state, or null before any gesture/reset has touched it - null reads
  /// as "the fitted base window", exactly [MapTransform.identity] would compute, without
  /// this State needing [_baseLngWindow]/[_baseLatWindow] built yet to construct one purely
  /// to represent "nothing has happened".
  MapTransform? _transform;

  Offset? _gestureStartFocalPoint;
  MapTransform? _gestureStartTransform;

  final Future<WorldOutlines> _worldFuture = WorldOutlines.load();
  final Future<RegionOutlines> _regionFuture = RegionOutlines.load();

  @override
  void initState() {
    super.initState();
    if (_tier == MapTier.world) {
      _baseLngWindow = const LngWindow(west: -180, spanDegrees: 360);
      _baseLatWindow = const LatWindow(south: -85, north: 85);
    } else {
      var lngW = computeLngWindow(_located.map((p) => p.lng!).toList());
      var latW = computeLatWindow(_located.map((p) => p.lat!).toList());
      final padding = math.max(
          math.max(lngW.spanDegrees, latW.spanDegrees) * _kRegionPaddingFraction,
          _kRegionMinPaddingDegrees);
      _baseLngWindow = lngW.padded(padding);
      _baseLatWindow = latW.padded(padding);
    }
  }

  MapTransform get _effectiveTransform =>
      _transform ?? MapTransform.identity(baseLng: _baseLngWindow, baseLat: _baseLatWindow);

  // Deliberately no SingleChildScrollView wrapping the whole thing (the old, gesture-free
  // map's own approach, and still what the list view's own caller uses) - the map canvas
  // below captures vertical drags for its own pan/zoom, and an ancestor Scrollable
  // competing for that same gesture is exactly the "dragging up sometimes scrolls the
  // page instead" roughness a real device surfaced. So: the map (or its own no-map state)
  // is never inside a scrollable at all - it's wrapped in Flexible instead, so it renders
  // at its own preferred [kPlacesMapHeight] whenever there's room, but SHRINKS rather than
  // overflowing on a short screen/large text-scale combination that leaves less than that
  // (a real, tested combination - see sheet_layout_smoke_test.dart's own worst-case sweep;
  // this is what that scrollable used to paper over by letting the viewer scroll past a
  // map that didn't fully fit, which is no longer an option once dragging on it has to mean
  // panning, never scrolling the page). _unlocatedNote below it - the one part of this view
  // whose height genuinely isn't bounded at all (a long combined list of unresolved place
  // names can wrap to several lines) - gets an Expanded SingleChildScrollView of its own
  // instead: a scrollable there is always safe, since nothing about a block of static text
  // competes for a gesture the way the map does. The caller (PlacesMapView's own doc
  // comment) is what has to give this widget a bounded height for either Flexible/Expanded
  // to be valid at all - true of its one real call site (_PlacesListView's own Expanded
  // map-mode slot) and every existing test that pumps this widget, which all go through
  // that same call site.
  @override
  Widget build(BuildContext context) {
    final mapOrState = _located.isEmpty
        ? _cannotPlotAnyState(context)
        : _tier == MapTier.singlePlace
            ? _singlePlaceState(context)
            : _map(context);
    if (_unlocated.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [Flexible(child: mapOrState)],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(child: mapOrState),
        const SizedBox(height: 10),
        Expanded(child: SingleChildScrollView(child: _unlocatedNote(context))),
      ],
    );
  }

  Widget _map(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: kPlacesMapHeight,
        color: _mapOcean,
        child: FutureBuilder<List<Object>>(
          // Both outline assets are small (see assets/worldmap/SOURCE.md - ~22KB and
          // ~300KB, neither gzipped, so parsing either is a handful of milliseconds) and
          // WorldOutlines.load()/RegionOutlines.load() each cache their own already-parsed
          // result - so waiting on both once, up front, regardless of which one a given
          // group's own fitted tier starts on, is simpler and just as fast in practice as
          // conditionally fetching only one: a world-tier view might still need the finer
          // asset the moment a viewer zooms in past kMapFineDetailMaxSpanDegrees (see
          // _mapCanvas), and neither asset is ever fetched a second time either way.
          future: Future.wait([_worldFuture, _regionFuture]),
          builder: (context, snapshot) {
            final data = snapshot.data;
            if (data == null) {
              return Center(child: CircularProgressIndicator(color: context.accent));
            }
            final world = data[0] as WorldOutlines;
            final region = data[1] as RegionOutlines;
            return LayoutBuilder(
              builder: (context, constraints) => _mapCanvas(
                context,
                world,
                region,
                Size(constraints.maxWidth, constraints.maxHeight),
              ),
            );
          },
        ),
      ),
    );
  }

  void _onScaleStart(ScaleStartDetails details) {
    _gestureStartFocalPoint = details.localFocalPoint;
    _gestureStartTransform = _effectiveTransform;
  }

  void _onScaleUpdate(ScaleUpdateDetails details, Size canvasSize) {
    final start = _gestureStartTransform;
    final startFocal = _gestureStartFocalPoint;
    if (start == null || startFocal == null) return;
    setState(() {
      _transform = updateMapTransformForScaleGesture(
        start: start,
        startFocalPoint: startFocal,
        currentFocalPoint: details.localFocalPoint,
        gestureScale: details.scale,
        baseLng: _baseLngWindow,
        baseLat: _baseLatWindow,
        canvasSize: canvasSize,
      );
    });
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _gestureStartFocalPoint = null;
    _gestureStartTransform = null;
  }

  /// Returns to the fitted view - the header's double-tap and the small reset button (see
  /// _resetButton) both just call this; a no-op (still valid, still cheap) when the view is
  /// already there.
  void _resetTransform() => setState(() => _transform = null);

  Widget _mapCanvas(BuildContext context, WorldOutlines world, RegionOutlines region, Size size) {
    final transform = _effectiveTransform;
    final window =
        applyMapTransform(baseLng: _baseLngWindow, baseLat: _baseLatWindow, transform: transform);
    final lngWindow = window.lng;
    final latWindow = window.lat;

    final effectiveSpan = math.max(lngWindow.spanDegrees, latWindow.spanDegrees);
    final useFineDetail = effectiveSpan <= kMapFineDetailMaxSpanDegrees;

    final maxPostCount = _located.map((p) => p.postCount).fold(1, math.max);
    final rawCenters = [
      for (final p in _located)
        projectLatLng(
            lat: p.lat!, lng: p.lng!, lngWindow: lngWindow, latWindow: latWindow, size: size)
    ];
    final radii = [for (final p in _located) markerRadius(p.postCount, maxPostCount)];
    final centers = nudgeOverlappingMarkers(rawCenters, radii);
    final markers = [
      for (var i = 0; i < _located.length; i++)
        (place: _located[i], center: centers[i], radius: radii[i]),
    ];

    final accent = context.accent;
    return GestureDetector(
      onScaleStart: _onScaleStart,
      onScaleUpdate: (d) => _onScaleUpdate(d, size),
      onScaleEnd: _onScaleEnd,
      onDoubleTap: _resetTransform,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: PlacesMapPainter(
                rings: useFineDetail ? region.admin0Rings : world.rings,
                borderRings: useFineDetail ? region.admin1Rings : const [],
                lngWindow: lngWindow,
                latWindow: latWindow,
                markers: markers,
                landColor: _mapLand,
                outlineColor: _mapOutline,
                borderColor: _mapBorder,
                accent: accent,
                accentMuted: accent.withValues(alpha: 0.55),
                showLabels: useFineDetail,
                labelColor: _mapLabelColor,
                labelHaloColor: Colors.black.withValues(alpha: 0.55),
              ),
            ),
          ),
          for (final m in markers) _markerTapTarget(m),
          _resetButton(context),
        ],
      ),
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

  /// The reset/recenter affordance the brief asks for explicitly, alongside the
  /// double-tap _mapCanvas's own GestureDetector already offers - a small, low-contrast
  /// icon rather than a full button, matching this map's own generally understated chrome
  /// (see the toggle row and attribution text above/below it).
  Widget _resetButton(BuildContext context) {
    return Positioned(
      right: 8,
      bottom: 8,
      child: Semantics(
        button: true,
        label: 'Reset map view',
        child: Material(
          color: Colors.black.withValues(alpha: 0.45),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: _resetTransform,
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(Icons.center_focus_strong, size: 16, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }

  Widget _singlePlaceState(BuildContext context) {
    final single = _located.length == 1;
    final headline = single
        ? 'Every check-in has been in ${_located.single.location}.'
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
  Widget _unlocatedNote(BuildContext context) {
    final names = _unlocated.map((p) => p.location).join(', ');
    return Text(
      "Couldn't place on the map: $names",
      style: const TextStyle(color: kFgMuted, fontSize: 12),
    );
  }
}
