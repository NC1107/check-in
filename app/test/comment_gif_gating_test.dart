import 'package:checkin/features/post/post_detail_screen.dart';
import 'package:checkin/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// commentGifAllowed gates the comment composer's gif icon. Both flags matter for different
/// reasons: gifSearch says whether there is anything to pick from, commentMedia says whether
/// the server accepts a comment carrying mediaId at all (an older server predates the field
/// and 400s on it - DisallowUnknownFields).
void main() {
  ServerAccount account({bool gifSearch = true, bool commentMedia = true}) => ServerAccount(
        id: 'a.invalid',
        baseUrl: 'https://a.invalid',
        serverName: 'a',
        token: 't',
        gifSearch: gifSearch,
        commentMedia: commentMedia,
      );

  test('no account (not signed in / group not found): not allowed', () {
    expect(commentGifAllowed(null), isFalse);
  });

  test('both flags set: allowed', () {
    expect(commentGifAllowed(account()), isTrue);
  });

  test('gifSearch alone is not enough - an old server predating commentMedia must not send it', () {
    expect(commentGifAllowed(account(gifSearch: true, commentMedia: false)), isFalse);
  });

  test('commentMedia alone is not enough - nothing to search would make gifSearch pointless', () {
    expect(commentGifAllowed(account(gifSearch: false, commentMedia: true)), isFalse);
  });

  test('neither flag: not allowed', () {
    expect(commentGifAllowed(account(gifSearch: false, commentMedia: false)), isFalse);
  });
}
