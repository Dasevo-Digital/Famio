import 'package:famio/src/shared_texts/shared_texts.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final all = collectSharedTexts();

  test('the shared catalogs have texts', () {
    expect(all.length, greaterThan(400));
    expect(all['MemberRole.adult'], 'Erwachsen');
  });

  for (final (language, texts) in [('en', sharedEn), ('es', sharedEs)]) {
    test('every shared text has a translation ($language)', () {
      final missing = [
        for (final MapEntry(:key, value: german) in all.entries)
          if (german.isNotEmpty && texts[key] == null) key,
      ];
      expect(missing, isEmpty);
      for (final MapEntry(:key, value: german) in all.entries) {
        for (final p in RegExp(r'\{\w+\}').allMatches(german)) {
          expect(texts[key], contains(p[0]), reason: key);
        }
      }
      final unused = texts.keys.where(
        (k) => !k.startsWith('Server|') && !all.containsKey(k),
      );
      expect(unused, isEmpty, reason: 'texts nobody asks for');
    });
  }

  test('the app language switches the shared texts', () {
    addTearDown(() => useSharedTexts('de'));
    useSharedTexts('en');
    expect(MemberRole.guest.label, 'Guest');
    expect(milestones.first.title, startsWith('Briefly lifts'));
    useSharedTexts('es');
    expect(MemberRole.guest.label, 'Invitado');
    useSharedTexts('de');
    expect(MemberRole.guest.label, 'Gast');
  });
}
