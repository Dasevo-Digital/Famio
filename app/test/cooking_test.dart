import 'package:famio/src/data/cooking.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('times in a step become timers', () {
    expect(stepTimers('Nudeln 10 Minuten kochen'), [
      const Duration(minutes: 10),
    ]);
    expect(stepTimers('Bei 180 °C 1,5 Std. backen'), [
      const Duration(minutes: 90),
    ]);
    expect(stepTimers('10–12 Min. ziehen lassen, dann 30 Sekunden rühren'), [
      const Duration(minutes: 10),
      const Duration(seconds: 30),
    ]);
    expect(stepTimers('Simmer for 20 minutes, rest 2 h'), [
      const Duration(minutes: 20),
      const Duration(hours: 2),
    ]);
    expect(stepTimers('Hornear 25 minutos'), [const Duration(minutes: 25)]);
    expect(stepTimers('Ruhen lassen: 1 Stunde'), [const Duration(hours: 1)]);
  });

  test('amounts and temperatures are no timers', () {
    expect(stepTimers('200 g Mehl, 4 Stück Butter, 3 Hände voll'), isEmpty);
    expect(stepTimers('Auf 180 °C vorheizen'), isEmpty);
    expect(stepTimers('Über Nacht, 48 Stunden marinieren'), isEmpty);
  });
}
