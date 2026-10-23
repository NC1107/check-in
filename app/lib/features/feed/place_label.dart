import 'dart:ui';

import 'package:geocoding/geocoding.dart';

typedef ReverseGeocoder = Future<List<Placemark>> Function(
    double latitude, double longitude, Locale locale);

/// The language every place label is resolved in. Without pinning it the geocoder answers
/// in the device locale, so the same coordinates become "Lisbon" on one member's phone and
/// "Lissabon" on another's - and the label is what the server's gazetteer matches on, so a
/// localized name can also drop the check-in off the Places map entirely.
const placeLabelLocale = Locale('en', 'US');

// The locale goes per call: geocoding 5.0.0's Geocoding(locale:) constructor never
// forwards it, so a constructor-level locale silently falls back to the device language.
Future<List<Placemark>> _platformGeocode(double latitude, double longitude, Locale locale) =>
    Geocoding().placemarkFromCoordinates(latitude, longitude, locale: locale);

/// Reverse-geocodes a coordinate to a coarse "City, Country". Shared by the photo EXIF
/// path and the clip's MP4-atom path so both post the same kind of label. Null when the
/// geocoder finds nothing. Raw coordinates never leave the phone.
Future<String?> placeLabelFromCoords(
  double lat,
  double lng, {
  ReverseGeocoder geocode = _platformGeocode,
}) async {
  try {
    final marks = await geocode(lat, lng, placeLabelLocale);
    if (marks.isEmpty) return null;
    final p = marks.first;
    final city = [p.locality, p.subAdministrativeArea, p.administrativeArea]
        .firstWhere((s) => s != null && s.isNotEmpty, orElse: () => null);
    final parts = <String>[
      if (city != null) city,
      if (p.country != null && p.country!.isNotEmpty) p.country!,
    ];
    return parts.isEmpty ? null : parts.join(', ');
  } catch (_) {
    return null;
  }
}
