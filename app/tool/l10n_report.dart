// What is left to translate: counts German texts still written directly
// in lib/ (outside lib/l10n), per file, and the texts in the ARB files.
//
// Not counted, because they are no texts anyone reads:
// * stored values and matched words: a string compared (`==`, `!=`,
//   `case`, `contains(…)`, `startsWith(…)`) or used as a key (`'Wohnen' =>`,
//   `'Wohnen':`, `'Kindergeld' || …`), raw strings (`r'…'`, patterns);
// * product, platform and font names (`_names`);
// * lines marked `// l10n: <why>` (at their end or on the line above), blocks between `// l10n-begin: <why>`
//   and `// l10n-end`, and files marked `// l10n-file: <why>` (parsers).
//
//   dart run tool/l10n_report.dart [--top 20] [--list]
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final topIndex = args.indexOf('--top');
  final top = topIndex >= 0 ? int.parse(args[topIndex + 1]) : 15;
  final list = args.contains('--list');
  final literal = RegExp(r"'((?:[^'\\\n]|\\.)*)'");
  final german = RegExp(
    r'[äöüÄÖÜß]|\b(der|die|das|und|nicht|ist|mit|für|ein|eine|auf|zu|du|dein|deine)\b'
    r'|^[A-ZÄÖÜ][a-zäöüß]{2,}$',
  );
  final counts = <String, int>{};
  var kept = 0;
  final files =
      Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where(
            (f) => f.path.endsWith('.dart') && !f.path.startsWith('lib/l10n/'),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    var n = 0;
    final lines = file.readAsLinesSync();
    var marked = lines.any((l) => l.startsWith('// l10n-file:'));
    var next = false;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final t = line.trim();
      final above = next;
      next = t.startsWith('// l10n:');
      if (t.startsWith('// l10n-begin:')) marked = true;
      if (t.startsWith('// l10n-end')) marked = false;
      if (t.startsWith('import ') ||
          t.startsWith('export ') ||
          t.startsWith('part ') ||
          t.startsWith('//')) {
        continue;
      }
      final skip = marked || above || line.contains('// l10n:');
      for (final m in literal.allMatches(line)) {
        final text = m[1]!;
        if (text.startsWith('package:') ||
            text.contains('/') && !text.contains(' ') ||
            !german.hasMatch(text)) {
          continue;
        }
        if (skip ||
            _names.contains(text) ||
            _noText(line.substring(0, m.start), line.substring(m.end))) {
          kept++;
          continue;
        }
        n++;
        if (list) stdout.writeln('${file.path}:${i + 1}  $text');
      }
    }
    if (n > 0) counts[file.path] = n;
  }
  final keys =
      (jsonDecode(File('lib/l10n/app_de.arb').readAsStringSync()) as Map).keys
          .where((k) => !(k as String).startsWith('@'))
          .length;
  final total = counts.values.fold<int>(0, (a, b) => a + b);
  stdout.writeln(
    'Übersetzt (ARB): $keys Texte · noch fest im Code: etwa $total Texte in '
    '${counts.length} Dateien '
    '(${(100 * keys / (keys + total)).toStringAsFixed(0)} %) · '
    'bewusst deutsch (Schlüssel, Suchwörter, Namen): $kept',
  );
  final sorted = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final e in sorted.take(top)) {
    stdout.writeln('${e.value.toString().padLeft(5)}  ${e.key}');
  }
}

/// A literal that is a stored value or a matched word, not a text: given
/// what stands before and after it on its line.
bool _noText(String before, String after) {
  final b = before.trimRight();
  final a = after.trimLeft();
  return before.endsWith('r') || // raw string: a pattern
      after.startsWith(':') || // map key
      a.startsWith('=>') ||
      a.startsWith('||') ||
      b.endsWith('==') ||
      b.endsWith('!=') ||
      b.endsWith('case') ||
      RegExp(r'\.(contains|startsWith|endsWith)\($').hasMatch(b);
}

/// Names that stay as they are in every language.
const _names = {
  'Android', 'Authentik', 'Browser', 'Chrome', 'Deutsch', 'Edge', 'English',
  'Famio', 'Firefox', 'Fredoka', 'Google', 'Linux', 'Lucide', 'Nextcloud',
  'Notification', 'Nunito', 'Opera', 'Posteo', 'Safari', 'Web', 'Windows',
  // PowerShell arguments of the Windows update.
  'Bypass', 'Hidden',
};
