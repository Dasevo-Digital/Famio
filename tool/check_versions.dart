import 'dart:io';

/// Checks that every place carries the version in `VERSION` and that
/// `app/CHANGELOG.md` and its English and Spanish versions have the user
/// notes (one to eight points).
///
///   dart run tool/check_versions.dart            check (pre-push, CI)
///   dart run tool/check_versions.dart --notes    print this version's notes
///                                                (for the release text)
void main(List<String> args) {
  final expected = File('VERSION').readAsStringSync().trim();
  if (args.contains('--notes')) {
    final notes = changelogSection(expected);
    if (notes == null) {
      stderr.writeln('app/CHANGELOG.md: kein Abschnitt für $expected');
      exitCode = 1;
    } else {
      stdout.write(notes);
    }
    return;
  }
  final checks = <String, RegExp>{
    'app/pubspec.yaml': RegExp(r'^version:\s*([^+\s]+)', multiLine: true),
    'server/pubspec.yaml': RegExp(r'^version:\s*([^\s]+)', multiLine: true),
    'homeassistant-addon/famio/config.yaml': RegExp(
      r'^version:\s*"([^"]+)"',
      multiLine: true,
    ),
    'homeassistant-integration/custom_components/famio/manifest.json': RegExp(
      r'"version":\s*"([^"]+)"',
    ),
    'server/lib/src/api.dart': RegExp(r"const serverVersion = '([^']+)'"),
  };
  var failed = false;
  for (final entry in checks.entries) {
    final source = File(entry.key).readAsStringSync();
    final actual = entry.value.firstMatch(source)?.group(1);
    if (actual != expected) {
      stderr.writeln(
        '${entry.key}: ${actual ?? 'Version fehlt'} (erwartet $expected)',
      );
      failed = true;
    }
  }
  for (final file in changelogs) {
    final notes = changelogSection(expected, file: file);
    final points = notes == null
        ? 0
        : RegExp(r'^- ', multiLine: true).allMatches(notes).length;
    if (points < 1 || points > 8) {
      stderr.writeln(
        '$file: ${notes == null ? 'kein Abschnitt' : '$points Punkte'} '
        'für $expected (erwartet: „## $expected – …“ mit 1 bis 8 Punkten in '
        'Nutzersprache)',
      );
      failed = true;
    }
  }
  if (failed) exitCode = 1;
}

/// The app's user notes: German, English and Spanish.
const changelogs = [
  'app/CHANGELOG.md',
  'app/CHANGELOG.en.md',
  'app/CHANGELOG.es.md',
];

/// The section `## <version>` of [file] with its heading, or null.
String? changelogSection(String version, {String file = 'app/CHANGELOG.md'}) {
  final text = File(file).readAsStringSync();
  final start = RegExp(
    '^## ${RegExp.escape(version)}(\\s|\$)',
    multiLine: true,
  ).firstMatch(text);
  if (start == null) return null;
  final next = RegExp(
    r'^## ',
    multiLine: true,
  ).firstMatch(text.substring(start.end));
  return text
          .substring(
            start.start,
            next == null ? text.length : start.end + next.start,
          )
          .trimRight() +
      '\n';
}
