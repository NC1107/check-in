import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/features/feed/compose_media_buttons.dart';

/// The composer's pick row. It used to vanish the moment a clip was attached, so the only
/// way back to a picker was the clip tile's small remove control. What is asserted here is
/// that the row survives an attached clip and that picking again replaces the clip on
/// purpose rather than silently.
void main() {
  late List<String> log;

  setUp(() => log = []);

  Widget host({required bool hasClip, bool hasPhotos = false}) => MaterialApp(
        home: Scaffold(
          body: ComposeMediaButtons(
            hasClip: hasClip,
            hasPhotos: hasPhotos,
            onGallery: () async => log.add('gallery'),
            onCamera: () async => log.add('camera'),
            onReplaceClip: () => log.add('cleared'),
          ),
        ),
      );

  testWidgets('the row is still there with a clip attached', (tester) async {
    await tester.pumpWidget(host(hasClip: true));

    expect(find.text('Gallery'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
  });

  testWidgets('replacing a clip asks first, then clears it before the picker opens',
      (tester) async {
    await tester.pumpWidget(host(hasClip: true));

    await tester.tap(find.text('Gallery'));
    await tester.pumpAndSettle();
    expect(find.text('Replace the current clip?'), findsOneWidget);
    expect(log, isEmpty); // nothing happens on the strength of the tap alone

    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();

    // Order matters: the old clip is gone before the new pick starts, so the composer is
    // never briefly holding both.
    expect(log, ['cleared', 'gallery']);
  });

  testWidgets('cancelling the confirm keeps the clip and opens nothing', (tester) async {
    await tester.pumpWidget(host(hasClip: true));

    await tester.tap(find.text('Camera'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(log, isEmpty);
  });

  testWidgets('the camera button asks the same question', (tester) async {
    await tester.pumpWidget(host(hasClip: true));

    await tester.tap(find.text('Camera'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();

    expect(log, ['cleared', 'camera']);
  });

  testWidgets('with photos attached the row keeps adding, no question asked', (tester) async {
    await tester.pumpWidget(host(hasClip: false, hasPhotos: true));

    expect(find.text('Add more'), findsOneWidget);
    await tester.tap(find.text('Add more'));
    await tester.pumpAndSettle();

    expect(find.text('Replace the current clip?'), findsNothing);
    expect(log, ['gallery']);
  });

  testWidgets('an empty composer picks straight away', (tester) async {
    await tester.pumpWidget(host(hasClip: false));

    await tester.tap(find.text('Gallery'));
    await tester.pumpAndSettle();

    expect(log, ['gallery']);
  });
}
