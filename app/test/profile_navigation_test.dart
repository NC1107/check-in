import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/post_card.dart';
import 'package:checkin/features/profile/profile_screen.dart';
import 'package:checkin/state/app_state.dart';

/// Tapping a post's author must land the viewer on their own editable profile when the
/// post is theirs (even from another group), never on the read-only stranger view of
/// themselves - that view has no settings/edit access, which was the reported bug.
void main() {
  final me = User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: false);
  final account = ServerAccount(
    id: 'alpha.invalid',
    baseUrl: 'https://alpha.invalid',
    serverName: 'Alpha',
    token: 't1',
    user: me,
  );

  Post post({required int authorId, required String authorName}) => Post(
        id: 5,
        authorId: authorId,
        authorName: authorName,
        kind: 'text',
        body: 'hello',
        createdAt: DateTime(2026, 7, 1),
        likeCount: 0,
        commentCount: 0,
        likedByViewer: false,
        groupId: 'alpha.invalid',
      );

  Future<void> pumpCard(WidgetTester tester, Post p) async {
    final controller =
        MultiSessionController.seeded(MultiSession(groups: [account], restored: true));
    await tester.pumpWidget(ProviderScope(
      overrides: [multiSessionProvider.overrideWith(() => controller)],
      child: MaterialApp(home: Scaffold(body: PostCard(post: p))),
    ));
    await tester.pump();
  }

  testWidgets('tapping your own post opens MyProfileScreen, not the read-only view',
      (tester) async {
    await pumpCard(tester, post(authorId: me.id, authorName: me.name));
    await tester.tap(find.text('Nick'));
    // Let the push transition finish (its own posts fetch hits an unresolvable .invalid
    // host and fails fast, so this settles quickly rather than idling out the default cap).
    await tester.pumpAndSettle(const Duration(milliseconds: 50), EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5));

    expect(find.byType(MyProfileScreen), findsOneWidget);
    expect(find.byType(ProfileScreen), findsNothing);
  });

  testWidgets("tapping someone else's post opens the read-only ProfileScreen", (tester) async {
    await pumpCard(tester, post(authorId: 2, authorName: 'Ada'));
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle(const Duration(milliseconds: 50), EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5));

    expect(find.byType(ProfileScreen), findsOneWidget);
    expect(find.byType(MyProfileScreen), findsNothing);
  });

  group('ProfileScreen.resolve', () {
    testWidgets('picks MyProfileScreen for the viewer\'s own id in that group', (tester) async {
      late BuildContext ctx;
      final controller =
          MultiSessionController.seeded(MultiSession(groups: [account], restored: true));
      await tester.pumpWidget(ProviderScope(
        overrides: [multiSessionProvider.overrideWith(() => controller)],
        child: MaterialApp(home: Builder(builder: (context) {
          ctx = context;
          return const SizedBox();
        })),
      ));

      final screen = ProfileScreen.resolve(ctx, userId: me.id, groupId: 'alpha.invalid');
      expect(screen, isA<MyProfileScreen>());
    });

    testWidgets('picks the read-only ProfileScreen for a different id', (tester) async {
      late BuildContext ctx;
      final controller =
          MultiSessionController.seeded(MultiSession(groups: [account], restored: true));
      await tester.pumpWidget(ProviderScope(
        overrides: [multiSessionProvider.overrideWith(() => controller)],
        child: MaterialApp(home: Builder(builder: (context) {
          ctx = context;
          return const SizedBox();
        })),
      ));

      final screen = ProfileScreen.resolve(ctx, userId: 2, groupId: 'alpha.invalid');
      expect(screen, isA<ProfileScreen>());
    });

    testWidgets('an unknown groupId opens an ordinary profile rather than guessing it is you',
        (tester) async {
      late BuildContext ctx;
      final controller =
          MultiSessionController.seeded(MultiSession(groups: [account], restored: true));
      await tester.pumpWidget(ProviderScope(
        overrides: [multiSessionProvider.overrideWith(() => controller)],
        child: MaterialApp(home: Builder(builder: (context) {
          ctx = context;
          return const SizedBox();
        })),
      ));

      final screen = ProfileScreen.resolve(ctx, userId: me.id, groupId: 'no-such-group');
      // "Is this me?" is decided by comparing a user id against the signed-in user of the
      // group the id CAME FROM. When that group is unknown there is nothing valid to
      // compare against: user ids are per-server, so checking it against whichever group
      // happens to be current can answer "yes, that's you" about a completely different
      // person who merely holds the same number there.
      //
      // So resolve declines to shortcut and opens the ordinary profile, which loads (or
      // fails) honestly. The original point of this test still holds - it must not crash.
      expect(screen, isA<ProfileScreen>());
      expect(screen, isNot(isA<MyProfileScreen>()));
    });
  });
}
