import 'package:famio/src/widgets/password_reveal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a password shows for a few seconds, then hides', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PasswordReveal(
            builder: (_, obscure, toggle) => TextField(
              obscureText: obscure,
              decoration: InputDecoration(suffixIcon: toggle),
            ),
          ),
        ),
      ),
    );
    bool obscured() =>
        tester.widget<TextField>(find.byType(TextField)).obscureText;

    expect(obscured(), isTrue);
    await tester.tap(find.byTooltip('Kurz anzeigen'));
    await tester.pump();
    expect(obscured(), isFalse);

    await tester.pump(PasswordReveal.visibleFor);
    expect(obscured(), isTrue);

    // Hidden again right away on request.
    await tester.tap(find.byTooltip('Kurz anzeigen'));
    await tester.pump();
    await tester.tap(find.byTooltip('Verbergen'));
    await tester.pump();
    expect(obscured(), isTrue);
  });
}
