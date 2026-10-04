import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../accounts.dart';
import '../files/file_store.dart';
import '../record_store.dart';
import '../settings.dart';

/// Exports as a ZIP of JSON files plus the uploaded files: for a member
/// everything they can see and their own location history (right of access
/// and data portability), for an admin the whole family, e.g. to move.
///
/// The archive is written to [tempDir] (inside the data directory, not a
/// RAM-backed /tmp) and deleted as soon as it was sent. Others' location
/// histories are never part of a family export.
class DataExport {
  DataExport({
    required this.db,
    required this.records,
    required this.accounts,
    required this.files,
    required this.settings,
    required this.tempDir,
  });

  final Database db;
  final RecordStore records;
  final Accounts accounts;
  final FileStore files;
  final SettingsStore settings;
  final String tempDir;

  static const _readme = '''
Famio – Datenexport

famio.json      wann, von welchem Server und was exportiert wurde
members.json    Mitglieder (ohne Passwörter)
records/*.json  Daten je Bereich: id, updatedAt (ms seit 1970), data
files/          hochgeladene Dateien (Fotos, Dokumente), Name: <id>-<name>
location.json   eigener Standortverlauf (nur im persönlichen Export)
settings.json   Servereinstellungen ohne Geheimnisse (nur Familien-Export)

Alle Zeiten in UTC, Texte in UTF-8.
''';

  /// Removes archives left behind by an interrupted download.
  void cleanUp() {
    final dir = Directory(tempDir);
    if (!dir.existsSync()) return;
    for (final f in dir.listSync().whereType<File>()) {
      if (p.basename(f.path).startsWith('export-')) f.deleteSync();
    }
  }

  /// What [member] may see.
  Future<File> member(FamilyMember member) => _write(
    scope: 'member',
    members: [member],
    records: (collection) =>
        records.all(collection, visibleToMember: member.id),
    files: [
      for (final f in files.all())
        if (files.mayRead(f, member.id)) f,
    ],
    extra: {
      'location.json': [
        for (final row in db.select(
          'SELECT at, latitude, longitude, accuracy FROM location_points'
          ' WHERE member_id = ? ORDER BY at',
          [member.id],
        ))
          {
            'at': DateTime.fromMillisecondsSinceEpoch(
              row['at'] as int,
              isUtc: true,
            ).toIso8601String(),
            'latitude': row['latitude'],
            'longitude': row['longitude'],
            'accuracy': row['accuracy'],
          },
      ],
    },
  );

  /// Everything, for an admin.
  Future<File> family() => _write(
    scope: 'family',
    members: accounts.members(),
    records: records.all,
    files: files.all(),
    extra: {
      'settings.json': {...settings.effective.toJson()},
    },
  );

  Future<File> _write({
    required String scope,
    required List<FamilyMember> members,
    required List<SyncRecord> Function(String collection) records,
    required List<StoredFile> files,
    Map<String, Object?> extra = const {},
  }) async {
    Directory(tempDir).createSync(recursive: true);
    final path = p.join(tempDir, 'export-${newId()}.zip');
    final zip = ZipFileEncoder()..create(path);
    void json(String name, Object? value) => zip.addArchiveFile(
      ArchiveFile.string(
        name,
        const JsonEncoder.withIndent('  ').convert(value),
      ),
    );
    try {
      zip.addArchiveFile(ArchiveFile.string('LIESMICH.txt', _readme));
      json('famio.json', {
        'format': 1,
        'scope': scope,
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'timeZone': settings.location.name,
      });
      json('members.json', [for (final m in members) m.toJson()]);
      for (final collection in Collections.all) {
        final list = records(collection);
        if (list.isEmpty) continue;
        json('records/$collection.json', [
          for (final r in list)
            {'id': r.id, 'updatedAt': r.updatedAt, 'data': r.data},
        ]);
      }
      for (final e in extra.entries) {
        json(e.key, e.value);
      }
      for (final f in files) {
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in this.files.read(f)) {
          bytes.add(chunk);
        }
        zip.addArchiveFile(
          ArchiveFile.bytes(
            'files/${f.id}-${_safe(f.name)}',
            bytes.takeBytes(),
          ),
        );
      }
      await zip.close();
      return File(path);
    } catch (_) {
      try {
        await zip.close();
      } catch (_) {}
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
      rethrow;
    }
  }

  static String _safe(String name) {
    final cleaned = name.replaceAll(RegExp(r'[^\w.\- äöüÄÖÜß]'), '_').trim();
    return cleaned.isEmpty ? 'datei' : cleaned;
  }
}

/// [file]'s bytes, deleting it after the last one was read (or on error).
Stream<List<int>> readAndDelete(File file) async* {
  try {
    yield* file.openRead();
  } finally {
    if (file.existsSync()) file.deleteSync();
  }
}
