import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/feed_screen.dart';
import 'package:checkin/features/feed/home_shell.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/widgets/feed_autoplay.dart';

/// The Memories surface is a Stack sibling drawn over the feed, not a pushed route - so
/// FeedAutoplayScope's own ModalRoute.isCurrent check never notices it opening.
/// FeedAutoplayScope's `enabled` has to be gated on the memories controller too, or a
/// playing clip keeps going, audibly, behind the opaque panel. See home_shell.dart's
/// `_memoriesOpen`.
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

  // HomeShell's own initState fires this on every build (see _refreshDigestOffset) - best
  // effort and swallowed on failure there, but a real Dio call against the reserved,
  // non-resolving alpha.invalid host still leaves platform-level DNS/connection timers
  // dangling past a rejected Future. Harmless in production (the request just eventually
  // errors), but flutter_test's own "no pending timers" end-of-test invariant catches it the
  // moment any test here does a final teardown pump - stubbed the same way feed/randomMemory
  // already are, so nothing in this suite makes a real network call at all.
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

  // Signed in (so the group is shown at all) but no `user` - HomeShell only builds
  // MyProfileScreen once `me != null`, and this test has no reason to stand up its
  // providers too. memoriesCapable is what makes the handle exist at all.
  const alpha = ServerAccount(
      id: 'alpha.invalid',
      baseUrl: 'https://alpha.invalid',
      serverName: 'Alpha',
      token: 't1',
      memoriesCapable: true);

  /// Pumps the real HomeShell. Returns the [MultiSessionController] it was built with, so a
  /// test can mutate the session afterwards (e.g. hide the group) and see HomeShell react to
  /// a real provider change, not a hand-built stand-in.
  Future<MultiSessionController> pump(WidgetTester tester,
      {MultiSession session = const MultiSession(groups: [alpha], restored: true)}) async {
    final controller = MultiSessionController.seeded(session);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          multiSessionProvider.overrideWith(() => controller),
          feedProvider.overrideWith((ref) async => const FeedResult(posts: [])),
          apiForGroupProvider.overrideWith((ref, groupId) => _FakeApi()),
          locationsProvider.overrideWith((ref, groupId) async => []),
          groupMembersProvider.overrideWith((ref, groupId) async => []),
        ],
        child: const MaterialApp(home: HomeShell()),
      ),
    );
    await tester.pump();
    // The real HomeShell's handle is capable here (alpha.memoriesCapable) and schedules its
    // ambient pulse timer (see MemoriesPillPulseController) the instant it first builds.
    // None of these tests unmount the tree themselves, so without this that timer is still
    // pending when the test body returns and flutter_test's own end-of-test invariant check
    // ("A Timer is still pending") fails a test that has nothing to do with the pulse.
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    return controller;
  }

  /// Drags [finder] by [totalOffset] over [duration] as several incremental moves rather
  /// than one jump - a lone giant moveBy can land as just the slop-crossing move that starts
  /// the gesture, with nothing left over to register as an update (see memories_test.dart's
  /// stepDrag, the same technique). Returns the still-down [TestGesture] so a caller can act
  /// while the drag is genuinely in progress, before ever releasing it.
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

  /// The Memories header title's current x position, which - being inside the surface's
  /// Transform.translate - directly reflects how open the surface is: 0 = the offscreen,
  /// fully-closed position on the left; 1 = its natural on-screen position at value 1.
  /// Reading actual screen geometry rather than reaching into HomeShell's private
  /// AnimationController is what makes this test able to tell a stranded mid-drag value
  /// apart from a clean 0 or 1 without any test-only backdoor into production code.
  ///
  /// Carries a small constant offset (the header's own ~18-28px leading padding, divided
  /// by screen width - a few percent) baked into the formula below, since it ignores that
  /// padding entirely: it reads as approximately true_value + that offset, not true_value
  /// exactly. Callers comparing against 0 or 1 should use a tolerance loose enough to
  /// absorb it (or, as the mid-drag test does, keep whatever value they are checking for
  /// "stuck" comfortably further from the endpoints than the offset is).
  double openFraction(WidgetTester tester, double screenWidth) {
    final dx = tester.getTopLeft(find.text('Memories')).dx;
    // offset.dx = -width * (1 - value)  =>  value = 1 + offset.dx / width
    return 1 + dx / screenWidth;
  }

  /// Reads the feed's live [FeedAutoplayController] straight from the tree - the same object
  /// FeedAutoplayScope hands every feed clip - so this asserts on the actual gate a clip's
  /// player checks, not just that something didn't throw. Read from FeedScreen's own
  /// element: FeedAutoplayScope's InheritedWidget is an ancestor of FeedScreen (it wraps it
  /// as `child`), not of HomeShell's own element, so the lookup has to start below it.
  FeedAutoplayController autoplay(WidgetTester tester) =>
      FeedAutoplayScope.maybeOf(tester.element(find.byType(FeedScreen)))!;

  testWidgets(
      'autoplay disables the instant the surface starts opening, and re-enables once it '
      'closes', (tester) async {
    await pump(tester);
    expect(autoplay(tester).enabled, isTrue,
        reason: 'the feed tab is showing and nothing is covering it yet');

    // Open via a plain tap (the accessibility path) and pump only partway through the
    // 260ms open animation - deliberately not settled yet, so this checks the "instant the
    // surface starts opening" claim against the animation itself, not just the fully-open
    // state a moment later. The first pump lets the controller's ticker actually start
    // (its first callback reports zero elapsed time); the second is what advances it.
    await tester.tap(find.bySemanticsLabel('Memories'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    expect(autoplay(tester).enabled, isFalse,
        reason: 'a clip must stop the moment the surface starts covering the feed, not only '
            'once it is fully open');

    await tester.pumpAndSettle();

    expect(autoplay(tester).enabled, isFalse, reason: 'fully open must still keep autoplay off');

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(autoplay(tester).enabled, isTrue,
        reason: 'closing the surface must give autoplay back to the feed');
  });

  testWidgets("the pill sits on the Feed icon's own vertical center, even with a bottom safe inset",
      (tester) async {
    // An iPhone-style home-indicator inset. BottomAppBar wraps its Row content in a SafeArea
    // *outside* a fixed-height 64 box (see Flutter's BottomAppBar.build), so the bar's real
    // rendered height is 64 + this inset with the Row pinned to the top of it - a handle
    // centered against that taller total height (the bug this guards) would sit visibly
    // below the icons' actual center by about half of it.
    tester.view.padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetPadding);
    await pump(tester);

    final pillY = tester.getCenter(find.byKey(const Key('memoriesPill'))).dy;
    final feedIconY = tester.getCenter(find.byIcon(Icons.home_rounded)).dy;

    expect(pillY, closeTo(feedIconY, 1.0),
        reason: "the handle overlay must center the pill on the Feed/You icons' own line, "
            "not against the bar's taller safe-area-inflated total height");
  });

  testWidgets(
      'capability dropping mid-drag settles the surface to exactly 0 or 1, never strands '
      'it, and normal open/close still work afterwards', (tester) async {
    final session = await pump(tester);
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;

    // Begin a drag on the handle and stop partway - well short of the open threshold
    // (0.35) or release, the same "mid-drag" moment the live reproduction got stuck at
    // (there, around 0.0375; the exact fraction does not matter, only that it lands
    // comfortably away from both 0 and 1 so a stuck value cannot be mistaken for a
    // settled one against openFraction's own small systematic offset - see its doc
    // comment).
    await stepDrag(tester, find.bySemanticsLabel('Memories'), Offset(width * 0.2, 0),
        const Duration(milliseconds: 300));

    final stuckIfUnfixed = openFraction(tester, width);
    expect(stuckIfUnfixed, greaterThan(0.1),
        reason: 'test sanity check: the drag itself must have moved the surface well past '
            'openFraction\'s ~0.02 baseline noise, or a stuck value here could look the '
            'same as a properly settled 0 - got $stuckIfUnfixed');

    // Mid-gesture - the finger is still down - the shown group changes (a filter change, a
    // capability update landing): memoriesCapableShownGroups goes empty. This is exactly
    // what tore the GestureDetector out from under the drag in the live repro:
    // MemoriesHandle's build() swaps to SizedBox.shrink(), and
    // DragGestureRecognizer.dispose() never fires onCancel - production has already lost
    // the recognizer at this point, so there is nothing further for the test to do with
    // the pointer either; the point is to observe what happens as a result of the
    // capability flip.
    await session.setHiddenGroups(const {'alpha.invalid'});
    await tester.pump();
    await tester.pumpAndSettle();

    expect(SchedulerBinding.instance.transientCallbackCount, 0,
        reason: 'the capability-drop guard must leave no animation pending');
    final settled = openFraction(tester, width);
    expect(settled < 0.1 || settled > 0.9, isTrue,
        reason: 'the surface must settle fully closed or fully open, never stranded in '
            'between (got openFraction=$settled)');

    // The normal paths must still work after this - the drag-cancel guard already taught
    // us once that a safety net can quietly break the paths it was not aimed at.
    await session.setHiddenGroups(const {});
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Memories'));
    await tester.pumpAndSettle();
    expect(openFraction(tester, width), closeTo(1, 0.05),
        reason: 'a plain tap must still open the surface normally afterwards');

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(openFraction(tester, width), closeTo(0, 0.05),
        reason: 'the close button must still close the surface normally afterwards');
  });
}
