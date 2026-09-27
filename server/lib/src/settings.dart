import 'dart:convert';

import 'package:famio_shared/famio_shared.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:timezone/timezone.dart' as tz;

import 'api_exception.dart';

/// Settings admins can change at runtime from any connected app.
///
/// Values stored here win over [defaults] (environment variables, add-on
/// options); clearing a value falls back to the default again.
class SettingsStore {
  SettingsStore(this._db, {required this.defaults}) {
    _load();
  }

  final Database _db;
  final ServerSettings defaults;
  var _stored = const ServerSettings();
  late tz.Location _location;

  static const maxUploadLimitMb = 4096;

  /// Only the values set in the app.
  ServerSettings get stored => _stored;

  ServerSettings get effective => ServerSettings(
    publicUrl: _stored.publicUrl ?? defaults.publicUrl,
    timeZone: _location.name,
    maxUploadMb: _stored.maxUploadMb ?? defaults.maxUploadMb ?? 100,
    mapTileUrl: _stored.mapTileUrl ?? defaults.mapTileUrl,
  );

  tz.Location get location => _location;
  String? get publicUrl => effective.publicUrl;
  int get maxUploadBytes => effective.maxUploadMb! * 1024 * 1024;

  /// Applies [changes]; keys that are present but null reset to the default.
  /// Unknown keys and invalid values are rejected before anything is saved.
  void update(Map<String, Object?> changes) {
    final unknown = changes.keys.where((k) => !ServerSettings.keys.contains(k));
    if (unknown.isNotEmpty) {
      throw ApiException.badRequest(
        'unknown_setting',
        'Unbekannte Einstellung: ${unknown.join(', ')}',
      );
    }
    final values = <String, Object?>{};
    for (final MapEntry(:key, :value) in changes.entries) {
      values[key] = switch (key) {
        'publicUrl' => _publicUrl(value),
        'timeZone' => _timeZone(value),
        'maxUploadMb' => _maxUpload(value),
        'mapTileUrl' => _mapTileUrl(value),
        _ => null,
      };
    }
    _db.execute('BEGIN');
    try {
      for (final MapEntry(:key, :value) in values.entries) {
        if (value == null) {
          _db.execute('DELETE FROM settings WHERE key = ?', [key]);
        } else {
          _db.execute(
            'INSERT INTO settings (key, value) VALUES (?, ?)'
            ' ON CONFLICT(key) DO UPDATE SET value = excluded.value',
            [key, jsonEncode(value)],
          );
        }
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    _load();
  }

  void _load() {
    final json = {
      for (final row in _db.select('SELECT key, value FROM settings'))
        row['key'] as String: jsonDecode(row['value'] as String),
    };
    _stored = ServerSettings.fromJson(json);
    _location =
        _zone(_stored.timeZone) ??
        _zone(defaults.timeZone) ??
        tz.getLocation('Europe/Berlin');
  }

  static tz.Location? _zone(String? name) {
    if (name == null) return null;
    try {
      return tz.getLocation(name);
    } on tz.LocationNotFoundException {
      return null;
    }
  }

  static String? _publicUrl(Object? value) {
    final text = (value as String?)?.trim() ?? '';
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    if (uri == null ||
        !(uri.isScheme('https') || uri.isScheme('http')) ||
        uri.host.isEmpty) {
      throw ApiException.badRequest(
        'invalid_public_url',
        'Öffentliche Adresse muss mit https:// beginnen, '
            'z. B. https://famio.example.org',
      );
    }
    return text.endsWith('/') ? text : '$text/';
  }

  static String? _timeZone(Object? value) {
    final text = (value as String?)?.trim() ?? '';
    if (text.isEmpty) return null;
    if (_zone(text) == null) {
      throw ApiException.badRequest(
        'invalid_time_zone',
        'Unbekannte Zeitzone „$text“ (Beispiel: Europe/Berlin)',
      );
    }
    return text;
  }

  static String? _mapTileUrl(Object? value) {
    final text = (value as String?)?.trim() ?? '';
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text.replaceAll(RegExp(r'[{}]'), ''));
    if (uri == null ||
        !uri.isScheme('https') ||
        !['{z}', '{x}', '{y}'].every(text.contains)) {
      throw ApiException.badRequest(
        'invalid_map_tiles',
        'Kartenkacheln: https-Adresse mit {z}, {x} und {y}, z. B. '
            'https://tiles.example.org/{z}/{x}/{y}.png',
      );
    }
    return text;
  }

  static int? _maxUpload(Object? value) {
    if (value == null) return null;
    final mb = value is int ? value : int.tryParse('$value');
    if (mb == null || mb < 1 || mb > maxUploadLimitMb) {
      throw ApiException.badRequest(
        'invalid_upload_limit',
        'Upload-Grenze: 1 bis $maxUploadLimitMb MB',
      );
    }
    return mb;
  }
}
