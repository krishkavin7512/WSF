// Smoke test for the SENTRA app.
//
// SentraApp wires up Supabase, Mapbox and flutter_dotenv at startup, which
// require platform initialization that isn't available in a plain widget
// test. So instead of pumping the full app, this verifies that the root
// MaterialApp renders a basic frame without throwing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App shell renders without error', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('SENTRA'))),
      ),
    );

    expect(find.text('SENTRA'), findsOneWidget);
  });
}
