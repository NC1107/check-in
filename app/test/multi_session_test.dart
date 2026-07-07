import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  Future<MultiSessionController> restoredController() async {
    final controller = MultiSessionController();
    // _load runs async from the constructor; wait for the restore to land.
    for (var i = 0; i < 100 && !controller.state.restored; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(controller.state.restored, isTrue);
    return controller;
  }

  test('migrates the legacy single session into the group list', () async {
    SharedPreferences.setMockInitialValues({'base_url': 'https://one.invalid'});
    secureStore['token'] = 'legacy-tok';

    final controller = await restoredController();
    final s = controller.state;

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

    final controller = await restoredController();
    final s = controller.state;

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

    final controller = await restoredController();
    // "Show only Beta" becomes "hide everyone but Beta".
    expect(controller.state.hiddenGroupIds, {'a.invalid'});
    expect(controller.state.shownGroups.map((g) => g.id), ['b.invalid']);

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

    final controller = await restoredController();
    expect(controller.state.hiddenGroupIds, isEmpty);
  });

  test('toggleGroup hides/shows a group and persists; the last shown group is protected', () async {
    SharedPreferences.setMockInitialValues({
      'groups_json': jsonEncode([
        {'id': 'a.invalid', 'baseUrl': 'https://a.invalid', 'name': 'Alpha'},
        {'id': 'b.invalid', 'baseUrl': 'https://b.invalid', 'name': 'Beta'},
      ]),
    });
    secureStore['token_a.invalid'] = 'tok-a';
    secureStore['token_b.invalid'] = 'tok-b';
    final controller = await restoredController();
    final prefs = await SharedPreferences.getInstance();

    await controller.toggleGroup('b.invalid');
    expect(controller.state.hiddenGroupIds, {'b.invalid'});
    expect(controller.state.shownGroups.map((g) => g.id), ['a.invalid']);
    expect(prefs.getString('hidden_group_ids'), jsonEncode(['b.invalid']));

    // Hiding the last shown group is refused (an empty feed helps no one).
    await controller.toggleGroup('a.invalid');
    expect(controller.state.hiddenGroupIds, {'b.invalid'});

    // Re-showing, then All resets.
    await controller.toggleGroup('b.invalid');
    expect(controller.state.hiddenGroupIds, isEmpty);
    await controller.toggleGroup('a.invalid');
    await controller.showAllGroups();
    expect(controller.state.hiddenGroupIds, isEmpty);
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

    final controller = await restoredController();
    expect(controller.state.hiddenGroupIds, {'a.invalid'});

    await controller.signOutGroup('b.invalid');
    expect(controller.state.byId('b.invalid'), isNotNull);
    expect(controller.state.byId('b.invalid')!.isSignedIn, isFalse);
    expect(secureStore.containsKey('token_b.invalid'), isFalse);
    // The other group is untouched.
    expect(controller.state.byId('a.invalid')!.token, 'tok-a');

    await controller.removeGroup('a.invalid');
    expect(controller.state.byId('a.invalid'), isNull);
    expect(secureStore.containsKey('token_a.invalid'), isFalse);
    // Removing a hidden group clears it from the hidden set too.
    expect(controller.state.hiddenGroupIds, isEmpty);
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
    final controller = await restoredController();

    await controller.renameGroup('a.invalid', 'Book Club');
    expect(controller.state.byId('a.invalid')!.displayName, 'Book Club');
    expect(controller.state.byId('a.invalid')!.serverName, 'Alpha');
    // Persisted so it survives a restart.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('groups_json'), contains('Book Club'));

    await controller.renameGroup('a.invalid', '   ');
    expect(controller.state.byId('a.invalid')!.nickname, isNull);
    expect(controller.state.byId('a.invalid')!.displayName, 'Alpha');
  });

  test('applyServerName updates the server name for everyone and drops any nickname', () async {
    SharedPreferences.setMockInitialValues({
      'groups_json': jsonEncode([
        {'id': 'a.invalid', 'baseUrl': 'https://a.invalid', 'name': 'Alpha', 'nickname': 'Mine'},
      ]),
    });
    final controller = await restoredController();
    expect(controller.state.byId('a.invalid')!.displayName, 'Mine');

    await controller.applyServerName('a.invalid', 'Weekend Warriors');
    final g = controller.state.byId('a.invalid')!;
    expect(g.serverName, 'Weekend Warriors');
    expect(g.nickname, isNull); // the new server name is authoritative now
    expect(g.displayName, 'Weekend Warriors');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('groups_json'), contains('Weekend Warriors'));
  });
}
