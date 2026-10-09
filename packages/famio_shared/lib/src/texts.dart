/// Texts of the shared enums and catalogs are German. An app (or the
/// server) shows them in another language by setting [sharedTexts]: it gets
/// a stable key ("MemberRole.adult", "milestone.walk.title") and the German
/// text, and returns the text to show – the German one if it has none.
library;

import 'i18n/en.dart';
import 'i18n/es.dart';

String Function(String key, String german) sharedTexts = _german;

String _german(String key, String german) => german;

/// [german] in the language of [sharedTexts]; `{name}` placeholders are
/// filled from [args] after the translation.
String sharedText(
  String key,
  String german, [
  Map<String, Object?> args = const {},
]) {
  var text = sharedTexts(key, german);
  for (final MapEntry(:key, :value) in args.entries) {
    text = text.replaceAll('{$key}', '$value');
  }
  return text;
}

/// The [language] text for [key] from Famio's own translations (English
/// and Spanish), or null for German and unknown keys.
String? sharedTranslation(String language, String key) => switch (language) {
  'en' => sharedEn[key],
  'es' => sharedEs[key],
  _ => null,
};

/// A message the server stored in German (the last error of a calendar
/// subscription, a backup check …) in the language of [sharedTexts]:
/// matches it against the server's texts, also with filled-in
/// placeholders, which are translated in turn. Unknown texts stay as they
/// are.
String localizeServerText(String text) {
  if (text.isEmpty) return text;
  final exact = sharedTexts('Server|$text', text);
  if (exact != text) return exact;
  for (final (template, pattern, names) in _serverTemplates) {
    final m = pattern.firstMatch(text);
    if (m == null) continue;
    return sharedText('Server|$template', template, {
      for (var i = 0; i < names.length; i++)
        names[i]: localizeServerText(m.group(i + 1)!),
    });
  }
  return text;
}

/// German server texts with placeholders as patterns, longest first (the
/// most specific wins).
final _serverTemplates = () {
  final out = <(String, RegExp, List<String>)>[];
  for (final key in sharedEn.keys) {
    if (!key.startsWith('Server|') || !key.contains('{')) continue;
    final template = key.substring('Server|'.length);
    final names = [
      for (final m in RegExp(r'\{(\w+)\}').allMatches(template)) m[1]!,
    ];
    final pattern = template
        .split(RegExp(r'\{\w+\}'))
        .map(RegExp.escape)
        .join('(.+?)');
    out.add((template, RegExp('^$pattern\$', dotAll: true), names));
  }
  out.sort((a, b) => b.$1.length.compareTo(a.$1.length));
  return out;
}();
