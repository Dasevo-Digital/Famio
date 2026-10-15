import 'dart:async';
import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../l10n.dart';
import '../platform/abi.dart';

/// Why an update was not installed; [message] is for the family.
class AppUpdateError implements Exception {
  const AppUpdateError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The packages this app installs itself. iOS and macOS follow with signed
/// builds (Apple developer account); the web app comes with the server.
AppPlatform? get selfUpdatePlatform {
  if (kIsWeb) return null;
  if (Platform.isAndroid) {
    // A 64-bit phone takes the smaller package with only its own code.
    return runsOnArm64 ? AppPlatform.androidArm64 : AppPlatform.android;
  }
  if (Platform.isWindows) return AppPlatform.windows;
  if (Platform.isLinux) return AppPlatform.linux;
  return null;
}

/// The server's package for this app if it is newer than the app.
Future<AppUpdateOffer?> availableUpdate(
  FamioApiClient api, {
  AppPlatform? platform,
  String? appVersion,
}) async {
  final target = platform ?? selfUpdatePlatform;
  if (target == null) return null;
  var offer = await api.appUpdate(target);
  // Servers and releases before 2.0.6 only have the package for all phones.
  if (offer == null && target == AppPlatform.androidArm64) {
    offer = await api.appUpdate(AppPlatform.android);
  }
  if (offer == null) return null;
  final mine = appVersion ?? (await PackageInfo.fromPlatform()).version;
  return compareVersions(mine, offer.version) < 0 ? offer : null;
}

/// The package [offer] names (the 64-bit or the all-phones Android one …).
AppPlatform? updatePlatformOf(AppUpdateOffer offer) => AppPlatform.values
    .where((p) => p.fileName(offer.version) == offer.file)
    .firstOrNull;

/// Downloads [offer] into [into] (the temporary folder) and checks it:
/// the list of checksums must carry the Famio release signature and name
/// exactly this file with the checksum it has. Throws [AppUpdateError].
Future<File> downloadUpdate(
  FamioApiClient api,
  AppUpdateOffer offer,
  AppPlatform platform, {
  void Function(double progress)? onProgress,
  Directory? into,
  String publicKey = famioReleaseKey,
}) async {
  final name = platform.fileName(offer.version);
  // The server names the file; only the expected name is accepted, so a
  // path can never point elsewhere.
  final want = offer.file == name
      ? await signedChecksum(
          offer.sums,
          offer.signature,
          name,
          publicKey: publicKey,
        )
      : null;
  if (want == null || want != offer.sha256) {
    throw AppUpdateError(tr.appUpdateNotSigned);
  }
  final dir = into ?? await getTemporaryDirectory();
  final file = File(p.join(dir.path, name));
  final (total, bytes) = await api.downloadAppUpdate(platform);
  final sink = file.openWrite();
  var received = 0;
  try {
    try {
      await for (final chunk in bytes) {
        received += chunk.length;
        if (received > offer.size) throw AppUpdateError(tr.appUpdateDamaged);
        sink.add(chunk);
        onProgress?.call(received / (total ?? offer.size));
      }
    } finally {
      await sink.close();
    }
    if (await sha256Hex(file.openRead()) != want) {
      throw AppUpdateError(tr.appUpdateDamaged);
    }
    return file;
  } catch (_) {
    // Nothing half downloaded or unchecked stays behind.
    if (file.existsSync()) file.deleteSync();
    rethrow;
  }
}

const _channel = MethodChannel('famio/app_update');

/// Android: whether Famio may install packages ("Apps aus dieser Quelle").
Future<bool> canInstallUpdates() async =>
    !Platform.isAndroid ||
    (await _channel.invokeMethod<bool>('canInstall') ?? false);

/// Android: opens the system setting that allows Famio to install.
Future<void> allowInstallingUpdates() =>
    _channel.invokeMethod<void>('openInstallSettings');

/// Installs the checked package. Android asks the user to confirm; on
/// Windows and Linux Famio closes, a small script replaces its files and
/// starts the new version.
Future<void> installUpdate(File file, AppPlatform platform) async {
  switch (platform) {
    case AppPlatform.android || AppPlatform.androidArm64:
      await _channel.invokeMethod<void>('install', {'path': file.path});
    case AppPlatform.windows || AppPlatform.linux:
      final exe = Platform.resolvedExecutable;
      final target = p.dirname(exe);
      if (!_writable(target)) throw AppUpdateError(tr.appUpdateNoWriteAccess);
      final script =
          File(
            p.join(
              file.parent.path,
              platform == AppPlatform.windows
                  ? 'famio-update.ps1'
                  : 'famio-update.sh',
            ),
          )..writeAsStringSync(
            platform == AppPlatform.windows ? _windowsScript : _linuxScript,
          );
      await Process.start(
        platform == AppPlatform.windows ? 'powershell.exe' : 'sh',
        [
          if (platform == AppPlatform.windows) ...[
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-WindowStyle',
            'Hidden',
            '-File',
          ],
          script.path,
          '$pid',
          file.path,
          target,
          exe,
        ],
        mode: ProcessStartMode.detached,
      );
      exit(0);
  }
}

bool _writable(String dir) {
  try {
    final probe = File(p.join(dir, '.famio-update-probe'))
      ..writeAsStringSync('');
    probe.deleteSync();
    return true;
  } on FileSystemException {
    return false;
  }
}

/// Waits for Famio to end, unpacks the ZIP over its folder and starts it.
const _windowsScript = r'''
param([int]$ProcessId, [string]$Archive, [string]$Target, [string]$Exe)
try { Wait-Process -Id $ProcessId -Timeout 60 -ErrorAction Stop } catch {}
Start-Sleep -Milliseconds 500
$tmp = Join-Path $env:TEMP ('famio-update-' + [guid]::NewGuid())
Expand-Archive -Path $Archive -DestinationPath $tmp -Force
Copy-Item -Path (Join-Path $tmp '*') -Destination $Target -Recurse -Force
Remove-Item $tmp -Recurse -Force
Remove-Item $Archive -Force
Start-Process -FilePath $Exe
''';

/// The same for Linux: the release's `bundle` folder over Famio's folder,
/// and its menu entry over the one from `install.sh`.
const _linuxScript = r'''
pid=$1; archive=$2; target=$3; exe=$4
while kill -0 "$pid" 2>/dev/null; do sleep 0.3; done
tmp=$(mktemp -d)
tar xzf "$archive" -C "$tmp"
cp -r "$tmp"/Famio-*-linux/bundle/. "$target/"
apps="$HOME/.local/share/applications"
for d in "$tmp"/Famio-*-linux/de.status403.famio.desktop; do
  if [ -f "$d" ] && [ -f "$apps/de.status403.famio.desktop" ]; then
    sed "s|^Exec=famio|Exec=$exe|" "$d" > "$apps/de.status403.famio.desktop"
    update-desktop-database "$apps" 2>/dev/null || true
  fi
done
rm -rf "$tmp" "$archive"
nohup "$exe" >/dev/null 2>&1 &
''';
