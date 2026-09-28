import 'package:famio/src/design/theme.dart';
import 'package:famio/src/screens/security_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<String?> ask(WidgetTester tester, {String? error}) async {
    String? result = 'untouched';
    await tester.pumpWidget(
      MaterialApp(
        theme: famioTheme(Brightness.light),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                result = await askTwoFactorCode(context, error: error),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('returns the entered code', (tester) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: famioTheme(Brightness.light),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await askTwoFactorCode(context),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.text('Bestätigen'));
    await tester.pumpAndSettle();
    expect(result, '123456');
  });

  testWidgets('switches to recovery codes and shows errors', (tester) async {
    await ask(tester, error: 'Der Code stimmt nicht');
    expect(find.text('Der Code stimmt nicht'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Code'), findsOneWidget);
    await tester.tap(find.textContaining('Wiederherstellungscode'));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(TextField, 'Wiederherstellungscode'),
      findsOneWidget,
    );
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
}
