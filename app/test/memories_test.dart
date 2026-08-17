import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/memories/memories_screen.dart';
import 'package:checkin/features/post/post_detail_screen.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/theme/accent.dart';

/// A fake ApiClient handing back canned randomMemory() responses in order, one per call
/// (the last entry repeats once exhausted) - lets a test pin exactly what "Another" fetches
/// second without a real server.
class _FakeMemoriesApi extends ApiClient {
  _FakeMemoriesApi(this._responses) : super(baseUrl: 'https://x.invalid');

  final List<Post?> _responses;
  int calls = 0;

  @override
  Future<Post?> randomMemory() async {
    final r = _responses[calls < _responses.length ? calls : _responses.length - 1];
    calls++;
    return r;
  }
}

/// A fake ApiClient whose randomMemory() doesn't resolve until the test completes
/// [completer] - lets a test hold a fetch open mid-flight to change other state (e.g. the
/// active group selection) before letting it land.
class _DelayedMemoriesApi extends ApiClient {
  _DelayedMemoriesApi(this.completer) : super(baseUrl: 'https://x.invalid');

  final Completer<Post?> completer;

  @override
  Future<Post?> randomMemory() => completer.future;
}

/// Mirrors home_shell.dart's wiring: one AnimationController shared by the handle (in a
/// bottom bar) and the surface (over the body) - exactly the shape MemoriesHandle and
/// MemoriesSurface are designed to be driven by. Exposed via a GlobalKey so tests can read
/// the controller's value and drive it directly where a gesture isn't the point of the test.
class _MemoriesHost extends StatefulWidget {
  const _MemoriesHost({super.key});

  @override
  State<_MemoriesHost> createState() => MemoriesHostState();
}

