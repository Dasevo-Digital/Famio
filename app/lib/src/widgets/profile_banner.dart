import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../l10n.dart';
import '../platform/app_profile.dart';

/// "Famio läuft auf diesem iPhone bald ab": shown in the days before iOS
/// stops opening a build installed from the Mac (see [appProfileExpires]).
class ProfileBanner extends StatelessWidget {
  const ProfileBanner({super.key});

  /// [end] formatted like "Sa., 1. Nov., 18:29".
  static String when(DateTime end) =>
      DateFormat.MMMEd(appLanguage).add_Hm().format(end);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DateTime?>(
      valueListenable: AppScope.of(context).profileExpires,
      builder: (context, end, _) {
        if (end == null || end.difference(DateTime.now()) > profileWarning) {
          return const SizedBox.shrink();
        }
        final c = FamioColors.of(context);
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: SoftCard(
            color: c.tint(FamioSection.settings),
            child: Row(
              children: [
                Icon(AppIcons.warningCircle, color: c.danger),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr.profileExpiresTitle,
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        tr.profileExpiresText(when(end)),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
