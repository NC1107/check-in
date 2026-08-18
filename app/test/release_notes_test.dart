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

    test('a marker we no longer recognise shows only what just changed', () {
      // Entries get consolidated when one store release bundles several internal ones, so a
      // marker can outlive its entry. Re-announcing the whole history to someone who has
      // used the app for a year would surface notes they read long ago.
      expect(unseenReleaseNotes('0.0-before-this-feature'), [releaseNotes.first]);
    });

    test('the internal TestFlight entries stay collapsed for a store member', () {
      // A member coming from the last public release carries the 1.3 marker. What matters
      // is not how many entries they see - later releases legitimately add more - but that
      // the eleven internal entries which shipped only to TestFlight between 1.5 and 1.19
      // stay collapsed into the single consolidated one, instead of becoming a wall.
      final seen = unseenReleaseNotes('1.3').map((n) => n.version).toList();
      const retired = [
        '1.9',
        '1.10',
        '1.11',
        '1.12',
        '1.13',
        '1.14',
        '1.15',
        '1.16',
        '1.17',
        '1.18',
        '1.19'
      ];
      for (final r in retired) {
        expect(seen, isNot(contains(r)), reason: '$r was collapsed and must not reappear');
      }
      expect(seen.last, '1.19.1', reason: 'the consolidated entry is the oldest they see');
    });

    test('the ordinary update path shows only what is new', () {
      // Someone already on the second-newest entry sees exactly the newest one.
      if (releaseNotes.length < 2) return;
      final unseen = unseenReleaseNotes(releaseNotes[1].version);
      expect(unseen, hasLength(1));
      expect(unseen.single.version, releaseNotes.first.version);
    });

    test('every entry has a distinct marker', () {
      // The marker is how "already seen" is recorded, so a duplicate would silently make
      // one of them unreachable.
      final versions = releaseNotes.map((n) => n.version).toList();
      expect(versions.toSet(), hasLength(versions.length));
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

      // Dismiss; the latest version is now remembered so it won't show again. The combined
      // highlights across every unseen version can scroll "Got it" below the fold, so bring
      // it into view first rather than assume the surface is tall enough to show it already.
      await tester.ensureVisible(find.text('Got it'));
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
