import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/widgets/media_frame.dart';
import 'package:checkin/widgets/photo_viewer.dart';

import 'support/fake_video_platform.dart';

/// A multi-image check-in's full-screen viewer must let the viewer swipe between every
/// photo on the post, not just the one they tapped into - that was the reported bug. A
/// single-photo context (e.g. a profile picture) must keep working exactly as before, with
/// no page counter cluttering the one-photo case.
void main() {
  final account = ServerAccount(
    id: 'alpha.invalid',
    baseUrl: 'https://alpha.invalid',
    serverName: 'Alpha',
    token: 't1',
    user: User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: false),
  );

  // Ids in, image-typed entries out: exactly what the feed passes for a post from a server
  // that predates typed media.
  Future<void> pump(WidgetTester tester,
      {required List<int> mediaIds, int initialIndex = 0}) async {
    final controller =
        MultiSessionController.seeded(MultiSession(groups: [account], restored: true));
    await tester.pumpWidget(ProviderScope(
      overrides: [multiSessionProvider.overrideWith(() => controller)],
      child: MaterialApp(
        home: Builder(builder: (context) {
          return Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => PhotoViewerScreen.open(context,
                    media: PostMedia.images(mediaIds),
                    initialIndex: initialIndex,
                    groupId: 'alpha.invalid'),
                child: const Text('open'),
              ),
            ),
          );
        }),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump(); // let the route animation start
    await tester.pump(const Duration(milliseconds: 200)); // and finish
  }

  // A bounded pump loop rather than pumpAndSettle(): the photo's own image is a real
  // network image against an unresolvable .invalid host, whose placeholder spinner
  // animates indefinitely and never lets pumpAndSettle's "no frames scheduled" condition
  // become true, even once the page/drag animation itself has long since finished.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('a single photo shows no page counter', (tester) async {
    await pump(tester, mediaIds: [7]);
    expect(find.textContaining('/'), findsNothing);
  });

  testWidgets('multiple photos show a counter and open on the tapped one', (tester) async {
    await pump(tester, mediaIds: [7, 8, 9], initialIndex: 1);
    expect(find.text('2/3'), findsOneWidget);
  });

  testWidgets('swiping left pages to the next photo and updates the counter', (tester) async {
    await pump(tester, mediaIds: [7, 8, 9]);
    expect(find.text('1/3'), findsOneWidget);

    await tester.fling(find.byType(PageView), const Offset(-400, 0), 800);
    await settle(tester);

    expect(find.text('2/3'), findsOneWidget);
  });

  testWidgets('swiping down past the dismiss threshold closes the viewer', (tester) async {
    await pump(tester, mediaIds: [7, 8]);
    expect(find.byType(PhotoViewerScreen), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(0, 400));
    await settle(tester);

    expect(find.byType(PhotoViewerScreen), findsNothing);
  });

  // The viewer branches on the media type: a photo is pinch-zoomable, a clip plays. A real
  // controller cannot initialise in flutter_test (there is no platform player), so the clip
  // page keeps showing its poster - which is exactly what is asserted: the branch, not the
  // playback.
  Future<void> pumpTyped(WidgetTester tester, PostMedia media) async {
    final controller = MultiSessionController.seeded(
      MultiSession(groups: [account], restored: true),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [multiSessionProvider.overrideWith(() => controller)],
      child: MaterialApp(
        home: PhotoViewerScreen(media: [media], groupId: 'alpha.invalid'),
      ),
    ));
    await settle(tester);
  }

  testWidgets('a photo page is a pinch-to-zoom InteractiveViewer', (tester) async {
    await pumpTyped(tester, const PostMedia(id: 7, mime: 'image/jpeg', width: 1600, height: 1200));
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('a clip page is the video host over its poster, not an InteractiveViewer',
      (tester) async {
    await pumpTyped(
      tester,
      const PostMedia(id: 8, mime: 'video/mp4', width: 1080, height: 1920, durationMs: 8000),
    );
    // Not the photo branch...
    expect(find.byType(InteractiveViewer), findsNothing);
    // ...and the poster (a MediaFrame) is shown underneath until a frame decodes, which it
    // never will here - so it stays put rather than flashing black.
    expect(find.byType(MediaFrame), findsOneWidget);
  });

  // Tapping an autoplaying feed clip must not send it back to its first frame. The feed
  // hands over the position it had reached and the viewer has to be playing from there, so
  // these run against a stand-in platform player that records what it was told to do.
  group('a clip opened from the feed', () {
    const clip = PostMedia(id: 8, mime: 'video/mp4', width: 1080, height: 1920, durationMs: 8000);

    late FakeVideoPlatform platform;
    late VideoPlayerPlatform original;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      original = VideoPlayerPlatform.instance;
      platform = FakeVideoPlatform();
      VideoPlayerPlatform.instance = platform;
    });

    // The other tests in this file want the plugin-less host, where a clip stays a poster.
    tearDown(() => VideoPlayerPlatform.instance = original);

    Future<void> open(WidgetTester tester, {Map<int, Duration> at = const {}}) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          multiSessionProvider.overrideWith(
            () => MultiSessionController.seeded(
              MultiSession(groups: [account], restored: true),
            ),
          ),
        ],
        child: MaterialApp(
          home: PhotoViewerScreen(
            media: const [clip],
            groupId: 'alpha.invalid',
            initialClipPositions: at,
          ),
        ),
      ));
      await settle(tester);
    }

    testWidgets('continues from where the feed had got to, before it plays', (tester) async {
      await open(tester, at: {8: const Duration(seconds: 3)});

      final seeked = platform.calls.indexOf('seek:${const Duration(seconds: 3)}');
      final played = platform.calls.indexOf('play');
      expect(seeked, isNonNegative, reason: 'the threaded position was never applied');
      // Playing first would show the opening frames the viewer has already watched - the
      // restart this whole hand-off exists to remove.
      expect(seeked, lessThan(played));

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('opened cold (no feed position) it starts at the beginning', (tester) async {
      await open(tester);

      expect(platform.calls.where((c) => c.startsWith('seek')), isEmpty);
      expect(platform.calls, contains('play'));

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  });
}
