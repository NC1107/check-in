import 'package:flutter/material.dart';
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
}
