import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/widgets/feed_autoplay.dart';
import 'package:checkin/widgets/feed_clip.dart';
import 'package:checkin/widgets/media_frame.dart';
import 'package:checkin/widgets/post_image_carousel.dart';

import 'support/fake_video_platform.dart';

/// Feed autoplay. The rule the whole design hangs on is that exactly one clip in the feed
/// holds a player: Android's decoder pool is small and this feed has a history of paying
/// for per-item state. So the manager's decisions are asserted directly, and the tiles are
/// asserted against a stand-in platform player - one picture on screen, posters everywhere
/// else, and nothing left running once the feed is not what the user is looking at.
void main() {
  group('the manager', () {
    FeedAutoplayController manager() {
      final c = FeedAutoplayController();
      addTearDown(c.dispose);
      return c;
    }

    testWidgets('the most visible clip takes the slot, and it is the only one', (tester) async {
      final autoplay = manager();
      final first = Object();
      final second = Object();

      autoplay.report(first, 0.95);
      autoplay.report(second, 0.80); // also well past the threshold
      await tester.pump(const Duration(milliseconds: 250));

      expect(autoplay.activeSlot, first);
      expect(autoplay.isActive(first), isTrue);
      // The invariant: "visible enough" is not a licence to play. Hand the slot to every
      // clip over the threshold and this is the line that fails.
      expect(autoplay.isActive(second), isFalse);
    });

    testWidgets('a clip only half on screen is not enough to start one', (tester) async {
      final autoplay = manager();
      final slot = Object();

      autoplay.report(slot, 0.5);
      await tester.pump(const Duration(milliseconds: 250));

      expect(autoplay.activeSlot, isNull);
    });

    testWidgets('nothing starts until the scroll settles', (tester) async {
      final autoplay = manager();
      final slot = Object();

      autoplay.report(slot, 0.9);
      await tester.pump(const Duration(milliseconds: 100));
      expect(autoplay.activeSlot, isNull); // still moving

      await tester.pump(const Duration(milliseconds: 150));
      expect(autoplay.activeSlot, slot);
    });

    testWidgets('a clip scrolled straight past never gets a player', (tester) async {
      final autoplay = manager();
      final passed = Object();
      final landed = Object();
      final slots = <Object?>[];
      autoplay.addListener(() => slots.add(autoplay.activeSlot));

      autoplay.report(passed, 0.9);
      await tester.pump(const Duration(milliseconds: 100));
      autoplay.report(passed, 0.05);
      autoplay.report(landed, 0.9);
      await tester.pump(const Duration(milliseconds: 250));

      // One decision, not three: the clip that was mid-flight was never activated and so
      // never cost a controller.
      expect(slots, [landed]);
    });

    testWidgets('a clip keeps the slot while a newcomer is more visible', (tester) async {
      final autoplay = manager();
      final playing = Object();
      final newcomer = Object();

      autoplay.report(playing, 0.9);
      await tester.pump(const Duration(milliseconds: 250));

      autoplay.report(playing, 0.5); // still mostly there
      autoplay.report(newcomer, 1.0);
      await tester.pump(const Duration(milliseconds: 250));

      expect(autoplay.activeSlot, playing);
      expect(autoplay.isActive(newcomer), isFalse);
    });

    testWidgets('the slot moves on once the playing clip is mostly gone', (tester) async {
      final autoplay = manager();
      final leaving = Object();
      final arriving = Object();

      autoplay.report(leaving, 0.9);
      await tester.pump(const Duration(milliseconds: 250));

      autoplay.report(leaving, 0.2);
      autoplay.report(arriving, 0.9);
      await tester.pump(const Duration(milliseconds: 250));

      expect(autoplay.activeSlot, arriving);
      expect(autoplay.isActive(leaving), isFalse);
    });

    testWidgets('a tile that goes away frees the slot', (tester) async {
      final autoplay = manager();
      final slot = Object();

      autoplay.report(slot, 0.9);
      await tester.pump(const Duration(milliseconds: 250));
      expect(autoplay.activeSlot, slot);

      autoplay.forget(slot);
      await tester.pump(const Duration(milliseconds: 250));
      expect(autoplay.activeSlot, isNull);
    });

    testWidgets('leaving the feed stops playback, coming back resumes it', (tester) async {
      final autoplay = manager();
      final slot = Object();

      autoplay.report(slot, 0.9);
      await tester.pump(const Duration(milliseconds: 250));
      expect(autoplay.activeSlot, slot);

      autoplay.setEnabled(false);
      await tester.pump(const Duration(milliseconds: 250));
      expect(autoplay.activeSlot, isNull);

      autoplay.setEnabled(true);
      await tester.pump(const Duration(milliseconds: 250));
      expect(autoplay.activeSlot, slot);
    });
  });

  group('the tiles', () {
    const account = ServerAccount(
      id: 'alpha.invalid',
      baseUrl: 'https://alpha.invalid',
      serverName: 'Alpha',
      token: 't1',
    );
    const first = PostMedia(
      id: 8,
      mime: 'video/mp4',
      width: 1080,
      height: 1920,
      durationMs: 6000,
      hasPoster: true,
    );
    const second = PostMedia(
      id: 9,
      mime: 'video/mp4',
      width: 1080,
      height: 1920,
      durationMs: 4000,
      hasPoster: true,
    );

    late FakeVideoPlatform platform;
    late List<VideoPlayerController> built;

    setUp(() {
      platform = FakeVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      built = [];
      SharedPreferences.setMockInitialValues({});
    });

    // Two clips in a scrolling list, sized so the first fills the 600pt test viewport and
    // only the head of the second peeks in under it. Real visibility drives these, the same
    // way scrolling the feed does.
    Widget host({bool enabled = true}) => ProviderScope(
          overrides: [
            multiSessionProvider.overrideWith(
              () => MultiSessionController.seeded(
                const MultiSession(groups: [account], restored: true),
              ),
            ),
            feedVideoFactoryProvider.overrideWithValue((url, headers) {
              final controller = VideoPlayerController.networkUrl(url, httpHeaders: headers);
              built.add(controller);
              return controller;
            }),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: FeedAutoplayScope(
                enabled: enabled,
                child: ListView(
                  children: const [
                    SizedBox(
                      height: 500,
                      child: MediaFrame(media: first, groupId: 'alpha.invalid'),
                    ),
                    SizedBox(
                      height: 500,
                      child: MediaFrame(media: second, groupId: 'alpha.invalid'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

    // Visibility is batched and the manager waits for the scroll to settle, so several
    // frames have to pass before anything is decided.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
    }

    // Tearing a player down runs through the platform and finishes off the test's fake
    // clock, so real async has to be let through before asking whether the decoder came
    // back.
    Future<void> drain(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }

    testWidgets('only the clip in view hosts a player; the rest stay posters', (tester) async {
      await tester.pumpWidget(host());
      await settle(tester);

      expect(find.byType(VideoPlayer), findsOneWidget);
      expect(
        find.descendant(of: find.byType(FeedClip).first, matching: find.byType(VideoPlayer)),
        findsOneWidget,
      );
      // The clip barely peeking in below it never asked for a player at all.
      expect(built.length, 1);
      // ...and still shows its poster with a play badge, not a black hole.
      expect(
        find.descendant(
          of: find.byType(FeedClip).last,
          matching: find.byIcon(Icons.play_arrow_rounded),
        ),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('the feed plays with sound and loops, and says so', (tester) async {
      await tester.pumpWidget(host());
      await settle(tester);

      final controller = built.single;
      expect(controller.value.isPlaying, isTrue);
      // Reels, not the muted Instagram feed: the silent switch is what silences this, and
      // that is the audio session's job, not a hardcoded zero here.
      expect(controller.value.volume, 1);
      expect(controller.value.isLooping, isTrue);
      expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
      // The play badge gives way to the picture rather than sitting on top of it.
      expect(
        find.descendant(
          of: find.byType(FeedClip).first,
          matching: find.byIcon(Icons.play_arrow_rounded),
        ),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('a device that muted clips before starts this one muted', (tester) async {
      SharedPreferences.setMockInitialValues({'feed_autoplay_muted': true});

      await tester.pumpWidget(host());
      await settle(tester);

      expect(built.single.value.volume, 0);
      expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('the badge mutes the clip and remembers it for the next one', (tester) async {
      await tester.pumpWidget(host());
      await settle(tester);
      expect(built.single.value.volume, 1);

      await tester.tap(find.byIcon(Icons.volume_up_rounded));
      await settle(tester);

      expect(built.single.value.volume, 0);
      expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('feed_autoplay_muted'), isTrue);

      // The next clip along starts from the same choice rather than blaring again.
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await settle(tester);
      expect(built.last.value.volume, 0);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    // The badge lives inside the carousel's tap target, which is what opens the viewer. A
    // mute that also opened full screen would be worse than no mute button at all, so the
    // two are asserted together, assembled the way the feed card assembles them.
    testWidgets('the mute badge takes its own tap, not the card\'s', (tester) async {
      const wide = PostMedia(
        id: 10,
        mime: 'video/mp4',
        width: 1920,
        height: 1080,
        durationMs: 5000,
        hasPoster: true,
      );
      final opened = <int>[];

      await tester.pumpWidget(ProviderScope(
        overrides: [
          multiSessionProvider.overrideWith(
            () => MultiSessionController.seeded(
              const MultiSession(groups: [account], restored: true),
            ),
          ),
          feedVideoFactoryProvider.overrideWithValue((url, headers) {
            final controller = VideoPlayerController.networkUrl(url, httpHeaders: headers);
            built.add(controller);
            return controller;
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: FeedAutoplayScope(
              enabled: true,
              child: PostImageCarousel(
                media: const [wide],
                groupId: 'alpha.invalid',
                onImageTap: opened.add,
              ),
            ),
          ),
        ),
      ));
      await settle(tester);
      expect(built.single.value.volume, 1);

      await tester.tap(find.byIcon(Icons.volume_up_rounded));
      await settle(tester);

      expect(built.single.value.volume, 0);
      expect(opened, isEmpty);

      // ...and the rest of the clip still opens it.
      await tester.tapAt(tester.getCenter(find.byType(FeedClip)));
      await settle(tester);
      expect(opened, [10]);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('the playing clip offers where it has got to, and only it', (tester) async {
      // What a controller polls itself up to, so the tile has a real position to offer
      // rather than the zero a freshly-created player reports.
      platform.position = const Duration(seconds: 2);
      await tester.pumpWidget(host());
      await settle(tester);

      final context = tester.element(find.byType(FeedClip).first);
      expect(
        FeedAutoplayScope.continuation(context, mediaId: 8, groupId: 'alpha.invalid'),
        {8: const Duration(seconds: 2)},
      );
      // The clip below is a poster, and the same clip under another group is another tile:
      // neither has a position to hand over.
      expect(
        FeedAutoplayScope.continuation(context, mediaId: 9, groupId: 'alpha.invalid'),
        isEmpty,
      );
      expect(
        FeedAutoplayScope.continuation(context, mediaId: 8, groupId: 'beta.invalid'),
        isEmpty,
      );

      // Scrolling on hands the player over, and the offer with it - a stale position would
      // open the viewer partway into a clip nobody was watching.
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await settle(tester);
      final after = tester.element(find.byType(FeedClip).last);
      expect(FeedAutoplayScope.continuation(after, mediaId: 8, groupId: 'alpha.invalid'), isEmpty);
      expect(
        FeedAutoplayScope.continuation(after, mediaId: 9, groupId: 'alpha.invalid'),
        {9: const Duration(seconds: 2)},
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('scrolling hands the one player on to the next clip', (tester) async {
      await tester.pumpWidget(host());
      await settle(tester);
      expect(find.byType(VideoPlayer), findsOneWidget);

      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await settle(tester);

      // Still exactly one player, now the second clip's, and the first one's decoder was
      // handed back rather than left running off screen.
      expect(find.byType(VideoPlayer), findsOneWidget);
      expect(
        find.descendant(of: find.byType(FeedClip).last, matching: find.byType(VideoPlayer)),
        findsOneWidget,
      );
      expect(built.length, 2);
      await drain(tester);
      expect(platform.disposed.length, 1);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('a route opened over the feed releases the player', (tester) async {
      await tester.pumpWidget(host());
      await settle(tester);
      expect(find.byType(VideoPlayer), findsOneWidget);

      // Tapping a clip opens the full-screen viewer, which plays its own copy with sound.
      // The feed's copy must be gone by then, not decoding away behind it.
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => const SizedBox())));
      await settle(tester);

      expect(find.byType(VideoPlayer), findsNothing);
      await drain(tester);
      expect(platform.disposed.length, 1);

      // Closing the viewer gives the feed its player back - the position is deliberately
      // not carried the other way: a feed clip looping from the top is normal.
      navigator.pop();
      await settle(tester);
      expect(find.byType(VideoPlayer), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('backgrounding the app stops the clip', (tester) async {
      await tester.pumpWidget(host());
      await settle(tester);
      expect(built.single.value.isPlaying, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(built.single.value.isPlaying, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(built.single.value.isPlaying, isTrue);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('leaving the feed tears the player down', (tester) async {
      await tester.pumpWidget(host());
      await settle(tester);
      expect(find.byType(VideoPlayer), findsOneWidget);

      await tester.pumpWidget(host(enabled: false));
      await settle(tester);

      expect(find.byType(VideoPlayer), findsNothing);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNWidgets(2));
      await drain(tester);
      expect(platform.disposed.length, 1);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('a clip that will not play keeps its poster, quietly', (tester) async {
      platform.refuse.add('/api/media/8');
      await tester.pumpWidget(host());
      await settle(tester);

      expect(find.byType(VideoPlayer), findsNothing);
      // Both tiles look exactly as they did before autoplay existed - no error card.
      expect(find.byIcon(Icons.play_arrow_rounded), findsNWidgets(2));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('outside a feed a clip is a poster and nothing else', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            multiSessionProvider.overrideWith(
              () => MultiSessionController.seeded(
                const MultiSession(groups: [account], restored: true),
              ),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                height: 200,
                child: MediaFrame(media: first, groupId: 'alpha.invalid'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(FeedClip), findsNothing);
      expect(find.byType(VideoPlayer), findsNothing);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });
  });
}
