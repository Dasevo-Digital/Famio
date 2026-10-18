import 'dart:convert';

import 'package:famio_shared/famio_shared.dart';
import 'package:sqlite3/sqlite3.dart';

import '../accounts.dart';
import '../i18n.dart';
import '../push/push_service.dart';

/// Tells members once per version that one of their devices runs an older
/// app the server can update: an Android phone, a Windows or Linux
/// computer. Called when the server has every package of its version (see
/// AppUpdates). Whom it told is kept, so a restart does not repeat it.
class UpdateNotices {
  UpdateNotices({
    required this.db,
    required this.accounts,
    required this.push,
    required this.version,
  });

  final Database db;
  final Accounts accounts;
  final PushService? push;

  /// The server's version: the one the apps get.
  final String version;

  static const _key = 'appUpdates.notified';

  /// Operating systems as the apps report them (`<version> <os>`) that
  /// [available] packages update.
  static Set<String> _systems(Set<AppPlatform> available) => {
    for (final p in available)
      switch (p) {
        AppPlatform.android || AppPlatform.androidArm64 => 'android',
        AppPlatform.windows => 'windows',
        AppPlatform.linux => 'linux',
      },
  };

  /// Sends the notice to members not told yet whose devices are behind.
  /// Returns whom it went to (for tests).
  Set<String> announce(Set<AppPlatform> available) {
    final systems = _systems(available);
    if (systems.isEmpty) return const {};
    final told = _told();
    final behind = <String>{};
    for (final (userId, app) in accounts.appVersions()) {
      final [appVersion, ...rest] = app.split(' ');
      final os = rest.isEmpty ? '' : rest.first;
      if (told.contains(userId) || !systems.contains(os)) continue;
      if (compareVersions(appVersion, version) < 0) behind.add(userId);
    }
    if (behind.isEmpty) return const {};
    _remember({...told, ...behind});
    push?.deliver(
      () => PushNotice(
        to: behind,
        title: t('Famio {version} ist da', {'version': version}),
        body: t(
          'Auf einem deiner Geräte läuft noch eine ältere Famio-Version. Famio dort öffnen und auf der Startseite „Aktualisieren“ antippen.',
        ),
        brief: t('Famio {version} ist da', {'version': version}),
        tag: 'arrow_up',
      ),
      null,
    );
    return behind;
  }

  Set<String> _told() {
    final row = db.select('SELECT value FROM settings WHERE key = ?', [
      _key,
    ]).firstOrNull;
    if (row == null) return {};
    final value = jsonDecode(row['value'] as String);
    if (value is! Map || value['version'] != version) return {};
    return {for (final id in value['members'] as List? ?? const []) '$id'};
  }

  void _remember(Set<String> members) => db.execute(
    'INSERT INTO settings (key, value) VALUES (?, ?)'
    ' ON CONFLICT(key) DO UPDATE SET value = excluded.value',
    [
      _key,
      jsonEncode({'version': version, 'members': members.toList()..sort()}),
    ],
  );
}
