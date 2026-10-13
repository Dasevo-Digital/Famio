import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../l10n.dart';

/// A short tip the first time a member opens an area: what the tour does
/// not show and is easy to miss there. "Verstanden" hides it for that area
/// for good; tips can be switched off and on again in the settings.
abstract final class SectionTips {
  static const _seenKey = 'tips.seen';
  static const _offKey = 'tips.off';

  /// The tip for [section], or null for areas without one.
  static String? textFor(FamioSection section) => switch (section) {
    FamioSection.calendar => tr.tipCalendar,
    FamioSection.tasks => tr.tipTasks,
    FamioSection.shopping => tr.tipShopping,
    FamioSection.kids => tr.tipKids,
    FamioSection.documents => tr.tipDocuments,
    FamioSection.location => tr.tipLocation,
    FamioSection.chores => tr.tipChores,
    FamioSection.meals => tr.tipMeals,
    FamioSection.budget => tr.tipBudget,
    FamioSection.health => tr.tipHealth,
    FamioSection.chat => tr.tipChat,
    FamioSection.home || FamioSection.contacts || FamioSection.settings => null,
  };

  /// Whether to show the tip of [section] now.
  static Future<bool> due(FamioSection section) async {
    if (textFor(section) == null) return false;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_offKey) ?? false) return false;
    return !(prefs.getStringList(_seenKey) ?? const []).contains(section.name);
  }

  static Future<void> seen(FamioSection section) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _seenKey,
      {...?prefs.getStringList(_seenKey), section.name}.toList(),
    );
  }

  static Future<bool> get enabled async =>
      !((await SharedPreferences.getInstance()).getBool(_offKey) ?? false);

  /// Switching tips on again shows every tip once more.
  static Future<void> setEnabled(bool on) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_offKey, !on);
    if (on) await prefs.remove(_seenKey);
  }
}

/// The tip of [section] as a card above the content.
class SectionTipCard extends StatelessWidget {
  const SectionTipCard({
    super.key,
    required this.section,
    required this.onGotIt,
    required this.onNoMore,
  });

  final FamioSection section;
  final VoidCallback onGotIt;
  final VoidCallback onNoMore;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    final color = c.strong(section);
    return Semantics(
      container: true,
      liveRegion: true,
      child: SoftCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(AppIcons.lightbulb, color: color, size: 20),
                const SizedBox(width: 8),
                Text(tr.tipTitle, style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 6),
            Text(SectionTips.textFor(section) ?? ''),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: c.inkSoft),
                    onPressed: onNoMore,
                    child: Text(tr.tipNoMore),
                  ),
                  ColorButton(
                    label: tr.tipGotIt,
                    color: color,
                    onPressed: onGotIt,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
