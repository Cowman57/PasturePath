import 'package:flutter_test/flutter_test.dart';

import 'package:tractorgps/main.dart';

void main() {
  testWidgets('App loads with PasturePath title', (WidgetTester tester) async {
    await tester.pumpWidget(const TractorGPSApp());
    await tester.pump();

    expect(find.text('PasturePath'), findsOneWidget);
  });
}
