import 'package:checkin/api/api_client.dart';
import 'package:checkin/features/feed/home_shell.dart';
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
}
