import 'dart:io';

import 'package:famio/src/environment.dart';
import 'package:flutter_test/flutter_test.dart';

/// The privacy information in German, English and Spanish (#502).
void main() {
  test('the app links the privacy information in its language', () {
    expect(AppEnv.privacyUrlFor('de'), AppEnv.privacyUrl);
    expect(AppEnv.privacyUrlFor('en'), endsWith('/docs/datenschutz.en.md'));
    expect(AppEnv.privacyUrlFor('es'), endsWith('/docs/datenschutz.es.md'));
    expect(AppEnv.privacyUrlFor('fr'), AppEnv.privacyUrl);
    for (final language in ['de', 'en', 'es']) {
      final name = AppEnv.privacyUrlFor(language).split('/').last;
      expect(File('../docs/$name').existsSync(), isTrue, reason: name);
    }
  });

  // A paragraph added to the German version only shows up here.
  test('the translations have the same parts as the German version', () {
    ({int sections, int bullets, int topics}) parts(String name) {
      final lines = File('../docs/$name').readAsLinesSync();
      return (
        sections: lines.where((l) => l.startsWith('## ')).length,
        bullets: lines.where((l) => l.startsWith('- ')).length,
        topics: lines.where((l) => l.startsWith('**')).length,
      );
    }

    final german = parts('datenschutz.md');
    expect(german.sections, greaterThan(4));
    expect(parts('datenschutz.en.md'), german);
    expect(parts('datenschutz.es.md'), german);
  });
}
