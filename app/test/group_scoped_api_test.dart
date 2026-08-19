import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/state/app_state.dart';

/// Asking for a group's API client must never quietly hand back a different group's.
///
/// Post ids, comment ids, media ids and user ids are only unique PER SERVER. Sending one
/// group's id to another group's server is not an error there - it either finds nothing, or
/// finds an unrelated row that happens to hold that number and acts on it. Nothing in the
/// system can detect that afterwards, which is why the wrong client must never be returned
/// in the first place.
///
/// Written from what must be true rather than from what the code does.
void main() {
  final me = User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: false);

  ServerAccount account(String id) => ServerAccount(
        id: id,
        baseUrl: 'https://$id',
        serverName: id,
        token: 't-$id',
        user: me,
      );

  ProviderContainer containerWith(List<ServerAccount> groups) {
    final c = ProviderContainer(overrides: [
      multiSessionProvider.overrideWith(
          () => MultiSessionController.seeded(MultiSession(groups: groups, restored: true))),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('a signed-in group resolves to its own server', () {
    final c = containerWith([account('alpha.invalid'), account('beta.invalid')]);
    expect(c.read(contentAccountProvider('beta.invalid'))?.id, 'beta.invalid');
  });

  test('a group that is no longer signed in must not resolve to another server', () {
    // The scenario: a member opens a cross-posted check-in, taps Reply on a comment from
    // their Family group, then signs out of Family from elsewhere in the app before
    // sending. The reply still carries Family's post id and Family's parent comment id.
    // If those are sent to whatever group is merely "current", they address rows on a
    // server that never held that conversation.
    final c = containerWith([account('alpha.invalid'), account('beta.invalid')]);

    final resolved = c.read(contentAccountProvider('gone.invalid'));

    expect(resolved, isNull,
        reason: "a request scoped to a group that is gone must not resolve to whichever "
            "group happens to be current - its ids mean something else on that server. "
            "Resolving to nothing makes the request fail loudly instead of landing "
            "silently on the wrong one");
  });

  test('no group at all still falls back to the current account', () {
    // A null groupId means "whatever the member is currently looking at" - that is a
    // deliberate absence, not a stale reference, so the fallback is correct there.
    final c = containerWith([account('alpha.invalid')]);
    expect(c.read(contentAccountProvider(null))?.id, 'alpha.invalid');
  });
}
