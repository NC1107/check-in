import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/memories/memories_screen.dart';
import 'package:checkin/features/post/post_detail_screen.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/widgets/photo_viewer.dart';

/// The Memories surface's "Forgotten photos" hub entry: the hub gating it on its own
/// capability, the fetch/loaded/empty/unsupported/error states, "Another" refetching, tapping
/// opening the existing full-screen viewer (not the post detail screen - see the founder's
/// brief), and the same stale-response/group-switch handling _SinglePostView shares with
/// "Random check-in" (already covered end-to-end for that view in memories_test.dart; this
/// file re-covers the same class through its other configuration rather than re-deriving it).
class _FakeForgottenApi extends ApiClient {
  _FakeForgottenApi(this._responses) : super(baseUrl: 'https://x.invalid');

  final List<Post?> _responses;
  int calls = 0;

  @override
  Future<Post?> forgottenPhoto() async {
    final r = _responses[calls < _responses.length ? calls : _responses.length - 1];
    calls++;
    return r;
  }
}

/// A fake ApiClient whose forgottenPhoto() doesn't resolve until the test completes
/// [completer] - lets a test hold a fetch open mid-flight to change other state (e.g. the
/// shown-group set) before letting it land, mirroring memories_test.dart's own
/// _DelayedMemoriesApi for randomMemory().
class _DelayedForgottenApi extends ApiClient {
  _DelayedForgottenApi(this.completer) : super(baseUrl: 'https://x.invalid');

  final Completer<Post?> completer;

  @override
  Future<Post?> forgottenPhoto() => completer.future;
}

