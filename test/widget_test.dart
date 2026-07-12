// Smoke test for the desktop theme scaffold. The full app widget requires the
// service graph built in main(); the UI-agent pages will add their own tests.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wenlistener_desktop/theme/app_theme.dart';

void main() {
  testWidgets('AppTheme.dark builds an OLED dark theme', (
    WidgetTester tester,
  ) async {
    final ThemeData theme = AppTheme.dark();
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const Scaffold(body: Center(child: Text('WenListener'))),
      ),
    );
    expect(find.text('WenListener'), findsOneWidget);
    expect(theme.brightness, Brightness.dark);
  });
}
