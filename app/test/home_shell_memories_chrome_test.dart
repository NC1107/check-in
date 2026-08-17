import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/home_shell.dart';
import 'package:checkin/state/app_state.dart';

/// While the Memories surface is open there's no reason to also show the bottom bar and FAB
/// underneath it - the founder's own ask ("we don't need the bottom bar in the memories page
/// as we can just swipe out of it"). These tests check the bar and FAB fade (and the FAB
/// slides) out together with the exact same motion the surface itself opens with, are never
/// hit-testable while the surface covers any part of the screen, and - the one that actually
/// matters for correctness, not polish - are never BOTH hidden and the surface ALSO closed,
/// which would strand a member with no navigation at all.
class _FakeApi extends ApiClient {
  _FakeApi() : super(baseUrl: 'https://alpha.invalid');

  @override
  Future<List<Post>> feed(
          {int? authorId,
          Set<String> locations = const {},
          DateTime? before,
          int? beforeId}) async =>
      [];

  @override
  Future<Post?> randomMemory() async => null;

  // See home_shell_memories_autoplay_test.dart's identical stub for why this exists: a real
  // Dio call against the reserved, non-resolving alpha.invalid host leaves platform-level
  // timers dangling past a rejected Future, which flutter_test's own "no pending timers"
  // end-of-test invariant catches the moment any test here does a final teardown pump.
  @override
  Future<NotifyPrefs> updateNotificationPrefs(
          {bool? posts,
          bool? replies,
          bool? likes,
          bool? digestEnabled,
          int? digestHour,
          int? digestOffset}) async =>
      NotifyPrefs(
          posts: true,
          replies: true,
          likes: true,
          digestEnabled: false,
          digestHour: 20,
          digestOffset: digestOffset ?? 0);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const alpha = ServerAccount(
      id: 'alpha.invalid',
      baseUrl: 'https://alpha.invalid',
      serverName: 'Alpha',
      token: 't1',
      memoriesCapable: true);

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          multiSessionProvider.overrideWith(() =>
              MultiSessionController.seeded(const MultiSession(groups: [alpha], restored: true))),
          feedProvider.overrideWith((ref) async => const FeedResult(posts: [])),
          apiForGroupProvider.overrideWith((ref, groupId) => _FakeApi()),
          locationsProvider.overrideWith((ref, groupId) async => []),
          groupMembersProvider.overrideWith((ref, groupId) async => []),
        ],
        child: const MaterialApp(home: HomeShell()),
      ),
    );
    await tester.pump();
    // Mirrors home_shell_memories_autoplay_test.dart's own teardown: a capable handle
    // schedules its ambient pulse timer the instant it first builds (see
    // MemoriesPillPulseController), and none of these tests unmount the tree themselves.
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  }

  // .first, not the bare finder: _ChromeFade's own Opacity/IgnorePointer wrap everything else
  // under that key, so it is the outermost (first, in element-tree order) match - but it
  // isn't the ONLY one, since a real FloatingActionButton/BottomAppBar subtree has Material
  // widgets of its own with Opacity/IgnorePointer buried inside their internal
  // implementation.
  Finder chromeOpacity(String key) =>
      find.descendant(of: find.byKey(Key(key)), matching: find.byType(Opacity)).first;

  Finder chromeIgnorePointer(String key) =>
      find.descendant(of: find.byKey(Key(key)), matching: find.byType(IgnorePointer)).first;

  double opacityOf(WidgetTester tester, String key) =>
      tester.widget<Opacity>(chromeOpacity(key)).opacity;

  bool ignoringOf(WidgetTester tester, String key) =>
      tester.widget<IgnorePointer>(chromeIgnorePointer(key)).ignoring;

  /// Drags [finder] by [totalOffset] over [duration] as several incremental moves rather than
  /// one jump - a lone giant moveBy can land as just the slop-crossing move that starts the
  /// gesture, with nothing left over to register as an update (the same technique
  /// memories_test.dart's stepDrag and home_shell_memories_autoplay_test.dart's own stepDrag
  /// use). Returns the still-down [TestGesture] so a caller can inspect state - or cancel it -
  /// before it is ever released.
  Future<TestGesture> stepDrag(
    WidgetTester tester,
    Finder finder,
    Offset totalOffset,
    Duration duration, {
    int steps = 5,
  }) async {
    final gesture = await tester.startGesture(tester.getCenter(finder));
    for (var i = 1; i <= steps; i++) {
      await gesture.moveBy(
        Offset(totalOffset.dx / steps, totalOffset.dy / steps),
        timeStamp: duration * i ~/ steps,
      );
      await tester.pump();
    }
    return gesture;
  }

  testWidgets('closed: the bar and FAB are fully visible and hit-testable', (tester) async {
    await pump(tester);

    expect(opacityOf(tester, 'bottomBarChrome'), 1);
    expect(opacityOf(tester, 'fabChrome'), 1);
    expect(ignoringOf(tester, 'bottomBarChrome'), isFalse);
    expect(ignoringOf(tester, 'fabChrome'), isFalse);

    // End to end, not just the flags: the FAB genuinely opens compose while closed.
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('New check-in'), findsOneWidget);
  });

  testWidgets('fully open: the bar and FAB are fully hidden and not hit-testable', (tester) async {
    await pump(tester);

    await tester.tap(find.bySemanticsLabel('Memories'));
    await tester.pumpAndSettle();

    expect(opacityOf(tester, 'bottomBarChrome'), 0);
    expect(opacityOf(tester, 'fabChrome'), 0);
    expect(ignoringOf(tester, 'bottomBarChrome'), isTrue);
    expect(ignoringOf(tester, 'fabChrome'), isTrue);

    // End to end: tapping where the (invisible, ignored) FAB sits must not open compose.
    await tester.tap(find.byIcon(Icons.add), warnIfMissed: false);
    await tester.pump();
    expect(find.text('New check-in'), findsNothing);
  });

  testWidgets(
      'mid-drag: the bar/FAB opacity tracks 1 - openness exactly, in lockstep with '
      'the surface', (tester) async {
    await pump(tester);
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;

    final gesture = await stepDrag(tester, find.bySemanticsLabel('Memories'),
        Offset(width * 0.5, 0), const Duration(milliseconds: 600));

    // Read the surface's own openness the same way home_shell_memories_autoplay_test.dart's
    // openFraction does: the header title's x position inside its Transform.translate.
    final dx = tester.getTopLeft(find.text('Memories')).dx;
    final openness = (1 + dx / width).clamp(0.0, 1.0);
    expect(openness, greaterThan(0.1),
        reason: 'test sanity check: the drag must have moved the surface well off closed');

    expect(opacityOf(tester, 'bottomBarChrome'), closeTo(1 - openness, 0.05));
    expect(opacityOf(tester, 'fabChrome'), closeTo(1 - openness, 0.05));

    await gesture.up(timeStamp: const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'an interrupted/cancelled drag never leaves the bar hidden while the surface reads '
      'closed, nor the reverse', (tester) async {
    await pump(tester);
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;

    // Short drag, well short of the open threshold - the same shape memories_test.dart's own
    // "a cancel mid-drag below the threshold settles closed" case uses, just reached through
    // the real handle gesture rather than driving MemoriesDragDriver directly.
    final gesture = await stepDrag(tester, find.bySemanticsLabel('Memories'),
        Offset(width * 0.1, 0), const Duration(milliseconds: 200));
    await gesture.cancel();
    await tester.pumpAndSettle();

    // Whichever way it settled, bar-hidden and surface-closed must never both be true at
    // once, and bar-visible and surface-open must never both be true either.
    final dx = tester.getTopLeft(find.text('Memories')).dx;
    final openness = (1 + dx / width).clamp(0.0, 1.0);
    final barOpacity = opacityOf(tester, 'bottomBarChrome');
    // openness carries the header's own small leading-padding offset baked in (a few percent
    // - see openFraction's doc comment in home_shell_memories_autoplay_test.dart), so this
    // tolerance is loose enough to absorb that measurement artifact rather than the real
    // controller value, which barOpacity reads exactly.
    expect(barOpacity, closeTo(1 - openness, 0.05));
    expect(openness < 0.5 || barOpacity < 0.5, isTrue,
        reason: 'the bar must not be hidden at the same time the surface reads closed');
    expect(openness > 0.5 || barOpacity > 0.5, isTrue,
        reason: 'the bar must not be visible at the same time the surface reads fully open');

    // And after a cancelled drag specifically, the surface must have settled fully - not left
    // stranded mid-transition with the bar in some permanent half-faded state.
    expect(openness < 0.05 || openness > 0.95, isTrue,
        reason: 'a cancelled drag must settle fully open or fully closed, never stranded');
  });

  testWidgets('closing the surface again brings the bar and FAB back', (tester) async {
    await pump(tester);

    await tester.tap(find.bySemanticsLabel('Memories'));
    await tester.pumpAndSettle();
    expect(opacityOf(tester, 'bottomBarChrome'), 0);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(opacityOf(tester, 'bottomBarChrome'), 1);
    expect(opacityOf(tester, 'fabChrome'), 1);
    expect(ignoringOf(tester, 'bottomBarChrome'), isFalse);
    expect(ignoringOf(tester, 'fabChrome'), isFalse);
  });
}
