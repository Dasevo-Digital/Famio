import 'package:famio/src/data/country.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/health_logic.dart';
import 'package:famio/src/data/holidays.dart';
import 'package:famio/src/data/kids_logic.dart';
import 'package:famio/src/screens/kids_emergency_screens.dart';
import 'package:famio/src/reminders/reminder_service.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

const _members = '[{"id":"m1","username":"mama","displayName":"Mama"}]';

SyncEngine _engine() => SyncEngine(
  store: LocalStore.open(':memory:')..setMeta('members', _members),
  api: FamioApiClient('localhost:1'),
  memberId: 'm1',
);

/// Austria and Switzerland follow other check-up, vaccination and
/// maternity rules: Famio shows no German windows there (#586).
void main() {
  setUpAll(() => initializeDateFormatting('de'));
  tearDown(() {
    familyCountry = FamilyCountry.de;
    familyHolidayRegion = null;
  });

  final lena = Child(
    id: 'c',
    name: 'Lena',
    birthDate: DateTime(2025, 6, 15),
    guardianIds: const ['m1'],
  );
  final at = DateTime(2025, 10, 1); // 3.5 months old
  final done = ChildEntry(
    id: 'e1',
    childId: 'c',
    kind: ChildEntryKind.checkup,
    refId: 'U3',
    date: DateTime(2025, 7, 20),
  );
  final booked = ChildEntry(
    id: 'e2',
    childId: 'c',
    kind: ChildEntryKind.vaccination,
    refId: vaccinations.first.id,
    date: DateTime(2025, 10, 8),
    planned: true,
  );

  test('in Germany the booklet windows apply as before', () {
    final states = {
      for (final d in checkupPlan(lena, const [], at)) d.state,
      for (final d in vaccinationPlan(lena, const [], at)) d.state,
    };
    expect(states, containsAll([DueState.due, DueState.upcoming]));
    expect(states, isNot(contains(DueState.unscheduled)));
  });

  for (final country in [FamilyCountry.at, FamilyCountry.ch]) {
    test('${country.code}: no German windows, records stay', () {
      familyCountry = country;
      final ups = checkupPlan(lena, [done], at);
      final vacs = vaccinationPlan(lena, [booked], at);
      for (final d in [...ups, ...vacs]) {
        if (d.entry == null) {
          expect(d.state, DueState.unscheduled, reason: d.id);
          expect(d.open, isFalse, reason: d.id);
          expect(d.tooLate, isFalse, reason: '${d.id} can be recorded');
        }
      }
      expect(ups.firstWhere((d) => d.id == 'U3').state, DueState.done);
      expect(
        vacs.firstWhere((d) => d.id == booked.refId).state,
        DueState.planned,
      );
      // Only the booked appointment is "next".
      expect(nextDue(lena, [done], at), isNull);
      expect(nextDue(lena, [done, booked], at)?.id, booked.refId);
    });

    test('${country.code}: reminders only for booked appointments', () {
      familyCountry = country;
      final engine = _engine()
        ..saveChild(lena)
        ..saveChildEntry(booked);
      final keys = [
        for (final r in familyReminders(
          engine,
          from: DateTime(2025, 9, 1),
          to: DateTime(2026, 9, 1),
        ))
          if (r.key.startsWith('kid:c:')) r.key,
      ];
      expect(keys, isNotEmpty);
      expect(keys.every((k) => k.contains(':appt')), isTrue, reason: '$keys');
    });

    test('${country.code}: pregnancy without German screenings', () {
      familyCountry = country;
      final ids = {for (final t in localPregnancyTasks) t.id};
      expect(ids, containsAll(['midwife', 'clinic', 'bag']));
      expect(ids, contains('pediatrician.other'));
      for (final german in [
        'us1',
        'us2',
        'us3',
        'ogtt',
        'pertussis',
        'maternity',
        'pediatrician',
      ]) {
        expect(ids, isNot(contains(german)));
      }
      final after = pregnancyChecklists.firstWhere((l) => l.id == 'after');
      final items = {for (final i in localChecklistItems(after)) i.id};
      expect(items, isNot(contains('after.parentalbenefit')));
      expect(items, isNot(contains('after.u2')));
      expect(items, containsAll(['after.midwife', 'after.registry.other']));

      final p = Pregnancy(id: 'p', dueDate: DateTime(2027, 3, 15));
      final engine = _engine()..savePregnancy(p);
      final keys = {
        for (final r in familyReminders(
          engine,
          from: DateTime(2026, 7, 1),
          to: DateTime(2027, 4, 1),
        ))
          r.key,
      };
      expect(keys, isNot(contains('preg:p:leave')));
      expect(keys, isNot(contains('preg:p:us2')));
      expect(keys, contains('preg:p:clinic'));
    });
  }

  test('emergency numbers of each country', () {
    List<String?> dials() => [for (final n in emergencyNumbers) n.dial];
    expect(dials(), ['112', '116117', '03019240']);
    familyCountry = FamilyCountry.at;
    expect(dials(), ['144', '1450', '141', '+4314064343']);
    expect(emergencyNumbers.first.title, startsWith('144'));
    familyCountry = FamilyCountry.ch;
    // The Swiss doctors' service has no single number.
    expect(dials(), ['144', '145', null]);
  });

  test('fever hints name the numbers of the family\'s country', () {
    final baby = Child(id: 'b', name: 'Ben', birthDate: DateTime(2026, 10, 1));
    final at = DateTime(2026, 11, 1);
    String hint(double celsius) => feverAdvice(baby, celsius, at: at).text;
    expect(hint(41.2), contains('116 117'));
    familyCountry = FamilyCountry.at;
    for (final c in [41.2, 38.2, 34.5]) {
      expect(hint(c), isNot(contains('116 117')), reason: '$c');
      expect(hint(c), contains('1450'), reason: '$c');
    }
    familyCountry = FamilyCountry.ch;
    for (final c in [41.2, 38.2, 34.5]) {
      expect(hint(c), isNot(contains('116 117')), reason: '$c');
      expect(hint(c), contains('Notfalldienst'), reason: '$c');
    }
  });

  test('Germany keeps its pregnancy reminders', () {
    final p = Pregnancy(id: 'p', dueDate: DateTime(2027, 3, 15));
    final engine = _engine()..savePregnancy(p);
    final keys = {
      for (final r in familyReminders(
        engine,
        from: DateTime(2026, 7, 1),
        to: DateTime(2027, 4, 1),
      ))
        r.key,
    };
    expect(keys, containsAll(['preg:p:leave', 'preg:p:us2']));
    expect(keys, isNot(contains('preg:p:pediatrician.other')));
  });
}
