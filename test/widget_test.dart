import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Check if image appears', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Image(image: AssetImage('assets/startpage.png'))),
        ),
      ),
    );

    // Check image only
    expect(find.byType(Image), findsOneWidget);
  });
}
