import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tractorgps/app_theme.dart';
import 'package:tractorgps/main.dart';

void main() {
  testWidgets('App boots with no debug banner', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(TractorGPSApp(themeController: ThemeController()));
    // Single pump only: MapScreen runs continuous animations, so
    // pumpAndSettle would never complete.
    await tester.pump();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.debugShowCheckedModeBanner, isFalse);
    expect(app.title, 'PasturePath V4');
    expect(app.themeMode, isNotNull);
  });
}
