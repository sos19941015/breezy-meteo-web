import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openmeteo_flutter_web/main.dart';

void main() {
  testWidgets('Weather app boots with header', (WidgetTester tester) async {
    await tester.pumpWidget(const WeatherApp(autoLocate: false));
    expect(find.text('Breezy-style Weather'), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
  });
}
