import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  group('chores', () {
    final monday = DateTime(2026, 9, 28);

    test('daily rotation takes turns on due days only', () {
      final chore = Chore(
        id: 'c',
        title: 'Tisch decken',
        memberIds: const ['a', 'b', 'c'],
        rotate: true,
        weekdays: const {1, 3, 5}, // Mo, Mi, Fr
        start: monday,
      );
      final turns = [
        for (var d = 0; d < 14; d++)
          if (chore.dueOn(monday.add(Duration(days: d))))
            chore.assigneeOn(monday.add(Duration(days: d))),
      ];
      expect(turns, ['a', 'b', 'c', 'a', 'b', 'c']);
      expect(chore.dueOn(monday.add(const Duration(days: 1))), isFalse);
      expect(chore.dueOn(monday.subtract(const Duration(days: 2))), isFalse);
    });

    test('weekly chores rotate per week and complete once per week', () {
      final chore = Chore(
        id: 'c',
        title: 'Bad putzen',
        memberIds: const ['a', 'b'],
        rotate: true,
        repeat: ChoreRepeat.weekly,
        start: monday.add(const Duration(days: 3)),
      );
      final thursday = monday.add(const Duration(days: 3));
      final sunday = monday.add(const Duration(days: 6));
      final nextWeek = monday.add(const Duration(days: 8));
      expect(chore.assigneeOn(thursday), 'a');
      expect(chore.assigneeOn(sunday), 'a');
      expect(chore.assigneeOn(nextWeek), 'b');
      expect(chore.completionId(thursday), chore.completionId(sunday));
      expect(chore.completionId(thursday), isNot(chore.completionId(nextWeek)));
      expect(chore.completionId(thursday).length, lessThanOrEqualTo(64));
    });

    test('without rotation, any listed member may do it', () {
      final chore = Chore(
        id: 'c',
        title: 'Müll',
        memberIds: const ['a', 'b'],
        start: monday,
      );
      expect(chore.assigneeOn(monday), isNull);
      expect(chore.isFor('a', monday), isTrue);
      expect(chore.isFor('x', monday), isFalse);
      final everyone = Chore(id: 'd', title: 'Blumen', start: monday);
      expect(everyone.isFor('x', monday), isTrue);
    });

    test('round-trips through records', () {
      final chore = Chore(
        id: 'c',
        title: 'Hund',
        emoji: '🐶',
        points: 3,
        memberIds: const ['a'],
        repeat: ChoreRepeat.once,
        date: monday,
        start: monday,
      );
      final back = Chore.fromRecord(
        SyncRecord(
          collection: Collections.chores,
          id: 'c',
          data: chore.toData(),
          updatedAt: 0,
        ),
      );
      expect(back.toData(), chore.toData());
      expect(back.dueOn(monday), isTrue);
      expect(back.dueOn(monday.add(const Duration(days: 1))), isFalse);
    });
  });

  test('allowance paydays start at since and repeat weekly', () {
    final a = Allowance(
      memberId: 'k',
      weeklyCents: 300,
      payday: DateTime.saturday,
      since: DateTime(2026, 9, 1), // Tuesday
    );
    final days = a.paydays(DateTime(2026, 8, 1), DateTime(2026, 9, 20)).toList();
    expect(days, [DateTime(2026, 9, 5), DateTime(2026, 9, 12), DateTime(2026, 9, 19)]);
    expect(a.bookingId(days.first), 'allow-k-2026-09-05');
  });

  group('medication', () {
    final m = Medication(
      id: 'm',
      name: 'Saft',
      times: const ['20:00', '08:00'],
      start: DateTime(2026, 9, 1),
      end: DateTime(2026, 9, 30),
      stock: 20,
      stockAt: DateTime(2026, 9, 1),
      perDose: 1,
    );

    test('doses per day within the plan', () {
      expect(m.dosesOn(DateTime(2026, 9, 10)), [
        DateTime(2026, 9, 10, 8),
        DateTime(2026, 9, 10, 20),
      ]);
      expect(m.dosesOn(DateTime(2026, 10, 1)), isEmpty);
      expect(m.dosesOn(DateTime(2026, 8, 31)), isEmpty);
    });

    test('stock lasts by the plan', () {
      expect(m.left(4), 16);
      expect(m.daysLeft(4), 8);
      final asNeeded = Medication(
        id: 'n',
        name: 'Nasenspray',
        start: _epoch,
        asNeeded: true,
        stock: 1,
      );
      expect(asNeeded.daysLeft(0), isNull);
      expect(asNeeded.dosesOn(DateTime(2026, 9, 10)), isEmpty);
    });

    test('keeps the audience of the carers', () {
      final data = Medication(
        id: 'm',
        name: 'X',
        start: DateTime(2026),
        careIds: const ['a'],
      ).toData();
      expect(data[SyncRecord.visibilityKey], ['a']);
    });
  });

  test('pantry: best-before and low stock', () {
    final item = PantryItem(
      id: 'p',
      name: 'Milch',
      amount: 1,
      minAmount: 2,
      bestBefore: DateTime(2026, 10, 2),
    );
    expect(item.low, isTrue);
    expect(item.daysLeft(DateTime(2026, 9, 30, 23)), 2);
    expect(item.amountLabel, '1');
    expect(item.copyWith(amount: 1.5, unit: 'l').amountLabel, '1,5 l');
  });

  test('polls survive the record round trip', () {
    final message = ChatMessage(
      id: 'x',
      chatId: ChatIds.family,
      authorId: 'a',
      sentAt: _epoch,
      poll: const Poll(
        question: 'Pizza oder Nudeln?',
        options: [
          PollOption(id: 'o0', text: 'Pizza'),
          PollOption(id: 'o1', text: 'Nudeln'),
        ],
      ),
    );
    final back = ChatMessage.fromRecord(
      SyncRecord(
        collection: Collections.chatMessages,
        id: 'x',
        data: message.toData(),
        updatedAt: 0,
      ),
    );
    expect(back.poll!.question, 'Pizza oder Nudeln?');
    expect(back.poll!.options.map((o) => o.text), ['Pizza', 'Nudeln']);
    expect(back.poll!.close().closed, isTrue);
    expect(PollVote.idFor('x' * 36, 'y' * 36).length, lessThanOrEqualTo(64));
  });
}

final _epoch = DateTime.utc(2026);
