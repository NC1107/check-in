import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/state/app_state.dart';
import 'package:checkin/theme/accent.dart';
import 'package:checkin/theme/accent_picker.dart';

/// The shared accent picker (used by both Appearance settings and signup profile setup).
/// Tapping a swatch updates the app-wide accent and persists it per-device.
void main() {
  testWidgets('tapping a swatch selects that accent and persists it', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: AccentPicker())),
      ),
    );
    await tester.pumpAndSettle();

    // Defaults to the first preset (green).
    expect(container.read(accentProvider).id, kAccentPresets.first.id);
    expect(find.text('Sky'), findsOneWidget);

    await tester.tap(find.text('Sky'));
    await tester.pumpAndSettle();
    expect(container.read(accentProvider).id, 'sky');

    // Persisted: a fresh controller restores the choice from storage.
    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    for (var i = 0; i < 50 && restored.read(accentProvider).id != 'sky'; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(restored.read(accentProvider).id, 'sky');
  });
}
