import 'package:devgrowth_ai/shared/widgets/gradient_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GradientText', () {
    testWidgets('renders the supplied text', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: GradientText('DevGrowth'),
          ),
        ),
      );

      expect(find.text('DevGrowth'), findsOneWidget);
    });

    testWidgets(
      'wraps the text in a ShaderMask so the gradient is applied',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: GradientText('DevGrowth'),
            ),
          ),
        );

        expect(find.byType(ShaderMask), findsOneWidget);
      },
    );

    testWidgets(
      'forces white text color so the shader replaces glyph color',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: GradientText(
                'DevGrowth',
                style: TextStyle(color: Colors.red, fontSize: 24),
              ),
            ),
          ),
        );

        final Text text = tester.widget<Text>(find.text('DevGrowth'));
        expect(text.style?.color, Colors.white);
        // Other style properties are preserved.
        expect(text.style?.fontSize, 24);
      },
    );
  });
}
