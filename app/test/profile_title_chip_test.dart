import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/profile/profile_screen.dart';
import 'package:checkin/state/app_state.dart';

/// A member's bestowed profile title (an award id from the recap system, e.g.
/// "quiet_achiever") renders as a small chip below the check-in count - see
/// profile_screen.dart's `_titleChip`/`_titleLabels`. These pin the three states: shown
/// with its mapped label, absent when there is none, and silently skipped for an id this
/// build doesn't recognise (a future server's new award).
class _FakeApi extends ApiClient {
  _FakeApi(this.user) : super(baseUrl: '');

  final User user;

  @override
  Future<User> getUser(int id) async => user;

  @override
  Future<List<Post>> userPosts(int userId, {DateTime? before}) async => const [];

  @override
  Future<bool> isBlocked(int userId) async => false;
}

void main() {
  ServerAccount viewerAccount(User me) => ServerAccount(
        id: 'alpha.invalid',
        baseUrl: 'https://alpha.invalid',
        serverName: 'Alpha',
        token: 't1',
        user: me,
      );

  Future<void> pumpOtherProfile(WidgetTester tester,
      {required User viewer, required User target}) async {
    final controller = MultiSessionController.seeded(
      MultiSession(groups: [viewerAccount(viewer)], restored: true),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(() => controller),
        contentApiProvider('alpha.invalid').overrideWithValue(_FakeApi(target)),
      ],
      child: MaterialApp(home: ProfileScreen(userId: target.id, groupId: 'alpha.invalid')),
    ));
    await tester.pumpAndSettle();
  }

  final viewer = User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: true);

  testWidgets('a member with a bestowed title shows it as a chip below the check-in count',
      (tester) async {
    final target =
        User(id: 2, name: 'Sam', phone: '+15550002222', isAdmin: false, title: 'quiet_achiever');
    await pumpOtherProfile(tester, viewer: viewer, target: target);

    expect(find.text('Quiet Achiever'), findsOneWidget);
  });

  testWidgets('a member with no title shows no chip at all', (tester) async {
    final target = User(id: 2, name: 'Sam', phone: '+15550002222', isAdmin: false);
    await pumpOtherProfile(tester, viewer: viewer, target: target);

    for (final label in const [
      'Most Loved',
      'Night Owl',
      'Early Bird',
      'Most Travelled',
      'Chatterbox',
      'Biggest Fan',
      'Quiet Achiever',
      'Most Tagged',
      'Conversation Starter',
    ]) {
      expect(find.text(label), findsNothing);
    }
  });

  testWidgets('an unrecognised title id from a future server renders nothing, not a crash',
      (tester) async {
    final target =
        User(id: 2, name: 'Sam', phone: '+15550002222', isAdmin: false, title: 'some_future_award');
    await pumpOtherProfile(tester, viewer: viewer, target: target);

    expect(tester.takeException(), isNull);
    expect(find.text('Sam'), findsOneWidget); // the profile itself still renders fine
    expect(find.textContaining('some_future_award'), findsNothing);
  });

  testWidgets('longest_thread reads as "Conversation Starter", not its old panel label',
      (tester) async {
    final target =
        User(id: 2, name: 'Sam', phone: '+15550002222', isAdmin: false, title: 'longest_thread');
    await pumpOtherProfile(tester, viewer: viewer, target: target);

    expect(find.text('Conversation Starter'), findsOneWidget);
    expect(find.text('Longest Thread'), findsNothing);
  });
}
