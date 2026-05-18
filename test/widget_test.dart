import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smart_expense_agent/screens/login_screen.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Login screen renders header and Continue button',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.pump();

    expect(find.text('Smart Expense Agent'), findsOneWidget);
    expect(find.text('Company Code'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
  });

  testWidgets('Empty submission shows validation error',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.pump();

    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(find.text('Please enter your Company Code'), findsOneWidget);
  });

  testWidgets('Short code shows length validation error',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.pump();

    await tester.enterText(find.byType(TextFormField), 'AB');
    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(
      find.text('Company Code must be at least 4 characters'),
      findsOneWidget,
    );
  });
}
