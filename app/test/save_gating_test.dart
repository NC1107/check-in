import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/post_card.dart';
import 'package:checkin/state/app_state.dart';

/// Save to gallery is an image-only affordance: Gal writes the downloaded bytes as they
/// arrive, so offering it for a clip would put an unopenable file in someone's camera roll
/// and call it saved.
void main() {
  final account = ServerAccount(
    id: 'alpha.invalid',
    baseUrl: 'https://alpha.invalid',
    serverName: 'Alpha',
    token: 't1',
    user: User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: false),
  );

  Post post(List<PostMedia> media) => Post(
        id: 5,
        authorId: 2,
        authorName: 'Ada',
        kind: media.any((m) => m.isVideo) ? 'video' : 'image',
        body: 'hello',
        createdAt: DateTime(2026, 8, 14),
        likeCount: 0,
        commentCount: 0,
        likedByViewer: false,
        mediaIds: [for (final m in media) m.id],
        media: media,
        groupId: 'alpha.invalid',
      );

  Future<void> openMenu(WidgetTester tester, Post p) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(
          () => MultiSessionController.seeded(MultiSession(groups: [account], restored: true)),
        ),
      ],
      child: MaterialApp(home: Scaffold(body: ListView(children: [PostCard(post: p)]))),
    ));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.more_horiz));
    // Bounded pumps rather than pumpAndSettle: the post's own images never resolve offline,
    // and their placeholder spinner animates forever.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('a photo can be saved', (tester) async {
    await openMenu(tester, post(const [PostMedia(id: 7, mime: 'image/jpeg')]));
    expect(find.text('Save photo'), findsOneWidget);
  });

  testWidgets('a check-in that is only a clip cannot', (tester) async {
    await openMenu(tester, post(const [PostMedia(id: 8, mime: 'video/mp4', durationMs: 9500)]));
    expect(find.text('Save photo'), findsNothing);
  });

  testWidgets('a clip alongside a photo still offers the photo', (tester) async {
    await openMenu(
        tester,
        post(const [
          PostMedia(id: 8, mime: 'video/mp4', durationMs: 9500),
          PostMedia(id: 9, mime: 'image/jpeg'),
        ]));
    expect(find.text('Save photo'), findsOneWidget);
  });
}
