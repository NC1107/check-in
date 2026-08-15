import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/state/app_state.dart';

/// Signup offers the accent picker on a device's first-ever signup and never again: the
/// accent is a single per-device theme, so a later group join must leave it alone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a fresh device is asked', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await shouldPromptForAccent(hasGroups: false), isTrue);
  });

  test('a device that already stored an accent is not asked', () async {
    SharedPreferences.setMockInitialValues({'accent_id': 'sky'});
    expect(await shouldPromptForAccent(hasGroups: false), isFalse);
  });

  test('an established device is not asked, even with no accent stored', () async {
    // Signed up once and skipped the swatches, or logged in to an existing account.
    SharedPreferences.setMockInitialValues({});
    expect(await shouldPromptForAccent(hasGroups: true), isFalse);
  });

  test('an established device with an accent is not asked', () async {
    SharedPreferences.setMockInitialValues({'accent_id': 'sky'});
    expect(await shouldPromptForAccent(hasGroups: true), isFalse);
  });
}
