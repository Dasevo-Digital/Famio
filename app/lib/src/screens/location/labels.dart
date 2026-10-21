import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../format.dart';
import '../../l10n.dart';

// Its own library, not a part of location_screens: the start page needs
// these lines, the map and the rest of "Wo ist wer?" load on first use.

/// After this long without a fresh fix a position counts as old.
const positionStaleAfter = Duration(minutes: 30);

/// After this long without any report the phone itself counts as silent,
/// and the label says so instead of naming a place: an iPhone lying still
/// reports nothing for hours, but rarely for a whole day – then Famio no
/// longer runs there (the server tells the adults after two days).
const deviceSilentAfter = Duration(hours: 24);

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
      if (deviceSilent(l, now)) {
        return tr.locationDeviceSilent(
          ago(l.lastContact ?? at, now: now),
          place == null ? '' : tr.locationDeviceSilentPlace(place.name),
        );
      }
      if (positionStale(l, now)) {
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
bool positionStale(MemberLocation l, DateTime now) =>
    l.at == null || now.difference(l.at!) >= positionStaleAfter;

/// Sharing is on, but the phone has not reported for [deviceSilentAfter].
bool deviceSilent(MemberLocation l, DateTime now) {
  final last = l.lastContact ?? l.at;
  return l.state == SharingState.active &&
      last != null &&
      now.difference(last) >= deviceSilentAfter;
}

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
