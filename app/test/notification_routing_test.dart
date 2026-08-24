import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/notifications/notification_route.dart';
import 'package:checkin/state/app_state.dart';

/// Which group a notification belongs to had no coverage at all, and getting it wrong is
/// the failure the member actually reported: post ids are only unique per server, so
/// opening the id on the wrong group shows a stranger's unrelated check-in and looks
/// exactly like the notification took you somewhere random.
///
/// The old code fell back to "the current group" whenever the payload could not be matched,
/// which is precisely the guess that produces that. These pin the rule that replaced it.
void main() {
  ServerAccount account(String host, {bool signedIn = true}) => ServerAccount(
        id: host,
        baseUrl: 'https://$host',
        serverName: host,
        token: signedIn ? 't' : null,
        user: signedIn ? User(id: 1, name: 'Nick', phone: '+1', isAdmin: false) : null,
      );

  MultiSession sessionOf(List<ServerAccount> groups) =>
      MultiSession(groups: groups, restored: true);

  /// A probe that says the post exists in exactly the named groups.
  Future<bool> Function(ServerAccount) probe(Set<String> holders, {List<String>? asked}) =>
      (g) async {
        asked?.add(g.id);
        return holders.contains(g.id);
      };

  group('pushPostId / pushCommentId', () {
    test('reads the ids a payload carries', () {
      final data = {'type': 'comment', 'postId': '42', 'commentId': '7'};
      expect(pushPostId(data), 42);
      expect(pushCommentId(data), 7);
    });

    test('a digest names no post, so there is nothing to open', () {
      expect(pushPostId({'type': 'digest'}), isNull);
    });

    test('a like names no comment, because it is about the post', () {
      expect(pushCommentId({'type': 'like', 'postId': '42'}), isNull);
    });

    test('a server too old to send a comment id simply does not', () {
      expect(pushCommentId({'type': 'comment', 'postId': '42'}), isNull);
    });
  });

  group('resolvePushGroup', () {
    test('uses the group the payload names', () async {
      final alpha = account('alpha.invalid');
      final beta = account('beta.invalid');
      final got = await resolvePushGroup(
        sessionOf([alpha, beta]),
        {'server': 'https://beta.invalid'},
        42,
        probe(const {}),
      );
      expect(got?.id, 'beta.invalid');
    });

    test('matches on host, so a trailing slash or a path does not break it', () async {
      final alpha = account('alpha.invalid');
      final got = await resolvePushGroup(
        sessionOf([alpha, account('beta.invalid')]),
        {'server': 'https://alpha.invalid/'},
        42,
        probe(const {}),
      );
      expect(got?.id, 'alpha.invalid');
    });

    test('with one group connected, an unnamed server is unambiguous', () async {
      final asked = <String>[];
      final got = await resolvePushGroup(
        sessionOf([account('alpha.invalid')]),
        const {},
        42,
        probe(const {}, asked: asked),
      );
      expect(got?.id, 'alpha.invalid');
      expect(asked, isEmpty, reason: 'there was nothing to probe for');
    });

    test('with several groups and no named server, the one holding the post wins', () async {
      final got = await resolvePushGroup(
        sessionOf([account('alpha.invalid'), account('beta.invalid'), account('gamma.invalid')]),
        const {},
        42,
        probe({'beta.invalid'}),
      );
      expect(got?.id, 'beta.invalid');
    });

    test('gives up rather than guessing when two groups hold that id', () async {
      final got = await resolvePushGroup(
        sessionOf([account('alpha.invalid'), account('beta.invalid')]),
        const {},
        42,
        probe({'alpha.invalid', 'beta.invalid'}),
      );
      expect(got, isNull,
          reason: 'opening the wrong check-in is worse than opening none - the member '
              'cannot tell it is the wrong one');
    });

    test('gives up when no group holds it', () async {
      final got = await resolvePushGroup(
        sessionOf([account('alpha.invalid'), account('beta.invalid')]),
        const {},
        42,
        probe(const {}),
      );
      expect(got, isNull);
    });

    test('a named server we are not signed in to falls through to the probe', () async {
      final got = await resolvePushGroup(
        sessionOf([account('alpha.invalid'), account('beta.invalid')]),
        {'server': 'https://gone.invalid'},
        42,
        probe({'alpha.invalid'}),
      );
      expect(got?.id, 'alpha.invalid');
    });

    test('a signed-out group cannot be the answer, or be probed', () async {
      final asked = <String>[];
      final got = await resolvePushGroup(
        sessionOf([account('alpha.invalid', signedIn: false)]),
        {'server': 'https://alpha.invalid'},
        42,
        probe({'alpha.invalid'}, asked: asked),
      );
      expect(got, isNull);
      expect(asked, isEmpty);
    });

    test('a probe that throws counts as "not here" rather than failing the tap', () async {
      final got = await resolvePushGroup(
        sessionOf([account('alpha.invalid'), account('beta.invalid')]),
        const {},
        42,
        (g) async {
          if (g.id == 'alpha.invalid') throw Exception('unreachable');
          return true;
        },
      );
      expect(got?.id, 'beta.invalid');
    });
  });
}
