import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/widgets/photo_viewer.dart';

/// A multi-image check-in's full-screen viewer must let the viewer swipe between every
/// photo on the post, not just the one they tapped into - that was the reported bug. A
/// single-photo context (e.g. a profile picture) must keep working exactly as before, with
/// no page counter cluttering the one-photo case.
void main() {
  final account = ServerAccount(
    id: 'alpha.invalid',
    baseUrl: 'https://alpha.invalid',
    serverName: 'Alpha',
    token: 't1',
    user: User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: false),
  );

  Future<void> pump(WidgetTester tester,
      {required List<int> mediaIds, int initialIndex = 0}) async {
    final controller =
        MultiSessionController.seeded(MultiSession(groups: [account], restored: true));
    await tester.pumpWidget(ProviderScope(
      overrides: [multiSessionProvider.overrideWith(() => controller)],
      child: MaterialApp(
        home: Builder(builder: (context) {
          return Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => PhotoViewerScreen.open(context,
                    mediaIds: mediaIds, initialIndex: initialIndex, groupId: 'alpha.invalid'),
                child: const Text('open'),
              ),
            ),
          );
        }),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump(); // let the route animation start
    await tester.pump(const Duration(milliseconds: 200)); // and finish
  }

  // A bounded pump loop rather than pumpAndSettle(): the photo's own image is a real
  // network image against an unresolvable .invalid host, whose placeholder spinner
  // animates indefinitely and never lets pumpAndSettle's "no frames scheduled" condition
  // become true, even once the page/drag animation itself has long since finished.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('a single photo shows no page counter', (tester) async {
    await pump(tester, mediaIds: [7]);
    expect(find.textContaining('/'), findsNothing);
  });

  testWidgets('multiple photos show a counter and open on the tapped one', (tester) async {
    await pump(tester, mediaIds: [7, 8, 9], initialIndex: 1);
    expect(find.text('2/3'), findsOneWidget);
  });

  testWidgets('swiping left pages to the next photo and updates the counter', (tester) async {
    await pump(tester, mediaIds: [7, 8, 9]);
    expect(find.text('1/3'), findsOneWidget);

    await tester.fling(find.byType(PageView), const Offset(-400, 0), 800);
    await settle(tester);

    expect(find.text('2/3'), findsOneWidget);
  });

  testWidgets('swiping down past the dismiss threshold closes the viewer', (tester) async {
    await pump(tester, mediaIds: [7, 8]);
    expect(find.byType(PhotoViewerScreen), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(0, 400));
    await settle(tester);

    expect(find.byType(PhotoViewerScreen), findsNothing);
  });
}
