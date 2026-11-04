import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/screens/connect_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('a German time can be typed in on a phone set to 12 hours', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.alwaysUse24HourFormatTestValue = false;
    addTearDown(tester.platformDispatcher.clearAlwaysUse24HourTestValue);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();

    final picked = showTimePicker(
      context: tester.element(find.byType(ConnectScreen)),
      initialTime: const TimeOfDay(hour: 7, minute: 0),
      initialEntryMode: TimePickerEntryMode.input,
    );
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), '16');
    await tester.pump();
    await tester.enterText(fields.at(1), '31');
    await tester.pump();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(await picked, const TimeOfDay(hour: 16, minute: 31));
  });
}
