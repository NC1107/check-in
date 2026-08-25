import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Driving a comment's Reply and Report the way a member reaches them.
///
/// Reply appears on the comment you tap, and only that one, so a test that reaches straight
/// for it would be exercising a state the app never puts on screen. The menu is always there
/// and needs no reveal - reporting has to be findable without knowing a comment can be
/// tapped at all.

/// Reveals [comment]'s controls by tapping it. Finds nothing else; use the helpers below.
Future<void> openCommentActions(WidgetTester tester, Finder comment) async {
  await tester.tap(comment);
  await tester.pump();
}

/// Taps Reply on the comment matching [comment], revealing its controls first.
Future<void> tapCommentReply(WidgetTester tester, Finder comment) async {
  await openCommentActions(tester, comment);
  // Only the open comment renders its controls, so there is exactly one of each on screen.
  await tester.tap(find.byIcon(Icons.reply_outlined));
  await tester.pump();
}

/// Opens the menu on the comment matching [comment] and picks Report. No reveal needed;
/// [comment] scopes the finder when a thread carries several menus.
Future<void> tapCommentReport(WidgetTester tester, Finder comment) async {
  final row = find.ancestor(of: comment, matching: find.byType(Row)).last;
  await tester.tap(find.descendant(of: row, matching: find.byIcon(Icons.more_horiz)));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Report comment'));
  await tester.pumpAndSettle();
}
