import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/post_card.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/widgets/feed_autoplay.dart';
import 'package:checkin/widgets/feed_clip.dart';
import 'package:checkin/widgets/photo_viewer.dart';

import 'support/fake_video_platform.dart';

/// Tapping an autoplaying feed clip into full screen.
///
/// The clip is already running when it is tapped, so nothing about it should have to be
/// built again: a second controller for the same clip means a network init and a seek, and
/// what the user gets for it is a play glyph and a stall exactly where they expected the
/// clip to carry on. So the feed lends the running player to the viewer and takes it back
/// on close, and these run the whole trip through the real card, the real scope and the
/// real viewer against a stand-in platform player that records every create, seek and
/// dispose.
void main() {
  final account = ServerAccount(
    id: 'alpha.invalid',
    baseUrl: 'https://alpha.invalid',
    serverName: 'Alpha',
    token: 't1',
    user: User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: false),
  );

  // Landscape, so the card's media box (and with it the whole card) fits the test viewport
  // and the tile is visible enough to be handed the autoplay slot.
  const clip = PostMedia(
    id: 8,
    mime: 'video/mp4',
    width: 1920,
    height: 1080,
    durationMs: 6000,
    hasPoster: true,
  );

  Post post({List<PostMedia> media = const [clip]}) => Post(
        id: 5,
        authorId: 2,
        authorName: 'Ada',
        kind: 'video',
        body: '',
        createdAt: DateTime(2026, 7, 1),
        likeCount: 0,
        commentCount: 0,
        likedByViewer: false,
        groupId: 'alpha.invalid',
        media: media,
      );

  late FakeVideoPlatform platform;
  late List<VideoPlayerController> built;

  setUp(() {
    platform = FakeVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    built = [];
    SharedPreferences.setMockInitialValues({});
  });

  /// The feed, as the app assembles it: an autoplay scope over real post cards.
  Widget host({required List<Post> posts}) => ProviderScope(
        overrides: [
          multiSessionProvider.overrideWith(
            () => MultiSessionController.seeded(
              MultiSession(groups: [account], restored: true),
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
              child: ListView(children: [for (final p in posts) PostCard(post: p)]),
            ),
          ),
        ),
      );

  // Visibility is batched, the manager waits for the scroll to settle, and the viewer's
  // route fades in. pumpAndSettle is no use here: the card's avatar is a real network image
  // against an unresolvable host, whose placeholder animates forever.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  // Disposing a player runs through the platform, off the test's fake clock, so real async
  // has to be let through before asking whether a decoder came back.
  Future<void> drain(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }

  FeedAutoplayController scopeOf(WidgetTester tester) =>
      FeedAutoplayScope.maybeOf(tester.element(find.byType(ListView)))!;

  Finder viewerVideo() => find.descendant(
        of: find.byType(PhotoViewerScreen),
        matching: find.byType(VideoPlayer),
      );

  Finder feedVideo() => find.descendant(
        of: find.byType(FeedClip),
        matching: find.byType(VideoPlayer),
      );

  /// Starts the feed clip playing, then taps it open. Tapped by position because the mute
  /// badge in the corner takes its own taps.
  Future<void> openFromFeed(WidgetTester tester) async {
    await tester.pumpWidget(host(posts: [post()]));
    await settle(tester);
    expect(built.length, 1, reason: 'the feed clip never started, so there is nothing to lend');
    expect(built.single.value.isPlaying, isTrue);

    await tester.tapAt(tester.getCenter(find.byType(FeedClip)));
    await settle(tester);
  }

  testWidgets('full screen adopts the running feed player instead of building another',
      (tester) async {
    await openFromFeed(tester);

    expect(find.byType(PhotoViewerScreen), findsOneWidget);
    // The seam: the viewer is drawing the very controller the feed had running.
    expect(identical(tester.widget<VideoPlayer>(viewerVideo()).controller, built.single), isTrue);
    // ...which is the whole win. A second player would show up as another create and the
    // seek that follows it, and that pair is what the user sees as a pause.
    expect(platform.created.length, 1);
    expect(platform.calls.where((c) => c.startsWith('seek')), isEmpty);
    // And the picture is up on the first frame: no poster underneath, no paused glyph over
    // it, which was the reported flash.
    expect(
      find.descendant(
        of: find.byType(PhotoViewerScreen),
        matching: find.byIcon(Icons.play_arrow_rounded),
      ),
      findsNothing,
    );
    expect(built.single.value.isPlaying, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('the tile it came from waits on its poster, and its player is not torn down',
      (tester) async {
    await openFromFeed(tester);

    // The feed still holds the tile, but not the picture: the poster it was drawn over is
    // exactly what stays behind, badge and all.
    expect(feedVideo(), findsNothing);
    expect(
      find.descendant(of: find.byType(FeedClip), matching: find.byIcon(Icons.play_arrow_rounded)),
      findsOneWidget,
    );
    // Opening a route over the feed releases the autoplay slot, and releasing a slot
    // normally disposes that tile's player. The lent one has to survive it - it is the
    // thing on screen.
    await drain(tester);
    expect(platform.disposed, isEmpty);
    // ...and the tile must not answer the loss of its player by building a replacement.
    expect(built.length, 1);
    expect(platform.created.length, 1);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('closing full screen gives the same player back to the same tile', (tester) async {
    await openFromFeed(tester);

    Navigator.of(tester.element(find.byType(PhotoViewerScreen))).pop();
    await settle(tester);

    expect(find.byType(PhotoViewerScreen), findsNothing);
    expect(feedVideo(), findsOneWidget);
    expect(identical(tester.widget<VideoPlayer>(feedVideo()).controller, built.single), isTrue);
    expect(built.single.value.isPlaying, isTrue);
    // Nothing was rebuilt on the way back either, so closing is as gapless as opening.
    expect(platform.created.length, 1);
    await drain(tester);
    expect(platform.disposed, isEmpty);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('exactly one player exists at every point of the trip', (tester) async {
    await tester.pumpWidget(host(posts: [post()]));
    await settle(tester);
    expect(find.byType(VideoPlayer), findsOneWidget);
    expect(feedVideo(), findsOneWidget);

    await tester.tapAt(tester.getCenter(find.byType(FeedClip)));
    await settle(tester);
    // Not two: the feed's tile and the viewer's page cannot both be drawing a player, or
    // Android is holding two decoders for one clip.
    expect(find.byType(VideoPlayer), findsOneWidget);
    expect(viewerVideo(), findsOneWidget);
    expect(scopeOf(tester).isLending, isTrue, reason: 'the feed lost track of its one player');

    Navigator.of(tester.element(find.byType(PhotoViewerScreen))).pop();
    await settle(tester);
    expect(find.byType(VideoPlayer), findsOneWidget);
    expect(feedVideo(), findsOneWidget);
    expect(scopeOf(tester).isLending, isFalse);

    expect(built.length, 1);
    expect(platform.created.length, 1);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('a player with no tile left to go back to is disposed, exactly once', (tester) async {
    await openFromFeed(tester);

    // The card is gone from the feed while full screen is open - a refresh, a filter, a
    // list that recycled the tile. The route stack is untouched, so the viewer still has
    // the player.
    await tester.pumpWidget(host(posts: []));
    await settle(tester);
    expect(find.byType(FeedClip), findsNothing);
    expect(find.byType(PhotoViewerScreen), findsOneWidget);
    // Losing the tile must not lose the loan with it: the record is what the player comes
    // back to, and the only thing that can decide to dispose it.
    expect(scopeOf(tester).isLending, isTrue);
    await drain(tester);
    expect(platform.disposed, isEmpty, reason: 'the viewer is still drawing it');

    Navigator.of(tester.element(find.byType(PhotoViewerScreen))).pop();
    await settle(tester);
    await drain(tester);

    // Nobody to hand it to, so the feed hands the decoder back itself rather than leaking
    // it - and only the one it was lent.
    expect(platform.disposed.length, 1);
    expect(platform.created.length, 1);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('paging past the lent clip and back finds the same player, paused meanwhile',
      (tester) async {
    const other = PostMedia(
      id: 9,
      mime: 'video/mp4',
      width: 1920,
      height: 1080,
      durationMs: 4000,
      hasPoster: true,
    );
    await tester.pumpWidget(host(posts: [
      post(media: const [clip, other])
    ]));
    await settle(tester);
    expect(built.length, 1);

    await tester.tapAt(tester.getCenter(find.byType(FeedClip)));
    await settle(tester);
    final lent = built.single;
    expect(identical(tester.widget<VideoPlayer>(viewerVideo()).controller, lent), isTrue);

    final pager = find.descendant(
      of: find.byType(PhotoViewerScreen),
      matching: find.byType(PageView),
    );
    await tester.fling(pager, const Offset(-600, 0), 1200);
    await settle(tester);

    // The second clip is the viewer's own to build and to bin. The lent one is only
    // stopped: handing it home now would have the feed playing it behind the viewer, and
    // swiping back would then cost a whole new player.
    expect(platform.created.length, 2);
    expect(lent.value.isPlaying, isFalse);
    await drain(tester);
    expect(platform.disposed, isEmpty);

    await tester.fling(pager, const Offset(600, 0), 1200);
    await settle(tester);

    expect(identical(tester.widget<VideoPlayer>(viewerVideo()).controller, lent), isTrue);
    expect(lent.value.isPlaying, isTrue);
    expect(platform.created.length, 2, reason: 'the lent player was rebuilt instead of resumed');
    await drain(tester);
    expect(platform.disposed.length, 1, reason: "only the viewer's own player is disposed");

    Navigator.of(tester.element(find.byType(PhotoViewerScreen))).pop();
    await settle(tester);
    await drain(tester);
    expect(identical(tester.widget<VideoPlayer>(feedVideo()).controller, lent), isTrue);
    expect(platform.disposed.length, 1);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('muting in full screen is still muted when the clip lands back in the feed',
      (tester) async {
    await openFromFeed(tester);
    expect(built.single.value.volume, 1);

    await tester.tap(find.descendant(
      of: find.byType(PhotoViewerScreen),
      matching: find.byIcon(Icons.volume_up_rounded),
    ));
    await settle(tester);
    expect(built.single.value.volume, 0);

    Navigator.of(tester.element(find.byType(PhotoViewerScreen))).pop();
    await settle(tester);

    expect(built.single.value.volume, 0);
    expect(
      find.descendant(of: find.byType(FeedClip), matching: find.byIcon(Icons.volume_off_rounded)),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('a clip with nothing to adopt still builds its own player', (tester) async {
    // A post detail or profile has no autoplay scope over it, so there is no running player
    // to lend and the viewer must go on doing what it always did.
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(
          () => MultiSessionController.seeded(
            MultiSession(groups: [account], restored: true),
          ),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(body: ListView(children: [PostCard(post: post())])),
      ),
    ));
    await settle(tester);
    expect(find.byType(FeedClip), findsNothing);
    expect(platform.created, isEmpty);

    await tester.tapAt(tester.getCenter(find.byType(PostCard)));
    await settle(tester);

    expect(find.byType(PhotoViewerScreen), findsOneWidget);
    expect(platform.created.length, 1);
    expect(viewerVideo(), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
