// Fills the Android home screen widget from local data and asks the
// launcher to pin it. The launcher's confirmations must be tapped from
// outside (adb/uiautomator); on the emulator image the launcher did not bind
// the widget while the app ran under instrumentation (2026-09-27).
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/home_widget/widget_sync.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_widget/home_widget.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('widget shows today', (tester) async {
    await initializeDateFormatting('de');
    final engine = SyncEngine(
      store: LocalStore.open(':memory:'),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    engine
      ..saveEvent(
        CalendarEvent(
          id: 'e',
          title: 'Fußballtraining',
          start: today.add(const Duration(hours: 23, minutes: 30)),
          end: today.add(const Duration(hours: 23, minutes: 59)),
        ),
      )
      ..saveMeal(
        PlannedMeal(
          id: 'm',
          date: today,
          slot: MealSlot.dinner,
          title: 'Pfannkuchen',
        ),
      )
      ..saveShoppingList(const ShoppingList(id: 'l', name: 'Einkauf'))
      ..saveShoppingItem(
        const ShoppingItem(id: 'i', listId: 'l', name: 'Milch'),
      )
      ..saveShoppingItem(
        const ShoppingItem(id: 'j', listId: 'l', name: 'Brot'),
      );
    HomeWidgetSync.attach(engine);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 4)),
    );
    expect(await HomeWidget.getWidgetData<String>('line1'), '🍽 Pfannkuchen');
    await HomeWidget.requestPinWidget(
      qualifiedAndroidName: 'de.status403.famio.FamioWidgetProvider',
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 90)),
    );
  });
}
