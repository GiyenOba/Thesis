import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bt/main.dart';

void main() {
  testWidgets('Food Safety Monitor smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    // Verify app title
    expect(find.text('Food Safety Monitor'), findsOneWidget);
    
    // Verify tabs are present
    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('Gas Levels'), findsOneWidget);
    expect(find.text('Devices'), findsOneWidget);
    
    // Verify initial state
    expect(find.text('No sensors connected'), findsOneWidget);
    expect(find.text('Connect Devices'), findsOneWidget);
  });
}
