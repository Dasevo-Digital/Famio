// The filled "today" circle of the month grid is the family's today, as the
// "Heute" button picks it, also when the device is in another zone (KAL-008).
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as zones;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  setUpAll(zones.initializeTimeZones);

  testWidgets('the today circle sits on the family\'s today', (tester) async {
    // 25 hours apart: at any moment one of them has another date than the
    // device.
    final now = DateTime.now();
    final zone = ['Pacific/Kiritimati', 'Pacific/Pago_Pago'].firstWhere((z) {
      final there = tz.TZDateTime.now(tz.getLocation(z));
      return !DateUtils.isSameDay(
        DateTime(there.year, there.month, there.day),
        now,
      );
    });
    final there = tz.TZDateTime.now(tz.getLocation(zone));
    final familyToday = DateTime(there.year, there.month, there.day);

    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'tips.off': true});
    FlutterSecureStorage.setMockInitialValues({});
    const me = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
    final state = AppState();
    await state.init();
    final engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('familyTimeZone', zone),
      api: FamioApiClient('localhost:1'),
      memberId: me.id,
    );
    state
      ..me = me
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.tap(find.text('Kalender').first);
    await tester.pumpAndSettle();

    final circles = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).shape == BoxShape.circle &&
          w.constraints == const BoxConstraints.tightFor(width: 26, height: 26),
    );
    expect(circles, findsOneWidget);
    expect(
      find.descendant(of: circles, matching: find.text('${familyToday.day}')),
      findsOneWidget,
      reason: 'family today ${familyToday.day} in $zone, device ${now.day}',
    );
    await tester.pump(const Duration(seconds: 1));
  });
}
