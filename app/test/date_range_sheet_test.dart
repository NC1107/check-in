import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/widgets/date_range_sheet.dart';

void main() {
  // A single fully-selectable past month, so each day number appears exactly once and the
  // finders don't depend on today's date or which months the lazy list has built.
  final firstDate = DateTime(2025, 3, 1);
  final lastDate = DateTime(2025, 3, 31);

  // A tall surface so the whole sheet (calendar + footer) is laid out and tappable.
  void tallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<DateRangeChoice?> openAndPick(
      WidgetTester tester, Future<void> Function() interact) async {
    DateRangeChoice? result;
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }),
      ),
    ));
    final future =
        showDateRangeSheet(ctx, firstDate: firstDate, lastDate: lastDate).then((r) => result = r);
    await tester.pumpAndSettle();
    await interact();
    await future;
    return result;
  }

  testWidgets('Apply is disabled until both ends are chosen, then returns the range',
      (tester) async {
    tallSurface(tester);

    final choice = await openAndPick(tester, () async {
      final applyBefore = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Apply'));
      expect(applyBefore.onPressed, isNull);

      await tester.tap(find.text('5'));
      await tester.pump();
      await tester.tap(find.text('12'));
      await tester.pump();

      final applyAfter = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Apply'));
      expect(applyAfter.onPressed, isNotNull);
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
    });

    expect(choice, isA<PickRange>());
    final range = (choice as PickRange).range;
    expect(range.start, DateTime(2025, 3, 5));
    expect(range.end, DateTime(2025, 3, 12));
  });

  testWidgets('a second tap before the start reanchors instead of making an empty range',
      (tester) async {
    tallSurface(tester);

    final choice = await openAndPick(tester, () async {
      await tester.tap(find.text('20'));
      await tester.pump();
      await tester.tap(find.text('8')); // earlier than the start
      await tester.pump();
      // Still only a start; end not set, so Apply stays disabled.
      final apply = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Apply'));
      expect(apply.onPressed, isNull);
      // Now complete it with a later day.
      await tester.tap(find.text('15'));
      await tester.pump();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
    });

    final range = (choice as PickRange).range;
    expect(range.start, DateTime(2025, 3, 8));
    expect(range.end, DateTime(2025, 3, 15));
  });

  testWidgets('Clear returns ClearRange', (tester) async {
    tallSurface(tester);
    final choice = await openAndPick(tester, () async {
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
    });
    expect(choice, isA<ClearRange>());
  });
}
