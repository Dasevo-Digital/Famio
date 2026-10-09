import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'l10n.dart';

/// "Heute", "Morgen", "Gestern" or e.g. "Fr, 2. Okt." (with year if not
/// the current one).
String dayLabel(DateTime day) {
  final today = DateUtils.dateOnly(DateTime.now());
  final diff = DateUtils.dateOnly(day).difference(today).inDays;
  return switch (diff) {
    0 => tr.commonToday,
    1 => tr.commonTomorrow,
    -1 => tr.commonYesterday,
    _ when day.year == today.year => DateFormat.MMMEd(appLanguage).format(day),
    _ => DateFormat.yMMMEd(appLanguage).format(day),
  };
}

String timeLabel(DateTime t) => DateFormat.jm(appLanguage).format(t);

String dateTimeLabel(DateTime t) => '${dayLabel(t)}, ${timeLabel(t)}';

/// [value] with [digits] decimals and the decimal mark of the app's
/// language ("1,5" in German and Spanish, "1.5" in English).
String decimal(num value, [int digits = 1]) {
  final text = value.toStringAsFixed(digits);
  return appLanguage == 'en' ? text : text.replaceAll('.', ',');
}

/// Short name of the ISO [weekday] (1 = Monday) in the app's language,
/// without the abbreviation dot ("Mo", "Mon", "lun").
String weekdayShort(int weekday) => DateFormat.E(
  appLanguage,
).format(DateTime(2024, 1, weekday)).replaceAll('.', '');

/// Full name of the ISO [weekday] (1 = Monday) in the app's language.
String weekdayLong(int weekday) =>
    DateFormat.EEEE(appLanguage).format(DateTime(2024, 1, weekday));

/// Short names of Monday to Sunday (or the first [count] days).
List<String> weekdaysShort([int count = 7]) => [
  for (var d = 1; d <= count; d++) weekdayShort(d),
];

/// [number] (as Dart writes it) with the decimal mark of the app's
/// language.
String decimalMark(String number) =>
    appLanguage == 'en' ? number : number.replaceAll('.', ',');
