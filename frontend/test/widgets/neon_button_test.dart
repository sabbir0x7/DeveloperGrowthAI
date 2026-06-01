import 'package:devgrowth_ai/shared/widgets/neon_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NeonButton', () {
    testWidgets('renders its label', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NeonButton(label: 'Run analysis', onPressed: () {}),
          ),
        ),
      );

      expect(find.text('Run analysis'), findsOneWidget);
    });

    testWidgets('invokes onPressed when enabled', (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NeonButton(label: 'Go', onPressed: () => taps++),
          ),
        ),
      );

      await tester.tap(find.byType(NeonButton));
      await tester.pump();

      expect(taps, 1);
    });

    testWidgets(
      'does not invoke onPressed while loading',
      (WidgetTester tester) async {
        int taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NeonButton(
                label: 'Loading',
                onPressed: () => taps++,
                isLoading: true,
              ),
            ),
          ),
        );

        // While loading, the label is replaced by a spinner.
        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        await tester.tap(find.byType(NeonButton));
        await tester.pump();
        expect(taps, 0);
      },
    );

    testWidgets(
      'disables itself when onPressed is null',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: NeonButton(label: 'Disabled', onPressed: null),
            ),
          ),
        );

        final OutlinedButton button =
            tester.widget<OutlinedButton>(find.byType(OutlinedButton));
        expect(button.onPressed, isNull);
      },
    );

    testWidgets(
      'shows a leading icon when provided',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NeonButton(
                label: 'Save',
                icon: Icons.save,
                onPressed: () {},
              ),
            ),
          ),
        );

        expect(find.byIcon(Icons.save), findsOneWidget);
      },
    );
  });
}
