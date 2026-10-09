import 'package:flutter/widgets.dart';

import '../l10n/app_localizations.dart';
import 'design/palette.dart';

export '../l10n/app_localizations.dart';

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
