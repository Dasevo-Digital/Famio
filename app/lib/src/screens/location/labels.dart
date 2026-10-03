part of '../location_screens.dart';

/// "Bei „Schule“ seit 8:02", "Unterwegs · vor 5 Min." …
String sharingLabel(MemberLocation? l, Place? place, {DateTime? now}) {
  now ??= DateTime.now();
  if (l == null) return 'Teilt keinen Standort';
  final time = DateFormat('HH:mm', 'de');
  switch (l.state) {
    case SharingState.paused:
      final until = l.pausedUntil;
      if (until == null) return 'Pausiert';
      return DateUtils.isSameDay(until, now)
          ? 'Pausiert bis ${time.format(until)} Uhr'
          : 'Pausiert bis ${DateFormat('E, HH:mm', 'de').format(until)} Uhr';
    case SharingState.denied:
      return 'Standortzugriff auf dem Handy fehlt';
    case SharingState.off:
      return 'Standort am Handy ausgeschaltet';
    case SharingState.scheduled:
      return 'Standortfreigabe ist nach Zeitplan gerade aus';
    case SharingState.active:
      final at = l.at;
      if (at == null) return 'Noch keine Position';
      if (_positionStale(l, now)) {
        final suffix = place == null ? '' : ': „${place.name}“';
        return 'Letzter Standort$suffix · ${ago(at, now: now)} · möglicherweise veraltet';
      }
      if (place != null) {
        return 'Bei „${place.name}“'
            '${l.placeSince == null ? '' : ' seit ${time.format(l.placeSince!)}'}'
            ' · zuletzt bestätigt ${ago(at, now: now)}';
      }
      return 'Unterwegs · zuletzt bestätigt ${ago(at, now: now)}';
  }
}

/// A heartbeat only proves that the phone reached the server. It must not
/// make an older measured coordinate appear current on the family map.
bool _positionStale(MemberLocation l, DateTime now) =>
    l.at == null || now.difference(l.at!) >= _stale;

String ago(DateTime t, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inMinutes < 2) return 'gerade eben';
  if (d.inMinutes < 60) return 'vor ${d.inMinutes} Min.';
  if (d.inHours < 24) return 'vor ${d.inHours} Std.';
  return DateFormat('d.M., HH:mm', 'de').format(t);
}

String scheduleLabel(LocationSchedule? schedule) {
  if (schedule == null) return 'Immer teilen';
  const names = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
  final days = schedule.weekdays.map((day) => names[day - 1]).join(', ');
  String clock(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
  return '$days · ${clock(schedule.startMinute)}–${clock(schedule.endMinute)} Uhr';
}
