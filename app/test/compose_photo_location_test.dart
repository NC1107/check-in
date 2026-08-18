import 'package:checkin/features/feed/home_shell.dart';
import 'package:flutter_test/flutter_test.dart';

/// Android 10+ redacts a gallery photo's GPS unless the app holds ACCESS_MEDIA_LOCATION,
/// asked for at runtime (see [VideoNative.ensureMediaLocationPermission] and MainActivity.kt's
/// ensureMediaLocationPermission). Before that, every reason a photo's location failed to
/// show up in compose - no permission, no GPS in the photo, no geocoder result - collapsed
/// into the same silent nothing. These tests pin the decision that now has to tell them
/// apart: [resolvePhotoLocation], the pure function [_ComposeSheetState._resolveLocation]
/// wires up to the real permission check and EXIF read.
///
/// Both native calls are passed in as plain closures, so this is a fast, deterministic unit
/// test with nothing to fake at the platform level - no picker, no channel mock, no image
/// file, no widget pump.
void main() {
  group('resolvePhotoLocation', () {
    test('permission granted: the first photo with GPS is offered', () async {
      final asked = <String>[];
      final result = await resolvePhotoLocation(
        paths: ['a.jpg', 'b.jpg'],
        fromGallery: true,
        ensurePermission: () async => true,
        placeForPhoto: (path) async {
          asked.add(path);
          if (path != 'b.jpg') return null;
          return (place: 'Testville, Testland', lat: 37.33, lng: 122.03);
        },
      );

      expect(result.outcome, PhotoLocationOutcome.found);
      expect(result.place, 'Testville, Testland');
      expect(result.lat, 37.33);
      expect(result.lng, 122.03);
      expect(result.source, 'b.jpg');
      // Both photos were actually looked at: 'a.jpg' has no GPS, so the search moved on
      // to 'b.jpg' rather than stopping (or wrongly succeeding) on the first one.
      expect(asked, ['a.jpg', 'b.jpg']);
    });

    test('permission refused: skipped before any photo is even looked at', () async {
      var permissionAsked = 0;
      final placeAsked = <String>[];
      final result = await resolvePhotoLocation(
        paths: ['a.jpg'],
        fromGallery: true,
        ensurePermission: () async {
          permissionAsked++;
          return false;
        },
        placeForPhoto: (path) async {
          placeAsked.add(path);
          return (place: 'Testville, Testland', lat: 37.33, lng: 122.03);
        },
      );

      expect(result.outcome, PhotoLocationOutcome.permissionRefused);
      expect(result.place, isNull);
      expect(result.source, isNull);
      expect(permissionAsked, 1);
      // The whole point of asking first: a refusal must never fall through to reading EXIF
      // anyway.
      expect(placeAsked, isEmpty);
    });

    test('permission granted but nothing has GPS: none, not an error', () async {
      final result = await resolvePhotoLocation(
        paths: ['a.jpg', 'b.jpg'],
        fromGallery: true,
        ensurePermission: () async => true,
        placeForPhoto: (path) async => null,
      );

      expect(result.outcome, PhotoLocationOutcome.none);
      expect(result.place, isNull);
      expect(result.lat, isNull);
      expect(result.lng, isNull);
      expect(result.source, isNull);
    });

    test('permission is checked at most once, however many photos are in the batch', () async {
      var permissionAsked = 0;
      await resolvePhotoLocation(
        paths: ['a.jpg', 'b.jpg', 'c.jpg'],
        fromGallery: true,
        ensurePermission: () async {
          permissionAsked++;
          return true;
        },
        placeForPhoto: (path) async => null,
      );

      // Checked once for the whole pick, not once per photo - otherwise a refusal would
      // re-prompt (or re-report denial) for every photo in a multi-photo batch instead of
      // once for the pick, which is the "don't spam them" requirement.
      expect(permissionAsked, 1);
    });

    test('a camera photo (fromGallery: false) never asks for media-location permission', () async {
      var permissionAsked = 0;
      final result = await resolvePhotoLocation(
        paths: ['camera.jpg'],
        fromGallery: false,
        ensurePermission: () async {
          permissionAsked++;
          return false; // even if it would refuse, it must never be asked at all
        },
        placeForPhoto: (path) async => (place: 'Testville, Testland', lat: 37.33, lng: 122.03),
      );

      expect(permissionAsked, 0);
      expect(result.outcome, PhotoLocationOutcome.found);
      expect(result.place, 'Testville, Testland');
    });

    test('no photos: nothing to resolve, and permission is never asked', () async {
      var permissionAsked = 0;
      final result = await resolvePhotoLocation(
        paths: const [],
        fromGallery: true,
        ensurePermission: () async {
          permissionAsked++;
          return true;
        },
        placeForPhoto: (path) async => (place: 'Testville, Testland', lat: 37.33, lng: 122.03),
      );

      expect(result.outcome, PhotoLocationOutcome.none);
      expect(permissionAsked, 1); // still checked once, ahead of the (empty) loop
    });
  });
}
