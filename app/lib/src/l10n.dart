import 'dart:ui' show PlatformDispatcher;

import 'package:famio_client/famio_client.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import 'design/palette.dart';
import 'shared_texts/shared_texts.dart';

export '../l10n/app_localizations.dart';

/// The languages Famio speaks, in the order of the language menu, with
/// their own names.
const appLanguages = {'de': 'Deutsch', 'en': 'English', 'es': 'Español'};

/// The device's language code. Tests pin it, since they read German texts
/// and the test machine speaks English.
String Function() deviceLanguage = () =>
    PlatformDispatcher.instance.locale.languageCode;

/// The language for the setting [choice]: one of [appLanguages], or for
/// "system" (and anything unknown) the device's language if Famio speaks
/// it, otherwise English.
String resolveLanguage(String? choice) {
  if (appLanguages.containsKey(choice)) return choice!;
  final device = deviceLanguage();
  return appLanguages.containsKey(device) ? device : 'en';
}

var _language = 'de';
L10n _texts = lookupL10n(const Locale('de'));

/// The app's language ('de', 'en' or 'es'); dates follow it.
String get appLanguage => _language;

/// The texts in the app's language, also where there is no BuildContext
/// (notifications, data helpers). The app is rebuilt completely when the
/// language changes, so widgets never keep texts of the old one.
L10n get tr => _texts;

void useLanguage(String code) {
  _language = code;
  _texts = lookupL10n(Locale(code));
  Intl.defaultLocale = code;
  useSharedTexts(code);
  FamioApiClient.language = code;
}

/// `context.l10n.settingsAccount`: the texts in the chosen language.
extension L10nContext on BuildContext {
  L10n get l10n => L10n.of(this);
}

/// Section names in the chosen language ([FamioSection.label] stays the
/// German name used in code and tests).
extension SectionTitle on FamioSection {
  String title(BuildContext context) {
    final l = context.l10n;
    return switch (this) {
      FamioSection.home => l.sectionHome,
      FamioSection.tasks => l.sectionTasks,
      FamioSection.shopping => l.sectionShopping,
      FamioSection.calendar => l.sectionCalendar,
      FamioSection.chat => l.sectionChat,
      FamioSection.documents => l.sectionDocuments,
      FamioSection.kids => l.sectionKids,
      FamioSection.location => l.sectionLocation,
      FamioSection.chores => l.sectionChores,
      FamioSection.meals => l.sectionMeals,
      FamioSection.budget => l.sectionBudget,
      FamioSection.health => l.sectionHealth,
      FamioSection.contacts => l.sectionContacts,
      FamioSection.settings => l.sectionSettings,
    };
  }
}
