import 'dart:io';

import 'package:famio/src/widgets/whats_new.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('reads versions, titles and wrapped points', () {
    final entries = parseChangelog('''
# Was ist neu

## 1.0.11 – Sicherer abgleichen

- Erster Punkt
  geht weiter.
- Zweiter Punkt

## 1.0.7

- Nur einer
''');
    expect(
      [for (final e in entries) (e.version, e.title)],
      [('1.0.11', 'Sicherer abgleichen'), ('1.0.7', '')],
    );
    expect(entries.first.points, [
      'Erster Punkt geht weiter.',
      'Zweiter Punkt',
    ]);
  });

  test('the shipped changelog has the app version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version:\s*([^+\s]+)',
      multiLine: true,
    ).firstMatch(pubspec)![1];
    final entries = parseChangelog(File('CHANGELOG.md').readAsStringSync());
    expect(entries.first.version, version);
    for (final e in entries) {
      expect(e.points.length, inInclusiveRange(1, 8), reason: e.version);
    }
    // English and Spanish: the same versions with the same points.
    for (final language in ['en', 'es']) {
      final translated = parseChangelog(
        File('CHANGELOG.$language.md').readAsStringSync(),
      );
      expect(
        [for (final e in translated) (e.version, e.points.length)],
        [for (final e in entries) (e.version, e.points.length)],
        reason: language,
      );
    }
  });

  testWidgets('after an update once, not after a fresh install', (
    tester,
  ) async {
    Future<void> start(String version) async {
      PackageInfo.setMockInitialValues(
        appName: 'Famio',
        packageName: 'famio',
        version: version,
        buildNumber: '1',
        buildSignature: '',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => maybeShowWhatsNew(context),
              child: const Text('Start'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
    }

    SharedPreferences.setMockInitialValues({});
    final current = parseChangelog(
      File('CHANGELOG.md').readAsStringSync(),
    ).first;
    // Fresh install: nothing shown.
    await start(current.version);
    expect(find.textContaining('Neu in'), findsNothing);
    // An older version was seen before: shown once.
    SharedPreferences.setMockInitialValues({'whatsNew.seen': '0.9.0'});
    await start(current.version);
    expect(find.textContaining('Neu in ${current.version}'), findsOneWidget);
    expect(find.text(current.points.first), findsOneWidget);
    // Next start: not again.
    await tester.pumpWidget(const SizedBox());
    await start(current.version);
    expect(find.textContaining('Neu in'), findsNothing);
  });
}
