import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/features/onboarding/auth_screen.dart';
import 'package:checkin/features/onboarding/phone_field.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/widgets/app_widgets.dart';

/// The login form must describe its fields to the OS so a password manager (Face ID on iOS,
/// the Google/Samsung/1Password pickers on Android) can fill and save the credential. The
/// app never stores the password itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async => null);
    SharedPreferences.setMockInitialValues({'seen_selfhost_intro': true});
  });

  Iterable<String>? hintsOf(WidgetTester tester, Finder within) => tester
      .widget<TextField>(find.descendant(of: within, matching: find.byType(TextField)))
      .autofillHints;

  testWidgets('AppTextField and PhoneField pass their hints through to the text field',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          AppTextField(
            key: const Key('pw'),
            controller: TextEditingController(),
            hint: 'pw',
            obscure: true,
            autofillHints: const [AutofillHints.password],
          ),
          PhoneField(
            key: const Key('phone'),
            controller: TextEditingController(),
            country: kCountries.first,
            onCountryChanged: (_) {},
            autofillHints: const [AutofillHints.username],
          ),
        ]),
      ),
    ));

    expect(hintsOf(tester, find.byKey(const Key('pw'))), [AutofillHints.password]);
    expect(hintsOf(tester, find.byKey(const Key('phone'))), [AutofillHints.username]);
  });

  testWidgets('the auth screen keeps its fields in one AutofillGroup', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider
            .overrideWith(() => MultiSessionController.seeded(const MultiSession(restored: true))),
      ],
      child: const MaterialApp(home: AuthScreen()),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(AutofillGroup), findsWidgets);
    final phone = find.byType(PhoneField);
    expect(phone, findsOneWidget);
    expect(find.ancestor(of: phone, matching: find.byType(AutofillGroup)), findsWidgets);
  });
}
