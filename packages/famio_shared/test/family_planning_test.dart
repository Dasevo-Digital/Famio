import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  test('ingredient lines are parsed and scaled', () {
    Ingredient p(String s) => Ingredient.parse(s);
    expect(p('200 g Mehl').amount, 200);
    expect(p('200 g Mehl').unit, 'g');
    expect(p('200 g Mehl').name, 'Mehl');
    expect(p('200g Mehl').unit, 'g');
    expect(p('1 1/2 EL Zucker').amount, 1.5);
    expect(p('1/2 TL Salz').amount, 0.5);
    expect(p('½ Zitrone').amount, 0.5);
    expect(p('½ Zitrone').name, 'Zitrone');
    expect(p('2½ Tassen Milch').amount, 2.5);
    expect(p('1,5 l Wasser').quantity(), '1,5 l');
    expect(p('2-3 Eier').amount, 2);
    expect(p('2 Eier').unit, '');
    expect(p('Salz und Pfeffer').amount, isNull);
    expect(p('Salz und Pfeffer').name, 'Salz und Pfeffer');
    expect(p('200 g Mehl').quantity(1.5), '300 g');
    expect(p('3 Eier').quantity(0.5), '1,5');
    expect(p('1 Prise Salz').toString(), '1 Prise Salz');
  });

  test('euro amounts', () {
    expect(formatEuro(123456), '1.234,56 €');
    expect(formatEuro(-5), '−0,05 €');
    expect(parseEuro('12,50'), 1250);
    expect(parseEuro('1.234,5'), 123450);
    expect(parseEuro('12.5'), 1250);
    expect(parseEuro('abc'), isNull);
  });

  test('monthly budget entries repeat until they end', () {
    final rent = BudgetEntry(
      id: 'r',
      date: DateTime(2026, 3, 1),
      cents: 90000,
      category: 'Wohnen',
      monthly: true,
      until: DateTime(2026, 8, 31),
    );
    expect(rent.inMonth(DateTime(2026, 2)), isFalse);
    expect(rent.inMonth(DateTime(2026, 3)), isTrue);
    expect(rent.inMonth(DateTime(2026, 8, 15)), isTrue);
    expect(rent.inMonth(DateTime(2026, 9)), isFalse);
    final back = BudgetEntry.fromRecord(
      SyncRecord(
        collection: Collections.budgetEntries,
        id: 'r',
        data: rent.toData(),
        updatedAt: 1,
      ),
    );
    expect(back.until, DateTime(2026, 8, 31));
    expect(back.monthly, isTrue);
  });

  test('timetable lessons and school end', () {
    var t = const Timetable(childId: 'c');
    t = t.withLesson(1, 0, 'Deutsch').withLesson(1, 3, 'Sport', 'Halle');
    expect(t.day(1).map((l) => l.subject), ['Deutsch', 'Sport']);
    expect(t.endOf(1), '11:30');
    expect(t.endOf(2), isNull);
    t = t.withLesson(1, 3, '');
    expect(t.endOf(1), '08:45');
    final back = Timetable.fromRecord(
      SyncRecord(
        collection: Collections.timetables,
        id: 'c',
        data: t.toData(),
        updatedAt: 1,
      ),
    );
    expect(back.lesson(1, 0)?.subject, 'Deutsch');
    expect(
      Timetable.fromRecord(
        SyncRecord(
          collection: Collections.timetables,
          id: 'x',
          data: const {},
          updatedAt: 1,
        ),
      ).periods,
      hasLength(8),
    );
  });
}
