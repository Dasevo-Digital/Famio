part of '../api.dart';

/// What is up in the family today, worked out as the apps do: today's
/// chores and whose turn they are, the next bin pickups and the countdowns.
/// For Home Assistant and other dashboards that only read.
extension _OverviewRoutes on FamioApi {
  Response _familyOverview(Request request) {
    final member = _auth(request);
    final now = tz.TZDateTime.now(location);
    final today = DateTime(now.year, now.month, now.day);
    String day(DateTime d) => dayKey(d);
    Iterable<SyncRecord> visible(String collection) =>
        records.all(collection, visibleToMember: member.id);

    // --- chores ---------------------------------------------------------
    final chores = [
      for (final r in visible(Collections.chores)) Chore.fromRecord(r),
    ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    PointEntry? completion(Chore c) {
      final r = records.get(Collections.pointEntries, c.completionId(today));
      if (r == null || r.deleted || !RecordStore.canSee(r, member.id)) {
        return null;
      }
      final entry = PointEntry.fromRecord(r);
      return entry.status == PointStatus.rejected ? null : entry;
    }

    // --- bins -----------------------------------------------------------
    final wasteRecord = records.get(
      Collections.wasteSettings,
      WasteSettings.recordId,
    );
    final waste =
        wasteRecord == null ||
            wasteRecord.deleted ||
            !RecordStore.canSee(wasteRecord, member.id)
        ? null
        : WasteSettings.fromRecord(wasteRecord);
    final adults = [
      for (final m in accounts.members())
        if (m.isAdult) m.id,
    ];
    final pickups = waste == null
        ? const <WastePickup>[]
        : waste
              .pickups([
                for (final collection in [
                  Collections.events,
                  Collections.externalEvents,
                ])
                  for (final r in visible(collection))
                    ...CalendarEvent.fromRecord(r).occurrencesBetween(
                      today,
                      today.add(const Duration(days: 60)),
                    ),
              ])
              .take(5)
              .toList();

    // --- countdowns -----------------------------------------------------
    final countdowns = <(int, DateTime, Map<String, Object?>)>[];
    for (final r in visible(Collections.events)) {
      final event = CalendarEvent.fromRecord(r);
      if (!event.countdown) continue;
      final next = event
          .occurrencesBetween(now, today.add(const Duration(days: 366)))
          .firstOrNull;
      if (next == null) continue;
      final days = daysBetween(today, next.start);
      countdowns.add((
        days < 0 ? 0 : days,
        next.start,
        {
          'id': event.id,
          'title': event.confidential ? t('Belegt') : event.title,
          'allDay': event.allDay,
          'start': event.allDay
              ? day(next.start)
              : next.start.toUtc().toIso8601String(),
          'days': days < 0 ? 0 : days,
          // A several-day event that has begun (the holiday week).
          'running': next.start.isBefore(today),
        },
      ));
    }
    countdowns.sort((a, b) {
      final byDays = a.$1.compareTo(b.$1);
      return byDays != 0 ? byDays : a.$2.compareTo(b.$2);
    });

    return _json({
      'today': day(today),
      'chores': [
        for (final c in chores)
          if (c.dueOn(today))
            {
              'id': c.id,
              'title': c.title,
              'emoji': c.emoji,
              'points': c.points,
              'repeat': c.repeat.name,
              'memberIds': c.memberIds,
              'assigneeId': c.assigneeOn(today),
              ...switch (completion(c)) {
                null => {'done': false},
                final e => {
                  'done': true,
                  'doneBy': e.memberId,
                  if (e.status == PointStatus.pending) 'pending': true,
                },
              },
            },
      ],
      'waste': [
        for (final p in pickups)
          {
            'day': day(p.day),
            'days': daysBetween(today, p.day),
            'kinds': [for (final k in p.kinds) k.name],
            'labels': [for (final k in p.kinds) k.label],
            'label': p.label,
            'titles': p.titles,
            'memberIds': switch (waste!.responsibleFor(p.day)) {
              final ids when ids.isEmpty => adults,
              final ids => ids,
            },
          },
      ],
      'countdowns': [for (final c in countdowns) c.$3],
    });
  }
}
