import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/profile/edit_profile_sheet.dart';
import 'package:checkin/state/app_state.dart';

/// A member's profile photo is set per-group (each group is an isolated server with its
/// own media storage), so nothing keeps them in sync automatically. These tests cover the
/// "Sync photo to all groups" action: it must save the current group's own edits (like
/// Save), then push just the photo - never the name, each group keeps its own - to every
/// other signed-in group, and must not silently drop a name edit or a partial failure.
class _FakeApi extends ApiClient {
  _FakeApi({this.uploadFails = false}) : super(baseUrl: '');

  final bool uploadFails;
  int updateProfileCalls = 0;
  int uploadCalls = 0;
  int setPhotoCalls = 0;
  int downloadCalls = 0;
  int? lastSetMediaId;
  String? lastName;

  @override
  Future<User> updateProfile({required String name, String? firstName, String? lastName}) async {
    updateProfileCalls++;
    this.lastName = name;
    return User(
        id: 1,
        name: name,
        firstName: firstName ?? '',
        lastName: lastName ?? '',
        phone: '+15550001111',
        isAdmin: false);
  }

  @override
  Future<int> uploadImageBytes(List<int> bytes, {String filename = 'upload.jpg'}) async {
    uploadCalls++;
    if (uploadFails) throw Exception('upload failed');
    return 99;
  }

  @override
  Future<User> setProfilePhoto(int mediaId) async {
    setPhotoCalls++;
    lastSetMediaId = mediaId;
    return User(
        id: 1, name: 'Nick', phone: '+15550001111', isAdmin: false, profileMediaId: mediaId);
  }

  @override
  Future<Uint8List> downloadMedia(int mediaId) async {
    downloadCalls++;
    return Uint8List.fromList([1, 2, 3]);
  }
}

void main() {
  ServerAccount account(String id, {int? profileMediaId}) => ServerAccount(
        id: id,
        baseUrl: 'https://$id',
        serverName: id,
        token: 't',
        user: User(
            id: 1,
            name: 'Nick',
            phone: '+15550001111',
            isAdmin: false,
            profileMediaId: profileMediaId),
      );

  Future<void> pumpSheet(
    WidgetTester tester, {
    required MultiSessionController controller,
    required ServerAccount editing,
    required Map<String, _FakeApi> apis,
  }) async {
    // The sheet is designed to size itself inside a bottom-sheet's own constraints; give
    // the test surface enough height for its natural (non-scrolling) size so it isn't
    // reported as overflowing in a plain Scaffold.
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(() => controller),
        for (final e in apis.entries) contentApiProvider(e.key).overrideWithValue(e.value),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: EditProfileSheet(user: editing.user!, groupId: editing.id),
        ),
      ),
    ));
    await tester.pump();
  }

  // A bounded pump loop rather than pumpAndSettle(): the sheet's existing-photo preview
  // is a real network image against an unresolvable .invalid host, whose placeholder
  // spinner animates indefinitely and never lets pumpAndSettle's "no frames scheduled"
  // condition become true, even once the sync/save logic itself has long since finished.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('Sync pushes the existing photo to every other group, not the name', (tester) async {
    final a = account('alpha.invalid', profileMediaId: 7);
    final b = account('beta.invalid');
    final controller = MultiSessionController.seeded(MultiSession(groups: [a, b], restored: true));
    final apiA = _FakeApi();
    final apiB = _FakeApi();

    await pumpSheet(tester,
        controller: controller, editing: a, apis: {'alpha.invalid': apiA, 'beta.invalid': apiB});

    expect(find.text('Sync photo to all groups'), findsOneWidget);
    await tester.tap(find.text('Sync photo to all groups'));
    await settle(tester);

    // Downloads the current group's existing photo once (no new photo was picked)...
    expect(apiA.downloadCalls, 1);
    // ...and re-uploads those same bytes to every group, including the one being edited.
    expect(apiA.uploadCalls, 1);
    expect(apiA.setPhotoCalls, 1);
    expect(apiB.uploadCalls, 1);
    expect(apiB.setPhotoCalls, 1);
    expect(apiB.lastSetMediaId, 99);
    // Neither group's display name is touched by Sync.
    expect(apiA.updateProfileCalls, 0);
    expect(apiB.updateProfileCalls, 0);

    // Both groups' cached sessions reflect the new photo immediately.
    expect(controller.state.byId('alpha.invalid')!.user!.profileMediaId, 99);
    expect(controller.state.byId('beta.invalid')!.user!.profileMediaId, 99);
  });

  testWidgets('Save only ever touches the group being edited', (tester) async {
    final a = account('alpha.invalid', profileMediaId: 7);
    final b = account('beta.invalid');
    final controller = MultiSessionController.seeded(MultiSession(groups: [a, b], restored: true));
    final apiA = _FakeApi();
    final apiB = _FakeApi();

    await pumpSheet(tester,
        controller: controller, editing: a, apis: {'alpha.invalid': apiA, 'beta.invalid': apiB});

    await tester.tap(find.text('Save'));
    await settle(tester);

    // Save doesn't touch the photo at all when none was picked and none was asked to sync.
    expect(apiA.uploadCalls, 0);
    expect(apiA.setPhotoCalls, 0);
    // The other group is never contacted by Save.
    expect(apiB.uploadCalls, 0);
    expect(apiB.setPhotoCalls, 0);
    expect(apiB.updateProfileCalls, 0);
  });

  testWidgets('a partial sync failure keeps the sheet open with an honest report', (tester) async {
    final a = account('alpha.invalid', profileMediaId: 7);
    final b = account('beta.invalid');
    final controller = MultiSessionController.seeded(MultiSession(groups: [a, b], restored: true));
    final apiA = _FakeApi();
    final apiB = _FakeApi(uploadFails: true);

    await pumpSheet(tester,
        controller: controller, editing: a, apis: {'alpha.invalid': apiA, 'beta.invalid': apiB});

    await tester.tap(find.text('Sync photo to all groups'));
    await settle(tester);

    // The reachable group still got the photo...
    expect(apiA.setPhotoCalls, 1);
    expect(controller.state.byId('alpha.invalid')!.user!.profileMediaId, 99);
    // ...but the sheet stays open (didn't pop) and says so, rather than silently losing
    // the failure or claiming full success.
    expect(find.byType(EditProfileSheet), findsOneWidget);
    expect(find.textContaining("couldn't reach"), findsOneWidget);
  });

  testWidgets('the sync button is hidden with only one signed-in group', (tester) async {
    final a = account('alpha.invalid', profileMediaId: 7);
    final controller = MultiSessionController.seeded(MultiSession(groups: [a], restored: true));
    final apiA = _FakeApi();

    await pumpSheet(tester, controller: controller, editing: a, apis: {'alpha.invalid': apiA});

    expect(find.text('Sync photo to all groups'), findsNothing);
  });
}
