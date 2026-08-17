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
        );

    for (final size in sizes) {
      for (final scale in textScales) {
        testWidgets('fits at $size, textScale $scale (all four entries)', (tester) async {
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
                  'four entries showing');
        });
      }
    }
  });
}
