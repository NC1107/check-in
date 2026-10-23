import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/widgets/post_image_carousel.dart';

/// A single-image post must size itself to the photo's own aspect ratio (clamped to
/// portrait no taller than 4:5, landscape no wider than 1.91:1) instead of getting stuck
/// cropped at the 4:3 default - that was the reported bug.
///
/// The old code detected the ratio with a second, separate CachedNetworkImageProvider
/// resolve of the same url, wired to a no-op onError: if that second fetch/decode ever
/// failed independently of the one actually displaying the photo (very plausible right
/// after a fresh upload, with nothing cached yet), the box silently and permanently stayed
/// at 4:3 forever while the photo itself displayed fine - cropped, since 16:9 doesn't fit a
/// 4:3 box. Confirmed live: a real PNG served over a local HTTP server came back reporting
/// exactly 4/3 (1.333...) instead of 16/9 (1.777...).
///
/// The fix reads the size off the same successful decode AuthImage already displays
/// (CachedNetworkImage's imageBuilder, which only ever fires for an image that is already
/// showing), so it can't fail independently - if the photo fails to load, AuthImage's own
/// error state shows instead of this ever being asked for a size.
///
/// A widget test can't exercise the real network fetch end to end: flutter_test's
/// TestWidgetsFlutterBinding fakes every HTTP request made from the widget tree's own async
/// work to a 400 (only code explicitly run inside tester.runAsync sees a real HttpClient),
/// so CachedNetworkImage can never actually succeed here - which is exactly why no test in
/// this repo asserts on a real decoded image. What's tested instead: the widget's sane
/// default before anything resolves, and - in isolation, via a hand-built PNG that needs no
/// network, disk cache, or dart:ui rasterizer at all - that resolving an already-successful
/// ImageProvider delivers its ImageInfo through exactly the resolve+listener technique
/// AuthImage now uses. (Picture.toImage() was tried first to build the test PNG, but hangs
/// under this engine's software rendering rather than completing - a rasterizer quirk of
/// this dev box, unrelated to the app code, so the PNG is built by hand instead.)
void main() {
  testWidgets('starts at the 4:3 default before anything has resolved', (tester) async {
    const account = ServerAccount(
      id: 'g',
      baseUrl: 'https://g.invalid',
      serverName: 'G',
      token: 't',
    );
    final controller =
        MultiSessionController.seeded(const MultiSession(groups: [account], restored: true));

    await tester.pumpWidget(ProviderScope(
      overrides: [multiSessionProvider.overrideWith(() => controller)],
      child: const MaterialApp(
        home: Scaffold(
          body: PostImageCarousel(
            media: [PostMedia(id: 1, mime: 'image/jpeg')],
            groupId: 'g',
          ),
        ),
      ),
    ));

    expect(tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio, closeTo(4 / 3, 0.001));
  });

  group('feed card aspect ratio', () {
    Future<void> pump(WidgetTester tester, List<PostMedia> media) async {
      const account = ServerAccount(
        id: 'g',
        baseUrl: 'https://g.invalid',
        serverName: 'G',
        token: 't',
      );
      final controller = MultiSessionController.seeded(
        const MultiSession(groups: [account], restored: true),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [multiSessionProvider.overrideWith(() => controller)],
          child: MaterialApp(
            home: Scaffold(
              body: PostImageCarousel(media: media, groupId: 'g'),
            ),
          ),
        ),
      );
    }

    double boxRatio(WidgetTester tester) {
      final size = tester.getSize(find.byType(AspectRatio).first);
      return size.width / size.height;
    }

    PostMedia sized(int w, int h, {int id = 1}) =>
        PostMedia(id: id, mime: 'image/jpeg', width: w, height: h);

    testWidgets(
      'stored dimensions size the box on the first frame and it never changes',
      (tester) async {
        await pump(tester, [sized(3, 4)]);
        final loading = tester.getSize(find.byType(AspectRatio).first);
        expect(loading.width / loading.height, closeTo(4 / 5, 0.001));

        // The load resolves (here to the broken-image state); the box must not move.
        await tester.pump(const Duration(seconds: 1));
        expect(tester.getSize(find.byType(AspectRatio).first), loading);
      },
    );

    testWidgets('a square photo stays square', (tester) async {
      await pump(tester, [sized(1000, 1000)]);
      expect(boxRatio(tester), closeTo(1, 0.001));
    });

    testWidgets('very tall photos clamp to 4:5', (tester) async {
      await pump(tester, [sized(1000, 4000)]);
      expect(boxRatio(tester), closeTo(4 / 5, 0.001));
    });

    testWidgets('very wide photos clamp to 1.91:1', (tester) async {
      await pump(tester, [sized(4000, 1000)]);
      expect(boxRatio(tester), closeTo(1.91, 0.001));
    });

    testWidgets(
      "a gallery takes the first photo's clamped ratio and keeps it across swipes",
      (tester) async {
        await pump(tester, [
          sized(1000, 4000, id: 1),
          sized(4000, 1000, id: 2),
        ]);
        final before = tester.getSize(find.byType(AspectRatio).first);
        expect(before.width / before.height, closeTo(4 / 5, 0.001));

        await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
        await tester.pump(const Duration(seconds: 1));
        expect(tester.getSize(find.byType(AspectRatio).first), before);
      },
    );

    group('decoded ratios for media the server sent no dimensions for', () {
      setUp(resetDecodedRatios);
      tearDown(() => PaintingBinding.instance.imageCache.clear());

      // Puts a decoded w x h image where AuthImage's provider will find it, so the widget
      // resolves it without any network.
      Future<void> seedDecoded(
        WidgetTester tester, {
        required String account,
        required int mediaId,
        required int w,
        required int h,
      }) async {
        final image = await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawRect(
            Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
            Paint()..color = const Color(0xFF3060C8),
          );
          return recorder.endRecording().toImage(w, h);
        });
        PaintingBinding.instance.imageCache.putIfAbsent(
          CachedNetworkImageProvider('https://x.invalid/$mediaId',
              cacheKey: 'media-$account-$mediaId'),
          () => OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image!))),
        );
      }

      Future<void> pumpIn(WidgetTester tester, Widget child, {List<String> groups = const ['g']}) {
        final accounts = [
          for (final id in groups)
            ServerAccount(id: id, baseUrl: 'https://$id.invalid', serverName: id, token: 't'),
        ];
        final controller = MultiSessionController.seeded(
          MultiSession(groups: accounts, restored: true),
        );
        return tester.pumpWidget(
          ProviderScope(
            overrides: [multiSessionProvider.overrideWith(() => controller)],
            child: MaterialApp(home: Scaffold(body: child)),
          ),
        );
      }

      double ratioOf(WidgetTester tester) {
        final size = tester.getSize(find.byType(AspectRatio).first);
        return size.width / size.height;
      }

      const bare = PostMedia(id: 7, mime: 'image/jpeg');

      testWidgets('a rebuilt card starts at the learned shape on its first frame', (tester) async {
        await seedDecoded(tester, account: 'g', mediaId: 7, w: 100, h: 100);
        const card = PostImageCarousel(media: [bare], groupId: 'g');

        await pumpIn(tester, card);
        expect(ratioOf(tester), closeTo(4 / 3, 0.001));
        await tester.pump();
        await tester.pump();
        expect(ratioOf(tester), closeTo(1, 0.001));

        await pumpIn(tester, const SizedBox());
        await pumpIn(tester, card);
        expect(ratioOf(tester), closeTo(1, 0.001));
      });

      testWidgets('another media id, or the same id in another group, does not inherit it', (
        tester,
      ) async {
        await seedDecoded(tester, account: 'g', mediaId: 7, w: 100, h: 100);
        await pumpIn(tester, const PostImageCarousel(media: [bare], groupId: 'g'));
        await tester.pump();
        await tester.pump();
        expect(ratioOf(tester), closeTo(1, 0.001));

        await pumpIn(tester, const SizedBox(), groups: ['g', 'h']);
        await pumpIn(
          tester,
          const PostImageCarousel(media: [PostMedia(id: 8, mime: 'image/jpeg')], groupId: 'g'),
          groups: ['g', 'h'],
        );
        expect(ratioOf(tester), closeTo(4 / 3, 0.001));

        await pumpIn(tester, const PostImageCarousel(media: [bare], groupId: 'h'),
            groups: ['g', 'h']);
        expect(ratioOf(tester), closeTo(4 / 3, 0.001));
      });

      testWidgets('server dimensions win over a conflicting decode', (tester) async {
        await seedDecoded(tester, account: 'g', mediaId: 7, w: 100, h: 100);
        await pumpIn(
          tester,
          const PostImageCarousel(
            media: [PostMedia(id: 7, mime: 'image/jpeg', width: 4, height: 5)],
            groupId: 'g',
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(ratioOf(tester), closeTo(4 / 5, 0.001));
      });

      testWidgets('a gallery whose first photo has no dimensions learns its height', (
        tester,
      ) async {
        await seedDecoded(tester, account: 'g', mediaId: 7, w: 100, h: 100);
        const gallery = PostImageCarousel(
          media: [bare, PostMedia(id: 9, mime: 'image/jpeg', width: 4000, height: 1000)],
          groupId: 'g',
        );
        await pumpIn(tester, gallery);
        await tester.pump();
        await tester.pump();
        expect(ratioOf(tester), closeTo(1, 0.001));

        await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
        await tester.pump(const Duration(seconds: 1));
        expect(ratioOf(tester), closeTo(1, 0.001));
      });
    });

    test('feedAspectFor falls back to 4:3 only when nothing is known', () {
      expect(
        feedAspectFor(const PostMedia(id: 99, mime: 'image/jpeg'), 'g'),
        closeTo(4 / 3, 0.001),
      );
    });
  });
  testWidgets('resolving an already-decoded image delivers its real intrinsic size via a listener',
      (tester) async {
    final bytes = _minimalPng(160, 90); // exactly 16:9

    // Exactly the technique AuthImage.imageBuilder now uses: resolve the provider that is
    // already being displayed, read the one ImageInfo it delivers, then detach.
    // The actual decode runs on a background isolate even for an in-memory source, so it
    // needs runAsync (a fake-clock pump alone never lets its completion callback fire).
    final delivered = await tester.runAsync(() async {
      final provider = MemoryImage(bytes);
      final stream = provider.resolve(ImageConfiguration.empty);
      final completer = Completer<ImageInfo>();
      late ImageStreamListener listener;
      listener = ImageStreamListener((info, _) {
        completer.complete(info);
        stream.removeListener(listener);
      }, onError: (err, st) => completer.completeError(err, st));
      stream.addListener(listener);
      return completer.future;
    });

    expect(delivered, isNotNull);
    final ratio = delivered!.image.width / delivered.image.height;
    expect(ratio, closeTo(16 / 9, 0.01));
  });
}

/// Builds a minimal valid solid-color PNG (8-bit RGB, no interlacing) entirely from raw
/// bytes - no dart:ui rendering/rasterizer involved, just the PNG file format itself.
Uint8List _minimalPng(int width, int height) {
  final out = BytesBuilder();
  out.add(const [137, 80, 78, 71, 13, 10, 26, 10]); // PNG signature

  void chunk(String type, List<int> data) {
    final typeBytes = type.codeUnits;
    out.add(_u32(data.length));
    out.add(typeBytes);
    out.add(data);
    out.add(_u32(_crc32([...typeBytes, ...data])));
  }

  chunk('IHDR', [
    ..._u32(width),
    ..._u32(height),
    8, // bit depth
    2, // color type: truecolor (RGB)
    0, 0, 0, // compression, filter, interlace
  ]);

  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0); // filter type: none
    for (var x = 0; x < width; x++) {
      raw.add(const [30, 60, 200]); // solid blue-ish pixel, RGB
    }
  }
  chunk('IDAT', ZLibEncoder().convert(raw.takeBytes()));
  chunk('IEND', const []);

  return out.takeBytes();
}

List<int> _u32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
