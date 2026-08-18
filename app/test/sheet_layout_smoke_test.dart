import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/memories/memories_screen.dart';
import 'package:checkin/features/settings/recap_settings_screen.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/widgets/gif_picker.dart';

/// A places() stand-in for the "Places map view" layout sweep below - returns whatever
/// worst-case payload that group builds, so every size/textScale case in the sweep pumps
/// the exact same content.
class _FakePlacesMapApi extends ApiClient {
  _FakePlacesMapApi(this._places) : super(baseUrl: '');

  final List<Place> _places;

  @override
  Future<List<Place>> places() async => _places;
}

/// Advertises every capability the Generate Recap sheet reads, so the sheet renders its
/// "Bestow titles" toggle too - the worst case for its layout.
class _FakeRecapApi extends ApiClient {
  _FakeRecapApi() : super(baseUrl: '');

  @override
  Future<ServerInfo> serverInfo() async =>
      ServerInfo(name: 'Alpha', initialized: true, recapCapable: true, titlesCapable: true);
}

/// A lighter overflow-only sweep (Guideline 4's class of bug - see the trim sheet's own
/// layout test) over three more surfaces that had zero layout coverage: the Generate Recap
/// sheet, the gif picker, and the Memories hub root. Each is pumped at its worst-case
/// content (every optional element showing) across the same small-screen/large-text-scale
/// grid; unlike the trim sheet these only assert "no overflow" - there's no single primary
/// action to additionally prove is reachable.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const sizes = [
    Size(320, 480),
    Size(320, 568),
    Size(375, 667),
  ];
  const textScales = [1.0, 1.3, 1.6];

  Future<void> setSurface(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget scaled(double textScale, Widget child) => Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child,
        ),
      );

  group('Generate Recap sheet', () {
    ServerAccount account() => ServerAccount(
          id: 'alpha.invalid',
          baseUrl: 'https://alpha.invalid',
          serverName: 'Alpha',
          token: 't1',
          recapCapable: true,
          user: User(id: 1, name: 'Robin', phone: '+15550001111', isAdmin: true),
        );

    for (final size in sizes) {
      for (final scale in textScales) {
        testWidgets('fits at $size, textScale $scale', (tester) async {
          await setSurface(tester, size);
          final controller =
              MultiSessionController.seeded(MultiSession(groups: [account()], restored: true));
          await tester.pumpWidget(ProviderScope(
            overrides: [
              multiSessionProvider.overrideWith(() => controller),
              apiForGroupProvider('alpha.invalid').overrideWithValue(_FakeRecapApi()),
            ],
            child: MaterialApp(
              builder: (context, child) => scaled(scale, child!),
              home: const RecapSettingsScreen(groupId: 'alpha.invalid'),
            ),
          ));
          await tester.pumpAndSettle();

          // The settings screen itself is a plain (already scrollable) ListView; the
          // button can sit below the fold - offstage by the default finder - at a small
          // size, which is not the overflow this test is checking for.
          final generateButton = find.text('Generate a recap now', skipOffstage: false);
          await tester.ensureVisible(generateButton);
          await tester.pumpAndSettle();
          await tester.tap(generateButton);
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull,
              reason: 'Generate Recap sheet must fit or scroll at $size / $scale');
        });
      }
    }
  });

  group('Gif picker', () {
    for (final size in sizes) {
      for (final scale in textScales) {
        testWidgets('fits at $size, textScale $scale', (tester) async {
          await setSurface(tester, size);
          await tester.pumpWidget(MaterialApp(
            builder: (context, child) => scaled(scale, child!),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showGifPicker(
                    context,
                    search: (q, page) async => const GifSearchPage(gifs: [], hasNext: false),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ));
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull,
              reason: 'Gif picker must fit or scroll at $size / $scale');
        });
      }
    }
  });

  group('Memories hub root', () {
    ServerAccount account() => const ServerAccount(
          id: 'alpha.invalid',
          baseUrl: 'https://alpha.invalid',
          serverName: 'Alpha',
          token: 't1',
          memoriesCapable: true,
          eventsCapable: true,
          timelineCapable: true,
          forgottenCapable: true,
          placesCapable: true,
        );

    for (final size in sizes) {
      for (final scale in textScales) {
        testWidgets('fits at $size, textScale $scale (all five entries)', (tester) async {
          await setSurface(tester, size);
          final controller = AnimationController(
              vsync: tester, duration: const Duration(milliseconds: 1), value: 1);
          addTearDown(controller.dispose);
          await tester.pumpWidget(ProviderScope(
            overrides: [
              multiSessionProvider.overrideWith(() =>
                  MultiSessionController.seeded(MultiSession(groups: [account()], restored: true))),
            ],
            child: MaterialApp(
              builder: (context, child) => scaled(scale, child!),
              home: Scaffold(
                body: MemoriesSurface(controller: controller, onClose: () {}),
              ),
            ),
          ));
          await tester.pump();

          expect(tester.takeException(), isNull,
              reason: 'Memories hub root must fit or scroll at $size / $scale with all '
                  'five entries showing');
        });
      }
    }
  });

  group('Places map view', () {
    ServerAccount account() => const ServerAccount(
          id: 'alpha.invalid',
          baseUrl: 'https://alpha.invalid',
          serverName: 'Alpha',
          token: 't1',
          memoriesCapable: true,
          placesCapable: true,
        );

    /// Worst-case content for the map screen: enough places to spread across continents
    /// (so the world tier - and so real markers, not the no-map state - actually renders),
    /// a long place name to stress the toggle row/note text wrapping, and one unresolved
    /// place so the "couldn't place on the map" note also has to fit alongside everything
    /// else.
    final places = [
      Place(
        location: 'San Francisco, United States of America',
        lat: 37.7749,
        lng: -122.4194,
        postCount: 20,
        photoCount: 10,
        posterCount: 5,
        firstSeen: DateTime(2025, 1, 1),
        lastSeen: DateTime(2026, 1, 1),
        homeArea: true,
      ),
      Place(
        location: 'Tokyo, Japan',
        lat: 35.6762,
        lng: 139.6503,
        postCount: 8,
        photoCount: 4,
        posterCount: 3,
        firstSeen: DateTime(2025, 3, 1),
        lastSeen: DateTime(2025, 9, 1),
        homeArea: false,
      ),
      Place(
        location: 'Sydney, Australia',
        lat: -33.8688,
        lng: 151.2093,
        postCount: 3,
        photoCount: 1,
        posterCount: 1,
        firstSeen: DateTime(2025, 6, 1),
        lastSeen: DateTime(2025, 6, 10),
        homeArea: false,
      ),
      Place(
        location: 'A Very Long Unresolved Vacation Rental Address',
        postCount: 1,
        photoCount: 0,
        posterCount: 1,
        firstSeen: DateTime(2025, 7, 1),
        lastSeen: DateTime(2025, 7, 3),
        homeArea: false,
      ),
    ];

    for (final size in sizes) {
      for (final scale in textScales) {
        testWidgets('fits at $size, textScale $scale (map mode, worst-case content)',
            (tester) async {
          await setSurface(tester, size);
          final controller = AnimationController(
              vsync: tester, duration: const Duration(milliseconds: 1), value: 1);
          addTearDown(controller.dispose);
          await tester.pumpWidget(ProviderScope(
            overrides: [
              multiSessionProvider.overrideWith(() =>
                  MultiSessionController.seeded(MultiSession(groups: [account()], restored: true))),
              apiForGroupProvider('alpha.invalid').overrideWithValue(_FakePlacesMapApi(places)),
            ],
            child: MaterialApp(
              builder: (context, child) => scaled(scale, child!),
              home: Scaffold(
                body: MemoriesSurface(controller: controller, onClose: () {}),
              ),
            ),
          ));
          await tester.pump();
          await tester.tap(find.text('Places'));
          for (var i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          await tester.tap(find.bySemanticsLabel('Map view'));
          for (var i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }

          expect(tester.takeException(), isNull,
              reason: 'Places map view must fit or scroll at $size / $scale with a '
                  'world-spanning payload, a long place name, and an unresolved place');
        });
      }
    }
  });
}
