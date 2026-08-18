import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';

import '../../../api/models.dart';
import '../../../theme/accent.dart';
import '../../../theme/tokens.dart';
import 'detail_outlines.dart';
import 'map_outline_layers.dart';
import 'map_tier.dart';
import 'place_marker.dart';
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

/// Detail-layer colours (lakes, rivers, built-up areas - see detail_outlines.dart).
///
/// Lakes sit a touch lighter than the open ocean rather than matching it exactly: an inland
/// lake painted in the identical colour reads as a hole punched through the land, where a
/// slightly lifted one reads as water sitting in it. Rivers are lighter again so a
/// single-pixel line stays visible against the land it crosses, and built-up areas are a
/// very low-alpha warm tint - enough that "a town is here" registers without competing with
/// the place nodes, which are the actual subject of this map.
const _mapLake = Color(0xFF14232E);
const _mapRiver = Color(0xFF35566B);
const _mapUrban = Color(0x1FE8B981);

/// The fixed height of the inline map card - short enough that it (plus the toggle row
/// above it and the couldn't-place note below) fits comfortably above the fold on a small
/// phone, tall enough that a world map's own aspect ratio (2:1) doesn't get too cramped.
const double kPlacesMapHeight = 240.0;

/// Above this visible span (degrees, the larger of the camera's own lng/lat span) the map
/// draws the coarse world-tier outline asset with no admin-1 boundaries; at or below it,
/// the finer region asset plus state lines (see region_outlines.dart).
///
/// A property of the CURRENT camera, not the group's own static [MapTier]: zooming a
/// world-tier view in past this crosses over to the finer layer exactly as if the group's
/// places had fitted a region view to begin with.
const double kMapFineDetailMaxSpanDegrees = 45.0;

/// Zoom bounds for the camera.
///
/// The ceiling is deliberately low for a map: with no tile imagery there is nothing below
/// roughly [_kMaxZoom] but empty ocean colour and the nodes themselves, so letting the
/// camera run to street level would only ever let someone get lost in a blank field. It is
/// still set well above the fitted view so a dense cluster can be pulled apart.
const double _kMinZoom = 1.0;
const double _kMaxZoom = 12.0;

/// The tightest the initial fit is allowed to zoom, for the same reason as [_kMaxZoom]: a
/// group whose places all sit inside one county would otherwise open on a blank field.
const double _kMaxFitZoom = 9.0;

/// The map view of the Memories surface's "Places" screen - the second way to look at the
/// same [places] the list view already fetched.
///
/// Pan, pinch-zoom, fling and double-tap-to-zoom all come from flutter_map rather than
/// from hand-written gesture and projection code. The Memories surface's own close gesture
/// is ALSO a horizontal drag anywhere on the surface, and the rule that keeps the two from
/// fighting is unchanged: the surface suppresses its own drag-to-close entirely while this
/// view is showing (see MemoriesHubController.mapViewActive), never a gesture-arena trick
/// here. The header's close (X) button and the Android back button are unaffected, so the
/// surface always stays closable.
class PlacesMapView extends StatelessWidget {
  const PlacesMapView({
    super.key,
    required this.places,
    required this.onOpenPlace,
    this.fullBleed = false,
    this.overlay,
    this.ringColorFor,
  });

  final List<Place> places;
  final ValueChanged<Place> onOpenPlace;

  /// Fills the space it is given, edge to edge, instead of rendering as a fixed-height
  /// rounded card.
  ///
  /// This is how Places opens: the map is the point of the screen, and a map big enough to
  /// read is worth more than a card with room for a toggle above it. The list is still one
  /// tap away from [overlay].
  final bool fullBleed;

  /// Chrome to float over the map in full-bleed mode - the view toggle and the group
  /// scope pill. Passed in rather than built here so this widget stays a rendering of
  /// places and knows nothing about the screen that hosts it.
  final Widget? overlay;

  /// The colour to ring each node with, or null for the default white.
  ///
  /// Only set when the map is showing several groups at once, where the ring is what says
  /// which group a place came from. With one group it would be a constant, and a constant
  /// coloured ring on every node is just a worse white one.
  final Color? Function(Place place)? ringColorFor;

  List<Place> get _located => [
        for (final p in places)
          if (p.lat != null && p.lng != null) p,
      ];

  List<Place> get _unlocated => [
        for (final p in places)
          if (p.lat == null || p.lng == null) p,
      ];

