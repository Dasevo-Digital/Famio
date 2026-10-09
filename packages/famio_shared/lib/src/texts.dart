/// Texts of the shared enums and catalogs are German. An app (or the
/// server) shows them in another language by setting [sharedTexts]: it gets
/// a stable key ("MemberRole.adult", "milestone.walk.title") and the German
/// text, and returns the text to show – the German one if it has none.
library;

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
