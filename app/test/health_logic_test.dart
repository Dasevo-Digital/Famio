import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/health_logic.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final child = Child(id: 'c1', name: 'Mia', birthDate: DateTime(2026, 8, 1));
  var n = 0;
  ChildLog log(
    LogKind kind,
    DateTime start, {
    DateTime? end,
    int? ml,
    BreastSide? side,
    DiaperKind? diaper,
    double? temp,
    String medication = '',
    double? interval,
  }) => ChildLog(
    id: 'l${n++}',
    childId: 'c1',
    kind: kind,
    start: start,
    end: end,
    amountMl: ml,
    side: side,
    diaper: diaper,
    temperatureC: temp,
    medication: medication,
    minIntervalHours: interval,
  );

  test('day summary splits sleep at midnight and counts feedings', () {
    final day = DateTime(2026, 9, 27);
    final logs = [
      log(
        LogKind.sleep,
        DateTime(2026, 9, 26, 22),
        end: DateTime(2026, 9, 27, 6),
      ),
      log(LogKind.bottle, DateTime(2026, 9, 27, 7), ml: 120),
      log(LogKind.bottle, DateTime(2026, 9, 27, 11), ml: 90),
      log(
        LogKind.breast,
        DateTime(2026, 9, 27, 14),
        end: DateTime(2026, 9, 27, 14, 15),
        side: BreastSide.left,
      ),
      log(LogKind.diaper, DateTime(2026, 9, 27, 8), diaper: DiaperKind.both),
      log(LogKind.diaper, DateTime(2026, 9, 27, 12), diaper: DiaperKind.wet),
      log(LogKind.temperature, DateTime(2026, 9, 27, 9), temp: 37.9),
      log(LogKind.temperature, DateTime(2026, 9, 27, 18), temp: 38.4),
      log(LogKind.bottle, DateTime(2026, 9, 28, 1), ml: 500), // next day
    ];
    final s = summarize(logs, day, DateTime(2026, 9, 27, 23));
    expect(s.sleep, const Duration(hours: 6));
    expect(s.milkMl, 210);
    expect(s.feedings, 3);
    expect(s.breast, const Duration(minutes: 15));
    expect(s.wet, 2);
    expect(s.dirty, 1);
    expect(s.maxTemperature, 38.4);
    // The night before gets its 2 hours.
    expect(
      summarize(logs, DateTime(2026, 9, 26), DateTime(2026, 9, 27, 23)).sleep,
      const Duration(hours: 2),
    );
  });

  test('a running sleep counts up to now', () {
    final logs = [log(LogKind.sleep, DateTime(2026, 9, 27, 13))];
    final s = summarize(
      logs,
      DateTime(2026, 9, 27),
      DateTime(2026, 9, 27, 14, 30),
    );
    expect(s.sleep, const Duration(minutes: 90));
  });

  test('next side and next dose', () {
    final logs = [
      log(
        LogKind.medication,
        DateTime(2026, 9, 27, 10),
        medication: 'Paracetamol Saft',
        interval: 6,
      ),
      log(LogKind.breast, DateTime(2026, 9, 27, 9), side: BreastSide.right),
      log(LogKind.breast, DateTime(2026, 9, 27, 6), side: BreastSide.left),
      log(
        LogKind.medication,
        DateTime(2026, 9, 27, 2),
        medication: 'paracetamol saft',
        interval: 6,
      ),
    ];
    expect(nextBreastSide(logs), BreastSide.left);
    expect(nextDoseAt(logs, 'Paracetamol saft'), DateTime(2026, 9, 27, 16));
    expect(nextDoseAt(logs, 'Ibuprofen'), isNull);
    expect(recentMedications(logs), hasLength(1));
  });

  test('fever advice depends on age and duration', () {
    final at = DateTime(2026, 9, 27);
    // 8 weeks old: 38.0 is urgent.
    expect(feverAdvice(child, 38.0, at: at).level, FeverLevel.urgent);
    final older = Child(id: 'c2', name: 'Ben', birthDate: DateTime(2023, 1, 1));
    expect(feverAdvice(older, 37.2, at: at).level, FeverLevel.normal);
    expect(feverAdvice(older, 37.8, at: at).level, FeverLevel.raised);
    expect(feverAdvice(older, 38.7, at: at).level, FeverLevel.fever);
    expect(feverAdvice(older, 40.1, at: at).level, FeverLevel.doctor);
    // Third day of fever: see the doctor.
    final days = [
      log(LogKind.temperature, DateTime(2026, 9, 25, 8), temp: 38.9),
      log(LogKind.temperature, DateTime(2026, 9, 26, 8), temp: 38.6),
    ];
    expect(
      feverAdvice(older, 38.6, at: at, logs: days).level,
      FeverLevel.doctor,
    );
  });

  test('logs share the guardians-only audience of the child', () {
    final engine = SyncEngine(
      store: LocalStore.open(':memory:'),
      api: FamioApiClient('localhost:1'),
      memberId: 'mama',
    );
    engine.saveChild(
      Child(
        id: 'c1',
        name: 'Mia',
        birthDate: DateTime(2026, 8, 1),
        guardianIds: const ['mama', 'papa'],
      ),
    );
    engine.saveChildLog(log(LogKind.bottle, DateTime(2026, 9, 27), ml: 100));
    final id = engine.childLogs('c1').single.id;
    expect(engine.record(Collections.childLogs, id)?.visibleTo, [
      'mama',
      'papa',
    ]);
    engine.saveChild(
      Child(
        id: 'c1',
        name: 'Mia',
        birthDate: DateTime(2026, 8, 1),
        guardianIds: const ['mama'],
      ),
    );
    expect(engine.record(Collections.childLogs, id)?.visibleTo, ['mama']);
    engine.deleteChild('c1');
    expect(engine.childLogs('c1'), isEmpty);
  });

  test('labels', () {
    expect(durationLabel(const Duration(minutes: 125)), '2 h 5 min');
    expect(durationLabel(const Duration(minutes: 12)), '12 min');
    expect(
      sinceLabel(DateTime(2026, 9, 27, 10), DateTime(2026, 9, 27, 12, 40)),
      'vor 2 h 40 min',
    );
  });
}
