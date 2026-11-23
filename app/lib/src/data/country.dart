import 'package:famio_client/famio_client.dart';

import '../l10n.dart';

/// The family's country (server setting, kept for offline use by the app
/// state). Germany unless an admin chose Austria or Switzerland.
FamilyCountry familyCountry = FamilyCountry.de;

/// Whether the German check-up, vaccination and maternity rules apply.
/// Elsewhere Famio keeps what the family records but shows no German
/// windows, due states or reminders for them.
bool get germanRules => familyCountry == FamilyCountry.de;

/// "in Österreich", "in der Schweiz" – for texts about the family's country.
String get inFamilyCountry => switch (familyCountry) {
  FamilyCountry.de => tr.countryInGermany,
  FamilyCountry.at => tr.countryInAustria,
  FamilyCountry.ch => tr.countryInSwitzerland,
};

/// The pregnancy appointments and to-dos that apply in the family's country.
List<PregnancyTask> get localPregnancyTasks => [
  for (final t in pregnancyTasks)
    if (t.appliesIn(familyCountry)) t,
];

/// The entries of [list] that apply in the family's country.
List<ChecklistItem> localChecklistItems(Checklist list) => [
  for (final i in list.items)
    if (i.appliesIn(familyCountry)) i,
];
