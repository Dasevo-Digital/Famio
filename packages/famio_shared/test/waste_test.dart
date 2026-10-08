import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  test('recognises the bins in municipal wording', () {
    expect(WasteKind.of('Gelber Sack'), WasteKind.packaging);
    expect(WasteKind.of('Wertstofftonne'), WasteKind.packaging);
    expect(WasteKind.of('Altpapier (4-wöchentlich)'), WasteKind.paper);
    expect(WasteKind.of('Bioabfall'), WasteKind.organic);
    expect(WasteKind.of('Restabfall 120 l'), WasteKind.residual);
    expect(WasteKind.of('Restmüll'), WasteKind.residual);
    expect(WasteKind.of('Altglas'), WasteKind.glass);
    expect(WasteKind.of('Weihnachtsbaum-Abholung'), WasteKind.garden);
    expect(WasteKind.of('Sperrmüll'), WasteKind.bulky);
    expect(WasteKind.of('Schadstoffmobil'), WasteKind.hazardous);
    expect(WasteKind.of('Müllabfuhr'), WasteKind.other);
    // Not bins.
    expect(WasteKind.of('Forest Gump schauen'), isNull);
    expect(WasteKind.of('Elternabend'), isNull);
  });

  CalendarEvent day(String id, String title, DateTime d, {String? source}) =>
      CalendarEvent(
        id: id,
        title: title,
        start: d,
        end: DateTime(d.year, d.month, d.day + 1),
        allDay: true,
        sourceId: source,
      );

  List<Occurrence> occ(List<CalendarEvent> events) => [
    for (final e in events)
      ...e.occurrencesBetween(DateTime(2026, 10, 1), DateTime(2026, 11, 1)),
  ];

  test('groups a day\'s bins; keyword mode wants all-day events', () {
    final pickups = const WasteSettings().pickups(
      occ([
        day('a', 'Gelber Sack', DateTime(2026, 10, 13)),
        day('b', 'Altpapier', DateTime(2026, 10, 13)),
        day('c', 'Restmüll', DateTime(2026, 10, 20)),
        CalendarEvent(
          id: 'd',
          title: 'Bio-Markt einkaufen',
          start: DateTime(2026, 10, 14, 10),
          end: DateTime(2026, 10, 14, 11),
        ),
      ]),
    );
    expect(
      [for (final p in pickups) (p.day, p.label)],
      [
        (DateTime(2026, 10, 13), '🔵 Papier, 🟡 Gelbe Tonne'),
        (DateTime(2026, 10, 20), '⚫ Restmüll'),
      ],
    );
  });

  test('with a chosen calendar only its events count, whatever the title', () {
    final pickups = const WasteSettings(sourceId: 'abfall').pickups(
      occ([
        day('a', 'Tour 3', DateTime(2026, 10, 13), source: 'abfall'),
        day('b', 'Gelber Sack', DateTime(2026, 10, 14), source: 'schule'),
      ]),
    );
    expect(pickups.single.kinds, [WasteKind.other]);
    expect(pickups.single.titles, ['Tour 3']);
  });

  test('takes turns week by week', () {
    const s = WasteSettings(memberIds: ['papa', 'mama'], rotate: true);
    final a = s.responsibleFor(DateTime(2026, 10, 13));
    final sameWeek = s.responsibleFor(DateTime(2026, 10, 18));
    final next = s.responsibleFor(DateTime(2026, 10, 20));
    expect(a, sameWeek);
    expect(next, isNot(a));
    expect(
      const WasteSettings(
        memberIds: ['papa', 'mama'],
      ).responsibleFor(DateTime(2026, 10, 13)),
      ['papa', 'mama'],
    );
    final back = WasteSettings.fromRecord(
      SyncRecord(
        collection: Collections.wasteSettings,
        id: WasteSettings.recordId,
        data: s.toData(),
        updatedAt: 1,
      ),
    );
    expect(back.memberIds, ['papa', 'mama']);
    expect((back.rotate, back.remindHour), (true, 18));
  });
}
