import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart';

import 'package:checkin/features/feed/place_label.dart';

void main() {
  test('pins the geocoder to en_US so labels match the gazetteer on any device', () async {
    Locale? seen;
    await placeLabelFromCoords(38.72, -9.14, geocode: (lat, lng, locale) async {
      seen = locale;
      return [const Placemark(locality: 'Lisbon', country: 'Portugal')];
    });
    expect(seen, const Locale('en', 'US'));
  });

  test('assembles "City, Country"', () async {
    final label = await placeLabelFromCoords(38.72, -9.14,
        geocode: (_, __, ___) async => [const Placemark(locality: 'Lisbon', country: 'Portugal')]);
    expect(label, 'Lisbon, Portugal');
  });

  test('falls back from locality to sub-administrative area to administrative area', () async {
    final label = await placeLabelFromCoords(0, 0,
        geocode: (_, __, ___) async => [
              const Placemark(
                  locality: '',
                  subAdministrativeArea: '',
                  administrativeArea: 'Texas',
                  country: 'USA')
            ]);
    expect(label, 'Texas, USA');
  });

  test('country alone when no city-level field is present', () async {
    final label = await placeLabelFromCoords(0, 0,
        geocode: (_, __, ___) async => [const Placemark(country: 'Iceland')]);
    expect(label, 'Iceland');
  });

  test('empty result and geocoder errors give null', () async {
    expect(await placeLabelFromCoords(0, 0, geocode: (_, __, ___) async => []), isNull);
    expect(await placeLabelFromCoords(0, 0, geocode: (_, __, ___) async => [const Placemark()]),
        isNull);
    expect(
        await placeLabelFromCoords(0, 0,
            geocode: (_, __, ___) async => throw Exception('no network')),
        isNull);
  });
}
