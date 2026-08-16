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

  void close() => controller.animateTo(0, duration: Duration.zero);

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
        child: Row(children: [MemoriesHandle(controller: controller)]),
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
            child: MemoriesHandle(controller: controller),
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
      // surface closed - exactly the real scenario of tapping "Give me a memory" or
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

      await tester.pumpWidget(MaterialApp(
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

      // Idle until "Give me a memory" is tapped.
      expect(find.text('Give me a memory'), findsOneWidget);
      await tester.tap(find.text('Give me a memory'));
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
      await tester.tap(find.text('Give me a memory'));
      await tester.pumpAndSettle();

      expect(find.text('Nothing to look back on yet.'), findsOneWidget);
      // Never a bare, permanent spinner - see feature spec's empty-state requirement.
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets(
        'a mid-flight fetch keeps the group it was actually fetched from, even if the shown '
        'selection changes before it resolves', (tester) async {
      final completer = Completer<Post?>();
      final groupA = account('a.invalid', memoriesCapable: true);
      final groupB = account('b.invalid', memoriesCapable: true);
      // Only A is shown, so the uniform pick among capable shown groups is deterministic.
      final session = MultiSessionController.seeded(MultiSession(
          groups: [groupA, groupB], hiddenGroupIds: const {'b.invalid'}, restored: true));

      final key = GlobalKey<MemoriesHostState>();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          multiSessionProvider.overrideWith(() => session),
          apiForGroupProvider.overrideWith((ref, id) => id == 'a.invalid'
              ? _DelayedMemoriesApi(completer)
              // B's api must never be read: nothing in this test ever shows B while the
              // fetch is in flight.
              : _FakeMemoriesApi([memory(999, body: 'should never be seen')])),
        ],
        child: MaterialApp(home: _MemoriesHost(key: key)),
      ));
      await tester.pump();

      await tester.tap(find.bySemanticsLabel('Memories'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Give me a memory'));
      await tester.pump(); // starts the fetch against A; leaves it pending on completer

      // The active selection changes mid-flight: A is hidden and B is shown instead - the
      // exact shape of bug that once double-attached a gif to the wrong cross-post target.
      await session.setHiddenGroups(const {'a.invalid'});
      await tester.pump();

      completer.complete(memory(555, body: 'memory from A'));
      await tester.pumpAndSettle();

      expect(find.text('memory from A'), findsOneWidget,
          reason: 'the fetch must resolve against the group it was sent to, not whatever is '
              'shown by the time the response lands');

      await tester.tap(find.bySemanticsLabel('Open this memory'));
      await tester.pumpAndSettle();

      final detail = tester.widget<PostDetailScreen>(find.byType(PostDetailScreen));
      expect(detail.postId, 555);
      expect(detail.groupId, 'a.invalid');
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
}
