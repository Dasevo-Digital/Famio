import 'package:famio/src/widgets/password_reveal.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a right click pastes into a password field', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => switch (call.method) {
        'Clipboard.getData' => {'text': 'geheim-123'},
        'Clipboard.hasStrings' => {'value': true},
        _ => null,
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PasswordReveal(
            builder: (_, obscure, toggle) => TextField(
              controller: controller,
              obscureText: obscure,
              contextMenuBuilder: PasswordReveal.contextMenu,
              decoration: InputDecoration(suffixIcon: toggle),
            ),
          ),
        ),
      ),
    );

    for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
      debugDefaultTargetPlatformOverride = platform;
      controller.clear();
      await tester.tap(
        find.byType(TextField),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.text('Einfügen'), findsOneWidget, reason: '$platform');
      await tester.tap(find.text('Einfügen'));
      await tester.pumpAndSettle();
      expect(controller.text, 'geheim-123', reason: '$platform');
      expect(find.text('Einfügen'), findsNothing);
      // Nothing to copy a password out with.
      expect(find.text('Kopieren'), findsNothing);
    }
    debugDefaultTargetPlatformOverride = null;
  });

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
