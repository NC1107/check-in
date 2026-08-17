import 'package:checkin/features/feed/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The trim sheet was the last thing App Review rejected the app for (Guideline 4): its
/// non-scrolling Column overflowed at a small width and pushed the primary button off
/// screen. This checks the sheet at the sizes and text scales that tripped that bug, and -
/// the part presence-only coverage would have missed - that the Trim button is actually
/// inside the visible screen and reachable by a tap, not merely present in the widget tree.
void main() {
  const sizes = [
    Size(320, 480), // iPhone-only app in the iPad compatibility window
    Size(320, 568), // iPhone SE
    Size(375, 667), // iPhone 8
  ];
  const textScales = [1.0, 1.3, 1.6];

  /// Opens the real trim flow (isScrollControlled, same as [HomeShell]'s own
  /// `_openTrimSheet`) for a 45s clip - well over the 10s cap - at [size]/[textScale]. No
  /// video plugin is registered in a widget test, so the sheet falls into its "no player"
  /// placeholder path; the layout under test doesn't depend on which path renders.
  Future<void> openTrimSheet(WidgetTester tester, Size size, double textScale) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showModalBottomSheet<({int startMs, int endMs})>(
                context: context,
                isScrollControlled: true,
                builder: (_) => const TrimSheet(path: 'fake.mp4', durationMs: 45000),
              ),
              child: const Text('open trim sheet'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open trim sheet'));
    await tester.pumpAndSettle();
  }

  for (final size in sizes) {
    for (final scale in textScales) {
      testWidgets('trim sheet fits at $size, textScale $scale', (tester) async {
        await openTrimSheet(tester, size, scale);

        expect(tester.takeException(), isNull,
            reason: 'trim sheet must fit or scroll at $size / $scale, not overflow');

        final trimButton = find.widgetWithText(TextButton, 'Trim');
        expect(trimButton, findsOneWidget);

        // Present in the tree is not enough - the last rejection was exactly a button still
        // in the tree but laid out past the bottom of the visible screen. Its rect must sit
        // fully inside the screen the sheet is being shown on.
        final rect = tester.getRect(trimButton);
        final screen = Offset.zero & size;
        expect(screen.contains(rect.topLeft) && screen.contains(rect.bottomRight), isTrue,
            reason: 'Trim button $rect must be fully on screen $screen, not pushed off it');

        // And it must actually be reachable: tapping it should hit the real button and pop
        // the sheet, not land on a rect with nothing behind it.
        await tester.tap(trimButton);
        await tester.pumpAndSettle();
        expect(find.byType(TrimSheet), findsNothing,
            reason: 'tapping Trim at its on-screen position must close the sheet');
      });
    }
  }
}
