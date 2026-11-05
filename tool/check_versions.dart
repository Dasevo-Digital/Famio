import 'dart:io';

/// Checks that every place carries the version in `VERSION`, that
/// `app/CHANGELOG.md` and its English and Spanish versions have the user
/// notes (one to eight points), that the Home Assistant add-on shows the
/// same notes and that all workflows use one Flutter.
///
///   dart run tool/check_versions.dart            check (pre-push, CI)
///   dart run tool/check_versions.dart --addon-changelog
///                                                write the add-on's
///                                                changelog from the app's
///   dart run tool/check_versions.dart --notes    print this version's notes
///                                                (for the release text)
///   dart run tool/check_versions.dart --flutter  print the workflows'
///                                                Flutter (release builds)
void main(List<String> args) {
  final expected = File('VERSION').readAsStringSync().trim();
  if (args.contains('--flutter')) {
    final versions = workflowFlutter().values.toSet();
    if (versions.length != 1) {
      stderr.writeln('Workflows: Flutter ${versions.join(', ')}');
      exitCode = 1;
    } else {
      stdout.writeln(versions.single);
    }
    return;
  }
  if (args.contains('--addon-changelog')) {
    File(addonChangelog).writeAsStringSync(expectedAddonChangelog());
    return;
  }
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
    'custom_components/famio/manifest.json': RegExp(r'"version":\s*"([^"]+)"'),
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
  // The add-on builds from the GitHub release of its version, so it follows
  // only once that release is complete (tool/addon_release.sh): until then
  // it may stay on an older version, never on a newer one.
  final addon = RegExp(
    r'^version:\s*"([^"]+)"',
    multiLine: true,
  ).firstMatch(File(addonConfig).readAsStringSync())?.group(1);
  if (addon == null || compareVersions(addon, expected) > 0) {
    stderr.writeln(
      '$addonConfig: ${addon ?? 'Version fehlt'} (höchstens $expected)',
    );
    failed = true;
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
  if (File(addonChangelog).readAsStringSync() != expectedAddonChangelog()) {
    stderr.writeln(
      '$addonChangelog: nicht wie app/CHANGELOG.md '
      '(dart tool/check_versions.dart --addon-changelog)',
    );
    failed = true;
  }
  final flutter = workflowFlutter();
  if (flutter.isEmpty || flutter.values.toSet().length > 1) {
    stderr.writeln(
      'Flutter-Version der Workflows nicht einheitlich: '
      '${flutter.entries.map((e) => '${e.key} ${e.value}').join(', ')}',
    );
    failed = true;
  }
  if (failed) exitCode = 1;
}

/// The Flutter each workflow sets up, by file and line ("ci.yml:43"): the
/// tests, the release check and the release builds should use one.
Map<String, String> workflowFlutter() {
  final pin = RegExp(
    r'''^\s*(?:flutter-version|FLUTTER_VERSION):\s*["']?(\d+\.\d+\.\d+)''',
  );
  return {
    for (final file
        in Directory('.github/workflows').listSync().whereType<File>().toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
      for (final (i, line) in file.readAsLinesSync().indexed)
        if (pin.firstMatch(line) case final m?)
          '${file.uri.pathSegments.last}:${i + 1}': m.group(1)!,
  };
}

/// The app's user notes: German, English and Spanish.
const changelogs = [
  'app/CHANGELOG.md',
  'app/CHANGELOG.en.md',
  'app/CHANGELOG.es.md',
];

const addonConfig = 'homeassistant-addon/famio/config.yaml';

/// Compares "2.0.9" and "2.0.10" by their numbers.
int compareVersions(String a, String b) {
  final x = a.split('.').map(int.parse).toList();
  final y = b.split('.').map(int.parse).toList();
  for (var i = 0; i < 3; i++) {
    final c = x[i].compareTo(y[i]);
    if (c != 0) return c;
  }
  return 0;
}

/// What Home Assistant shows when the add-on has an update: until 2.0.33 it
/// still ended at 0.20.0.
const addonChangelog = 'homeassistant-addon/famio/CHANGELOG.md';

/// The add-on's changelog: the app's German notes, then the add-on's own
/// notes of the 0.x versions (from before the app kept any).
String expectedAddonChangelog() {
  final app = File('app/CHANGELOG.md').readAsStringSync();
  final notes = app.substring(app.indexOf('\n## ') + 1).trimRight();
  final own = File(addonChangelog).readAsStringSync();
  final old = RegExp(r'^## 0\.', multiLine: true).firstMatch(own);
  return '# Changelog\n\n'
      'Was sich je Version ändert. Die ausführlichen Release-Texte stehen '
      'bei den Releases.\n\n'
      '$notes\n'
      '${old == null ? '' : '\n${own.substring(old.start).trimRight()}\n'}';
}

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
