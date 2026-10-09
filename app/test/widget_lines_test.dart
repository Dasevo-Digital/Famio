import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/home_widget/widget_sync.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('home widget lines summarize today', () {
    final engine = SyncEngine(
      store: LocalStore.open(':memory:'),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    final now = DateTime(2026, 9, 28, 9);
    engine
      ..saveEvent(
        CalendarEvent(
          id: 'e',
          title: 'Fußballtraining',
          start: DateTime(2026, 9, 28, 17, 30),
          end: DateTime(2026, 9, 28, 19),
        ),
      )
      ..saveEvent(
        CalendarEvent(
          id: 'past',
          title: 'Frühstück',
          start: DateTime(2026, 9, 28, 7),
          end: DateTime(2026, 9, 28, 8),
        ),
      )
      ..saveMeal(
        PlannedMeal(
          id: 'm',
          date: DateTime(2026, 9, 28),
          slot: MealSlot.dinner,
          title: 'Pizza',
        ),
      )
      ..saveTask(Task(id: 't', title: 'Müll', due: DateTime(2026, 9, 28)))
      ..saveShoppingList(const ShoppingList(id: 'l', name: 'Einkauf'))
      ..saveShoppingItem(
        const ShoppingItem(id: 'i', listId: 'l', name: 'Milch'),
      )
      ..saveChild(Child(id: 'c', name: 'Emil', birthDate: DateTime(2026, 7, 1)))
      ..saveChildLog(
        ChildLog(
          id: 's',
          childId: 'c',
          kind: LogKind.sleep,
          start: DateTime(2026, 9, 28, 8, 15),
        ),
      );
    final (title, lines) = widgetLines(engine, now);
    expect(title, 'Famio · Mo., 28.9.');
    expect(lines, [
      '17:30 Fußballtraining',
      '🍽 Pizza',
      '✅ 1 Aufgabe heute',
      '🛒 1 Sache einkaufen',
      '🌙 Emil schläft seit 08:15',
    ]);
  });
}
