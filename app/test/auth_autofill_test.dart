import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/onboarding/auth_screen.dart';
import 'package:checkin/features/onboarding/phone_field.dart';
import 'package:checkin/state/app_state.dart';

/// The auth forms must describe their fields to the OS so a password manager (Face ID on iOS,
/// the system picker on Android) can fill and save the credential, and must tell it when the
/// sign-in worked. The app never stores the password itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  // shouldSave true is what makes the OS offer to store the credential; the framework itself
  // sends a shouldSave false whenever a field loses focus.
  const saveAutofill = 'TextInput.finishAutofillContext true';

  // The test binding already owns the text-input channel and logs every call made on it.
  List<String> textInputCalls(WidgetTester tester) =>
      [for (final c in tester.testTextInput.log) '${c.method} ${c.arguments}'];

  setUp(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureChannel, (call) async => null);
    SharedPreferences.setMockInitialValues({'seen_selfhost_intro': true});
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpAuth(WidgetTester tester, _FakeApi api) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider
            .overrideWith(() => MultiSessionController.seeded(const MultiSession(restored: true))),
      ],
      child: MaterialApp(home: AuthScreen(clientFactory: (_, {token}) => api)),
    ));
    await settle(tester);
    await tester.enterText(find.byType(TextField).at(0), 'beta.invalid');
    await tester.enterText(find.byType(TextField).at(1), '2025550186');
    await settle(tester);
    await tester.tap(find.text('Continue'));
    await settle(tester);
  }

  Iterable<String>? hintsOf(WidgetTester tester, int fieldIndex) =>
      tester.widget<TextField>(find.byType(TextField).at(fieldIndex)).autofillHints;

  testWidgets(
      'login: phone is the username, password is the password, and success finishes '
      'the autofill context', (tester) async {
    await pumpAuth(tester, _FakeApi(registered: true));

    expect(find.byType(AutofillGroup), findsWidgets);
    expect(hintsOf(tester, 1), [AutofillHints.username]);
    expect(hintsOf(tester, 2), [AutofillHints.password]);
    expect(textInputCalls(tester), isNot(contains(saveAutofill)));

    await tester.enterText(find.byType(TextField).at(2), 'hunter2hunter2');
    await settle(tester);
    await tester.tap(find.text('Log in'));
    await settle(tester);

    expect(textInputCalls(tester), contains(saveAutofill));
  });

  testWidgets('a failed login does not finish the autofill context', (tester) async {
    await pumpAuth(tester, _FakeApi(registered: true, loginFails: true));
    await tester.enterText(find.byType(TextField).at(2), 'wrong-password');
    await settle(tester);
    await tester.tap(find.text('Log in'));
    await settle(tester);

    expect(textInputCalls(tester), isNot(contains(saveAutofill)));
  });

  testWidgets('signup: the new password is hinted as newPassword', (tester) async {
    await pumpAuth(tester, _FakeApi(registered: false));

    expect(find.text('Full name'), findsOneWidget); // reached the profile step
    final last = find.byType(TextField).evaluate().length - 1;
    expect(hintsOf(tester, last), [AutofillHints.newPassword]);
    expect(find.byType(PhoneField), findsNothing);
  });
}

class _FakeApi extends ApiClient {
  _FakeApi({required this.registered, this.loginFails = false})
      : super(baseUrl: 'https://fake.invalid');

  final bool registered;
  final bool loginFails;

  @override
  Future<ServerInfo> serverInfo() async => ServerInfo(name: 'Beta', initialized: true);

  @override
  Future<({bool allowed, bool registered, bool isFirstAdmin})> checkPhone(String phone) async =>
      (allowed: true, registered: registered, isFirstAdmin: false);

  @override
  Future<AuthResult> login({required String phone, required String password}) async {
    if (loginFails) {
      throw DioException(
        requestOptions: RequestOptions(path: '/api/auth/login'),
        response: Response(requestOptions: RequestOptions(path: ''), statusCode: 401),
      );
    }
    return AuthResult(
      token: 't',
      user: User(id: 2, name: 'Nick', phone: phone, isAdmin: false),
    );
  }
}
