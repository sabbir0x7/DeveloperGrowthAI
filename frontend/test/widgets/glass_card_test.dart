import 'package:devgrowth_ai/shared/widgets/glass_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GlassCard', () {
    testWidgets('renders its child', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: GlassCard(
              child: Text('hello-glass'),
            ),
          ),
        ),
      );

      expect(find.text('hello-glass'), findsOneWidget);
    });

    testWidgets(
      'wraps child in a BackdropFilter for the blurred backdrop',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: GlassCard(child: Text('x')),
            ),
          ),
        );

        expect(find.byType(BackdropFilter), findsOneWidget);
      },
    );

    testWidgets(
      'uses a translucent fill with non-zero, sub-opaque alpha',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: GlassCard(child: SizedBox(width: 10, height: 10)),
            ),
          ),
        );

        // Find the inner Container created by GlassCard. Use a lambda to skip
        // any Containers Flutter inserts internally (e.g. for Scaffold).
        final Iterable<Container> containers = tester
            .widgetList<Container>(find.byType(Container))
            .where((Container c) => c.decoration is BoxDecoration);

        // At least one container has a translucent fill.
        final bool hasTranslucentFill = containers.any((Container c) {
          final BoxDecoration d = c.decoration! as BoxDecoration;
          final Color? color = d.color;
          if (color == null) {
            return false;
          }
          final double a = color.a;
          return a > 0.0 && a < 1.0;
        });

        expect(hasTranslucentFill, isTrue);
      },
    );
  });
}
