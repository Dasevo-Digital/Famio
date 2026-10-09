import 'package:famio_client/famio_client.dart';


/// Shows the German texts of the shared enums and catalogs (roles,
/// milestones, vaccinations …) in [language].
void useSharedTexts(String language) {
  sharedTexts = (key, german) => sharedTranslation(language, key) ?? german;
}

/// Every key the shared package asks for, with its German text: all enum
/// values and catalog entries (see test/shared_texts_test.dart).
Map<String, String> collectSharedTexts() {
  final found = <String, String>{};
  final before = sharedTexts;
  sharedTexts = (key, german) => found[key] = german;
  try {
    for (final values in <List<Enum>>[
      MemberRole.values,
      ServiceAccess.values,
      TwoFactorPolicy.values,
      GermanState.values,
      MilestoneArea.values,
      ChoreRepeat.values,
      MoneyKind.values,
      ContactRole.values,
      DocumentCategory.values,
      PantryPlace.values,
      LogKind.values,
      BreastSide.values,
      MilkKind.values,
      DiaperKind.values,
      WasteKind.values,
      MealSlot.values,
      DeadlineArea.values,
    ]) {
      for (final v in values) {
        (v as dynamic).label;
      }
    }
    for (final m in milestones) {
      m.title;
      m.hint;
    }
    for (final c in checkups) {
      c.title;
      c.window;
    }
    for (final v in vaccinations) {
      v.title;
      v.dose;
      v.note;
    }
    for (final w in pregnancyWeeks) {
      w.like;
      w.info;
    }
    for (final t in pregnancyTasks) {
      t.title;
      t.info;
    }
    for (final l in pregnancyChecklists) {
      l.title;
      for (final i in l.items) {
        i.title;
      }
    }
    for (final s in GermanState.values) {
      for (final h in germanHolidays(2026, s)) {
        h.name;
      }
    }
    for (final c in shoppingCategories) {
      c.label;
    }
    for (final p in deadlinePresets) {
      p.title;
      p.hint;
    }
    for (final t in builtInTemplates) {
      for (final i in t.items) {
        i.name;
        i.quantity;
      }
    }
    LocationAlert.checkInTexts;
    for (final (arrived, checkIn) in [
      (true, null),
      (false, null),
      (true, 'x'),
    ]) {
      LocationAlert(
        id: '',
        memberId: '',
        placeId: '',
        placeName: 'p',
        arrived: arrived,
        at: DateTime(2026),
        checkIn: checkIn,
      ).text('m');
    }
    for (final f in TaskRepeat.values) {
      f.label(1);
      f.label(2);
    }
    ClientTexts.all();
  } finally {
    sharedTexts = before;
  }
  return found;
}
