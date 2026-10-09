import 'dart:async';

import 'package:famio_shared/famio_shared.dart';

/// Languages the server answers in (German is the default).
const serverLanguages = {'de', 'en', 'es'};

const _languageKey = #famioLanguage;

/// The language of the current request ('de', 'en' or 'es'); German
/// outside of requests (background jobs, logs).
String get requestLanguage => Zone.current[_languageKey] as String? ?? 'de';

/// Runs [body] with [t] answering in [language].
R inLanguage<R>(String language, R Function() body) =>
    runZoned(body, zoneValues: {_languageKey: language});

/// [german] in the language of the current request; `{name}` placeholders
/// come from [args]. The translations are in famio_shared (keys
/// `Server|<German text>`), so the apps can also translate texts the
/// server stored (e.g. the last error of a calendar subscription).
String t(String german, [Map<String, Object?> args = const {}]) =>
    sharedText('Server|$german', german, args);

/// The language an `Accept-Language` header asks for, if the server
/// speaks it ("en-US,en;q=0.9" → "en").
String? languageFrom(String? acceptLanguage) {
  for (final part in (acceptLanguage ?? '').split(',')) {
    final code = part.split(';').first.trim().split('-').first.toLowerCase();
    if (serverLanguages.contains(code)) return code;
  }
  return null;
}

/// Lets the shared texts (roles, holidays, messages) follow the language
/// of the current request.
void useRequestLanguage() {
  sharedTexts = (key, german) =>
      sharedTranslation(requestLanguage, key) ?? german;
}
