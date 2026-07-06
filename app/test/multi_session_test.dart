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
    expect(s.activeGroupId, 'one.invalid');

    // Legacy keys are gone; the token is re-keyed per group.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('base_url'), isNull);
    expect(secureStore.containsKey('token'), isFalse);
    expect(secureStore['token_one.invalid'], 'legacy-tok');
  });

  test('restores a multi-group list with per-group tokens and the active group', () async {
    SharedPreferences.setMockInitialValues({
      'groups_json': jsonEncode([
        {'id': 'a.invalid', 'baseUrl': 'https://a.invalid', 'name': 'Alpha'},
        {'id': 'b.invalid', 'baseUrl': 'https://b.invalid', 'name': 'Beta'},
      ]),
      'active_group_id': 'b.invalid',
    });
    secureStore['token_a.invalid'] = 'tok-a';
    // b has no token: signed out there, but the entry must survive for re-login.

    final controller = await restoredController();
    final s = controller.state;

    expect([for (final g in s.groups) g.id], ['a.invalid', 'b.invalid']);
    expect(s.byId('a.invalid')!.token, 'tok-a');
    expect(s.byId('b.invalid')!.isSignedIn, isFalse);
    expect(s.activeGroupId, 'b.invalid');
    expect(s.signedIn.map((g) => g.id), ['a.invalid']);
  });

  test("'' persists the All view and an unknown active id falls back", () async {
    SharedPreferences.setMockInitialValues({
      'groups_json': jsonEncode([
        {'id': 'a.invalid', 'baseUrl': 'https://a.invalid', 'name': 'Alpha'},
      ]),
      'active_group_id': 'gone.invalid',
    });

    final controller = await restoredController();
    expect(controller.state.activeGroupId, 'a.invalid');

    await controller.setActive(null);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('active_group_id'), '');
  });

  test('signOutGroup drops only that group; removeGroup drops the entry too', () async {
    SharedPreferences.setMockInitialValues({
      'groups_json': jsonEncode([
        {'id': 'a.invalid', 'baseUrl': 'https://a.invalid', 'name': 'Alpha'},
        {'id': 'b.invalid', 'baseUrl': 'https://b.invalid', 'name': 'Beta'},
      ]),
      'active_group_id': 'a.invalid',
    });
    secureStore['token_a.invalid'] = 'tok-a';
    secureStore['token_b.invalid'] = 'tok-b';

    final controller = await restoredController();

    await controller.signOutGroup('b.invalid');
    expect(controller.state.byId('b.invalid'), isNotNull);
    expect(controller.state.byId('b.invalid')!.isSignedIn, isFalse);
    expect(secureStore.containsKey('token_b.invalid'), isFalse);
    // The other group is untouched.
    expect(controller.state.byId('a.invalid')!.token, 'tok-a');

    await controller.removeGroup('a.invalid');
    expect(controller.state.byId('a.invalid'), isNull);
    expect(secureStore.containsKey('token_a.invalid'), isFalse);
    // Active falls to the remaining group.
    expect(controller.state.activeGroupId, 'b.invalid');
  });

  test('groupIdFor derives the host', () {
    expect(MultiSessionController.groupIdFor('https://alpha.example.com'), 'alpha.example.com');
    expect(MultiSessionController.groupIdFor('https://x.dev:8443'), 'x.dev');
    expect(MultiSessionController.groupIdFor('not a url'), 'not a url');
  });
}
