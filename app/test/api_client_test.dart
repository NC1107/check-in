import 'dart:io';

import 'package:checkin/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// The parts of ApiClient that can be checked without a server: what it names its uploads,
/// what URL a media variant resolves to, and what every request identifies itself as.
void main() {
  test('an upload is named from its extension, clips included', () {
    expect(uploadContentType('/tmp/photo.HEIC').toString(), 'image/jpeg');
    expect(uploadContentType('/tmp/photo.jpg').toString(), 'image/jpeg');
    expect(uploadContentType('/tmp/sticker.GIF').toString(), 'image/gif');
    expect(uploadContentType('/tmp/shot.png').toString(), 'image/png');
    expect(uploadContentType('/tmp/shot.webp').toString(), 'image/webp');
    expect(uploadContentType('/tmp/clip.mp4').toString(), 'video/mp4');
    // A name with no extension at all must not be read as its own extension.
    expect(fileExtension('/tmp/noextension'), '');
    expect(uploadContentType('/tmp/noextension').toString(), 'image/jpeg');
  });

  test('a variant is asked for on the media URL, and omitted when there is none', () {
    final api = ApiClient(baseUrl: 'https://alpha.invalid');
    expect(api.imageUrl(7), 'https://alpha.invalid/api/media/7');
    expect(api.imageUrl(7, variant: 'poster'), 'https://alpha.invalid/api/media/7?variant=poster');
  });

  test('media requests carry the client version, with and without a session', () {
    expect(ApiClient(baseUrl: 'https://alpha.invalid').authHeaders, {
      'X-Client-Version': kClientVersion,
    });
    expect(ApiClient(baseUrl: 'https://alpha.invalid', token: 't1').authHeaders, {
      'X-Client-Version': kClientVersion,
      'Authorization': 'Bearer t1',
    });
  });

  test('the reported client version is the version actually being built', () {
    // Nothing derives the header from the build at runtime (no package_info_plus), so this
    // is what stops the two silently diverging across a release.
    final pubspec = File('pubspec.yaml').readAsLinesSync();
    final declared = pubspec.firstWhere((l) => l.startsWith('version:')).split(':')[1].trim();
    expect(declared.split('+').first, kClientVersion);
  });
}
