import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/widgets/media_frame.dart';
import 'package:checkin/widgets/photo_viewer.dart';
import 'package:checkin/widgets/post_image_carousel.dart';

/// Tapping a feed photo should fly it into the full-screen viewer instead of cross-fading a
/// fresh copy. That continuity comes from a [Hero] whose tag matches between the tapped feed
/// image and the viewer's initial page, so this pins the shared tag formula and asserts both
/// call sites use it - the source hero in the carousel and the destination hero in the viewer.
void main() {
  const account = ServerAccount(
    id: 'g',
    baseUrl: 'https://g.invalid',
    serverName: 'G',
    token: 't',
  );

  ProviderScope wrap(Widget child) {
    final controller =
        MultiSessionController.seeded(const MultiSession(groups: [account], restored: true));
    return ProviderScope(
      overrides: [multiSessionProvider.overrideWith(() => controller)],
      child: MaterialApp(home: Scaffold(body: child)),
    );
  }

  Finder heroWith(String tag) => find.byWidgetPredicate((w) => w is Hero && w.tag == tag);

  test('the tag is scoped by group id and media id so it cannot collide across groups', () {
    expect(photoHeroTag('g', 7), 'photo-g-7');
    expect(photoHeroTag('other', 7), isNot(photoHeroTag('g', 7)));
    expect(photoHeroTag(null, 7), 'photo-null-7');
  });

  testWidgets('a feed photo carries the shared hero tag', (tester) async {
    await tester.pumpWidget(wrap(const PostImageCarousel(
      media: [PostMedia(id: 7, mime: 'image/jpeg')],
      groupId: 'g',
    )));

    expect(heroWith(photoHeroTag('g', 7)), findsOneWidget);
  });

  testWidgets('a clip poster is not heroed', (tester) async {
    await tester.pumpWidget(wrap(const PostImageCarousel(
      media: [PostMedia(id: 7, mime: 'video/mp4', hasPoster: true)],
      groupId: 'g',
    )));

    expect(find.byType(Hero), findsNothing);
  });

  testWidgets('the viewer opens on a page carrying the same tag as the tapped feed photo',
      (tester) async {
    await tester.pumpWidget(wrap(Builder(builder: (context) {
      return PostImageCarousel(
        media: const [PostMedia(id: 7, mime: 'image/jpeg'), PostMedia(id: 8, mime: 'image/jpeg')],
        groupId: 'g',
        onImageTap: (mediaId) => PhotoViewerScreen.open(
          context,
          media: const [PostMedia(id: 7, mime: 'image/jpeg'), PostMedia(id: 8, mime: 'image/jpeg')],
          initialIndex: mediaId == 7 ? 0 : 1,
          groupId: 'g',
        ),
      );
    })));

    await tester.tap(find.byType(PostImageCarousel));
    await tester.pump(); // start the route + hero flight
    await tester.pump(const Duration(milliseconds: 300)); // and finish it

    expect(find.byType(PhotoViewerScreen), findsOneWidget);
    // The destination hero on the initial page matches the source tag: continuity holds.
    // (The feed route stays mounted under the transparent viewer, so the source hero with
    // the same tag is still in the tree too - scope the check to the viewer's subtree.)
    expect(
      find.descendant(of: find.byType(PhotoViewerScreen), matching: heroWith(photoHeroTag('g', 7))),
      findsOneWidget,
    );
  });
}
