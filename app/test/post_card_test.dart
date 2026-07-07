import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/post_card.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/theme/group_color.dart';

/// The post card shows a group marker (a colored dot, labelled with the group name for
/// screen readers, plus a left rail) only in the merged feed - i.e. when a groupColor is
/// passed. A single-group view passes null and shows no marker. A plain text post needs no
/// media, so nothing hits the network.
void main() {
  final user = User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: true);
  final account = ServerAccount(
    id: 'alpha.invalid',
    baseUrl: 'https://alpha.invalid',
    serverName: 'Alpha',
    token: 't1',
    user: user,
  );
  final post = Post(
    id: 5,
    authorId: 2,
    authorName: 'Ada',
    kind: 'text',
    body: 'hello',
    createdAt: DateTime(2026, 7, 1),
    likeCount: 0,
    commentCount: 0,
    likedByViewer: false,
    groupId: 'alpha.invalid',
  );

  Future<void> pumpCard(WidgetTester tester, {Color? groupColor}) async {
    final controller =
        MultiSessionController.seeded(MultiSession(groups: [account], restored: true));
    await tester.pumpWidget(ProviderScope(
      overrides: [multiSessionProvider.overrideWith((ref) => controller)],
      child: MaterialApp(home: Scaffold(body: PostCard(post: post, groupColor: groupColor))),
    ));
    await tester.pump();
  }

  testWidgets('shows the group marker only when a group color is set', (tester) async {
    await pumpCard(tester, groupColor: groupColorById('coral'));
    expect(find.bySemanticsLabel('Group: Alpha'), findsOneWidget);

    await pumpCard(tester, groupColor: null);
    expect(find.bySemanticsLabel('Group: Alpha'), findsNothing);
  });
}
