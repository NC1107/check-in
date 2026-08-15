import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/onboarding/auth_screen.dart';
import 'package:checkin/features/onboarding/profile_prefill.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/widgets/app_widgets.dart';

/// Joining a second group used to start the profile step blank, so the name, photo and
/// birthday already on the device had to be retyped. These cover the copy - and, more
/// importantly, the phone match that gates it: the device is shared, and pre-filling a
/// stranger's signup with the owner's name and face would be far worse than the friction.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The multi-session store reads tokens from secure storage; mock the channel.
  const secureChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async => null);
    SharedPreferences.setMockInitialValues({'seen_selfhost_intro': true});
  });

  ServerAccount account({
    String id = 'alpha.invalid',
    String name = 'Alpha',
    String phone = '+12025550186',
    String firstName = 'Nick',
    String lastName = 'Conn',
    String? displayName,
    int? profileMediaId,
    int birthdayMonth = 0,
    int birthdayDay = 0,
  }) =>
      ServerAccount(
        id: id,
        baseUrl: 'https://$id',
        serverName: name,
        token: 't1',
        user: User(
          id: 1,
          name: displayName ?? '$firstName $lastName'.trim(),
          firstName: firstName,
          lastName: lastName,
          phone: phone,
          isAdmin: false,
          profileMediaId: profileMediaId,
          birthdayMonth: birthdayMonth,
          birthdayDay: birthdayDay,
        ),
      );

  // A bounded pump loop rather than pumpAndSettle(): the profile step can hold a decoded
  // photo and a modal picker whose animations keep frames scheduled, and every fake here
  // completes immediately, so a fixed number of frames is both enough and terminating.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Pumps the auth screen and drives it to the profile step: type a server and a number,
  /// then Continue. [number] is the national part, so it decides whether the seeded
  /// account matches.
  Future<void> pumpToProfile(
    WidgetTester tester, {
    required List<ServerAccount> groups,
    String number = '2025550186',
    _FakeApi? api,
    List<Override> overrides = const [],
  }) async {
    final controller = MultiSessionController.seeded(MultiSession(groups: groups, restored: true));
    final entryApi = api ?? _FakeApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [multiSessionProvider.overrideWith((ref) => controller), ...overrides],
        child: MaterialApp(home: AuthScreen(clientFactory: (_, {token}) => entryApi)),
      ),
    );
    await settle(tester);

    await tester.enterText(find.byType(TextField).first, 'beta.invalid');
    await tester.enterText(find.byType(TextField).at(1), number);
    await settle(tester);
    await tester.tap(find.text('Continue'));
    await settle(tester);
  }

  // On the profile step: 0 first name, 1 last name, 2 display name, 3 password.
  String fieldText(WidgetTester tester, int index) =>
      tester.widget<TextField>(find.byType(TextField).at(index)).controller!.text;

  Finder note = find.textContaining('Filled in from your');

  bool finishEnabled(WidgetTester tester) =>
      tester.widget<PrimaryButton>(find.widgetWithText(PrimaryButton, 'Finish')).enabled;

  testWidgets('the profile step arrives filled in from the matching account', (tester) async {
    await pumpToProfile(tester, groups: [account()]);

    expect(find.text('Full name'), findsOneWidget); // the profile step did render
    expect(fieldText(tester, 0), 'Nick');
    expect(fieldText(tester, 1), 'Conn');
    expect(note, findsOneWidget);
    expect(find.textContaining('Alpha'), findsOneWidget);
  });

  testWidgets('a display name that is just the full name is not copied', (tester) async {
    // The server fills a blank display name in with the full name, so copying a matching
    // one would turn that default into an explicit choice the user never made.
    await pumpToProfile(tester, groups: [account(displayName: 'Nick Conn')]);

    expect(fieldText(tester, 2), '');
  });

  testWidgets('a display name the user actually chose is copied', (tester) async {
    await pumpToProfile(tester, groups: [account(displayName: 'Nicky')]);

    expect(fieldText(tester, 2), 'Nicky');
  });

  testWidgets('a different number on the same device gets nothing at all', (tester) async {
    // The safety guard. Someone borrowing the phone to join their own group must not be
    // handed the owner's name, and must not cause a single request to the owner's server.
    final source = _FakeApi();
    await pumpToProfile(
      tester,
      groups: [account(profileMediaId: 7)],
      number: '2025550999',
      overrides: [contentApiProvider('alpha.invalid').overrideWithValue(source)],
    );

    expect(find.text('Full name'), findsOneWidget);
    expect(fieldText(tester, 0), '');
    expect(fieldText(tester, 1), '');
    expect(fieldText(tester, 2), '');
    expect(note, findsNothing);
    expect(source.downloadCalls, 0);
    expect(find.text('Add photo'), findsOneWidget);
  });

  testWidgets('the profile photo is carried across as bytes', (tester) async {
    // Media ids are per-server, so only the bytes are portable.
    final source = _FakeApi();
    await pumpToProfile(
      tester,
      groups: [account(profileMediaId: 7)],
      overrides: [contentApiProvider('alpha.invalid').overrideWithValue(source)],
    );

    expect(source.downloadCalls, 1);
    expect(source.lastDownloadedId, 7);
    expect(
      find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage),
      findsOneWidget,
    );
    expect(find.text('Add photo'), findsNothing);
  });

  testWidgets('an unreachable source server costs the photo, not the join', (tester) async {
    final source = _FakeApi(downloadFails: true);
    await pumpToProfile(
      tester,
      groups: [account(profileMediaId: 7)],
      overrides: [contentApiProvider('alpha.invalid').overrideWithValue(source)],
    );

    expect(source.downloadCalls, 1);
    // The step is fully usable, says nothing about a failure, and still offers the picker.
    expect(find.text('Full name'), findsOneWidget);
    expect(note, findsOneWidget);
    expect(find.text('Add photo'), findsOneWidget);
    expect(find.textContaining("Couldn't"), findsNothing);
  });

  testWidgets('going back and forward again does not undo a typed edit', (tester) async {
    await pumpToProfile(tester, groups: [account()]);
    expect(fieldText(tester, 0), 'Nick');

    await tester.enterText(find.byType(TextField).first, 'Nicolas');
    await settle(tester);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await settle(tester);
    await tester.tap(find.text('Continue'));
    await settle(tester);

    expect(fieldText(tester, 0), 'Nicolas');
  });

  testWidgets('changing the number to one that does not match clears the prefill', (tester) async {
    // _back() leaves the controllers alone, so a prefill that no longer belongs to the
    // typed number has to be actively cleared rather than merely not re-applied.
    await pumpToProfile(tester, groups: [account()]);
    expect(fieldText(tester, 0), 'Nick');

    await tester.tap(find.byIcon(Icons.arrow_back));
    await settle(tester);
    await tester.enterText(find.byType(TextField).at(1), '2025550999');
    await settle(tester);
    await tester.tap(find.text('Continue'));
    await settle(tester);

    expect(fieldText(tester, 0), '');
    expect(fieldText(tester, 1), '');
    expect(note, findsNothing);
  });

  testWidgets('a birthday remembered from a previous signup fills in exactly', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'seen_selfhost_intro': true, 'signup_birthday': '1990-03-14'});

    await pumpToProfile(tester, groups: [account(birthdayMonth: 3, birthdayDay: 14)]);
    await tester.enterText(find.byType(TextField).at(3), 'hunter2hunter2');
    await settle(tester);

    expect(find.text('Pick your birthday'), findsNothing);
    expect(finishEnabled(tester), isTrue);
  });

  testWidgets('without a remembered year the picker is only seeded, never committed',
      (tester) async {
    // The API deliberately never returns a birth year, so the month and day alone can open
    // the picker on the right day but must not stand in for a date the user never entered.
    await pumpToProfile(tester, groups: [account(birthdayMonth: 3, birthdayDay: 14)]);
    await tester.enterText(find.byType(TextField).at(3), 'hunter2hunter2');
    await settle(tester);

    expect(find.text('Pick your birthday'), findsOneWidget);
    expect(finishEnabled(tester), isFalse);

    await tester.tap(find.text('Pick your birthday'));
    await settle(tester);
    final picker = tester.widget<CupertinoDatePicker>(find.byType(CupertinoDatePicker));
    expect(picker.initialDateTime.month, 3);
    expect(picker.initialDateTime.day, 14);
  });

  testWidgets('finishing signup remembers the birthday for the next group', (tester) async {
    // Nothing else on the device ever sees the full date again, so if this is not written
    // here the next join is back to scrolling for a year.
    SharedPreferences.setMockInitialValues(
        {'seen_selfhost_intro': true, 'signup_birthday': '1990-03-14'});

    await pumpToProfile(tester, groups: [account(birthdayMonth: 3, birthdayDay: 14)]);
    await tester.enterText(find.byType(TextField).at(3), 'hunter2hunter2');
    await settle(tester);
    await tester.tap(find.text('Finish'));
    await settle(tester);

    expect(find.text("You're all set"), findsOneWidget);
    expect(await lastSignupBirthday(), DateTime(1990, 3, 14));
  });
}

