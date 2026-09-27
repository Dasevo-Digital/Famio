import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

SyncRecord _record(String collection, String id, Map<String, Object?> data) =>
    SyncRecord(collection: collection, id: id, data: data, updatedAt: 1);

void main() {
  test('child log round trip keeps times and details', () {
    final start = DateTime(2026, 9, 27, 14, 5);
    final log = ChildLog(
      id: 'l1',
      childId: 'c1',
      kind: LogKind.breast,
      start: start,
      side: BreastSide.right,
      remindAt: start.add(const Duration(hours: 3)),
      by: 'm1',
    );
    expect(log.running, isTrue);
    final back = ChildLog.fromRecord(
      _record(Collections.childLogs, 'l1', log.toData()),
    );
    expect(back.start, start);
    expect(back.side, BreastSide.right);
    expect(back.remindAt, start.add(const Duration(hours: 3)));
    expect(back.end, isNull);
    final done = back.copyWith(end: start.add(const Duration(minutes: 12)));
    expect(done.running, isFalse);
    expect(done.duration().inMinutes, 12);

    final fever = ChildLog.fromRecord(
      _record(Collections.childLogs, 'l2', {
        'childId': 'c1',
        'kind': 'temperature',
        'start': start.toUtc().toIso8601String(),
        'temperatureC': 38.6,
      }),
    );
    expect(fever.temperatureC, 38.6);
    expect(fever.duration(), Duration.zero);
  });

  test('emergency info and sex survive the child record', () {
    final child = Child(
      id: 'c1',
      name: 'Mia',
      birthDate: DateTime(2025, 3, 1),
      sex: ChildSex.female,
      emergency: const EmergencyInfo(
        allergies: 'Erdnüsse',
        bloodType: 'A+',
        doctorContactId: 'k1',
      ),
    );
    final back = Child.fromRecord(
      _record(Collections.children, 'c1', child.toData()),
    );
    expect(back.sex, ChildSex.female);
    expect(back.emergency.allergies, 'Erdnüsse');
    expect(back.emergency.doctorContactId, 'k1');
    expect(back.emergency.isEmpty, isFalse);
    // Older records without the fields.
    final old = Child.fromRecord(
      _record(Collections.children, 'c2', {
        'name': 'Ben',
        'birthDate': '2020-01-01',
      }),
    );
    expect(old.sex, isNull);
    expect(old.emergency.isEmpty, isTrue);
  });

  test('WHO references match the published percentiles', () {
    // Boys, weight at birth: P50 3.3464 kg, P97.7 (z=2) 4.4194 kg.
    final birth = growthReference(ChildSex.male, GrowthMeasure.weight, 0)!;
    expect(birth.valueAt(0), closeTo(3.3464, 1e-4));
    expect(birth.valueAt(2), closeTo(4.419354, 1e-3));
    expect(growthPercentile(birth, 3.3464), closeTo(50, 0.01));
    // Girls, head at 24 months: P50 47.1822 cm.
    final head = growthReference(ChildSex.female, GrowthMeasure.head, 24)!;
    expect(head.valueAt(0), closeTo(47.1822, 1e-4));
    // Between months it interpolates; beyond 24 months there is none.
    final mid = growthReference(ChildSex.male, GrowthMeasure.weight, 0.5)!;
    expect(mid.m, closeTo((3.3464 + 4.4709) / 2, 1e-4));
    expect(growthReference(ChildSex.male, GrowthMeasure.weight, 30), isNull);
  });

  test('contacts round trip', () {
    const c = FamilyContact(
      id: 'k1',
      name: 'Dr. Sommer',
      role: ContactRole.pediatrician,
      phone: '040 123',
      childIds: ['c1'],
    );
    final back = FamilyContact.fromRecord(
      _record(Collections.contacts, 'k1', c.toData()),
    );
    expect(back.role, ContactRole.pediatrician);
    expect(back.childIds, ['c1']);
  });

  test('pregnancy weeks count from 280 days before the due date', () {
    final p = Pregnancy(id: 'p', dueDate: DateTime(2027, 3, 15));
    expect(p.start, DateTime(2026, 6, 8));
    expect(p.weekOn(DateTime(2026, 6, 8)), (0, 0));
    // Across the end of daylight saving time (25 Oct 2026).
    expect(p.weekOn(DateTime(2026, 10, 26, 0, 30)), (20, 0));
    expect(p.weekOn(DateTime(2027, 3, 15)), (40, 0));
    expect(p.dayOf(24, 3), DateTime(2026, 11, 26));
    expect(pregnancyWeek(24)!.weightG, 600);
    expect(pregnancyWeek(45)!.week, 40);
    final back = Pregnancy.fromRecord(
      _record(
        Collections.pregnancies,
        'p',
        p
            .copyWith(
              done: {'us1'},
              contractions: [
                Contraction(
                  DateTime(2027, 3, 14, 3),
                  DateTime(2027, 3, 14, 3, 1),
                ),
                Contraction(DateTime(2027, 3, 14, 3, 6)),
              ],
            )
            .toData(),
      ),
    );
    expect(back.done, {'us1'});
    expect(back.contractions.first.length, const Duration(minutes: 1));
    expect(back.contractions.last.end, isNull);
  });
}
