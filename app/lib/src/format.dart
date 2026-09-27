import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// "Heute", "Morgen", "Gestern" or e.g. "Fr, 2. Okt." (with year if not
/// the current one).
String dayLabel(DateTime day) {
  final today = DateUtils.dateOnly(DateTime.now());
  final diff = DateUtils.dateOnly(day).difference(today).inDays;
  return switch (diff) {
    0 => 'Heute',
    1 => 'Morgen',
    -1 => 'Gestern',
    _ when day.year == today.year => DateFormat('E, d. MMM', 'de').format(day),
    _ => DateFormat('E, d. MMM y', 'de').format(day),
  };
}

String timeLabel(DateTime t) => DateFormat.Hm('de').format(t);

String dateTimeLabel(DateTime t) => '${dayLabel(t)}, ${timeLabel(t)}';
