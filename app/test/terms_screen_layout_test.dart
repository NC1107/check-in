import 'package:checkin/features/onboarding/terms_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The EULA screen gates the whole app and is the first thing App Review sees. An
// iPhone-only app still runs on iPad (in a compact compatibility window) and on short
// iPhones, so the screen must fit or scroll at small sizes - otherwise the "I agree"
// button clips off and the app looks broken (App Store Guideline 4).
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: TermsScreen())));
    await tester.pump();
  }

  for (final size in const [
    Size(320, 480), // iPhone-only app in the iPad compatibility window
    Size(320, 568), // iPhone SE
    Size(375, 667), // iPhone 8
  ]) {
    testWidgets('Terms screen does not overflow at $size', (tester) async {
      await pumpAt(tester, size);
      expect(tester.takeException(), isNull,
          reason: 'EULA content must fit or scroll at $size, not clip the agree button');
    });
  }
}
