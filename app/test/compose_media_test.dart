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

    test('a selection under the cap is handed back unchanged', () {
      // Two independent handles: a 3s pick stays 3s, it is not stretched to a fixed width.
      final three = clampTrimWindow(0, 3000, 30000);
      expect(three.startMs, 0);
      expect(three.endMs, 3000);
    });

    test('an over-cap span is trimmed by moving the dragged edge, not the anchor', () {
      // Dragging the end past the cap pulls the END back to start + 10s; the start is left
      // where it is. This is the line a mutation would drop: without the 10s cap the window
      // would be the full 11s and a >10s clip would sail through.
      final draggedEnd = clampTrimWindow(0, 11000, 30000, moved: TrimEdge.end);
      expect(draggedEnd.startMs, 0);
      expect(draggedEnd.endMs, 10000);

      // Dragging the start of the same 11s span instead moves the START forward to end - 10s;
      // the end is the anchor and does not move. So the opposite handle is never dragged along.
      final draggedStart = clampTrimWindow(0, 11000, 30000, moved: TrimEdge.start);
      expect(draggedStart.startMs, 1000);
      expect(draggedStart.endMs, 11000);
    });

    test('a span under the minimum is bumped to one second', () {
      // Squeezing the end almost onto the start holds the window open at the 1s minimum by
      // moving the dragged (end) edge.
      final tiny = clampTrimWindow(5000, 5300, 30000, moved: TrimEdge.end);
      expect(tiny.startMs, 5000);
      expect(tiny.endMs, 6000);
    });

    test('out-of-range edges clamp back inside the clip', () {
      final past = clampTrimWindow(-500, 40000, 30000);
      expect(past.startMs, 0);
      expect(past.endMs, 10000); // capped at start + 10s, and inside [0, 30000]
      expect(past.endMs, lessThanOrEqualTo(30000));
      expect(past.endMs - past.startMs, lessThanOrEqualTo(10000));
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