/// Answers the unauthenticated onboarding calls, the signup that follows, and - standing
/// in for the source group's server - the profile photo download.
class _FakeApi extends ApiClient {
  _FakeApi({this.downloadFails = false}) : super(baseUrl: 'https://fake.invalid');

  final bool downloadFails;
  int downloadCalls = 0;
  int? lastDownloadedId;

  @override
  Future<ServerInfo> serverInfo() async => ServerInfo(name: 'Beta', initialized: true);

  @override
  Future<({bool allowed, bool registered, bool isFirstAdmin})> checkPhone(String phone) async =>
      (allowed: true, registered: false, isFirstAdmin: false);

  @override
  Future<Uint8List> downloadMedia(int mediaId) async {
    downloadCalls++;
    lastDownloadedId = mediaId;
    if (downloadFails) throw Exception('source server unreachable');
    return Uint8List.fromList(kTransparentPixelPng);
  }

  @override
  Future<AuthResult> signup({
    required String phone,
    required String firstName,
    required String lastName,
    String? displayName,
    required String birthday,
    required String password,
    int? mediaId,
  }) async =>
      AuthResult(
        token: 't2',
        user: User(id: 2, name: '$firstName $lastName', phone: phone, isAdmin: false),
      );
}

/// A real 1x1 PNG: the profile step decodes whatever the source group returns, and a
/// handful of arbitrary bytes would fail to decode and log an exception.
const kTransparentPixelPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];
