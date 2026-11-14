// What an iPhone shows names no other platform or store: App Review 2.3.10
// (#496). Each text that does is either replaced or hidden there right
// where it is used, or listed below with the reason it never shows on iOS.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _elsewhere = {
  'settingsEncryptedButWithoutSystem':
      'only without a system keychain; iPhones always have one',
  'adminAppUpdatesIntro': 'in the dialog of the tile that iOS hides',
  'appUpdateAndroidHint': 'the install step of the Android update',
  'ocrModelLoading': 'an error of the Android recognition only',
  'ocrNeedsPlayServices': 'an error of the Android recognition only',
  'settingsBuiltInModels': 'its tile is Android only',
  'settingsBuiltInModelsPlay': 'its tile is Android only',
  'settingsBuiltInModelsBundled': 'its tile is Android only',
  'pantryScannerFirstUse': 'with the Play models, Android only',
  'pushBatteryOptimizationAndroidMay': 'in the OwnPush.native block',
  'supportSubtitle': 'the tip link is not in store builds',
  'locationYouShareOwnLocation': 'only where the device cannot share',
};

const _guards = [
  'AppEnv.onIos',
  'OwnPush.native',
  'isAndroid',
  'TargetPlatform.android',
  'LocationSharing.supported',
  'AppEnv.storeBuild',
  '_playModels',
];

void main() {
  test('texts about other platforms stay off iPhones', () {
    final de =
        (jsonDecode(File('lib/l10n/app_de.arb').readAsStringSync()) as Map)
            .cast<String, Object?>();
    final other = RegExp(
      r'Android|Play Store|Google Play|F-Droid|GitHub|Windows|Linux|APK|Ko-fi',
    );
    final keys = [
      for (final e in de.entries)
        if (!e.key.startsWith('@') && other.hasMatch('${e.value}')) e.key,
    ];
    expect(keys, isNotEmpty);
    final files = {
      for (final f in Directory('lib/src').listSync(recursive: true))
        if (f is File && f.path.endsWith('.dart')) f.path: f.readAsLinesSync(),
    };
    final unguarded = <String>[];
    for (final key in keys) {
      if (_elsewhere.containsKey(key)) continue;
      final use = RegExp('\\.$key\\b');
      for (final MapEntry(key: path, value: lines) in files.entries) {
        for (var i = 0; i < lines.length; i++) {
          if (!use.hasMatch(lines[i])) continue;
          final around = lines
              .sublist(i < 8 ? 0 : i - 8, i + 1 < lines.length ? i + 2 : i + 1)
              .join('\n');
          if (!_guards.any(around.contains)) {
            unguarded.add('$key $path:${i + 1}');
          }
        }
      }
    }
    expect(unguarded, isEmpty);
    for (final key in _elsewhere.keys) {
      expect(de.containsKey(key), isTrue, reason: '$key is gone');
    }
  });
}
