import 'package:flutter/widgets.dart';

import '../design/app_icons.dart';
import '../design/palette.dart';
import '../l10n.dart';

/// A tile of the start page, in the order of the page. The family can hide
/// each one in the server settings ([module] in `hiddenModules`, known to the
/// server as `ServerSettings.tileModules`); the tile of a hidden [section]
/// goes with it.
enum HomeTile {
  inbox(AppIcons.clipboardList),
  today(AppIcons.calendarHeart, section: FamioSection.calendar),
  weather(AppIcons.cloudSun),
  memories(AppIcons.images),
  countdown(AppIcons.partyPopper, section: FamioSection.calendar),
  waste(AppIcons.recycle),
  tasks(AppIcons.checkSquareOffset, section: FamioSection.tasks),
  deadlines(AppIcons.wrench),
  shopping(AppIcons.basket, section: FamioSection.shopping),
  meals(AppIcons.cookingPot, section: FamioSection.meals),
  chores(AppIcons.trophy, section: FamioSection.chores),
  chat(AppIcons.chatsCircle, section: FamioSection.chat),
  location(AppIcons.mapPinned, section: FamioSection.location),
  medications(AppIcons.pill, section: FamioSection.health),
  kids(AppIcons.baby, section: FamioSection.kids),
  birthdays(AppIcons.cake, section: FamioSection.calendar),
  documents(AppIcons.folderSimpleStar, section: FamioSection.documents),
  budget(AppIcons.wallet, section: FamioSection.budget),
  notes(AppIcons.note),
  wishes(AppIcons.gift),
  loans(AppIcons.package);

  const HomeTile(this.icon, {this.section});

  final IconData icon;

  /// The area it belongs to, if any.
  final FamioSection? section;

  String get module => 'tile.$name';

  /// Whether it may appear when [hidden] are switched off.
  bool shownWith(Set<String> hidden) =>
      !hidden.contains(module) &&
      (section == null || !hidden.contains(section!.name));

  String title(BuildContext context) {
    final l = context.l10n;
    return switch (this) {
      inbox => l.inboxTitle,
      today => l.commonToday,
      weather => l.weatherWeather,
      memories => l.memoriesTitleYears,
      countdown => l.homeCountdown,
      waste => l.homeBins,
      tasks => l.sectionTasks,
      deadlines => l.commonDeadlines,
      shopping => l.sectionShopping,
      meals => l.sectionMeals,
      chores => l.sectionChores,
      chat => l.sectionChat,
      location => l.homeWhoWhere,
      medications => l.commonMedications,
      kids => l.sectionKids,
      birthdays => l.commonBirthdays,
      documents => l.sectionDocuments,
      budget => l.sectionBudget,
      notes => l.commonPinboard,
      wishes => l.settingsWishes,
      loans => l.loansTitle,
    };
  }
}
