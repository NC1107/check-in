import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/feed_screen.dart';
import 'package:checkin/state/app_state.dart';

/// Feed-screen behaviors around the status-bar tap-strip and the bulk-download flow.
/// The API is stubbed (feed pagination returns nothing more) so no network is touched.
class _FakeApi extends ApiClient {
  _FakeApi() : super(baseUrl: 'https://alpha.invalid');

  @override
  Future<List<Post>> feed(
          {int? authorId,
          Set<String> locations = const {},
          DateTime? before,
          int? beforeId}) async =>
      [];
}

/// A bounded pump loop rather than pumpAndSettle(): a post with photos on it renders them,
/// and their placeholder spinner animates indefinitely against an unresolvable .invalid
/// host, so pumpAndSettle's "no frames scheduled" condition never becomes true. Same
/// technique as photo_viewer_test.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const alpha = ServerAccount(
      id: 'alpha.invalid', baseUrl: 'https://alpha.invalid', serverName: 'Alpha', token: 't1');

  Post post(int id, DateTime created, String body, {List<int> mediaIds = const []}) => Post(
        id: id,
        authorId: 1,
        authorName: 'Nick',
        // The card renders whatever is attached, whatever the kind says, so these photos
        // do load - as placeholders, since nothing resolves offline. The download collector
        // counts the same attachments, which is what makes galleries testable here.
        kind: 'text',
        body: body,
        createdAt: created,
        likeCount: 0,
        commentCount: 0,
        likedByViewer: false,
        mediaIds: mediaIds,
        groupId: 'alpha.invalid',
      );

  Future<void> pump(WidgetTester tester, List<Post> posts) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          multiSessionProvider.overrideWith(() =>
              MultiSessionController.seeded(const MultiSession(groups: [alpha], restored: true))),
          feedProvider.overrideWith((ref) async => FeedResult(posts: posts)),
          apiForGroupProvider.overrideWith((ref, groupId) => _FakeApi()),
          locationsProvider.overrideWith((ref, groupId) async => []),
          groupMembersProvider.overrideWith((ref, groupId) async => []),
        ],
        child: MaterialApp(
          // Simulate a phone's status-bar inset so the tap-strip has real height.
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(padding: const EdgeInsets.only(top: 40)),
            child: child!,
          ),
          home: const FeedScreen(),
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets('tapping the status-bar strip scrolls the feed back to the top', (tester) async {
    final now = DateTime.now();
    await pump(tester, [
      for (var i = 0; i < 20; i++)
        post(100 - i, now.subtract(Duration(minutes: i)), 'post number $i\nwith a second line'),
    ]);

    ScrollableState scrollable() => tester.state<ScrollableState>(find.byType(Scrollable).first);

    // Scroll down, away from the top.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -800));
    await settle(tester);
    expect(scrollable().position.pixels, greaterThan(0));

    // A tap inside the status-bar inset (the strip spans its full height) animates back.
    await tester.tapAt(const Offset(200, 20));
    await settle(tester);
    expect(scrollable().position.pixels, 0);
  });

  testWidgets(
      'bulk download confirms with the exact photo count (galleries included) and a summary; '
      'Cancel downloads nothing', (tester) async {
    final now = DateTime.now();
    await pump(tester, [
      post(2, now, 'beach gallery', mediaIds: [11, 12, 13]),
      post(1, now.subtract(const Duration(days: 40)), 'old single', mediaIds: [9]),
    ]);

    // No filter → no download button in the search bar.
    expect(find.byIcon(Icons.download_rounded), findsNothing);

    // Apply the Today preset (scoped to the sheet - the feed shows a "Today" divider too).
    await tester.tap(find.byIcon(Icons.filter_list));
    await settle(tester);
    await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.text('Today')));
    await tester.pump();
    await tester.tap(find.text('Show results'));
    await settle(tester);

    // The compact download button appears left of the filter icon; tap it.
    await tester.tap(find.byIcon(Icons.download_rounded));
    await settle(tester);

    // Only today's gallery matches: all 3 of its photos are counted, the old post's photo
    // isn't, and the summary reflects the active filter.
    expect(find.text('Download 3 photos?'), findsOneWidget);
    expect(find.text('Save 3 photos from today to your device.'), findsOneWidget);

    // Cancel: dialog closes, nothing downloads, and the button is idle again.
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(find.text('Download 3 photos?'), findsNothing);
    expect(find.byIcon(Icons.download_rounded), findsOneWidget);
  });

  testWidgets('active filter chips are opaque, so they stay legible over scrolling photos',
      (tester) async {
    final now = DateTime.now();
    await pump(tester, [post(1, now, 'a post')]);

    await tester.tap(find.byIcon(Icons.filter_list));
    await settle(tester);
    await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.text('Today')));
    await tester.pump();
    await tester.tap(find.text('Show results'));
    await settle(tester);

    // The only close icon on the filtered feed is the chip's remove affordance.
    expect(find.byIcon(Icons.close), findsOneWidget);
    final box = tester.widget<Container>(
      find.ancestor(of: find.byIcon(Icons.close), matching: find.byType(Container)).first,
    );
    final fill = (box.decoration! as BoxDecoration).color!;
    // A translucent tint disappears the moment a photo scrolls underneath it.
    expect(fill.a, 1.0, reason: 'filter chip fill must be fully opaque');
  });
}
