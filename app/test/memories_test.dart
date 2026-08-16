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
  /// the host's controller.
  Future<GlobalKey<MemoriesHostState>> pumpHost(
    WidgetTester tester, {
    List<ServerAccount> groups = const [],
    ApiClient Function(String groupId)? api,
  }) async {
    final key = GlobalKey<MemoriesHostState>();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(
            () => MultiSessionController.seeded(MultiSession(groups: groups, restored: true))),
        if (api != null) apiForGroupProvider.overrideWith((ref, id) => api(id)),
      ],
      child: MaterialApp(home: _MemoriesHost(key: key)),
    ));
    await tester.pump();
    return key;
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