  @override
  Widget build(BuildContext context) {
    final located = _located;
    final unlocated = _unlocated;
    final tier = decideMapTier([for (final p in located) (lat: p.lat!, lng: p.lng!)]);

    // The map proper, or the honest stand-in for a group that has nothing to plot yet.
    // Built once and placed by whichever layout branch runs below, so the two states are
    // never reachable in one mode and missing from the other.
    final bool plottable = located.isNotEmpty && tier != MapTier.singlePlace;

    if (fullBleed) {
      final Widget body = plottable
          ? PlacesMapCanvas(
              located: located,
              tier: tier,
              onOpenPlace: onOpenPlace,
              ringColorFor: ringColorFor,
              onExpand: () => _openFullScreen(context, located, tier),
            )
          : Center(
              child: located.isEmpty
                  ? const _MapEmptyState(
                      icon: Icons.public_off_outlined,
                      message: "None of your group's places could be placed on a map yet.",
                    )
                  : _SinglePlaceState(located: located),
            );
      return Stack(
        children: [
          Positioned.fill(child: body),
          // The chrome rides above EVERY state, not just the plottable one: the toggle is
          // the only way back to the list, and a group with one place or none is exactly
          // the group whose owner most needs it.
          if (overlay != null) Positioned(left: 12, top: 10, right: 12, child: overlay!),
          if (unlocated.isNotEmpty)
            Positioned(left: 12, right: 12, bottom: 10, child: _unlocatedPill(unlocated)),
        ],
      );
    }

    final Widget mapOrState;
    if (located.isEmpty) {
      mapOrState = const _MapEmptyState(
        icon: Icons.public_off_outlined,
        message: "None of your group's places could be placed on a map yet.",
      );
    } else if (tier == MapTier.singlePlace) {
      mapOrState = _SinglePlaceState(located: located);
    } else {
      mapOrState = ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          height: kPlacesMapHeight,
          child: PlacesMapCanvas(
            located: located,
            tier: tier,
            onOpenPlace: onOpenPlace,
            ringColorFor: ringColorFor,
            onExpand: () => _openFullScreen(context, located, tier),
          ),
        ),
      );
    }

    if (unlocated.isEmpty) {
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
        Expanded(child: SingleChildScrollView(child: _unlocatedNote(unlocated))),
      ],
    );
  }

  void _openFullScreen(BuildContext context, List<Place> located, MapTier tier) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlacesMapScreen(
          located: located,
          tier: tier,
          onOpenPlace: onOpenPlace,
        ),
      ),
    );
  }

  /// The full-bleed equivalent of [_unlocatedNote] - the same honesty in the space a map
  /// overlay actually has. Names them where there are few enough to name, and counts them
  /// otherwise, rather than letting a long list cover the map it is annotating.
  Widget _unlocatedPill(List<Place> unlocated) {
    final text = unlocated.length <= 2
        ? "Couldn't place on the map: ${unlocated.map((p) => p.location).join(', ')}"
        : "Couldn't place on the map: ${unlocated.length} places";
    return Align(
      alignment: Alignment.centerLeft,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(9999),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kFgSecondary, fontSize: 11)),
        ),
      ),
    );
  }

  /// The honest surfacing [Place.lat]/[Place.lng]'s own doc comment requires: a place with
  /// no resolved coordinates never silently vanishes just because a map exists - it's still
  /// in the list view, and here its name is named explicitly rather than only being absent
  /// from the canvas above.
  Widget _unlocatedNote(List<Place> unlocated) {
    final names = unlocated.map((p) => p.location).join(', ');
    return Text(
      "Couldn't place on the map: $names",
      style: const TextStyle(color: kFgMuted, fontSize: 12),
    );
  }
}

/// The full-screen map, pushed from the inline card's expand button.
///
/// The same [PlacesMapCanvas] the card shows, given the whole window - which is the only
/// size at which a group spread across a few states can be read at all.
class PlacesMapScreen extends StatelessWidget {
  const PlacesMapScreen({
    super.key,
    required this.located,
    required this.tier,
    required this.onOpenPlace,
  });

