/// Times in a recipe step, e.g. "10 Minuten köcheln" or "1,5 Std. backen":
/// the cooking mode offers each as a kitchen timer. A range ("10–12 Min.")
/// counts from its lower end, so nothing burns while waiting.
List<Duration> stepTimers(String step) {
  final found = <Duration>[];
  for (final m in _time.allMatches(step)) {
    final amount = double.tryParse(m.group(1)!.replaceAll(',', '.'));
    if (amount == null || amount <= 0) continue;
    final unit = m.group(2)!.toLowerCase();
    final seconds = unit.startsWith(RegExp('se[kcg]'))
        ? amount // Sekunden, seconds, segundos
        : unit.startsWith(RegExp('st|h'))
        ? amount * 3600 // Stunden, hours, horas
        : amount * 60; // Minuten, minutes, minutos
    final d = Duration(seconds: seconds.round());
    // Longer than a day is no kitchen timer ("2 Stunden ziehen lassen" is).
    if (d <= const Duration(hours: 24) && !found.contains(d)) found.add(d);
  }
  return found;
}

// "10", "1,5", "10–12", "10-12", "10 bis 12", "10 to 12", "10 a 12",
// then the unit. "Std."/"h" for hours, "Min."/"min" for minutes.
final _time = RegExp(
  r'(\d+(?:[.,]\d+)?)(?:\s*(?:-|–|bis|to|a)\s*\d+(?:[.,]\d+)?)?\s*'
  r'(sekunden|sekunde|sek\.?|seconds?|secs?|segundos?|seg\.?|'
  r'stunden|stunde|std\.?|hours?|hrs?|horas?|h|'
  r'minuten|minute|minutes|minutos?|mins?\.?|min\.?)'
  r'(?![a-zäöüß])',
  caseSensitive: false,
);
