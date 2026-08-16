import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/widgets/gif_picker.dart';

/// One recorded call to the fake search function: what query and page it was asked for.
typedef _Call = ({String query, int page});

GifResult _gif(String id) => GifResult(
      id: id,
      title: 'title-$id',
      previewUrl: 'https://static.klipy.invalid/$id.webp',
      previewWidth: 100,
      previewHeight: 100,
      gifUrl: 'https://static.klipy.invalid/$id.gif',
      width: 100,
      height: 100,
    );

void main() {
  Future<void> pumpPicker(WidgetTester tester, GifSearch search) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showGifPicker(context, search: search),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  // A bounded pump loop rather than pumpAndSettle: the tiles are real Image.network widgets
  // against an unresolvable host, whose retry/placeholder machinery never lets
  // pumpAndSettle's "no frames scheduled" condition become true.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('renders a grid of results from the search function on open', (tester) async {
    final calls = <_Call>[];
    Future<GifSearchPage> search(String q, int page) async {
      calls.add((query: q, page: page));
      return GifSearchPage(gifs: [_gif('a'), _gif('b'), _gif('c')], hasNext: false);
    }

    await pumpPicker(tester, search);
    await settle(tester);

    // Trending (empty query) is requested on open, before any typing.
    expect(calls, hasLength(1));
    expect(calls.single.query, '');
    expect(calls.single.page, 1);
    expect(find.byType(Image), findsNWidgets(3));
    expect(find.text('Powered by KLIPY'), findsOneWidget);
  });

  testWidgets('an empty trending result shows an empty state, not a blank sheet', (tester) async {
    Future<GifSearchPage> search(String q, int page) async =>
        const GifSearchPage(gifs: [], hasNext: false);
    await pumpPicker(tester, search);
    await settle(tester);
    expect(find.textContaining('No gifs'), findsOneWidget);
  });

  testWidgets('a failed load shows a retry, which asks again', (tester) async {
    var attempt = 0;
    Future<GifSearchPage> search(String q, int page) async {
      attempt++;
      if (attempt == 1) throw Exception('network down');
      return GifSearchPage(gifs: [_gif('a')], hasNext: false);
    }

    await pumpPicker(tester, search);
    await settle(tester);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.byType(Image), findsNothing);

    await tester.tap(find.text('Try again'));
    await settle(tester);
    expect(attempt, 2);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('typing debounces to exactly one search after the pause', (tester) async {
    final calls = <_Call>[];
    Future<GifSearchPage> search(String q, int page) async {
      calls.add((query: q, page: page));
      return const GifSearchPage(gifs: [], hasNext: false);
    }

    await pumpPicker(tester, search);
    await settle(tester);
    expect(calls, hasLength(1)); // the initial trending load

    // A normal typing cadence: each keystroke lands well inside the debounce window of the
    // one before it, so nothing should fire until the pause after the last keystroke.
    await tester.enterText(find.byType(TextField), 'c');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'ca');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'cat');
    await tester.pump(const Duration(milliseconds: 200)); // < 350ms since the last edit
    expect(calls, hasLength(1), reason: 'the debounce must not have fired yet');

    await tester.pump(kGifSearchDebounce + const Duration(milliseconds: 50));
    expect(calls, hasLength(2));
    expect(calls.last.query, 'cat');
    expect(calls.last.page, 1); // a new query always resets to page 1
  });

  testWidgets('scrolling near the bottom requests the next page once', (tester) async {
    final calls = <_Call>[];
    Future<GifSearchPage> search(String q, int page) async {
      calls.add((query: q, page: page));
      if (page == 1) {
        return GifSearchPage(gifs: [for (var i = 0; i < 20; i++) _gif('p1-$i')], hasNext: true);
      }
      return GifSearchPage(gifs: [for (var i = 0; i < 20; i++) _gif('p2-$i')], hasNext: false);
    }

    await pumpPicker(tester, search);
    await settle(tester);
    expect(calls, hasLength(1));

    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -4000));
    await settle(tester);

    final pageTwoCalls = calls.where((c) => c.page == 2);
    expect(pageTwoCalls, hasLength(1),
        reason: 'one drag past the trigger zone must fire exactly one next-page request');
    expect(find.byType(Image), findsNWidgets(40)); // both pages' tiles now in the grid
  });

  testWidgets('a picked tile pops the sheet with that result', (tester) async {
    final a = _gif('a');
    Future<GifSearchPage> search(String q, int page) async =>
        GifSearchPage(gifs: [a, _gif('b')], hasNext: false);

    GifResult? picked;
    var pending = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              pending = true;
              picked = await showGifPicker(context, search: search);
              pending = false;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await settle(tester);

    await tester.tap(find.byType(Image).first);
    await settle(tester);
    await tester.pumpAndSettle();

    expect(pending, isFalse);
    expect(picked?.id, a.id);
  });
}
