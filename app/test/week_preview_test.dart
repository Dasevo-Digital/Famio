import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/week_preview.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  SyncEngine newEngine() => SyncEngine(
    store: LocalStore.open(':memory:'),
    api: FamioApiClient('localhost:1'),
    memberId: 'papa',
  );

  final monday = DateTime(2026, 10, 12);

  CalendarEvent at(
    String id,
    String title,
    DateTime start, {
    List<String> who = const [],
    String? bringer,
  }) => CalendarEvent(
    id: id,
    title: title,
    start: start,
    end: start.add(const Duration(hours: 1)),
    memberIds: who,
    bringerId: bringer,
  );

  test('lists my week and my lifts, not the others\' appointments', () {
    final engine = newEngine()
      ..saveEvent(at('a', 'Elternabend', DateTime(2026, 10, 12, 19)))
      ..saveEvent(
        at(
          'b',
          'Training',
          DateTime(2026, 10, 14, 17),
          who: ['kind'],
          bringer: 'papa',
        ),
      )
      ..saveEvent(
        at('c', 'Friseur Mama', DateTime(2026, 10, 15, 10), who: ['mama']),
      )
      // Last week and next week stay out.
      ..saveEvent(at('d', 'Vorbei', DateTime(2026, 10, 11, 10)))
      ..saveEvent(at('e', 'Später', DateTime(2026, 10, 19, 10)));
    final p = buildWeekPreview(engine, monday)!;
    expect(p.title, 'Deine Woche: 2 Termine · 1 Fahrt');
    expect(p.lines, ['Mo 19:00 Elternabend', 'Mi 17:00 🚗 bringen: Training']);
  });

  test('a quiet week sends nothing, a busy one is shortened', () {
    final engine = newEngine();
    // No holiday region is set, so no holidays show up either.
    expect(buildWeekPreview(engine, monday), isNull);
    for (var i = 0; i < 10; i++) {
      engine.saveEvent(at('x$i', 'Termin $i', DateTime(2026, 10, 13, 8 + i)));
    }
    final p = buildWeekPreview(engine, monday)!;
    expect(p.lines, hasLength(WeekPreview.maxLines));
    expect(p.lines.last, '… und 3 weitere');
  });

  test('fires on Sundays at 18:00', () {
    final times = weekPreviewTimes(
      DateTime(2026, 10, 8, 12),
      DateTime(2026, 10, 22),
    ).toList();
    expect(times, [
      (DateTime(2026, 10, 11, 18), DateTime(2026, 10, 12)),
      (DateTime(2026, 10, 18, 18), DateTime(2026, 10, 19)),
    ]);
    // Sunday evening after 18:00: next week's.
    expect(
      weekPreviewTimes(
        DateTime(2026, 10, 11, 19),
        DateTime(2026, 10, 19),
      ).single.$1,
      DateTime(2026, 10, 18, 18),
    );
  });
}
