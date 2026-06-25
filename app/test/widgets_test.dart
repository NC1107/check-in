import 'package:checkin/widgets/app_widgets.dart';
import 'package:checkin/widgets/user_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  testWidgets('UserAvatar shows the name initial when there is no photo', (tester) async {
    await tester.pumpWidget(_wrap(const UserAvatar(name: 'Nick', size: 40)));
    expect(find.text('N'), findsOneWidget);
  });

  testWidgets('UserAvatar falls back to "?" for an empty name', (tester) async {
    await tester.pumpWidget(_wrap(const UserAvatar(name: '', size: 40)));
    expect(find.text('?'), findsOneWidget);
  });

  testWidgets('AppTextField renders its error text when set', (tester) async {
    final ctrl = TextEditingController();
    await tester.pumpWidget(_wrap(
      AppTextField(controller: ctrl, hint: 'Phone', errorText: 'Not on the invite list'),
    ));
    expect(find.text('Not on the invite list'), findsOneWidget);
  });

  testWidgets('AppTextField shows no error row when errorText is null', (tester) async {
    final ctrl = TextEditingController();
    await tester.pumpWidget(_wrap(AppTextField(controller: ctrl, hint: 'Phone')));
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  testWidgets('PrimaryButton shows a spinner while busy and is disabled', (tester) async {
    var tapped = false;
    await tester.pumpWidget(_wrap(
      PrimaryButton(label: 'Continue', enabled: false, busy: true, onTap: () => tapped = true),
    ));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byType(PrimaryButton));
    expect(tapped, isFalse);
  });
}
