import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/state/app_state.dart';

/// Multi-session persistence: the legacy single-session migration and per-group
/// token handling. Secure storage is mocked at the platform channel; server URLs use
/// the reserved .invalid TLD so hydration fails fast (a network error must never sign
/// a group out).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> secureStore;

  setUp(() {
    secureStore = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
      switch (call.method) {
        case 'read':
          return secureStore[args['key'] as String];
        case 'write':
          secureStore[args['key'] as String] = args['value'] as String;
          return null;
        case 'delete':
          secureStore.remove(args['key'] as String);
          return null;
        case 'readAll':
          return secureStore;
        case 'deleteAll':
          secureStore.clear();
          return null;
        case 'containsKey':
          return secureStore.containsKey(args['key'] as String);
      }
      return null;
    });
  });

  /// Boots the controller through a container - a Notifier only holds state once a provider
  /// has built it - and waits for the restore build() kicks off to land.
  Future<ProviderContainer> restoredContainer() async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    for (var i = 0; i < 100 && !container.session.restored; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(container.session.restored, isTrue);
    return container;
  }

  test('migrates the legacy single session into the group list', () async {
    SharedPreferences.setMockInitialValues({'base_url': 'https://one.invalid'});
    secureStore['token'] = 'legacy-tok';

    final container = await restoredContainer();
    final s = container.session;

    expect(s.groups, hasLength(1));
    expect(s.groups.single.id, 'one.invalid');
    expect(s.groups.single.baseUrl, 'https://one.invalid');
    expect(s.groups.single.token, 'legacy-tok');
    // A single group is shown by default (nothing hidden).
    expect(s.hiddenGroupIds, isEmpty);

    // Legacy keys are gone; the token is re-keyed per group.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('base_url'), isNull);
    expect(secureStore.containsKey('token'), isFalse);
    expect(secureStore['token_one.invalid'], 'legacy-tok');
  });

  test('restores a multi-group list with per-group tokens; nothing hidden by default', () async {
    SharedPreferences.setMockInitialValues({
      'groups_json': jsonEncode([
        {'id': 'a.invalid', 'baseUrl': 'https://a.invalid', 'name': 'Alpha'},
        {'id': 'b.invalid', 'baseUrl': 'https://b.invalid', 'name': 'Beta'},
      ]),
    });
    secureStore['token_a.invalid'] = 'tok-a';
    // b has no token: signed out there, but the entry must survive for re-login.

    final container = await restoredContainer();
    final s = container.session;

    expect([for (final g in s.groups) g.id], ['a.invalid', 'b.invalid']);
    expect(s.byId('a.invalid')!.token, 'tok-a');
    expect(s.byId('b.invalid')!.isSignedIn, isFalse);
    expect(s.hiddenGroupIds, isEmpty);
    expect(s.signedIn.map((g) => g.id), ['a.invalid']);
  });

  test('migrates active_group_id: a specific group hides the others, then drops the key', () async {
    SharedPreferences.setMockInitialValues({
      'groups_json': jsonEncode([
        {'id': 'a.invalid', 'baseUrl': 'https://a.invalid', 'name': 'Alpha'},
        {'id': 'b.invalid', 'baseUrl': 'https://b.invalid', 'name': 'Beta'},
      ]),
      'active_group_id': 'b.invalid',
    });
    secureStore['token_a.invalid'] = 'tok-a';
    secureStore['token_b.invalid'] = 'tok-b';

    final container = await restoredContainer();
    // "Show only Beta" becomes "hide everyone but Beta".
    expect(container.session.hiddenGroupIds, {'a.invalid'});
    expect(container.session.shownGroups.map((g) => g.id), ['b.invalid']);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('active_group_id'), isNull); // retired
    expect(prefs.getString('hidden_group_ids'), jsonEncode(['a.invalid']));
  });

  test("migrates '' / unknown active_group_id to the All view (nothing hidden)", () async {
    SharedPreferences.setMockInitialValues({
      'groups_json': jsonEncode([
        {'id': 'a.invalid', 'baseUrl': 'https://a.invalid', 'name': 'Alpha'},
        {'id': 'b.invalid', 'baseUrl': 'https://b.invalid', 'name': 'Beta'},
      ]),
      'active_group_id': 'gone.invalid',
    });

    final container = await restoredContainer();
    expect(container.session.hiddenGroupIds, isEmpty);
  });

  test('toggleGroup hides/shows a group and persists; hiding every group is allowed', () async {
    SharedPreferences.setMockInitialValues({
      'groups_json': jsonEncode([
        {'id': 'a.invalid', 'baseUrl': 'https://a.invalid', 'name': 'Alpha'},
        {'id': 'b.invalid', 'baseUrl': 'https://b.invalid', 'name': 'Beta'},
      ]),
    });
    secureStore['token_a.invalid'] = 'tok-a';
    secureStore['token_b.invalid'] = 'tok-b';
    final container = await restoredContainer();
    final controller = container.controller;
    final prefs = await SharedPreferences.getInstance();

    await controller.toggleGroup('b.invalid');
    expect(container.session.hiddenGroupIds, {'b.invalid'});
    expect(container.session.shownGroups.map((g) => g.id), ['a.invalid']);
    expect(prefs.getString('hidden_group_ids'), jsonEncode(['b.invalid']));

    // The last shown group can be hidden too - the feed shows an explicit empty state.
    await controller.toggleGroup('a.invalid');
    expect(container.session.hiddenGroupIds, {'a.invalid', 'b.invalid'});
    expect(container.session.shownGroups, isEmpty);
    expect(container.session.nothingShown, isTrue);
    // Screens that need "a group" (profile/settings) still get one.
    expect(container.session.current?.id, 'a.invalid');

    // All resets.
    await controller.showAllGroups();
    expect(container.session.hiddenGroupIds, isEmpty);
    expect(prefs.getString('hidden_group_ids'), jsonEncode(<String>[]));
  });

  test('signOutGroup drops only that group; removeGroup drops the entry and un-hides it', () async {
    SharedPreferences.setMockInitialValues({
      'groups_json': jsonEncode([
        {'id': 'a.invalid', 'baseUrl': 'https://a.invalid', 'name': 'Alpha'},
        {'id': 'b.invalid', 'baseUrl': 'https://b.invalid', 'name': 'Beta'},
      ]),
      'hidden_group_ids': jsonEncode(['a.invalid']),
    });
    secureStore['token_a.invalid'] = 'tok-a';
    secureStore['token_b.invalid'] = 'tok-b';

    final container = await restoredContainer();
    final controller = container.controller;
    expect(container.session.hiddenGroupIds, {'a.invalid'});

    await controller.signOutGroup('b.invalid');
    expect(container.session.byId('b.invalid'), isNotNull);
    expect(container.session.byId('b.invalid')!.isSignedIn, isFalse);
    expect(secureStore.containsKey('token_b.invalid'), isFalse);
    // The other group is untouched.
    expect(container.session.byId('a.invalid')!.token, 'tok-a');

    await controller.removeGroup('a.invalid');
    expect(container.session.byId('a.invalid'), isNull);
    expect(secureStore.containsKey('token_a.invalid'), isFalse);
    // Removing a hidden group clears it from the hidden set too.
    expect(container.session.hiddenGroupIds, isEmpty);
  });

  test('addGroup carries the server capabilities across from server-info', () async {
    // Without this every flag stayed false until the next launch ran _hydrate, so a member
    // who had just connected saw none of the features their server actually supports -
    // no activity bell, no Memories, no Places - until they restarted the app.
    SharedPreferences.setMockInitialValues({});
    final container = await restoredContainer();
    await container.read(multiSessionProvider.notifier).addGroup(
          baseUrl: 'https://alpha.invalid',
          serverName: 'Alpha',
          token: 't1',
          user: User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: true),
          info: ServerInfo(
            name: 'Alpha',
            initialized: true,
            mediaTypes: const ['image', 'gif', 'video'],
            gifSearch: true,
            commentMedia: true,
            crossComments: true,
            recapCapable: true,
            memoriesCapable: true,
            eventsCapable: true,
            timelineCapable: true,
            forgottenCapable: true,
            placesCapable: true,
            activityCapable: true,
          ),
        );

    final g = container.session.byId('alpha.invalid')!;
    expect(g.activityCapable, isTrue);
    expect(g.placesCapable, isTrue);
    expect(g.memoriesCapable, isTrue);
    expect(g.gifSearch, isTrue);
    expect(g.mediaTypes, contains('video'));
  });

  test('a group connected with no server-info claims no capabilities', () async {
    // Unknown must mean "not capable", never "anything goes": offering a feature a server
    // does not have sends the member into a view that can only fail.
    SharedPreferences.setMockInitialValues({});
    final container = await restoredContainer();
    await container.read(multiSessionProvider.notifier).addGroup(
          baseUrl: 'https://beta.invalid',
          serverName: 'Beta',
          token: 't2',
          user: User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: true),
        );

    final g = container.session.byId('beta.invalid')!;
    expect(g.activityCapable, isFalse);
    expect(g.placesCapable, isFalse);
    expect(g.mediaTypes, const ['image']);
  });

  test('groupIdFor derives the host', () {
    expect(MultiSessionController.groupIdFor('https://alpha.example.com'), 'alpha.example.com');
    expect(MultiSessionController.groupIdFor('https://x.dev:8443'), 'x.dev');
    expect(MultiSessionController.groupIdFor('not a url'), 'not a url');
  });

  test('renameGroup sets/clears a local nickname and persists it', () async {
    SharedPreferences.setMockInitialValues({
      'groups_json': jsonEncode([
        {'id': 'a.invalid', 'baseUrl': 'https://a.invalid', 'name': 'Alpha'},
      ]),
    });
    final container = await restoredContainer();
    final controller = container.controller;

    await controller.renameGroup('a.invalid', 'Book Club');
    expect(container.session.byId('a.invalid')!.displayName, 'Book Club');
    expect(container.session.byId('a.invalid')!.serverName, 'Alpha');
    // Persisted so it survives a restart.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('groups_json'), contains('Book Club'));

    await controller.renameGroup('a.invalid', '   ');
    expect(container.session.byId('a.invalid')!.nickname, isNull);
    expect(container.session.byId('a.invalid')!.displayName, 'Alpha');
  });

  test('applyServerName updates the server name for everyone and drops any nickname', () async {
    SharedPreferences.setMockInitialValues({
      'groups_json': jsonEncode([
        {'id': 'a.invalid', 'baseUrl': 'https://a.invalid', 'name': 'Alpha', 'nickname': 'Mine'},
      ]),
    });
    final container = await restoredContainer();
    final controller = container.controller;
    expect(container.session.byId('a.invalid')!.displayName, 'Mine');

    await controller.applyServerName('a.invalid', 'Weekend Warriors');
    final g = container.session.byId('a.invalid')!;
    expect(g.serverName, 'Weekend Warriors');
    expect(g.nickname, isNull); // the new server name is authoritative now
    expect(g.displayName, 'Weekend Warriors');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('groups_json'), contains('Weekend Warriors'));
  });

  test('composeDefaults: post where you are looking, else every signed-in group', () {
    const a =
        ServerAccount(id: 'a.invalid', baseUrl: 'https://a.invalid', serverName: 'A', token: 't1');
    const b =
        ServerAccount(id: 'b.invalid', baseUrl: 'https://b.invalid', serverName: 'B', token: 't2');

    // Everything shown → both are targets.
    const all = MultiSession(groups: [a, b], restored: true);
    expect(all.composeDefaults.map((g) => g.id), ['a.invalid', 'b.invalid']);

    // One group in view → just that one.
    const one = MultiSession(groups: [a, b], hiddenGroupIds: {'b.invalid'}, restored: true);
    expect(one.composeDefaults.map((g) => g.id), ['a.invalid']);

    // Nothing shown → fall back to every signed-in group (an empty compose helps no one).
    const none =
        MultiSession(groups: [a, b], hiddenGroupIds: {'a.invalid', 'b.invalid'}, restored: true);
    expect(none.composeDefaults.map((g) => g.id), ['a.invalid', 'b.invalid']);
  });

  test('applyServerColor sets/clears the group color and persists it', () async {
    SharedPreferences.setMockInitialValues({
      'groups_json': jsonEncode([
        {'id': 'a.invalid', 'baseUrl': 'https://a.invalid', 'name': 'Alpha'},
      ]),
    });
    final container = await restoredContainer();
    final controller = container.controller;
    final prefs = await SharedPreferences.getInstance();

    await controller.applyServerColor('a.invalid', 'coral');
    expect(container.session.byId('a.invalid')!.color, 'coral');
    expect(prefs.getString('groups_json'), contains('coral'));

    // Empty clears it back to the automatic color and drops it from storage.
    await controller.applyServerColor('a.invalid', '');
    expect(container.session.byId('a.invalid')!.color, isNull);
    expect(prefs.getString('groups_json'), isNot(contains('coral')));
  });
}

/// The controller and the session it exposes, read back through the container that owns it.
extension on ProviderContainer {
  MultiSession get session => read(multiSessionProvider);
  MultiSessionController get controller => read(multiSessionProvider.notifier);
}
