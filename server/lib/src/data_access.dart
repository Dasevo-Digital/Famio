import 'dart:io';

import 'package:path/path.dart' as p;

/// Why the server cannot use [dataDir] and the key file at [keyPath], or
/// null if it can: write to the folder, read and write the databases, read
/// the key. Checked before anything is opened, so a wrong owner (e.g. data
/// a root container created, now run as an unprivileged user) gives a clear
/// hint instead of a database error.
String? dataAccessProblem(String dataDir, String keyPath, {bool? docker}) {
  final hint = (docker ?? File('/.dockerenv').existsSync())
      ? 'Das Docker-Image läuft seit 1.0.11 als Benutzer 65532, nicht als '
            'root. Einmalig im Ordner der docker-compose.yml ausführen: '
            'mkdir -p data keys && sudo chown -R 65532:65532 data keys'
      : 'Besitzer und Rechte prüfen: Der Dienst muss Ordner und Datenbanken '
            'schreiben und den Schlüssel lesen dürfen.';
  try {
    Directory(dataDir).createSync(recursive: true);
    final probe = File(p.join(dataDir, '.famio-write-test'));
    probe.writeAsStringSync('ok', flush: true);
    probe.deleteSync();
  } on FileSystemException catch (e) {
    return 'Kein Schreibzugriff auf das Datenverzeichnis $dataDir '
        '(${e.osError?.message ?? e.message}). $hint';
  }
  for (final name in ['famio.db', 'files.db']) {
    final f = File(p.join(dataDir, name));
    if (!f.existsSync()) continue;
    try {
      f.openSync(mode: FileMode.append).closeSync();
    } on FileSystemException catch (e) {
      return 'Kein Zugriff auf ${f.path} '
          '(${e.osError?.message ?? e.message}). $hint';
    }
  }
  final key = File(keyPath);
  if (key.existsSync()) {
    try {
      key.openSync().closeSync();
    } on FileSystemException catch (e) {
      return 'Die Schlüsseldatei $keyPath ist nicht lesbar '
          '(${e.osError?.message ?? e.message}). $hint';
    }
  }
  return null;
}