/// A bounded stand-in for pumpAndSettle(): a real AuthImage's network fetch never resolves in
/// a widget test, so pumpAndSettle's "pump until nothing is scheduled" loop times out the
/// instant a forgotten photo's own card renders its cover image - unlike "Random check-in"'s
/// own tests, this feature's posts always carry media (see the server's has-media rule), so
/// every loaded-state screen here hits this. Mirrors memories_events_test.dart's identical
/// helper, needed there for exactly the same reason.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ServerAccount account(String id, {bool memoriesCapable = false, bool forgottenCapable = false}) =>
      ServerAccount(
        id: id,
        baseUrl: 'https://$id',
        serverName: id,
        token: 't',
        memoriesCapable: memoriesCapable,
        forgottenCapable: forgottenCapable,
      );

  Post photo(int id, {String authorName = 'Ada', DateTime? createdAt}) => Post(
        id: id,
        authorId: 9,
        authorName: authorName,
        kind: 'image',
        body: '',
        createdAt: createdAt ?? DateTime.now().subtract(const Duration(days: 400)),
        likeCount: 1,
        commentCount: 0,
        likedByViewer: false,
        mediaIds: const [501],
        media: const [PostMedia(id: 501, mime: 'image/jpeg', width: 800, height: 600)],
      );

  /// Pumps a Memories surface already fully open (value: 1), wired to [serverAccount] as the
  /// one signed-in, shown group - mirrors memories_events_test.dart's own pumpOpenSurface,
  /// skipping the handle-tap/drag machinery those flows already cover on their own.
  Future<void> pumpOpenSurface(WidgetTester tester,
      {required ServerAccount serverAccount, required ApiClient api}) async {
    final controller = AnimationController(
        vsync: const TestVSync(), value: 1, duration: const Duration(milliseconds: 220));
    addTearDown(controller.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(() =>
            MultiSessionController.seeded(MultiSession(groups: [serverAccount], restored: true))),
        apiForGroupProvider.overrideWith((ref, id) => api),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: MemoriesSurface(controller: controller, onClose: () => controller.value = 0),
        ),
      ),
    ));
    await tester.pump();
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  }

  /// Wires up more than one shown group, each resolved to its own api via [apiFor] - what the
  /// group-switch-mid-fetch tests need.
  Future<void> pumpOpenSurfaceMulti(WidgetTester tester,
      {required List<ServerAccount> groups,
      Set<String> hiddenGroupIds = const {},
      required ApiClient Function(String groupId) apiFor}) async {
    final controller = AnimationController(
        vsync: const TestVSync(), value: 1, duration: const Duration(milliseconds: 220));
    addTearDown(controller.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(() => MultiSessionController.seeded(
            MultiSession(groups: groups, hiddenGroupIds: hiddenGroupIds, restored: true))),
        apiForGroupProvider.overrideWith((ref, id) => apiFor(id)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: MemoriesSurface(controller: controller, onClose: () => controller.value = 0),
        ),
      ),
    ));
    await tester.pump();
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  }

  group('hub capability gate', () {
    testWidgets('offers "Forgotten photos" when the group advertises the capability',
        (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', forgottenCapable: true),
          api: _FakeForgottenApi([null]));

      expect(find.text('Forgotten photos'), findsOneWidget);
    });

    testWidgets('hides "Forgotten photos" when the group predates the capability', (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', memoriesCapable: true, forgottenCapable: false),
          api: _FakeForgottenApi([null]));

      expect(find.text('Random check-in'), findsOneWidget);
      expect(find.text('Forgotten photos'), findsNothing);
    });
  });

  group('surface content', () {
    testWidgets(
        'fetches and renders a forgotten photo, Another refetches, tapping opens the '
        'existing full-screen viewer with the go-to-post route', (tester) async {
      final first = photo(701, authorName: 'Ada');
      final second = photo(702, authorName: 'Bea');
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', forgottenCapable: true),
          api: _FakeForgottenApi([first, second]));

      await tester.tap(find.text('Forgotten photos')); // hub entry
      await settle(tester);
      await tester.tap(find.text('Forgotten photos')); // the idle action button
      await settle(tester);

      expect(find.text('Ada'), findsOneWidget);

      // The card carries a real cover photo (unlike "Random check-in"'s own text-only test
      // fixtures), so it's tall enough that "Another" sits below the test viewport's fold
      // until the scroll view is actually scrolled to it.
      await tester.ensureVisible(find.text('Another'));
      await tester.tap(find.text('Another'));
      await settle(tester);

      expect(find.text('Bea'), findsOneWidget);
      expect(find.text('Ada'), findsNothing);

      await tester.ensureVisible(find.bySemanticsLabel('Open this photo'));
      await tester.tap(find.bySemanticsLabel('Open this photo'));
      await settle(tester);

      final viewer = tester.widget<PhotoViewerScreen>(find.byType(PhotoViewerScreen));
      expect(viewer.postId, 702,
          reason: 'the viewer must be scoped to whatever "Another" most recently fetched');
      expect(viewer.groupId, 'a.invalid');
      expect(viewer.media.single.id, 501);
      expect(find.byType(PostDetailScreen), findsNothing,
          reason: 'a forgotten photo opens the full-screen viewer, never the post detail '
              'screen directly - that is "Random check-in"\'s own behavior, not this one\'s');
    });

    testWidgets('renders the truthful empty state for a group with nothing old enough yet',
        (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', forgottenCapable: true),
          api: _FakeForgottenApi([null]));

      await tester.tap(find.text('Forgotten photos'));
      await settle(tester);
      await tester.tap(find.text('Forgotten photos'));
      await settle(tester);

      expect(find.text('Nothing forgotten yet.'), findsOneWidget);
      // Never a bare, permanent spinner.
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('an honest error state when the fetch fails, with a way to retry', (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', forgottenCapable: true),
          api: _ThrowingForgottenApi());

      await tester.tap(find.text('Forgotten photos'));
      await settle(tester);
      await tester.tap(find.text('Forgotten photos'));
      await settle(tester);

      expect(find.text("Couldn't load a forgotten photo."), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets(
        'a mid-flight fetch is abandoned when the resolved group changes before it resolves',
        (tester) async {
      final completer = Completer<Post?>();
      final groupA = account('a.invalid', forgottenCapable: true);
      final groupB = account('b.invalid', forgottenCapable: true);
      await pumpOpenSurfaceMulti(tester,
          groups: [groupA, groupB],
          hiddenGroupIds: const {'b.invalid'},
          apiFor: (id) => id == 'a.invalid'
              ? _DelayedForgottenApi(completer)
              : _FakeForgottenApi([photo(556, authorName: 'from B')]));

      await tester.tap(find.text('Forgotten photos'));
      await settle(tester);
      await tester.tap(find.text('Forgotten photos'));
      await tester.pump(); // starts the fetch against A; leaves it pending on completer

      // The resolved group changes mid-flight: A is hidden, B becomes the sole shown group.
      final container = ProviderScope.containerOf(tester.element(find.byType(MemoriesSurface)));
      await container.read(multiSessionProvider.notifier).setHiddenGroups(const {'a.invalid'});
      await settle(tester);

      await tester.ensureVisible(find.bySemanticsLabel('Open this photo'));
      await tester.tap(find.bySemanticsLabel('Open this photo'));
      await settle(tester);
      final viewer = tester.widget<PhotoViewerScreen>(find.byType(PhotoViewerScreen));
      expect(viewer.postId, 556,
          reason: 'once the resolved group changes, the view must show B\'s own refetched '
              'result');
      expect(viewer.groupId, 'b.invalid');

      // A's abandoned request finally lands - it must never be allowed to paint over B's
      // already-showing, correctly-resolved result.
      completer.complete(photo(555, authorName: 'from A'));
      await settle(tester);
      expect(find.text('from A'), findsNothing,
          reason: 'a late response from a group that is no longer resolved must never paint');
    });
  });
}

/// An ApiClient whose forgottenPhoto() always throws - the honest-error-state fixture.
class _ThrowingForgottenApi extends ApiClient {
  _ThrowingForgottenApi() : super(baseUrl: 'https://x.invalid');

  @override
  Future<Post?> forgottenPhoto() async => throw Exception('boom');
}
