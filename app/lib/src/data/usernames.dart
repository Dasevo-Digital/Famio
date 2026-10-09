import '../l10n.dart';

/// Login names as the server accepts them: 2–32 characters of
/// `A–Z a–z 0–9 . _ -` (see `Accounts._checkUsername` on the server).
final _valid = RegExp(r'^[A-Za-z0-9._-]{2,32}$');

bool isValidUsername(String username) => _valid.hasMatch(username);

/// Why [username] would be refused, or null when it is fine.
String? usernameProblem(String username) {
  if (username.isEmpty) return null;
  if (username.length < 2) return tr.usernamesLeast2Characters;
  if (username.length > 32) return tr.usernamesMost32Characters;
  if (!isValidUsername(username)) {
    return tr.usernamesOnlyLettersWithoutUmlauts;
  }
  return null;
}

const _replacements = {
  'ä': 'ae', 'ö': 'oe', 'ü': 'ue', 'ß': 'ss', //
  'á': 'a', 'à': 'a', 'â': 'a', 'å': 'a', 'ã': 'a', 'æ': 'ae',
  'ç': 'c', 'č': 'c', 'ć': 'c',
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'ě': 'e',
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
  'ñ': 'n', 'ń': 'n', 'ň': 'n',
  'ó': 'o', 'ò': 'o', 'ô': 'o', 'õ': 'o', 'ø': 'o', 'œ': 'oe',
  'ř': 'r', 'š': 's', 'ś': 's', 'ş': 's', 'ž': 'z', 'ź': 'z', 'ż': 'z',
  'ú': 'u', 'ù': 'u', 'û': 'u', 'ů': 'u', 'ý': 'y', 'ÿ': 'y', 'ł': 'l',
};

/// A login name derived from a display name: "Jürgen Müller" →
/// "juergen.mueller", numbered when [taken] already has it ("lena2").
/// Empty when the name yields nothing usable.
String suggestUsername(String name, Iterable<String> taken) {
  final buffer = StringBuffer();
  for (final char in name.trim().toLowerCase().split('')) {
    final mapped = _replacements[char] ?? char;
    if (RegExp(r'^[a-z0-9._-]+$').hasMatch(mapped)) {
      buffer.write(mapped);
    } else if (RegExp(r'\s').hasMatch(mapped)) {
      buffer.write('.');
    }
    // Anything else (emoji, apostrophes, other scripts) is left out.
  }
  var base = buffer
      .toString()
      .replaceAll(RegExp(r'[._-]{2,}'), '.')
      .replaceAll(RegExp(r'^[._-]+|[._-]+$'), '');
  if (base.length > 30) base = base.substring(0, 30);
  if (base.isEmpty) return '';
  if (base.length < 2) base = '${base}1';
  final used = {for (final t in taken) t.toLowerCase()};
  if (!used.contains(base)) return base;
  for (var n = 2; ; n++) {
    final candidate = '$base$n';
    if (!used.contains(candidate)) return candidate;
  }
}
