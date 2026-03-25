// This is a basic Flutter widget test.

import 'package:flutter_test/flutter_test.dart';
import 'package:codified/main.dart';

void main() {
  testWidgets('App launches with splash screen', (WidgetTester tester) async {
    await tester.pumpWidget(const HRMSApp());

    // Verify that the splash screen is shown
    expect(find.text('BriskPeople'), findsOneWidget);
    expect(find.text('H R M S'), findsOneWidget);
  });
}

