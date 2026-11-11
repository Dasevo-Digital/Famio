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

  test('ranges and exact amounts read back the same (#401)', () {
    Ingredient p(String s) => Ingredient.parse(s);
    expect(p('2-3 Eier').upTo, 3);
    expect(p('2–3 Eier').quantity(), '2–3');
    expect(p('2–3 Eier').quantity(2), '4–6');
    expect(p('3-2 Eier').upTo, isNull);
    expect(p('1 ½–2 EL Öl').upTo, 2);
    for (final line in [
      '0,25 l Sahne',
      '12,5 g Hefe',
      '37,5 g Butter',
      '⅓ TL Zimt',
      '1 ⅔ Tassen Mehl',
      '0,125 l Weißwein',
      '2–3 Eier',
      '1 Prise Salz',
      'Salz und Pfeffer',
      '200 g Mehl',
    ]) {
      final i = p(line);
      expect(i.editText, line);
      expect(p(i.editText).toJson(), i.toJson(), reason: line);
    }
    expect(p('¼ l Sahne').editText, '0,25 l Sahne');
    expect(p('¼ l Sahne').scaled(1 / 3).exactQuantity(decimals: 2), '0,08 l');
    expect(Ingredient.fromJson(p('2-3 Eier').toJson()).upTo, 3);
  });

  test('shopping amounts add up without losing anything (#402)', () {
    Ingredient p(String s) => Ingredient.parse(s);
    expect(addQuantities('500 g', p('1 kg Mehl')), '1,5 kg');
    expect(addQuantities('1,5 kg', p('200 g Mehl')), '1,7 kg');
    expect(addQuantities('200 g', p('300 g Mehl')), '500 g');
    expect(addQuantities('1 kg', p('1 kg Mehl')), '2 kg');
    expect(addQuantities('0,25 l', p('125 ml Sahne')), '375 ml');
    expect(addQuantities('750 ml', p('0,5 l Milch')), '1,25 l');
    expect(addQuantities('2 EL', p('1 el Öl')), '3 el');
    expect(addQuantities('2', p('1 Zwiebeln')), '3');
    // Cannot be added up: the caller appends instead.
    expect(addQuantities('2 große', p('1 Zwiebeln')), isNull);
    expect(addQuantities('500 g + 1 kg', p('200 g Mehl')), isNull);
    expect(addQuantities('1 Packung', p('500 ml Milch')), isNull);
    expect(addQuantities('500 g', p('1 l Milch')), isNull);
    expect(addQuantities('2–3', p('1 Ei')), isNull);
    expect(addQuantities('2', p('1-2 Eier')), isNull);
    expect(addQuantities('', p('1 Ei')), isNull);
    expect(addQuantities('2', p('Salz')), isNull);
  });

  test('euro amounts', () {
    expect(formatEuro(123456), '1.234,56 €');
    expect(formatEuro(-5), '−0,05 €');
    expect(parseEuro('12,50'), 1250);
    expect(parseEuro('1.234,5'), 123450);
    expect(parseEuro('12.5'), 1250);
    // A dot before three digits groups thousands (#403).
    expect(parseEuro('1.500'), 150000);
    expect(parseEuro('2.000'), 200000);
    expect(parseEuro('1.234.567'), 123456700);
    expect(parseEuro('12.50'), 1250);
    expect(parseEuro('1.5'), 150);
    expect(parseEuro('1.500,00'), 150000);
    expect(parseEuro('1\u00a0500,00 €'), 150000);
    expect(parseEuro('1.50.0'), isNull);
    expect(parseEuro('abc'), isNull);
  });

  test('an appointment keeps its files, also in copies', () {
    const photo = FileRef(id: 'f1', name: 'a.jpg', mime: 'image/jpeg', size: 3);
    final event = CalendarEvent(
      id: 'e',
      title: 'Basar',
      start: DateTime(2026, 12, 12, 15),
      end: DateTime(2026, 12, 12, 16),
      files: const [photo],
    );
    final back = CalendarEvent.fromRecord(
      SyncRecord(
        collection: Collections.events,
        id: 'e',
        data: event.toData(),
        updatedAt: 1,
      ),
    );
    expect(back.files.single.id, 'f1');
    expect(event.withId('x').files, hasLength(1));
    expect(event.copyWith(title: 'Markt').files, hasLength(1));
    expect(
      recordFileIds(
        SyncRecord(
          collection: Collections.events,
          id: 'e',
          data: event.toData(),
          updatedAt: 1,
        ),
      ),
      ['f1'],
    );
    // Without files nothing is written.
    expect(event.copyWith(files: []).toData(), isNot(contains('files')));
  });

  group('salary paid late in the month', () {
    BudgetEntry salary(
      DateTime date, {
      String category = 'Gehalt',
      bool income = true,
      bool monthly = false,
      DateTime? until,
      bool? nextMonth,
    }) => BudgetEntry(
      id: 's',
      date: date,
      cents: 300000,
      category: category,
      income: income,
      monthly: monthly,
      until: until,
      nextMonth: nextMonth,
    );

    test('counts for the next month, across the year too', () {
      final october = salary(DateTime(2026, 10, 28));
      expect(october.inMonth(DateTime(2026, 10)), isFalse);
      expect(october.inMonth(DateTime(2026, 11, 20)), isTrue);
      expect(october.inMonth(DateTime(2026, 12)), isFalse);
      expect(october.paidIn(DateTime(2026, 10)), isTrue);
      final december = salary(DateTime(2026, 12, 30));
      expect(december.inMonth(DateTime(2027)), isTrue);
    });

    test('early salary and other money stay in their month', () {
      expect(salary(DateTime(2026, 11, 14)).countsNextMonth, isFalse);
      expect(salary(DateTime(2026, 11, 15)).countsNextMonth, isTrue);
      final benefit = salary(DateTime(2026, 11, 28), category: 'Kindergeld');
      expect(benefit.inMonth(DateTime(2026, 11)), isTrue);
      final refund = salary(DateTime(2026, 11, 28), income: false);
      expect(refund.inMonth(DateTime(2026, 11)), isTrue);
    });

    test('the entry can say otherwise, and keeps it', () {
      final same = salary(DateTime(2026, 10, 28), nextMonth: false);
      expect(same.inMonth(DateTime(2026, 10)), isTrue);
      final moved = salary(
        DateTime(2026, 10, 2),
        category: 'Kindergeld',
        nextMonth: true,
      );
      expect(moved.inMonth(DateTime(2026, 11)), isTrue);
      BudgetEntry again(BudgetEntry e) => BudgetEntry.fromRecord(
        SyncRecord(
          collection: Collections.budgetEntries,
          id: e.id,
          data: e.toData(),
          updatedAt: 1,
        ),
      );
      expect(again(same).nextMonth, isFalse);
      expect(again(moved).nextMonth, isTrue);
      expect(
        salary(DateTime(2026, 10, 28)).toData(),
        isNot(contains('nextMonth')),
      );
    });

    test('a monthly salary moves as a whole', () {
      final monthly = salary(
        DateTime(2026, 9, 28),
        monthly: true,
        until: DateTime(2026, 11, 30),
      );
      expect(monthly.inMonth(DateTime(2026, 9)), isFalse);
      expect(monthly.inMonth(DateTime(2026, 10)), isTrue);
      expect(monthly.inMonth(DateTime(2026, 12)), isTrue);
      expect(monthly.inMonth(DateTime(2027)), isFalse);
      expect(monthly.paidIn(DateTime(2026, 9)), isTrue);
      expect(monthly.paidIn(DateTime(2026, 12)), isFalse);
    });
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
