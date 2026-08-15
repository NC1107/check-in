import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
        home: Scaffold(body: PostImageCarousel(mediaIds: [1], groupId: 'g')),
      ),
    ));

    expect(tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio, closeTo(4 / 3, 0.001));
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
