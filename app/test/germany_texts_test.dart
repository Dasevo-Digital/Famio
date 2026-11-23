import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Numbers and rules of Germany say so in English and Spanish, and the
/// out-of-hours number is not left out there (#526, #443).
void main() {
  Map<String, Object?> arb(String language) =>
      (jsonDecode(File('lib/l10n/app_$language.arb').readAsStringSync()) as Map)
          .cast();

  test('116 117 is named with its country in every language', () {
    final de = arb('de');
    final wrong = <String>[];
    for (final (language, country) in [('en', 'Germany'), ('es', 'Alemania')]) {
      final texts = arb(language);
      for (final MapEntry(:key, :value) in de.entries) {
        if (key.startsWith('@') || !'$value'.contains('116 117')) continue;
        final text = '${texts[key]}';
        if (!text.contains('116 117') || !text.contains(country)) {
          wrong.add('$language $key');
        }
      }
    }
    expect(wrong, isEmpty);
  });

  test('texts for Austria and Switzerland name no German number (#586)', () {
    final wrong = <String>[];
    for (final language in ['de', 'en', 'es']) {
      for (final MapEntry(:key, :value) in arb(language).entries) {
        final local =
            RegExp(r'(At|Ch)$').hasMatch(key) || key.contains('Austria');
        if (!local || key.startsWith('@')) continue;
        if ('$value'.contains('116 117') || '$value'.contains('19240')) {
          wrong.add('$language $key');
        }
      }
    }
    expect(wrong, isEmpty);
  });
}
