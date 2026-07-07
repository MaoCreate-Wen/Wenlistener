import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenlistener/theme/app_theme.dart';
import 'package:wenlistener/widgets/placeholder_page.dart';

void main() {
  testWidgets('PlaceholderPage renders under the dark theme',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: const Scaffold(body: PlaceholderPage(title: 'Home')),
      ),
    );

    expect(find.byType(PlaceholderPage), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
  });
}
