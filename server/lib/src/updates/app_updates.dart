import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../i18n.dart';

/// An app package the server hands out, checked against the signed
/// release.
class AppPackage {
  const AppPackage({
    required this.platform,
    required this.version,
    required this.file,
    required this.sha256,
    required this.sums,
    required this.signature,
  });

  final AppPlatform platform;
  final String version;
  final File file;
  final String sha256;

  /// `SHA256SUMS.txt` and its signature, for the app to check itself.
  final String sums;
  final String signature;

  String get name => p.basename(file.path);
  int get size => file.lengthSync();
}

/// The app packages of this server's own version (Android, Windows,
/// Linux), so the family's apps update to exactly the server's version,
/// also in a home network without internet.
///
/// Off until an admin switches it on: only then the server asks the public
/// GitHub release, fetches `SHA256SUMS.txt` with its signature (see
/// release_signature.dart) and the packages, checks both and keeps them in
/// [dir]. Packages of other versions are removed.
class AppUpdates {
  AppUpdates({
    required this.db,
    required this.dir,
    required this.version,
    http.Client? client,
    this.publicKey = famioReleaseKey,
    Uri? releases,
    this.retry = const Duration(hours: 6),
    this.retrySoon = const Duration(minutes: 10),
    this.onError,
  }) : _http = client ?? http.Client(),
       releases =
           releases ??
           Uri.parse(
             'https://api.github.com/repos/Dasevo-Digital/Famio/releases/tags/',
           );

  final Database db;

  /// E.g. `<data>/app-updates`; one folder per version inside.
  final String dir;

  /// The server's version: the one the apps get.
  final String version;
  final String publicKey;

  /// Release by tag: `<releases>v<version>`.
  final Uri releases;
  final Duration retry;

  /// After a failed attempt (a stalled download, GitHub not reachable):
  /// tried again this soon, up to [_quickRetries] times, before only
  /// [retry] is left.
  final Duration retrySoon;

  /// For the server log; failures are also shown in the admin screen.
  final void Function(String line)? onError;

  /// Every package of the release is here (at start or after fetching):
  /// the platforms there are packages for.
  void Function(Set<AppPlatform> available)? onReady;
  final http.Client _http;
  Timer? _timer;
  Timer? _soon;
  var _failures = 0;
  static const _quickRetries = 3;
  Future<void>? _running;

  static const _key = 'appUpdates';
  static const _statusKey = 'appUpdates.status';

  /// Nothing larger is downloaded (the APK is about 90 MB).
  static const maxBytes = 400 * 1024 * 1024;

  bool get enabled => (_setting(_key) as Map?)?['enabled'] == true;

  Directory get _versionDir => Directory(p.join(dir, version));

  void start() {
    // Retries now and then until every package of the release is there.
    _timer ??= Timer.periodic(retry, (_) {
      if (enabled && !_complete) unawaited(prepare());
    });
    if (enabled && !_complete) unawaited(prepare());
    if (enabled && _complete) _ready();
  }

  void _ready() => onReady?.call({
    for (final platform in AppPlatform.values)
      if (package(platform) != null) platform,
  });

  void stop() {
    _timer?.cancel();
    _timer = null;
    _soon?.cancel();
    _soon = null;
  }

  /// What the admin screen shows.
  Map<String, Object?> info() => {
    'enabled': enabled,
    'version': version,
    'packages': {
      for (final platform in AppPlatform.values)
        if (package(platform) case final pkg?) platform.name: pkg.size,
    },
    ...?(_setting(_statusKey) as Map?)?.cast<String, Object?>(),
  };

  /// Switches the distribution on (and fetches the packages right away) or
  /// off (and removes them).
  Future<Map<String, Object?>> configure({required bool enabled}) async {
    _put(_key, {'enabled': enabled});
    if (enabled) {
      await prepare();
    } else {
      _soon?.cancel();
      _failures = 0;
      db.execute('DELETE FROM settings WHERE key = ?', [_statusKey]);
      final folder = Directory(dir);
      if (folder.existsSync()) folder.deleteSync(recursive: true);
    }
    return info();
  }

  /// The package for [platform], if switched on and fetched.
  AppPackage? package(AppPlatform platform) {
    if (!enabled) return null;
    final folder = _versionDir;
    final sumsFile = File(p.join(folder.path, 'SHA256SUMS.txt'));
    final sigFile = File(p.join(folder.path, 'SHA256SUMS.txt.sig'));
    final file = File(p.join(folder.path, platform.fileName(version)));
    if (!sumsFile.existsSync() || !sigFile.existsSync() || !file.existsSync()) {
      return null;
    }
    final sums = sumsFile.readAsStringSync();
    final sha = parseChecksums(sums)[platform.fileName(version)];
    if (sha == null) return null;
    return AppPackage(
      platform: platform,
      version: version,
      file: file,
      sha256: sha,
      sums: sums,
      signature: sigFile.readAsStringSync(),
    );
  }

  /// Every package the release has (older ones lack some) is here; the
  /// signed list is written last.
  bool get _complete {
    final sums = File(p.join(_versionDir.path, 'SHA256SUMS.txt'));
    if (!sums.existsSync()) return false;
    final listed = parseChecksums(sums.readAsStringSync());
    return AppPlatform.values.every(
      (platform) =>
          !listed.containsKey(platform.fileName(version)) ||
          package(platform) != null,
    );
  }

