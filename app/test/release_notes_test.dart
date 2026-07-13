import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/features/whats_new/release_notes.dart';

void main() {
  group('unseenReleaseNotes', () {
    test('a fresh install (null marker) shows nothing', () {
      expect(unseenReleaseNotes(null), isEmpty);
    });

    test('already on the latest shows nothing', () {
      expect(unseenReleaseNotes(releaseNotes.first.version), isEmpty);
    });

    test('an unknown/older marker shows everything, newest first', () {
      expect(unseenReleaseNotes('0.0-before-this-feature'), releaseNotes);
    });
  });

  group('maybeShowWhatsNew', () {
    // A phone-height surface: the sheet grows with the number of highlights, and the
    // default 600px test window would push "Got it" below the fold.
    void tallSurface(WidgetTester tester) {
      tester.view.physicalSize = const Size(500, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    Widget host() => MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => maybeShowWhatsNew(context),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        );

    testWidgets('pops once after an update, then records the latest version', (tester) async {
      tallSurface(tester);
      SharedPreferences.setMockInitialValues(
          {'whats_new_last_seen_version': '0.0-before-this-feature'});
      await tester.pumpWidget(host());

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text("What's New"), findsOneWidget);
      expect(find.text('Got it'), findsOneWidget);

      // Dismiss; the latest version is now remembered so it won't show again.
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('whats_new_last_seen_version'), releaseNotes.first.version);

      // Second launch: nothing to show.
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text("What's New"), findsNothing);
    });

    testWidgets('stays silent on a fresh install but seeds the version', (tester) async {
      tallSurface(tester);
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(host());

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text("What's New"), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('whats_new_last_seen_version'), releaseNotes.first.version);
    });
  });
}
