import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/home_shell.dart';
import 'package:checkin/state/app_state.dart';

/// Tagging people on a cross-post. Tags are stored per server against that server's own
/// user ids, so the same human is a different id in each group - the compose sheet has to
/// resolve them per target and send each group only its own ids. Sending one group's ids to
/// another would tag whoever happens to hold those numbers there.
class _FakeApi extends ApiClient {
  _FakeApi(this.groupId) : super(baseUrl: 'https://$groupId');

  final String groupId;

  /// peopleIds as this group's server received them (null = the field was omitted).
  List<int>? taggedReceived;
  bool posted = false;

  @override
  Future<Post> createPost({
    required String kind,
    required String body,
    List<int>? mediaIds,
    String? location,
    List<int>? peopleIds,
    String? crossPostId,
  }) async {
    posted = true;
    // The client omits an empty list, and so must this fake: "nobody tagged" and "these
    // people tagged" have to stay distinguishable.
    taggedReceived = (peopleIds == null || peopleIds.isEmpty) ? null : peopleIds;
    return Post(
      id: 1,
      authorId: 1,
      authorName: 'Nick',
      kind: 'text',
      body: body,
      createdAt: DateTime(2026, 1, 1),
      likeCount: 0,
      commentCount: 0,
      likedByViewer: false,
    );
  }
}

void main() {
  User member(int id, String name, String phone) =>
      User(id: id, name: name, phone: phone, isAdmin: false);

  // The same human on three servers: Nick (the author) is 1/11/21, Ada is 2/12 and has no
  // account in Gamma, Grace is 3/-/23.
  final rosters = {
    'alpha.invalid': [
      member(1, 'Nick', '+15550001111'),
      member(2, 'Ada', '+15550002222'),
      member(3, 'Grace', '+15550003333'),
    ],
    'beta.invalid': [
      member(11, 'Nick', '+15550001111'),
      member(12, 'Ada', '+15550002222'),
    ],
    'gamma.invalid': [
      member(21, 'Nick', '+15550001111'),
      member(23, 'Grace', '+15550003333'),
    ],
  };

  ServerAccount account(String id, String name, int meId) => ServerAccount(
        id: id,
        baseUrl: 'https://$id',
        serverName: name,
        token: 't',
        user: User(id: meId, name: 'Nick', phone: '+15550001111', isAdmin: false),
      );

  final groups = [
    account('alpha.invalid', 'Alpha', 1),
    account('beta.invalid', 'Beta', 11),
    account('gamma.invalid', 'Gamma', 21),
  ];

  /// Opens the compose sheet the way the feed's compose button does, over a fake API per
  /// group that records what each server was asked to post.
  Future<Map<String, _FakeApi>> openCompose(WidgetTester tester) async {
    final apis = {for (final g in groups) g.id: _FakeApi(g.id)};
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          multiSessionProvider.overrideWith(
              () => MultiSessionController.seeded(MultiSession(groups: groups, restored: true))),
          apiForGroupProvider.overrideWith((ref, groupId) => apis[groupId]!),
          groupMembersProvider
              .overrideWith((ref, groupId) async => rosters[groupId] ?? const <User>[]),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showModalBottomSheet<bool?>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => const ComposeSheet(),
                ),
                child: const Text('compose'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('compose'));
    await tester.pumpAndSettle();
    return apis;
  }

  /// Picks [name] in the tag sheet and confirms.
  Future<void> tagPerson(WidgetTester tester, String name) async {
    await tester.tap(find.text('Tag people'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, name));
    await tester.pump();
    await tester.tap(find.text('Done (1)'));
    await tester.pumpAndSettle();
  }

  testWidgets('a cross-post tags the same human with each group\'s own member id', (tester) async {
    final apis = await openCompose(tester);
    // All three groups are targets by default, and tagging is offered anyway - it used to be
    // hidden the moment a second group was selected, which made it unusable for anyone who
    // cross-posts.
    expect(find.text('Share (3)'), findsOneWidget);
    expect(find.text('Tag people'), findsOneWidget);

    await tagPerson(tester, 'Ada');
    expect(find.text('Ada'), findsOneWidget); // the compose row now names her

    await tester.enterText(find.byType(TextField).first, 'at the crag');
    await tester.pump();
    await tester.tap(find.text('Share (3)'));
    await tester.pumpAndSettle();

    // Each server got the id Ada holds THERE. Any of these carrying another group's number
    // would tag a stranger on that server.
    expect(apis['alpha.invalid']!.taggedReceived, [2]);
    expect(apis['beta.invalid']!.taggedReceived, [12]);
    // Gamma has no account for Ada: it still gets the post, just without her.
    expect(apis['gamma.invalid']!.posted, isTrue);
    expect(apis['gamma.invalid']!.taggedReceived, isNull);
  });

  testWidgets('the picker says which groups a person is missing from', (tester) async {
    await openCompose(tester);
    await tester.tap(find.text('Tag people'));
    await tester.pumpAndSettle();

    // Ada is in Alpha and Beta only; Grace in Alpha and Gamma only.
    expect(find.text('not in Gamma'), findsOneWidget);
    expect(find.text('not in Beta'), findsOneWidget);
    // The author is never offered: the post is implicitly his, on every server.
    expect(find.widgetWithText(ListTile, 'Nick'), findsNothing);
  });

  testWidgets('dropping a target keeps tags that survive it and clears the rest', (tester) async {
    final apis = await openCompose(tester);
    await tagPerson(tester, 'Ada'); // Alpha + Beta

    // Drop Beta: Ada still has an Alpha account, so she stays tagged there.
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(find.text('Ada'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'at the crag');
    await tester.pump();
    await tester.tap(find.text('Share (2)'));
    await tester.pumpAndSettle();

    expect(apis['alpha.invalid']!.taggedReceived, [2]);
    expect(apis['beta.invalid']!.posted, isFalse); // no longer a target
    expect(apis['gamma.invalid']!.taggedReceived, isNull);
  });

  testWidgets('a tag whose last group is dropped goes away with it', (tester) async {
    await openCompose(tester);
    await tagPerson(tester, 'Ada'); // Alpha + Beta
    expect(find.text('Ada'), findsOneWidget);

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();

    // Only Gamma is left, and it has no account for Ada - there is no id left to tag.
    expect(find.text('Ada'), findsNothing);
    expect(find.text('Tag people'), findsOneWidget);
  });

  testWidgets('with no group selected there is nobody to tag', (tester) async {
    await openCompose(tester);
    for (final name in ['Alpha', 'Beta', 'Gamma']) {
      await tester.tap(find.text(name));
      await tester.pumpAndSettle();
    }
    expect(find.text('pick at least one group'), findsOneWidget);
    expect(find.text('Tag people'), findsNothing);
  });

  testWidgets('adding a group after tagging re-binds the tag to that group\'s id too',
      (tester) async {
    final apis = await openCompose(tester);
    // Start with Alpha only, tag Ada there, then bring Beta back in.
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gamma'));
    await tester.pumpAndSettle();
    await tagPerson(tester, 'Ada');

    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    // Re-opening the picker re-binds the carried-over selection to the fuller roster: the
    // stale entry only knew Alpha's id for her.
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done (1)'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'at the crag');
    await tester.pump();
    await tester.tap(find.text('Share (2)'));
    await tester.pumpAndSettle();

    expect(apis['alpha.invalid']!.taggedReceived, [2]);
    expect(apis['beta.invalid']!.taggedReceived, [12]);
  });
}
