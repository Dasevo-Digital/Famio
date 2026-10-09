import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../l10n.dart';

/// The setup checklist for admins: what is done, what is missing and where
/// to change it. Loaded from the server each time it is shown.
class SetupChecklist extends StatefulWidget {
  const SetupChecklist({super.key});

  @override
  State<SetupChecklist> createState() => _SetupChecklistState();
}

class _SetupChecklistState extends State<SetupChecklist> {
  late Future<List<SetupStep>> _steps = _load();

  Future<List<SetupStep>> _load() =>
      AppScope.read(context).engine!.api.setupChecklist();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = FamioColors.of(context);
    return FutureBuilder<List<SetupStep>>(
      future: _steps,
      builder: (context, snapshot) {
        final steps = snapshot.data;
        if (steps == null) {
          return snapshot.hasError
              ? Text(tr.setupSetupStatusNotAvailable)
              : const LinearProgressIndicator();
        }
        final done = steps.where((s) => s.done).length;
        return SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      done == steps.length
                          ? tr.setupEverythingSetUp
                          : tr.setupDoneTotalDone(done, steps.length),
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: tr.commonCheckAgain,
                    icon: const Icon(AppIcons.arrowsClockwise),
                    onPressed: () => setState(() => _steps = _load()),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              for (final s in steps)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        s.done ? AppIcons.check : AppIcons.warningCircle,
                        size: 20,
                        color: s.done
                            ? c.strong(FamioSection.tasks)
                            : theme.colorScheme.error,
                        semanticLabel: s.done
                            ? tr.commonDoneLower
                            : tr.commonOpenLower,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(s.title, style: theme.textTheme.titleSmall),
                            Text(s.detail, style: theme.textTheme.bodySmall),
                            if (!s.done && s.where.isNotEmpty)
                              Text(
                                '→ ${s.where}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: c.inkSoft,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Start page, admins only: "Einrichtung abschließen (5 von 8)" until all
/// is set up or the admin hides it. Asked once per app start.
class SetupBanner extends StatefulWidget {
  const SetupBanner({super.key});

  static const _hiddenKey = 'setup.hidden';

  /// One request per app start (the start page rebuilds often).
  static Future<List<SetupStep>?>? _cached;

  @override
  State<SetupBanner> createState() => _SetupBannerState();
}

class _SetupBannerState extends State<SetupBanner> {
  var _hidden = false;

  Future<List<SetupStep>?> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(SetupBanner._hiddenKey) ?? false) return null;
    if (!mounted) return null;
    try {
      return await AppScope.read(context).engine!.api.setupChecklist();
    } catch (_) {
      return null; // Offline or an older server: no banner.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hidden) return const SizedBox.shrink();
    final c = FamioColors.of(context);
    return FutureBuilder<List<SetupStep>?>(
      future: SetupBanner._cached ??= _load(),
      builder: (context, snapshot) {
        final steps = snapshot.data;
        if (steps == null || steps.every((s) => s.done)) {
          return const SizedBox.shrink();
        }
        final done = steps.where((s) => s.done).length;
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: SoftCard(
            color: c.tint(FamioSection.settings),
            onTap: () => showModalBottomSheet<void>(
              context: context,
              useRootNavigator: true,
              isScrollControlled: true,
              showDragHandle: true,
              useSafeArea: true,
              builder: (_) => const SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: SetupChecklist(),
              ),
            ).then((_) => SetupBanner._cached = null),
            child: Row(
              children: [
                Icon(
                  AppIcons.listChecks,
                  color: c.strong(FamioSection.settings),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    tr.setupFinishSetupDoneTotal(done, steps.length),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: tr.commonHide,
                  icon: const Icon(AppIcons.x),
                  onPressed: () async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool(SetupBanner._hiddenKey, true);
                    if (mounted) setState(() => _hidden = true);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
