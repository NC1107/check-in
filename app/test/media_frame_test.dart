import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/widgets/auth_image.dart';
import 'package:checkin/widgets/photo_viewer.dart';
import 'package:checkin/widgets/post_image_carousel.dart';

/// How the feed and the viewer render an attachment now that they know what it is. Before
/// typed media both pointed an image widget at every media id, so a clip rendered as a
/// broken-image icon. Nothing here resolves a real image (flutter_test fakes every request
/// to a 400), which is the point: what is asserted is what each branch *asks* for.
void main() {
  const account = ServerAccount(
    id: 'alpha.invalid',
    baseUrl: 'https://alpha.invalid',
    serverName: 'Alpha',
    token: 't1',
  );

  const photo = PostMedia(id: 7, mime: 'image/jpeg', width: 1600, height: 1200);
  const clip = PostMedia(
    id: 8,
    mime: 'video/mp4',
    width: 1080,
    height: 1920,
    durationMs: 9500,
    hasPoster: true,
  );

  Widget host(Widget child) => ProviderScope(
        overrides: [
          multiSessionProvider.overrideWith(
            () => MultiSessionController.seeded(
              const MultiSession(groups: [account], restored: true),
            ),
          ),
        ],
        child: MaterialApp(home: Scaffold(body: child)),
      );

  group('carousel', () {
    testWidgets('a photo is still just an image', (tester) async {
      await tester
          .pumpWidget(host(const PostImageCarousel(media: [photo], groupId: 'alpha.invalid')));
      await tester.pump();

      expect(find.byType(AuthImage), findsOneWidget);
      expect(tester.widget<AuthImage>(find.byType(AuthImage)).variant, isNull);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
    });

    testWidgets('a clip shows its poster, a play badge and its length', (tester) async {
      await tester
          .pumpWidget(host(const PostImageCarousel(media: [clip], groupId: 'alpha.invalid')));
      await tester.pump();

      // The poster, not the clip's own bytes - those would never decode as an image.
      final image = tester.widget<AuthImage>(find.byType(AuthImage));
      expect(image.mediaId, 8);
      expect(image.variant, 'poster');
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.text('0:10'), findsOneWidget);
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
    });

    testWidgets('a clip with no poster is not sent looking for one', (tester) async {
      const posterless = PostMedia(id: 8, mime: 'video/mp4', durationMs: 4000);
      await tester
          .pumpWidget(host(const PostImageCarousel(media: [posterless], groupId: 'alpha.invalid')));
      await tester.pump();

      // The server answers ?variant=poster with the clip itself when it has none, so asking
      // anyway would render a broken-image icon where the check-in should be.
      expect(find.byType(AuthImage), findsNothing);
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.text('0:04'), findsOneWidget);
    });

    testWidgets('the stored dimensions size the box before anything has decoded', (tester) async {
      await tester
          .pumpWidget(host(const PostImageCarousel(media: [clip], groupId: 'alpha.invalid')));
      await tester.pump();

      // 1080x1920 is taller than the 4:5 clamp, so the box sits at the clamp - not at the
      // 4:3 default it would use if the dimensions were ignored until decode.
      expect(tester.widget<AspectRatio>(find.byType(AspectRatio).first).aspectRatio,
          closeTo(4 / 5, 0.001));
    });

    testWidgets('a mixed post pages between a photo and a clip', (tester) async {
      await tester.pumpWidget(
          host(const PostImageCarousel(media: [photo, clip], groupId: 'alpha.invalid')));
      await tester.pump();

      expect(find.text('1/2'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);

      await tester.fling(find.byType(PageView), const Offset(-400, 0), 800);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.text('2/2'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.text('0:10'), findsOneWidget);
    });
  });

  testWidgets('the full-screen viewer shows a clip as its poster, never as a broken image',
      (tester) async {
    await tester.pumpWidget(host(const PhotoViewerScreen(media: [clip], groupId: 'alpha.invalid')));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(tester.widget<AuthImage>(find.byType(AuthImage)).variant, 'poster');
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
  });

  testWidgets('a poster and its clip cache under different keys', (tester) async {
    // The poster and the clip share one media id, so a cache key built from the id alone
    // serves whichever arrived first to both: the feed's poster would fill the viewer, or
    // the viewer's photo would land in the feed. This fails the moment the variant stops
    // reaching the key.
    await tester.pumpWidget(host(const Column(children: [
      SizedBox(height: 10, child: AuthImage(mediaId: 8, groupId: 'alpha.invalid')),
      SizedBox(
        height: 10,
        child: AuthImage(mediaId: 8, groupId: 'alpha.invalid', variant: 'poster'),
      ),
    ])));
    await tester.pump();

    final keys = tester
        .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .map((w) => w.cacheKey)
        .toList();
    expect(keys.length, 2);
    expect(keys.first, isNot(keys.last));
    expect(keys.last, endsWith('-poster'));

    // And the two must not be fetched from the same URL either.
    final urls = tester
        .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .map((w) => w.imageUrl)
        .toList();
    expect(urls.first, isNot(urls.last));
    expect(urls.last, endsWith('?variant=poster'));
  });
}