  /// Fetches what is missing; one run at a time.
  Future<void> prepare() =>
      _running ??= _prepare().whenComplete(() => _running = null);

  Future<void> _prepare() async {
    final checkedAt = DateTime.now().toUtc().toIso8601String();
    try {
      final assets = await _assets();
      final sums = await _text(
        assets['SHA256SUMS.txt'] ??
            (throw _Failure(t('Im Release fehlt SHA256SUMS.txt.'))),
      );
      final signature = await _text(
        assets['SHA256SUMS.txt.sig'] ??
            (throw _Failure(t('Das Release ist nicht signiert.'))),
      );
      if (!await verifyReleaseSignature(
        sums,
        signature,
        publicKey: publicKey,
      )) {
        throw _Failure(t('Die Signatur des Releases passt nicht.'));
      }
      final hashes = parseChecksums(sums);
      final folder = _versionDir..createSync(recursive: true);
      for (final platform in AppPlatform.values) {
        final name = platform.fileName(version);
        final want = hashes[name];
        final url = assets[name];
        if (want == null || url == null) continue;
        final file = File(p.join(folder.path, name));
        if (file.existsSync() && await sha256Hex(file.openRead()) == want) {
          continue;
        }
        await _download(url, file, want);
      }
      // Written last: a package counts only together with its signed list.
      File(p.join(folder.path, 'SHA256SUMS.txt')).writeAsStringSync(sums);
      File(
        p.join(folder.path, 'SHA256SUMS.txt.sig'),
      ).writeAsStringSync(signature);
      for (final other in Directory(dir).listSync()) {
        if (p.basename(other.path) != version) {
          other.deleteSync(recursive: true);
        }
      }
      _put(_statusKey, {'checkedAt': checkedAt});
      _failures = 0;
      if (_complete) _ready();
    } on Exception catch (e) {
      final message = e is _Failure ? e.message : '$e';
      _put(_statusKey, {'checkedAt': checkedAt, 'error': message});
      onError?.call('[app-updates] $version: $message');
      if (++_failures <= _quickRetries) {
        _soon?.cancel();
        _soon = Timer(retrySoon, () {
          if (enabled && !_complete) unawaited(prepare());
        });
      }
    }
  }

  /// File name → download address of this version's release.
  Future<Map<String, Uri>> _assets() async {
    final response = await _http
        .get(releases.resolve('v$version'), headers: _headers)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 404) {
      throw _Failure(
        t('Für Version {version} gibt es kein Release.', {'version': version}),
      );
    }
    if (response.statusCode != 200) {
      throw _Failure(
        t('Release-Liste antwortet mit {code}.', {'code': response.statusCode}),
      );
    }
    final release = jsonDecode(response.body) as Map;
    return {
      for (final a in release['assets'] as List? ?? const [])
        if (a is Map && a['browser_download_url'] is String)
          '${a['name']}': Uri.parse(a['browser_download_url'] as String),
    };
  }

  Future<String> _text(Uri url) async {
    final response = await _http
        .get(url, headers: _headers)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw _Failure(
        t('Download antwortet mit {code}.', {'code': response.statusCode}),
      );
    }
    return utf8.decode(response.bodyBytes);
  }

  /// Into a `.part` file first; renamed only when the checksum fits.
  Future<void> _download(Uri url, File file, String sha256) async {
    final part = File('${file.path}.part');
    final response = await _http.send(
      http.Request('GET', url)..headers.addAll(_headers),
    );
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw _Failure(
        t('Download antwortet mit {code}.', {'code': response.statusCode}),
      );
    }
    final sink = part.openWrite();
    var bytes = 0;
    try {
      await for (final chunk in response.stream.timeout(
        const Duration(minutes: 2),
      )) {
        bytes += chunk.length;
        if (bytes > maxBytes) {
          throw _Failure(t('Das Paket ist zu groß.'));
        }
        sink.add(chunk);
      }
    } catch (_) {
      // A broken download leaves nothing behind.
      await sink.close();
      if (part.existsSync()) part.deleteSync();
      rethrow;
    }
    await sink.close();
    if (await sha256Hex(part.openRead()) != sha256) {
      part.deleteSync();
      throw _Failure(
        t('Die Prüfsumme von {file} passt nicht.', {
          'file': p.basename(file.path),
        }),
      );
    }
    part.renameSync(file.path);
  }

  Map<String, String> get _headers => {
    // GitHub's API refuses requests without one.
    'user-agent': 'Famio-Server/$version',
    'accept': 'application/vnd.github+json, application/octet-stream',
  };

  // --- settings ------------------------------------------------------------

  Object? _setting(String key) {
    final row = db.select('SELECT value FROM settings WHERE key = ?', [
      key,
    ]).firstOrNull;
    return row == null ? null : jsonDecode(row['value'] as String);
  }

  void _put(String key, Object? value) => db.execute(
    'INSERT INTO settings (key, value) VALUES (?, ?)'
    ' ON CONFLICT(key) DO UPDATE SET value = excluded.value',
    [key, jsonEncode(value)],
  );
}

class _Failure implements Exception {
  _Failure(this.message);

  final String message;

  @override
  String toString() => message;
}
