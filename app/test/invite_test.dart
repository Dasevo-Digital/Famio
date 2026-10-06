import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('the sign-in screen offers joining with an invitation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mit Einladung beitreten'));
    await tester.pumpAndSettle();
    expect(find.text('Server'), findsOneWidget);
    expect(find.text('Code'), findsOneWidget);
    // Desktop tests have no camera: no scan button.
    expect(find.text('QR-Code scannen'), findsNothing);
  });
}
