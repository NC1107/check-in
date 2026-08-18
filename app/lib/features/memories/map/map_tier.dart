import 'geo.dart';

/// How much of the world the map view needs to show, decided purely from the spread of the
/// group's own placed points (see [decideMapTier]) - never a user zoom/pan choice, since v1
/// ships without gestures (see the map view's own doc comment for why).
enum MapTier {
  /// The group's places reach across countries or continents - show the whole world,
  /// scaled to fit every marker.
  world,

  /// The group's places sit within roughly one country or a neighbouring group of them -
  /// fit the view tightly to just that area's own outlines.
  region,

  /// Every placed point sits within [kMapSinglePlaceRadiusKm] of every other - too tight a
  /// cluster to draw a map at all; one dot on an otherwise-empty outline reads as broken,
  /// not informative, so the map view renders a tasteful "you've all been in one place"
  /// state instead (see PlacesMapView).
  singlePlace,
}

/// Below this diameter (the greatest distance between any two placed points, in km), the
/// group's places are treated as one cluster rather than plotted - roughly a single
/// metro area (Denver to Boulder is ~40km; London to Watford is ~25km), picked so a group
/// that's only ever checked in around one city doesn't get a map with a single dot on it.
const double kMapSinglePlaceRadiusKm = 50.0;

/// At or above this diameter, the group's places are treated as spanning multiple
/// countries or continents and shown against the whole world rather than fit tightly to
/// their own bounding window - roughly the distance across a large country (contiguous
/// USA's own diagonal, Seattle-to-Miami, is ~4300km) up to an intercontinental hop
/// (New York-to-London is ~5600km). A single very large country can therefore land in the
/// world tier rather than its own tightly-fit region - an accepted, documented edge case:
/// there's no spread threshold that cleanly separates "one big country" from "two
/// countries" in general, and defaulting to the world view for an extreme spread is the
/// safer failure than fitting a view so wide it's indistinguishable from the world one
/// anyway.
const double kMapWorldSpanKm = 3000.0;

/// Decides which [MapTier] the map view should render for a group's own placed points
/// (already filtered to just the ones with resolved coordinates - see PlacesMapView). Pure:
/// a function of the points' own spread alone, nothing else, so it's directly testable
/// without a widget tree.
MapTier decideMapTier(List<LatLng> points) {
  if (points.length <= 1) return MapTier.singlePlace;
  final diameterKm = maxPairwiseDistanceKm(points);
  if (diameterKm <= kMapSinglePlaceRadiusKm) return MapTier.singlePlace;
  if (diameterKm >= kMapWorldSpanKm) return MapTier.world;
  return MapTier.region;
}