  final List<Place> located;
  final MapTier tier;
  final ValueChanged<Place> onOpenPlace;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _mapOcean,
      body: Stack(
        children: [
          Positioned.fill(
            child: PlacesMapCanvas(
              located: located,
              tier: tier,
              onOpenPlace: (place) {
                Navigator.of(context).pop();
                onOpenPlace(place);
              },
            ),
          ),
          Positioned(
            left: 8,
            top: MediaQuery.of(context).padding.top + 8,
            child: _MapChipButton(
              icon: Icons.arrow_back,
              semanticLabel: 'Close full screen map',
              onTap: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}

/// The map itself, shared by the inline card and the full-screen route.
class PlacesMapCanvas extends StatefulWidget {
  const PlacesMapCanvas({
    super.key,
    required this.located,
    required this.tier,
    required this.onOpenPlace,
    this.onExpand,
    this.ringColorFor,
  });

  final List<Place> located;
  final MapTier tier;
  final ValueChanged<Place> onOpenPlace;

  /// Shows the expand-to-full-screen affordance when non-null - the full-screen route
  /// itself passes null, since it is already full screen.
  final VoidCallback? onExpand;

  /// See PlacesMapView.ringColorFor.
  final Color? Function(Place place)? ringColorFor;

  @override
  State<PlacesMapCanvas> createState() => _PlacesMapCanvasState();
}

class _PlacesMapCanvasState extends State<PlacesMapCanvas> {
  final MapController _mapController = MapController();

  final Future<WorldOutlines> _worldFuture = WorldOutlines.load();
  final Future<RegionOutlines> _regionFuture = RegionOutlines.load();
  final Future<DetailOutlines> _detailFuture = DetailOutlines.load();

  late bool _fineDetail = widget.tier != MapTier.world;

  late CameraFit _initialFit = _buildFit();

  @override
  void didUpdateWidget(PlacesMapCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The set of places can change under a live map - switching the scope pill to "all
    // groups" is exactly that. Without refitting, the camera stays where the first group's
    // own bounds put it and the newly-arrived places sit outside the viewport, culled and
    // invisible, which reads as the switch having done nothing.
    if (!identical(oldWidget.located, widget.located) &&
        !_sameCoords(oldWidget.located, widget.located)) {
      _initialFit = _buildFit();
      _fineDetail = widget.tier != MapTier.world;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _mapController.fitCamera(_initialFit);
      });
    }
  }

  static bool _sameCoords(List<Place> a, List<Place> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].lat != b[i].lat || a[i].lng != b[i].lng) return false;
    }
    return true;
  }

  CameraFit _buildFit() {
    if (widget.tier == MapTier.world) {
      return CameraFit.bounds(
        // Trimmed short of the poles: Mercator stretches them without bound, and no
        // group's places are down there anyway.
        bounds: LatLngBounds(const LatLng(-58, -175), const LatLng(76, 175)),
        padding: const EdgeInsets.all(12),
      );
    }
    return CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(
        [for (final p in widget.located) LatLng(p.lat!, p.lng!)],
      ),
      padding: const EdgeInsets.all(48),
      maxZoom: _kMaxFitZoom,
    );
  }

  /// Flips the outline layer when the camera crosses [kMapFineDetailMaxSpanDegrees].
  ///
  /// Reads the camera's real visible span rather than a zoom number, so the threshold means
  /// the same thing on a short inline card as on a full-screen tablet, where the same zoom
  /// shows very different amounts of world.
  void _onMapEvent(MapEvent event) {
    final bounds = event.camera.visibleBounds;
    final span = math.max(
      (bounds.east - bounds.west).abs(),
      (bounds.north - bounds.south).abs(),
    );
    final fine = span <= kMapFineDetailMaxSpanDegrees;
    if (fine != _fineDetail && mounted) setState(() => _fineDetail = fine);
  }

  void _resetCamera() => _mapController.fitCamera(_initialFit);

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _mapOcean,
      child: FutureBuilder<List<Object>>(
        // Both outline assets are small (~22KB and ~300KB) and each caches its own parsed
        // result, so waiting on both up front regardless of the starting tier is simpler
        // and just as fast as fetching one conditionally: a world-tier view needs the
        // finer asset the moment someone zooms in past the threshold.
        future: Future.wait([_worldFuture, _regionFuture, _detailFuture]),
        builder: (context, snapshot) {
          final data = snapshot.data;
          if (data == null) {
            return Center(child: CircularProgressIndicator(color: context.accent));
          }
          return _buildMap(context, data[0] as WorldOutlines, data[1] as RegionOutlines,
              data[2] as DetailOutlines);
        },
      ),
    );
  }

  Widget _buildMap(
      BuildContext context, WorldOutlines world, RegionOutlines region, DetailOutlines detail) {
    final accent = context.accent;
    final maxPostCount = widget.located.map((p) => p.postCount).fold(1, math.max);

    return Stack(
      children: [
        Positioned.fill(
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCameraFit: _initialFit,
              backgroundColor: _mapOcean,
              minZoom: _kMinZoom,
              maxZoom: _kMaxZoom,
              onMapEvent: _onMapEvent,
              // Rotation off deliberately: north-up is what makes a coastline recognisable
              // when there are no labels or roads to orient by, and a stray two-finger
              // twist while pinching would otherwise leave the map crooked with no obvious
              // way back.
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
            ),
            children: [
              PolygonLayer(
                polygons: landPolygons(
                  _fineDetail ? region.admin0Rings : world.rings,
                  fill: _mapLand,
                  border: _mapOutline,
                  strokeWidth: 0.8,
                ),
              ),
              if (_fineDetail) ...[
                // Paint order matters: built-up tint first so water drawn after it reads as
                // being ON the land rather than under a haze, then lakes, then rivers, and
                // the administrative boundary last so a state line stays legible where it
                // runs along a river - which, often enough, is exactly where it runs.
                PolygonLayer(
                  polygons: landPolygons(
                    detail.urbanRings,
                    fill: _mapUrban,
                    border: _mapUrban,
                    strokeWidth: 0,
                  ),
                ),
                PolygonLayer(
                  polygons: landPolygons(
                    detail.lakeRings,
                    fill: _mapLake,
                    border: _mapRiver,
                    strokeWidth: 0.4,
                  ),
                ),
                PolylineLayer(
                  polylines: borderPolylines(
                    detail.riverLines,
                    color: _mapRiver,
                    strokeWidth: 0.9,
                  ),
                ),
                PolylineLayer(
                  polylines: borderPolylines(
                    region.admin1Rings,
                    color: _mapBorder,
                    strokeWidth: 0.7,
                  ),
                ),
              ],
              MarkerClusterLayerWidget(
                options: MarkerClusterLayerOptions(
                  maxClusterRadius: 42,
                  size: const Size(48, 48),
                  padding: const EdgeInsets.all(40),
                  maxZoom: _kMaxZoom,
                  // Each node handles its own tap (see PlacePhotoNode.onTap for why), which
                  // is exactly what this flag hands over.
                  markerChildBehavior: true,
                  markers: [
                    for (final p in widget.located)
                      _PlaceMarker(
                        place: p,
                        diameter: placeNodeDiameter(p.postCount, maxPostCount),
                        accent: accent,
                        ringColor: widget.ringColorFor?.call(p),
                        onTap: () => widget.onOpenPlace(p),
                      ),
                  ],
                  builder: (context, markers) => PlaceClusterNode(
                    places: [
                      for (final m in markers)
                        if (m is _PlaceMarker) m.place,
                    ],
                    diameter: 48,
                    accent: accent,
                  ),
                ),
              ),
            ],
          ),
        ),
        Positioned(
          right: 8,
          bottom: 8,
          child: Column(
            children: [
              if (widget.onExpand != null) ...[
                _MapChipButton(
                  icon: Icons.fullscreen,
                  semanticLabel: 'Open full screen map',
                  onTap: widget.onExpand!,
                ),
                const SizedBox(height: 8),
              ],
              _MapChipButton(
                icon: Icons.center_focus_strong,
                semanticLabel: 'Reset map view',
                onTap: _resetCamera,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A [Marker] that remembers which [Place] it stands for, so the cluster layer's own tap
/// and cluster-builder callbacks (which hand back plain [Marker]s) can get back to it
/// without a side table keyed on coordinates.
class _PlaceMarker extends Marker {
  _PlaceMarker({
    required this.place,
    required double diameter,
    required Color accent,
    required VoidCallback onTap,
    Color? ringColor,
  }) : super(
          point: LatLng(place.lat!, place.lng!),
          width: diameter,
          height: diameter,
          alignment: Alignment.center,
          child: PlacePhotoNode(
            place: place,
            diameter: diameter,
            accent: accent,
            ringColor: ringColor,
            onTap: onTap,
          ),
        );

  final Place place;
}

/// The small circular chrome buttons overlaid on the map - understated on purpose, to sit
/// over the map without competing with the place nodes.
class _MapChipButton extends StatelessWidget {
  const _MapChipButton({
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: Colors.black.withValues(alpha: 0.5),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Icon(icon, size: 18, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class _SinglePlaceState extends StatelessWidget {
  const _SinglePlaceState({required this.located});

  final List<Place> located;

  @override
  Widget build(BuildContext context) {
    final headline = located.length == 1
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
}

class _MapEmptyState extends StatelessWidget {
  const _MapEmptyState({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
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
            Icon(icon, size: 36, color: kFgMuted),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: kFgSecondary, fontSize: 14, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