class MemoriesHostState extends State<_MemoriesHost> with SingleTickerProviderStateMixin {
  late final controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 220));

  /// Threaded straight to [MemoriesHandle.feedActive]. Toggled via [setFeedActive] rather than
  /// rebuilding [_MemoriesHost], so a test can flip it mid-test the same way home_shell.dart's
  /// real tab switch would - see the pulse-wiring tests' "leaving the Feed tab" cases.
  bool _feedActive = true;

  void close() => controller.animateTo(0, duration: Duration.zero);

  void setFeedActive(bool active) => setState(() => _feedActive = active);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        const SizedBox.expand(),
        Positioned.fill(child: MemoriesSurface(controller: controller, onClose: close)),
      ]),
      bottomNavigationBar: SizedBox(
        height: 64,
        child: Row(children: [MemoriesHandle(controller: controller, feedActive: _feedActive)]),
      ),
    );
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ServerAccount account(String id, {bool memoriesCapable = false}) => ServerAccount(
        id: id,
        baseUrl: 'https://$id',
        serverName: id,
        token: 't',
        memoriesCapable: memoriesCapable,
      );

  Post memory(int id, {String body = 'an old check-in', DateTime? createdAt}) => Post(
        id: id,
        authorId: 9,
        authorName: 'Ada',
        kind: 'text',
        body: body,
        createdAt: createdAt ?? DateTime.now().subtract(const Duration(days: 400)),
        likeCount: 0,
        commentCount: 0,
        likedByViewer: false,
      );

  /// Pumps [_MemoriesHost] with [groups] as the signed-in session (and any active group's
  /// [ServerAccount.memoriesCapable] driving the handle's visibility), returning a key onto
  /// the host's controller. [disableAnimations] wraps the tree in a [MediaQuery] reporting
  /// reduced motion, pinned to the test binding's default 800x600 logical surface so a
  /// test can reason about drag fractions against a known width.
  Future<GlobalKey<MemoriesHostState>> pumpHost(
    WidgetTester tester, {
    List<ServerAccount> groups = const [],
    ApiClient Function(String groupId)? api,
    bool disableAnimations = false,
  }) async {
    final key = GlobalKey<MemoriesHostState>();
    Widget home = _MemoriesHost(key: key);
    if (disableAnimations) {
      home = MediaQuery(
        data: const MediaQueryData(size: Size(800, 600), disableAnimations: true),
        child: home,
      );
    }
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(
            () => MultiSessionController.seeded(MultiSession(groups: groups, restored: true))),
        if (api != null) apiForGroupProvider.overrideWith((ref, id) => api(id)),
      ],
      child: MaterialApp(home: home),
    ));
    await tester.pump();
    // A capable handle schedules its ambient pulse timer (see MemoriesPillPulseController)
    // the instant it first builds, since every gating condition defaults to eligible. Most
    // tests here never touch the pulse and so never unmount the tree themselves - without
    // this, that timer is still pending when the test body returns and flutter_test's own
    // end-of-test invariant check ("A Timer is still pending") fails a test that has nothing
    // to do with the pulse at all.
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    return key;
  }

  /// Drags [finder] by [totalOffset] over [duration] as several incremental moves (mirroring
  /// how tester.timedDrag itself steps a drag) rather than one single jump - a lone giant
  /// moveBy can land as just the slop-crossing move that starts the gesture, with nothing
  /// left over to report as an update. Returns the still-down [TestGesture] so a caller can
  /// inspect state before releasing it with `gesture.up(timeStamp: duration)`.
  Future<TestGesture> stepDrag(
    WidgetTester tester,
    Finder finder,
    Offset totalOffset,
    Duration duration, {
    int steps = 10,
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

  group('memoryAgeLabel', () {
    final now = DateTime(2026, 8, 16);

    test('a few weeks back reads as weeks, not "last <month>"', () {
      expect(memoryAgeLabel(DateTime(2026, 8, 1), now: now), '2 weeks ago');
    });

    test('a month or more back but within the last year reads as "last <month>"', () {
      expect(memoryAgeLabel(DateTime(2026, 6, 20), now: now), 'last June');
    });

    test('a year or more back reads as "N years ago"', () {
      expect(memoryAgeLabel(DateTime(2023, 8, 1), now: now), '3 years ago');
    });

    test('exactly one year back is singular', () {
      expect(memoryAgeLabel(DateTime(2025, 6, 1), now: now), '1 year ago');
    });
  });

  group('capability gating', () {
    testWidgets('the handle is absent when no shown group advertises memories', (tester) async {
      await pumpHost(tester, groups: [account('a.invalid')]);
      expect(find.bySemanticsLabel('Memories'), findsNothing);
    });

    testWidgets('the handle is present when a shown group advertises memories', (tester) async {
      await pumpHost(tester, groups: [account('a.invalid', memoriesCapable: true)]);
      expect(find.bySemanticsLabel('Memories'), findsOneWidget);
    });
  });

  group('group selection', () {
    ServerAccount accountWith(String id, {bool memories = false, bool events = false}) =>
        ServerAccount(
          id: id,
          baseUrl: 'https://$id',
          serverName: id,
          token: 't',
          memoriesCapable: memories,
          eventsCapable: events,
        );

    test(
        'effectiveMemoriesGroupId follows the feed\'s own single-group filter when it '
        'resolves to exactly one group', () {
      final session = MultiSession(
        groups: [
          accountWith('a.invalid', memories: true),
          accountWith('b.invalid', memories: true)
        ],
        hiddenGroupIds: const {'a.invalid'},
        restored: true,
      );
      expect(effectiveMemoriesGroupId(session, null), 'b.invalid');
    });

    test(
        'effectiveMemoriesGroupId falls back to the first capable group in shown order when '
        'the feed filter does not resolve to exactly one group', () {
      final session = MultiSession(
        groups: [accountWith('a.invalid', events: true), accountWith('b.invalid', memories: true)],
        restored: true,
      );
      // Both shown (no single-group filter to defer to) - the deterministic fallback is
      // simply "first in the app's existing shown-group order", regardless of which of the
      // two capabilities each one happens to carry.
      expect(effectiveMemoriesGroupId(session, null), 'a.invalid');
    });

    test(
        'effectiveMemoriesGroupId keeps an explicit pick even when it differs from the '
        'deterministic default', () {
      final session = MultiSession(
        groups: [
          accountWith('a.invalid', memories: true),
          accountWith('b.invalid', memories: true)
        ],
        restored: true,
      );
      expect(effectiveMemoriesGroupId(session, 'b.invalid'), 'b.invalid');
    });

    test('effectiveMemoriesGroupId repairs a pick that no longer names a shown, capable group', () {
      final session =
          MultiSession(groups: [accountWith('a.invalid', memories: true)], restored: true);
      expect(effectiveMemoriesGroupId(session, 'gone.invalid'), 'a.invalid');
    });

    test('effectiveMemoriesGroupId resolves to null with nothing capable shown', () {
      final session = MultiSession(groups: [accountWith('a.invalid')], restored: true);
      expect(effectiveMemoriesGroupId(session, null), isNull);
    });

    testWidgets('the group selector is absent with exactly one capable group', (tester) async {
      await pumpHost(tester,
          groups: [account('a.invalid', memoriesCapable: true)],
          api: (id) => _FakeMemoriesApi([null]));

      await tester.tap(find.bySemanticsLabel('Memories'));
      await tester.pumpAndSettle();

      expect(find.text('a.invalid'), findsNothing);
    });

    testWidgets('the group selector appears with more than one capable group', (tester) async {
      await pumpHost(tester,
          groups: [
            account('a.invalid', memoriesCapable: true),
            account('b.invalid', memoriesCapable: true)
          ],
          api: (id) => _FakeMemoriesApi([null]));

      await tester.tap(find.bySemanticsLabel('Memories'));
      await tester.pumpAndSettle();

      expect(find.text('a.invalid'), findsOneWidget);
      expect(find.text('b.invalid'), findsOneWidget);
    });

    testWidgets(
        'the default group pick is deterministic across repeated fresh opens - never random, '
        'the exact bug this feature replaces', (tester) async {
      // A is memories-only, B is events-only, so whichever of "Random check-in"/"Group
      // trips" the hub root offers on first open - before the selector is ever touched -
      // reveals which group the default landed on without drilling any further in.
      final groups = [
        accountWith('a.invalid', memories: true),
        accountWith('b.invalid', events: true)
      ];
      String? firstOpenEntries;
      for (var i = 0; i < 2; i++) {
        await pumpHost(tester, groups: groups, api: (id) => _FakeMemoriesApi([null]));
        await tester.tap(find.bySemanticsLabel('Memories'));
        await tester.pumpAndSettle();

        final entries = [
          if (find.text('Random check-in').evaluate().isNotEmpty) 'Random check-in',
          if (find.text('Group trips').evaluate().isNotEmpty) 'Group trips',
        ].join(',');
        if (firstOpenEntries == null) {
          firstOpenEntries = entries;
        } else {
          expect(entries, firstOpenEntries,
              reason: 'the default group selection must be deterministic, never random, '
                  'across repeated fresh opens');
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  });

  group('layout stability', () {
    // A bottom bar built from exactly the same pieces home_shell.dart now uses, mirrored
    // side by side: [base] carries no trace of the Memories feature at all (the true
    // pre-feature shape); [overlay] wraps the identical bar in the Stack + overlaid handle
    // home_shell.dart actually builds. The regression this guards: an earlier version made
    // the handle a real Row participant (a fixed-width leading child, mirrored by a
    // trailing spacer to keep the FAB notch centered) - the notch stayed centered, but the
    // Feed/You icons still shifted inward by half the handle's width, at every screen size,
    // which is exactly the kind of visible change an "invisible" feature must never cause.
    Widget bar({required bool overlay, required AnimationController controller}) {
      final row = const BottomAppBar(
        color: Colors.black,
        elevation: 0,
        height: 64,
        padding: EdgeInsets.zero,
        shape: CircularNotchedRectangle(),
        notchMargin: 9,
        child: Row(
          children: [
            Expanded(child: Center(key: Key('feed'), child: SizedBox(width: 24, height: 24))),
            SizedBox(width: 64), // FAB notch
            Expanded(child: Center(key: Key('you'), child: SizedBox(width: 24, height: 24))),
          ],
        ),
      );
      if (!overlay) return row;
      return Stack(
        alignment: Alignment.centerLeft,
        children: [
          row,
          SizedBox(
            width: kMemoriesHandleWidth,
            height: 64,
            child: MemoriesHandle(controller: controller, feedActive: true),
          ),
        ],
      );
    }

    Future<void> pumpBar(WidgetTester tester,
        {required bool overlay, required double width}) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = Size(width, 600);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Torn down and rebuilt fresh each call (rather than reused across calls in the same
      // test) so a NotifierProvider override - which only ever runs its factory once for a
      // living element - can't leave a stale MultiSessionController behind. See the
      // "surface content" tests' pumpHost for the same reasoning.
      await tester.pumpWidget(const SizedBox.shrink());
      final controller = AnimationController(vsync: const TestVSync());
      addTearDown(controller.dispose);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          multiSessionProvider.overrideWith(() => MultiSessionController.seeded(
              MultiSession(groups: [account('a.invalid', memoriesCapable: true)], restored: true))),
        ],
        child: MaterialApp(
          home: Scaffold(bottomNavigationBar: bar(overlay: overlay, controller: controller)),
        ),
      ));
      await tester.pump();
      // Mirrors pumpHost's own teardown: a capable overlay handle schedules its ambient
      // pulse timer immediately, and this helper's own next call already tears the PREVIOUS
      // tree down (the SizedBox.shrink() above) but nothing tears down the last one built in
      // a test - without this, that pulse timer is still pending when the test ends.
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    }

    for (final width in const [320.0, 800.0]) {
      testWidgets(
          'the Feed and You icons sit exactly where they do without the handle at all, at '
          'width $width', (tester) async {
        await pumpBar(tester, overlay: false, width: width);
        final baseFeed = tester.getCenter(find.byKey(const Key('feed'))).dx;
        final baseYou = tester.getCenter(find.byKey(const Key('you'))).dx;

        await pumpBar(tester, overlay: true, width: width);
        final overlayFeed = tester.getCenter(find.byKey(const Key('feed'))).dx;
        final overlayYou = tester.getCenter(find.byKey(const Key('you'))).dx;

        expect(overlayFeed, baseFeed,
            reason: 'the overlaid handle must not move the Feed icon at width $width');
        expect(overlayYou, baseYou,
            reason: 'the overlaid handle must not move the You icon at width $width');
      });
    }
  });

  group('opening', () {
    testWidgets('tapping the handle opens the surface - the accessibility path', (tester) async {
      final key = await pumpHost(tester,
          groups: [account('a.invalid', memoriesCapable: true)],
          api: (id) => _FakeMemoriesApi([null]));
      expect(key.currentState!.controller.value, 0);

      await tester.tap(find.bySemanticsLabel('Memories'));
      await tester.pumpAndSettle();

      expect(key.currentState!.controller.value, 1);
      expect(find.text('Memories'), findsOneWidget); // the surface's own header title
    });

    testWidgets('dragging the handle right past the commit threshold opens it', (tester) async {
      final key = await pumpHost(tester,
          groups: [account('a.invalid', memoriesCapable: true)],
          api: (id) => _FakeMemoriesApi([null]));
      final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;

      // Slow drag well past kMemoriesOpenThreshold (35%) of the screen width - 1500ms keeps
      // its average velocity under kMemoriesFlickVelocity (500px/s), so this exercises the
      // position-based commit rather than accidentally qualifying as a flick.
      await tester.timedDrag(find.bySemanticsLabel('Memories'), Offset(width * 0.6, 0),
          const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();

      expect(key.currentState!.controller.value, 1);
    });

    testWidgets('a short drag released below the threshold snaps closed', (tester) async {
      final key = await pumpHost(tester,
          groups: [account('a.invalid', memoriesCapable: true)],
          api: (id) => _FakeMemoriesApi([null]));
      final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;

      // Slow drag that never reaches kMemoriesOpenThreshold (35%).
      await tester.timedDrag(find.bySemanticsLabel('Memories'), Offset(width * 0.15, 0),
          const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      expect(key.currentState!.controller.value, 0);
    });

    testWidgets('a fast flick commits open even from a short drag', (tester) async {
      final key = await pumpHost(tester,
          groups: [account('a.invalid', memoriesCapable: true)],
          api: (id) => _FakeMemoriesApi([null]));
      final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;

      // A short (10% of width) but fast fling - well under kMemoriesOpenThreshold on
      // distance alone, but fast enough to clear kMemoriesFlickVelocity.
      await tester.fling(find.bySemanticsLabel('Memories'), Offset(width * 0.1, 0), 2000);
      await tester.pumpAndSettle();

      expect(key.currentState!.controller.value, 1);
    });

    testWidgets(
        'reduced motion: dragging right does not move the controller live, but still opens '
        'past the threshold on release', (tester) async {
      final key = await pumpHost(tester,
          groups: [account('a.invalid', memoriesCapable: true)],
          api: (id) => _FakeMemoriesApi([null]),
          disableAnimations: true);

      // width is pinned to 800 by pumpHost's disableAnimations MediaQuery override. 480px
      // (60% of 800) at t=1500ms: past kMemoriesOpenThreshold, and its ~320px/s average
      // stays under kMemoriesFlickVelocity, so only the position-based path is in play.
      const duration = Duration(milliseconds: 1500);
      final gesture =
          await stepDrag(tester, find.bySemanticsLabel('Memories'), const Offset(480, 0), duration);

      expect(key.currentState!.controller.value, 0,
          reason: 'reduced motion must not live-track the drag mid-gesture');

      await gesture.up(timeStamp: duration);
      await tester.pumpAndSettle();

      expect(key.currentState!.controller.value, 1,
          reason: 'release past the threshold must still commit open, just without the live '
              'tracking that got it there');
    });

    testWidgets('reduced motion: a short drag released below the threshold still snaps closed',
        (tester) async {
      final key = await pumpHost(tester,
          groups: [account('a.invalid', memoriesCapable: true)],
          api: (id) => _FakeMemoriesApi([null]),
          disableAnimations: true);

      // 120px (15% of 800) at t=1500ms: below kMemoriesOpenThreshold, ~80px/s - nowhere near
      // a flick either.
      const duration = Duration(milliseconds: 1500);
      final gesture =
          await stepDrag(tester, find.bySemanticsLabel('Memories'), const Offset(120, 0), duration);

      expect(key.currentState!.controller.value, 0,
          reason: 'reduced motion must not live-track the drag mid-gesture');

      await gesture.up(timeStamp: duration);
      await tester.pumpAndSettle();

      expect(key.currentState!.controller.value, 0,
          reason: 'a drag that never reached the threshold must settle closed even without '
              'live tracking to show it falling short');
    });
  });

  group('drag cancel', () {
    // A system-cancelled gesture (app backgrounded mid-drag, another recognizer stealing
    // the arena) never fires onHorizontalDragEnd - only onHorizontalDragCancel - so without
    // wiring that up too, the controller is simply abandoned wherever the drag had got to,
    // and the surface can sit part-open indefinitely. Exercised directly against
    // MemoriesDragDriver (no widget needed) since it is the one place this logic lives.
    testWidgets('a cancel mid-drag settles open past the threshold, zero velocity', (tester) async {
      final controller = AnimationController(
          vsync: const TestVSync(), duration: const Duration(milliseconds: 220));
      addTearDown(controller.dispose);
      final drag = MemoriesDragDriver(controller);

      drag.start();
      drag.update(
          DragUpdateDetails(
              globalPosition: Offset.zero, delta: const Offset(0.7, 0), primaryDelta: 0.7),
          1,
          false);
      expect(controller.value, closeTo(0.7, 0.0001));

      drag.cancel(false);
      await tester.pumpAndSettle();

      expect(controller.value, 1,
          reason: 'a cancel past the open threshold must still commit open, exactly like a '
              'zero-velocity release would');
    });

    testWidgets('a cancel mid-drag below the threshold settles closed', (tester) async {
      final controller = AnimationController(
          vsync: const TestVSync(), duration: const Duration(milliseconds: 220));
      addTearDown(controller.dispose);
      final drag = MemoriesDragDriver(controller);

      drag.start();
      drag.update(
          DragUpdateDetails(
              globalPosition: Offset.zero, delta: const Offset(0.1, 0), primaryDelta: 0.1),
          1,
          false);
      expect(controller.value, closeTo(0.1, 0.0001));

      drag.cancel(false);
      await tester.pumpAndSettle();

      expect(controller.value, 0,
          reason: 'a cancel below the open threshold must settle closed, not sit stuck '
              'part-open');
    });

    testWidgets(
        'a cancel with no drag in progress is a no-op - an ordinary tap must not '
        'move the surface', (tester) async {
      // Starts fully OPEN, deliberately not 0: a buggy cancel that ignores whether a drag
      // was actually in progress would call settleMemoriesTarget with the driver's default
      // (untouched) _dragAccum of 0, which is below the open threshold, and yank the
      // surface closed - exactly the real scenario of tapping "Random check-in" or
      // "Another" while the surface is sitting open. Starting at 0 could not tell a
      // present guard from a missing one: either way the controller would settle at 0,
      // since that is also what settleMemoriesTarget(0, 0) computes.
      final controller = AnimationController(
          vsync: const TestVSync(), value: 1, duration: const Duration(milliseconds: 220));
      addTearDown(controller.dispose);
      final drag = MemoriesDragDriver(controller);

      // No start()/update() first - this is exactly what Flutter's DragGestureRecognizer
      // fires for a plain tap that a sibling tap recognizer won instead of this one (see
      // DragGestureRecognizer.didStopTrackingLastPointer): onCancel with no onStart ever
      // having happened.
      drag.cancel(false);
      await tester.pumpAndSettle();

      expect(controller.value, 1,
          reason: 'a cancel that never followed a start must not touch the controller at all');
    });
  });

  group('closing', () {
    testWidgets('Android back closes the surface rather than popping the route', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final controller = AnimationController(
          vsync: const TestVSync(), value: 1, duration: const Duration(milliseconds: 220));
      addTearDown(controller.dispose);
      var closeCalls = 0;

      await tester.pumpWidget(ProviderScope(
        // The surface's hub root reads multiSessionProvider (to decide which entries to
        // offer) the instant it builds, so this needs a real ProviderScope even though
        // this test never interacts with the hub itself.
        overrides: [
          multiSessionProvider.overrideWith(
              () => MultiSessionController.seeded(const MultiSession(restored: true))),
        ],
        child: MaterialApp(
          navigatorKey: nav,
          home: Scaffold(
            body: MemoriesSurface(
              controller: controller,
              onClose: () {
                closeCalls++;
                controller.value = 0;
              },
            ),
          ),
        ),
      ));
      await tester.pump();

      // maybePop() itself returns true whenever the pop request was consumed - including
      // when a PopScope's canPop:false swallows it (Navigator's own semantics: only a
      // route-less history returns false) - so the real assertion is the side effect: the
      // surface closed instead of the (nonexistent) route actually popping.
      await nav.currentState!.maybePop();
      await tester.pump();

      expect(closeCalls, 1, reason: 'back must close the surface, not fall through unhandled');
      expect(controller.value, 0);

      // Once closed, back is free to behave normally again (nothing left to intercept).
      final secondDidPop = await nav.currentState!.maybePop();
      expect(secondDidPop, isFalse,
          reason: 'with the surface closed there is nothing left for this single-route stack '
              'to pop, and PopScope must no longer be swallowing it');
    });
  });

  group('surface content', () {
    testWidgets('fetches and renders a memory, Another refetches, tapping opens the post',
        (tester) async {
      final first = memory(101, body: 'first memory');
      final second = memory(102, body: 'second memory');
      final key = await pumpHost(tester,
          groups: [account('a.invalid', memoriesCapable: true)],
          api: (id) => _FakeMemoriesApi([first, second]));

      await tester.tap(find.bySemanticsLabel('Memories'));
      await tester.pumpAndSettle();
      expect(key.currentState!.controller.value, 1);

      // Hub root: the "Random check-in" entry, then the screen it opens onto.
      expect(find.text('Random check-in'), findsOneWidget);
      await tester.tap(find.text('Random check-in'));
      await tester.pumpAndSettle();

      // Idle until "Random check-in" is tapped.
      expect(find.text('Random check-in'), findsOneWidget);
      await tester.tap(find.text('Random check-in'));
      await tester.pumpAndSettle();

      expect(find.text('first memory'), findsOneWidget);
      expect(find.text('Ada'), findsOneWidget);

      await tester.tap(find.text('Another'));
      await tester.pumpAndSettle();

      expect(find.text('second memory'), findsOneWidget);
      expect(find.text('first memory'), findsNothing);

      await tester.tap(find.bySemanticsLabel('Open this memory'));
      await tester.pumpAndSettle();

      final detail = tester.widget<PostDetailScreen>(find.byType(PostDetailScreen));
      expect(detail.postId, 102);
      expect(detail.groupId, 'a.invalid');
    });

    testWidgets('renders the truthful empty state when the server has nothing eligible',
        (tester) async {
      await pumpHost(tester,
          groups: [account('a.invalid', memoriesCapable: true)],
          api: (id) => _FakeMemoriesApi([null]));

      await tester.tap(find.bySemanticsLabel('Memories'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Random check-in')); // hub entry
      await tester.pumpAndSettle();
      await tester.tap(find.text('Random check-in')); // the action button
      await tester.pumpAndSettle();

      expect(find.text('Nothing to look back on yet.'), findsOneWidget);
      // Never a bare, permanent spinner - see feature spec's empty-state requirement.
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets(
        'a mid-flight fetch is abandoned when the resolved group changes before it resolves - '
        'the newly resolved group\'s own fetch is what ends up shown, and the abandoned '
        'response is stamped with (but never surfaces under) the group it truly came from',
        (tester) async {
      final completer = Completer<Post?>();
      final groupA = account('a.invalid', memoriesCapable: true);
      final groupB = account('b.invalid', memoriesCapable: true);
      // Only A is shown, so it's the sole shown group and effectiveMemoriesGroupId resolves
      // to it deterministically with no selection made yet.
      final session = MultiSessionController.seeded(MultiSession(
          groups: [groupA, groupB], hiddenGroupIds: const {'b.invalid'}, restored: true));

      final key = GlobalKey<MemoriesHostState>();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          multiSessionProvider.overrideWith(() => session),
          apiForGroupProvider.overrideWith((ref, id) => id == 'a.invalid'
              ? _DelayedMemoriesApi(completer)
              : _FakeMemoriesApi([memory(556, body: 'memory from B')])),
        ],
        child: MaterialApp(home: _MemoriesHost(key: key)),
      ));
      await tester.pump();

      await tester.tap(find.bySemanticsLabel('Memories'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Random check-in')); // hub entry
      await tester.pumpAndSettle();
      await tester.tap(find.text('Random check-in')); // the action button
      await tester.pump(); // starts the fetch against A; leaves it pending on completer

      // The resolved group changes mid-flight: A is hidden and B is shown instead - the
      // exact shape of bug that once double-attached a gif to the wrong cross-post target.
      // Here that resolution flows from the feed's own shown-group filter rather than the
      // header selector, but _MemoriesBody reacts to any groupId change the same way.
      await session.setHiddenGroups(const {'a.invalid'});
      await tester.pumpAndSettle();

      expect(find.text('memory from B'), findsOneWidget,
          reason: 'once the resolved group changes, the view must refetch and show that '
              "group's own result rather than sit on a stale one from the group it left "
              'behind');

      // A's abandoned request finally lands - it must never be allowed to paint over B's
      // already-showing, correctly-resolved result.
      completer.complete(memory(555, body: 'memory from A'));
      await tester.pumpAndSettle();

      expect(find.text('memory from A'), findsNothing,
          reason: 'a late response from a group that is no longer resolved must never paint, '
              'or the header pill and the content on screen would disagree');

      await tester.tap(find.bySemanticsLabel('Open this memory'));
      await tester.pumpAndSettle();

      final detail = tester.widget<PostDetailScreen>(find.byType(PostDetailScreen));
      expect(detail.postId, 556);
      expect(detail.groupId, 'b.invalid');
    });

    testWidgets(
        'switching the header\'s group selector while a memory is already showing refetches '
        'from the newly selected group', (tester) async {
      final groupA = account('a.invalid', memoriesCapable: true);
      final groupB = account('b.invalid', memoriesCapable: true);
      await pumpHost(tester,
          groups: [groupA, groupB],
          api: (id) => id == 'a.invalid'
              ? _FakeMemoriesApi([memory(201, body: 'from A')])
              : _FakeMemoriesApi([memory(202, body: 'from B')]));

      await tester.tap(find.bySemanticsLabel('Memories'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Random check-in')); // hub entry
      await tester.pumpAndSettle();
      await tester.tap(find.text('Random check-in')); // action button - fetches the default, A
      await tester.pumpAndSettle();
      expect(find.text('from A'), findsOneWidget);

      await tester.tap(find.text('b.invalid')); // the selector pill
      await tester.pumpAndSettle();

      expect(find.text('from B'), findsOneWidget,
          reason: 'switching the selector must refetch the currently-showing view from the '
              'newly picked group');
      expect(find.text('from A'), findsNothing);

      await tester.tap(find.bySemanticsLabel('Open this memory'));
      await tester.pumpAndSettle();

      final detail = tester.widget<PostDetailScreen>(find.byType(PostDetailScreen));
      expect(detail.postId, 202,
          reason: 'the refetched result must carry the newly selected group\'s id');
      expect(detail.groupId, 'b.invalid');
    });

    testWidgets(
        'switching the selector during the very first fetch (before it has ever resolved) '
        'still refetches, and the abandoned group\'s late response can never paint',
        (tester) async {
      // The gap the previous fix missed: the very first fetch never sets _fetched until it
      // resolves, so a guard keyed on _fetched alone sees nothing to react to here - this
      // is exactly "switch while _loading && !_fetched with the selector visible".
      final completerA = Completer<Post?>();
      final groupA = account('a.invalid', memoriesCapable: true);
      final groupB = account('b.invalid', memoriesCapable: true);
      await pumpHost(tester,
          groups: [groupA, groupB],
          api: (id) => id == 'a.invalid'
              ? _DelayedMemoriesApi(completerA)
              : _FakeMemoriesApi([memory(302, body: 'from B')]));

      await tester.tap(find.bySemanticsLabel('Memories'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Random check-in')); // hub entry
      await tester.pumpAndSettle();
      await tester
          .tap(find.text('Random check-in')); // action button - starts the first fetch, against A
      await tester.pump(); // leaves it pending on completerA; _fetched is still false here

      await tester.tap(find.text('b.invalid')); // the selector pill
      await tester.pumpAndSettle();

      expect(find.text('from B'), findsOneWidget,
          reason: 'switching mid-fetch must still refetch from the newly selected group, even '
              'though the abandoned fetch never resolved');

      // A's abandoned request finally lands - it must never be allowed to paint, even though
      // it's the only future left to settle.
      completerA.complete(memory(101, body: 'from A'));
      await tester.pumpAndSettle();

      expect(find.text('from A'), findsNothing,
          reason: 'a late response from a group the user has since switched away from must '
              'never paint, or the pill and the content on screen would disagree');
      expect(find.text('from B'), findsOneWidget);
    });

    testWidgets('renders the renamed hub entry and button, never the old strings', (tester) async {
      await pumpHost(tester,
          groups: [account('a.invalid', memoriesCapable: true)],
          api: (id) => _FakeMemoriesApi([null]));

      await tester.tap(find.bySemanticsLabel('Memories'));
      await tester.pumpAndSettle();

      expect(find.text('Random check-in'), findsOneWidget);
      expect(find.text('Give me a memory'), findsNothing);

      await tester.tap(find.text('Random check-in'));
      await tester.pumpAndSettle();

      expect(find.text('Random check-in'), findsOneWidget); // the idle-state button
      expect(find.text('Give me a memory'), findsNothing);
    });
  });

  group('lifecycle', () {
    testWidgets(
        'no animation controller or drag listener leaks when the host unmounts mid-animation',
        (tester) async {
      final key = await pumpHost(tester,
          groups: [account('a.invalid', memoriesCapable: true)],
          api: (id) => _FakeMemoriesApi([null]));

      key.currentState!.controller.animateTo(1);
      await tester.pump();
      expect(SchedulerBinding.instance.transientCallbackCount, greaterThan(0),
          reason: 'the open animation should be ticking');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 300));

      expect(SchedulerBinding.instance.transientCallbackCount, 0,
          reason: 'unmounting mid-animation must not leave a ticker running behind it');
      expect(tester.takeException(), isNull);
    });
  });

  group('pill pulse controller', () {
    // These build no widget tree at all - MemoriesPillPulseController is a plain object
    // driving an AnimationController, exactly like MemoriesDragDriver above, so its
    // scheduling rules are exercised directly. Still `testWidgets`, not `test`, purely to get
    // the fake clock tester.pump(duration) advances - a real dart:async Timer here would
    // otherwise make this suite wait out 30 real seconds per test.
    testWidgets('inactive by default: rest opacity, nothing scheduled', (tester) async {
      final controller = AnimationController(vsync: const TestVSync());
      addTearDown(controller.dispose);
      final pulse = MemoriesPillPulseController(controller);
      addTearDown(pulse.dispose);

      expect(pulse.opacity, kMemoriesPillRestOpacity);
      expect(pulse.hasPendingTimer, isFalse);
    });

    testWidgets(
        'setActive(true) schedules a timer; a full interval fires one rise-hold-fall pulse, '
        'then reschedules the next one', (tester) async {
      final controller = AnimationController(vsync: const TestVSync());
      addTearDown(controller.dispose);
      final pulse = MemoriesPillPulseController(controller);
      addTearDown(pulse.dispose);

      pulse.setActive(true);
      expect(pulse.hasPendingTimer, isTrue);
      expect(pulse.opacity, kMemoriesPillRestOpacity,
          reason: 'no pulse until the interval actually elapses');

      await tester.pump(kMemoriesPillPulseInterval);
      await tester.pump(kMemoriesPillPulseRise);
      expect(pulse.opacity, closeTo(kMemoriesPillPeakOpacity, 0.01));

      await tester.pump(kMemoriesPillPulseHold);
      expect(pulse.opacity, closeTo(kMemoriesPillPeakOpacity, 0.01),
          reason: 'holds near peak for the hold window');

      await tester.pump(kMemoriesPillPulseFall);
      // One more, past the boundary rather than a bare zero-duration pump: a controller
      // pumped by exactly its own total duration reports value 1.0 but its ticker doesn't
      // itself flip AnimationStatus.completed (and stop) until a frame strictly PAST that
      // point - a bare pump() reuses the same already-elapsed clock reading and so never
      // supplies one. Without this the sweep's own status listener (which reschedules the
      // next pulse) never runs, and the still-registered ticker trips flutter_test's own
      // end-of-test "animation still running" check.
      await tester.pump(const Duration(milliseconds: 1));
      expect(pulse.opacity, closeTo(kMemoriesPillRestOpacity, 0.01));
      expect(pulse.hasPendingTimer, isTrue,
          reason: 'settling back to rest must reschedule the next pulse, not stop for good');
      // Explicit, not just the addTearDown above: this test's whole point is proving a
      // rescheduled timer is genuinely pending when it ends, and addTearDown callbacks run
      // after flutter_test's own "no pending timers" end-of-test check, too late to satisfy
      // it - the assertion above already exercised what matters, so nothing is lost by
      // cleaning up before returning rather than after.
      pulse.dispose();
    });

    testWidgets('setActive(false) cancels a pending timer and snaps straight back to rest',
        (tester) async {
      final controller = AnimationController(vsync: const TestVSync());
      addTearDown(controller.dispose);
      final pulse = MemoriesPillPulseController(controller);
      addTearDown(pulse.dispose);

      pulse.setActive(true);
      expect(pulse.hasPendingTimer, isTrue);

      pulse.setActive(false);
      expect(pulse.hasPendingTimer, isFalse);
      expect(pulse.opacity, kMemoriesPillRestOpacity);

      // Waiting out a couple of full intervals while inactive must never fire a pulse.
      await tester.pump(kMemoriesPillPulseInterval * 2);
      expect(pulse.opacity, kMemoriesPillRestOpacity);
      expect(pulse.hasPendingTimer, isFalse);
    });

    testWidgets(
        'going inactive mid-pulse cuts it off immediately rather than letting the cycle finish',
        (tester) async {
      final controller = AnimationController(vsync: const TestVSync());
      addTearDown(controller.dispose);
      final pulse = MemoriesPillPulseController(controller);
      addTearDown(pulse.dispose);

      pulse.setActive(true);
      await tester.pump(kMemoriesPillPulseInterval);
      await tester.pump(kMemoriesPillPulseRise);
      expect(pulse.opacity, closeTo(kMemoriesPillPeakOpacity, 0.01),
          reason: 'test sanity check: the pulse should be mid-hold, near peak, right now');

      pulse.setActive(false);
      expect(pulse.opacity, kMemoriesPillRestOpacity,
          reason: 'a gating condition dropping must cut the pulse off immediately, not let a '
              'mid-flight cycle finish');
      expect(SchedulerBinding.instance.transientCallbackCount, 0,
          reason: 'no ticker should be left running once the pulse is cut off');
    });

    testWidgets('dispose cancels a pending timer', (tester) async {
      final controller = AnimationController(vsync: const TestVSync());
      addTearDown(controller.dispose);
      final pulse = MemoriesPillPulseController(controller);

      pulse.setActive(true);
      expect(pulse.hasPendingTimer, isTrue);

      pulse.dispose();
      expect(pulse.hasPendingTimer, isFalse);
    });
  });

  group('pill pulse wiring', () {
    Finder pillFinder() => find.byKey(const Key('memoriesPill'));

    Color pillColor(WidgetTester tester) =>
        (tester.widget<Container>(pillFinder()).decoration! as BoxDecoration).color!;

    testWidgets(
        'at rest the pill sits at the barely-there opacity, tinted by the accent - '
        'not a hardcoded grey', (tester) async {
      await pumpHost(tester, groups: [account('a.invalid', memoriesCapable: true)]);
      final color = pillColor(tester);
      expect(color.a, closeTo(kMemoriesPillRestOpacity, 0.01));
      // No accent theme extension is wired up in this bare MaterialApp host, so
      // context.accent resolves through AccentContext's own fallback to the first preset -
      // exactly what a real app with nothing customized shows.
      final accent = kAccentPresets.first.base;
      expect(color.r, closeTo(accent.r, 0.005));
      expect(color.g, closeTo(accent.g, 0.005));
      expect(color.b, closeTo(accent.b, 0.005));
    });

    testWidgets(
        'after 30s idle on the Feed tab with the surface closed, the pill pulses up to peak '
        'and back down', (tester) async {
      await pumpHost(tester, groups: [account('a.invalid', memoriesCapable: true)]);

      await tester.pump(kMemoriesPillPulseInterval);
      await tester.pump(kMemoriesPillPulseRise);
      expect(pillColor(tester).a, closeTo(kMemoriesPillPeakOpacity, 0.01));

      await tester.pump(kMemoriesPillPulseHold + kMemoriesPillPulseFall);
      expect(pillColor(tester).a, closeTo(kMemoriesPillRestOpacity, 0.01));
    });

    testWidgets('the tap still opens the surface mid-pulse, at peak opacity', (tester) async {
      final key = await pumpHost(tester,
          groups: [account('a.invalid', memoriesCapable: true)],
          api: (id) => _FakeMemoriesApi([null]));

      await tester.pump(kMemoriesPillPulseInterval);
      await tester.pump(kMemoriesPillPulseRise);
      expect(pillColor(tester).a, closeTo(kMemoriesPillPeakOpacity, 0.01),
          reason: 'test sanity check: the pulse should be at its peak right now');

      await tester.tap(find.bySemanticsLabel('Memories'));
      await tester.pumpAndSettle();
      expect(key.currentState!.controller.value, 1,
          reason: 'the tap must open the surface regardless of what the pulse is doing - the '
              'pulse is a hint, never a gate');
    });

    testWidgets('the drag gesture still works while the pill is at rest opacity', (tester) async {
      final key = await pumpHost(tester,
          groups: [account('a.invalid', memoriesCapable: true)],
          api: (id) => _FakeMemoriesApi([null]));
      final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      expect(pillColor(tester).a, closeTo(kMemoriesPillRestOpacity, 0.01));

      await tester.timedDrag(find.bySemanticsLabel('Memories'), Offset(width * 0.6, 0),
          const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(key.currentState!.controller.value, 1);
    });

    testWidgets('leaving the Feed tab stops the pulse and it never fires while away',
        (tester) async {
      final key = await pumpHost(tester, groups: [account('a.invalid', memoriesCapable: true)]);
      key.currentState!.setFeedActive(false);
      await tester.pump();

      await tester.pump(kMemoriesPillPulseInterval * 2);
      expect(pillColor(tester).a, closeTo(kMemoriesPillRestOpacity, 0.01));
      expect(SchedulerBinding.instance.transientCallbackCount, 0);
    });

    testWidgets('returning to the Feed tab lets the pulse schedule normally again', (tester) async {
      final key = await pumpHost(tester, groups: [account('a.invalid', memoriesCapable: true)]);
      key.currentState!.setFeedActive(false);
      await tester.pump();
      key.currentState!.setFeedActive(true);
      await tester.pump();

      await tester.pump(kMemoriesPillPulseInterval);
      await tester.pump(kMemoriesPillPulseRise);
      expect(pillColor(tester).a, closeTo(kMemoriesPillPeakOpacity, 0.01));
    });

    testWidgets('opening the surface stops the pulse; it never fires while the surface stays open',
        (tester) async {
      final key = await pumpHost(tester,
          groups: [account('a.invalid', memoriesCapable: true)],
          api: (id) => _FakeMemoriesApi([null]));

      await tester.tap(find.bySemanticsLabel('Memories'));
      await tester.pumpAndSettle();
      expect(key.currentState!.controller.value, 1);

      await tester.pump(kMemoriesPillPulseInterval * 2);
      expect(pillColor(tester).a, closeTo(kMemoriesPillRestOpacity, 0.01),
          reason: 'the pulse must never fire while the surface covers the screen');
    });

    testWidgets('backgrounding the app stops the pulse; resuming lets it schedule again',
        (tester) async {
      await pumpHost(tester, groups: [account('a.invalid', memoriesCapable: true)]);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.pump(kMemoriesPillPulseInterval * 2);
      expect(pillColor(tester).a, closeTo(kMemoriesPillRestOpacity, 0.01),
          reason: 'a timer waking every 30s in the background is a battery bug - the pulse '
              'must not run at all while backgrounded');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(kMemoriesPillPulseInterval);
      await tester.pump(kMemoriesPillPulseRise);
      expect(pillColor(tester).a, closeTo(kMemoriesPillPeakOpacity, 0.01),
          reason: 'resuming must let the pulse schedule normally again');
    });

    testWidgets('reduced motion renders a constant modest opacity and never schedules a pulse',
        (tester) async {
      await pumpHost(tester,
          groups: [account('a.invalid', memoriesCapable: true)], disableAnimations: true);
      expect(pillColor(tester).a, closeTo(kMemoriesPillReducedMotionOpacity, 0.01));

      await tester.pump(kMemoriesPillPulseInterval * 2);
      expect(pillColor(tester).a, closeTo(kMemoriesPillReducedMotionOpacity, 0.01),
          reason: 'reduced motion must never animate the pill at all, constant only');
      expect(SchedulerBinding.instance.transientCallbackCount, 0);
    });
  });
}
