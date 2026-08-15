import 'package:checkin/api/api_client.dart';
import 'package:checkin/features/feed/home_shell.dart';
import 'package:checkin/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// What compose decides about a picked file before anything is uploaded. Both decisions
/// used to be implicit - every pick was re-encoded to jpeg, whatever it was - and both had
/// the same consequence: the file that reached the server was not the file that was
/// picked.
void main() {
  test('a gif is uploaded as it was picked, so it keeps animating', () {
    // The compressor only writes stills: running a gif through it posts one flattened
    // frame, which is what happened to every gif before this.
    expect(needsReencodeBeforeUpload('/tmp/party.gif'), isFalse);
    expect(needsReencodeBeforeUpload('/tmp/PARTY.GIF'), isFalse);
    // And it goes up labelled as what it is, not as the jpeg it is not.
    expect(uploadContentType('/tmp/party.gif').toString(), 'image/gif');
  });

  test('a photo is still re-encoded', () {
    // HEIC especially: the server cannot decode it, so skipping this would post nothing.
    expect(needsReencodeBeforeUpload('/tmp/IMG_0001.HEIC'), isTrue);
    expect(needsReencodeBeforeUpload('/tmp/photo.jpg'), isTrue);
    expect(needsReencodeBeforeUpload('/tmp/photo.png'), isTrue);
  });

  test('a clip is recognised before it can be posted as a photo', () {
    expect(isVideoPick('/tmp/clip.mp4'), isTrue);
    expect(isVideoPick('/tmp/clip.MOV'), isTrue);
    expect(isVideoPick('/tmp/clip.m4v'), isTrue);
    expect(isVideoPick('/tmp/photo.jpg'), isFalse);
    expect(isVideoPick('/tmp/party.gif'), isFalse);
    // A name that merely contains a clip extension is not one.
    expect(isVideoPick('/tmp/mp4/photo.jpg'), isFalse);
  });

  test('one selector routes each file to its upload path', () {
    // The clip, gif and photo paths must never be decided differently at different call
    // sites; this is the single place that maps a file to what happens to it.
    expect(uploadKindFor('/tmp/clip.mp4'), UploadKind.video);
    expect(uploadKindFor('/tmp/clip.MOV'), UploadKind.video);
    expect(uploadKindFor('/tmp/party.gif'), UploadKind.rawImage);
    expect(uploadKindFor('/tmp/IMG.HEIC'), UploadKind.reencodeImage);
    expect(uploadKindFor('/tmp/photo.jpg'), UploadKind.reencodeImage);
  });

  group('the 10s clip cap', () {
    test('trims only a clip over ten seconds', () {
      // The boundary is what the server's cap and the trim sheet agree on, so the exact
      // 10000ms edge matters.
      expect(clipNeedsTrim(9999), isFalse);
      expect(clipNeedsTrim(10000), isFalse);
      expect(clipNeedsTrim(10001), isTrue);
    });

    test('the trim window is clamped to at most ten seconds, inside the clip', () {
      // A start at zero on a long clip yields exactly the 10s cap, not the whole clip - the
      // cap is min(start + 10s, duration). This is the line a mutation would drop: without
      // it the window would be the full 30s and a >10s clip would sail through.
      final full = clampTrimWindow(0, 30000);
      expect(full.startMs, 0);
      expect(full.endMs, 10000);

      // A window near the end runs only to the clip's end, never past it.
      final tail = clampTrimWindow(27000, 30000);
      expect(tail.startMs, 27000);
      expect(tail.endMs, 30000);

      // A short clip keeps its whole length.
      final short = clampTrimWindow(0, 4000);
      expect(short.endMs, 4000);

      // A negative or past-the-end start is pulled back inside [0, duration].
      expect(clampTrimWindow(-500, 30000).startMs, 0);
      final past = clampTrimWindow(40000, 30000);
      expect(past.startMs, lessThanOrEqualTo(30000));
      expect(past.endMs, lessThanOrEqualTo(30000));
      expect(past.endMs, greaterThanOrEqualTo(past.startMs));
    });
  });

  group('video group gating', () {
    ServerAccount group(String id, List<String> mediaTypes) => ServerAccount(
          id: id,
          baseUrl: 'https://$id',
          serverName: id,
          token: 't',
          mediaTypes: mediaTypes,
        );

    test('a server predating typed media takes images only', () {
      expect(mediaTypesSupportsVideo(const ['image']), isFalse);
      expect(mediaTypesSupportsVideo(const ['image', 'gif']), isFalse);
      expect(mediaTypesSupportsVideo(const ['image', 'gif', 'video']), isTrue);
    });

    test('compose offers a clip only when every target can store it', () {
      final video = group('a.invalid', const ['image', 'gif', 'video']);
      final stills = group('b.invalid', const ['image', 'gif']);
      // No target selected: nothing to post a clip to.
      expect(clipComposeAllowed(const []), isFalse);
      // Every target takes video: allowed.
      expect(clipComposeAllowed([video]), isTrue);
      // One target that can't store a clip takes the option away for the whole selection,
      // since a clip is a single attachment shared to all of them.
      expect(clipComposeAllowed([video, stills]), isFalse);
      expect(clipComposeAllowed([stills]), isFalse);
    });
  });

  group('poster best-effort', () {
    test('a failing poster upload never fails the post', () async {
      // The poster is only the pre-play still; the feed renders a posterless clip fine, so a
      // thrown poster upload must be swallowed rather than take the post down with it.
      var attempted = false;
      await attachPosterBestEffort(() async {
        attempted = true;
        throw Exception('poster endpoint down');
      });
      expect(attempted, isTrue); // it tried
      // and returned normally: reaching here without a rethrow is the assertion.
    });

    test('a working poster upload runs to completion', () async {
      var attached = false;
      await attachPosterBestEffort(() async => attached = true);
      expect(attached, isTrue);
    });
  });
}
