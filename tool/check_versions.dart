import 'dart:io';

void main() {
  final expected = File('VERSION').readAsStringSync().trim();
  final checks = <String, RegExp>{
    'app/pubspec.yaml': RegExp(r'^version:\s*([^+\s]+)', multiLine: true),
    'server/pubspec.yaml': RegExp(r'^version:\s*([^\s]+)', multiLine: true),
    'homeassistant-addon/famio/config.yaml': RegExp(
      r'^version:\s*"([^"]+)"',
      multiLine: true,
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
  if (failed) exitCode = 1;
}
