part of '../location_screens.dart';

/// "Bei „Schule“ seit 8:02", "Unterwegs · vor 5 Min." …
String sharingLabel(MemberLocation? l, Place? place, {DateTime? now}) {
  now ??= DateTime.now();
  if (l == null) return tr.locationNotSharingLocation;
  final time = DateFormat.jm(appLanguage);
  switch (l.state) {
    case SharingState.paused:
      final until = l.pausedUntil;
      if (until == null) return tr.locationPaused;
      return DateUtils.isSameDay(until, now)
          ? tr.locationPausedUntil(time.format(until))
          : tr.locationPausedUntil(
              DateFormat.E(appLanguage).add_jm().format(until),
            );
    case SharingState.denied:
      return tr.locationLocationAccessMissingPhone;
    case SharingState.off:
      return tr.locationLocationTurnedOffPhone2;
    case SharingState.scheduled:
      return tr.locationLocationSharingOffRight;
    case SharingState.active:
      final at = l.at;
      if (at == null) return tr.locationNoPositionYet;
      if (_positionStale(l, now)) {
        final suffix = place == null ? '' : ': „${place.name}“';
        return tr.locationLastLocationPlaceAgo(suffix, ago(at, now: now));
      }
      if (place != null) {
        return tr.locationPlaceSinceLastConfirmed(
          place.name,
          l.placeSince == null
              ? ''
              : tr.locationSinceTime(time.format(l.placeSince!)),
          ago(at, now: now),
        );
      }
      return tr.locationWayLastConfirmedAgo(ago(at, now: now));
  }
}

/// A heartbeat only proves that the phone reached the server. It must not
/// make an older measured coordinate appear current on the family map.
bool _positionStale(MemberLocation l, DateTime now) =>
    l.at == null || now.difference(l.at!) >= _stale;

String ago(DateTime t, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inMinutes < 2) return tr.agoJustNow;
  if (d.inMinutes < 60) return tr.agoAgo(tr.agoMinutes(d.inMinutes));
  if (d.inHours < 24) return tr.agoAgo(tr.agoHours(d.inHours));
  return DateFormat.Md(appLanguage).add_jm().format(t);
}

String scheduleLabel(LocationSchedule? schedule) {
  if (schedule == null) return tr.locationAlwaysShare;
  final names = weekdaysShort();
  final days = schedule.weekdays.map((day) => names[day - 1]).join(', ');
  String clock(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
  return tr.locationDays2(
    days,
    clock(schedule.startMinute),
    clock(schedule.endMinute),
  );
}
