import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// The German texts of all `t('…')` calls in lib/ (adjacent literals
/// joined, escapes resolved).
Set<String> serverTexts() {
  final found = <String>{};
  final call = RegExp(r'(?<![\w.])t\(\s*');
  for (final file in Directory('lib').listSync(recursive: true)) {
    if (file is! File || !file.path.endsWith('.dart')) continue;
    final src = file.readAsStringSync();
    for (final m in call.allMatches(src)) {
      var i = m.end;
      final text = StringBuffer();
      var literals = 0;
      while (i < src.length && (src[i] == "'" || src[i] == '"')) {
        final quote = src[i++];
        while (src[i] != quote) {
          if (src[i] == r'\') {
            final next = src[i + 1];
            text.write(next == 'n' ? '\n' : next);
            i += 2;
          } else {
            text.write(src[i++]);
          }
        }
        i++;
        literals++;
        while (i < src.length && ' \n\t'.contains(src[i])) {
          i++;
        }
      }
      if (literals > 0) found.add(text.toString());
    }
  }
  return found;
}

void main() {
  final texts = serverTexts();

  test('the server has translatable texts', () {
    expect(texts.length, greaterThan(250));
    expect(texts, contains('Nicht angemeldet'));
  });

  for (final (language, table) in [('en', sharedEn), ('es', sharedEs)]) {
    test('every server text has a translation ($language)', () {
      final missing = [
        for (final german in texts)
          if (table['Server|$german'] == null) german,
      ];
      expect(missing, isEmpty);
      for (final german in texts) {
        for (final p in RegExp(r'\{\w+\}').allMatches(german)) {
          expect(table['Server|$german'], contains(p[0]), reason: german);
        }
      }
      final unused = [
        for (final key in table.keys)
          if (key.startsWith('Server|') &&
              !texts.contains(key.substring('Server|'.length)))
            key,
      ];
      expect(unused, isEmpty, reason: 'translations nobody asks for');
    });
  }

  test('answers in the language the app asks for', () async {
    final app = FamioServerApp.inMemory();
    Future<String> message(String? language) async {
      final r = await app.handler(
        Request(
          'GET',
          Uri.parse('http://famio.test/api/me'),
          headers: {'accept-language': ?language},
        ),
      );
      expect(r.statusCode, 401);
      return (jsonDecode(await r.readAsString()) as Map)['message'] as String;
    }

    expect(await message(null), 'Nicht angemeldet');
    expect(await message('en-US,en;q=0.9'), 'Not signed in');
    expect(await message('es'), 'Sesión no iniciada');
    expect(await message('fr, de;q=0.5'), 'Nicht angemeldet');
  });

  test('push messages go out in the language of each app', () async {
    final app = FamioServerApp.inMemory();
    final mama = app.accounts.create(
      username: 'mama',
      displayName: 'Mama',
      passwordHash: 'x',
    );
    app.accounts.noteLanguage(mama.id, 'en');
    expect(app.accounts.languageOf(mama.id), 'en');
    final papa = app.accounts.create(
      username: 'papa',
      displayName: 'Papa',
      passwordHash: 'x',
    );
    expect(app.accounts.languageOf(papa.id), 'de');
  });
}
