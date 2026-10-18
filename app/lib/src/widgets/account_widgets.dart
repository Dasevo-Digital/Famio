import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../format.dart';
import '../l10n.dart';

// Shared by the settings and the server administration, which the web app
// loads only when opened (see DeferredPage).

/// A signed-in device with an optional "sign out" button.
class DeviceTile extends StatelessWidget {
  const DeviceTile({super.key, required this.session, this.onSignOut});

  final DeviceSession session;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final device = session.device ?? tr.adminUnknownDevice;
    final mobile = RegExp('android|ios', caseSensitive: false).hasMatch(device);
    return ListTile(
      leading: Icon(mobile ? AppIcons.smartphone : AppIcons.laptop),
      title: Text(deviceLabel(device)),
      subtitle: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: session.current
                  ? tr.settingsThisDevice
                  : tr.adminLastActiveSeenSigned(
                      agoText(session.lastSeen),
                      DateFormat.yMd(appLanguage).format(session.createdAt),
                    ),
            ),
            if (session.appVersionNumber case final version?) ...[
              TextSpan(text: '\n${tr.adminAppVersion(version)}'),
              if (session.outdated)
                TextSpan(
                  text: ' · ${tr.adminAppOutdated}',
                  style: TextStyle(
                    color: c.danger,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ],
        ),
      ),
      trailing: onSignOut == null
          ? null
          : IconButton(
              icon: Icon(AppIcons.signOut, color: c.danger),
              tooltip: tr.settingsSignOut,
              onPressed: onSignOut,
            ),
    );
  }

  /// `macos (Marcos-MacBook)` → `macOS · Marcos-MacBook`.
  static String deviceLabel(String device) {
    final match = RegExp(r'^(\w+) \((.*)\)$').firstMatch(device);
    if (match == null) return device;
    final os = switch (match[1]!.toLowerCase()) {
      'macos' => 'macOS',
      'ios' => 'iOS',
      'android' => 'Android',
      'windows' => 'Windows',
      'linux' => 'Linux',
      final other => other,
    };
    return '$os · ${match[2]}';
  }
}

/// Palette of avatar colors to choose from.
class AvatarColorPicker extends StatelessWidget {
  const AvatarColorPicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final int? selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr.kidsColor, style: TextStyle(color: c.inkSoft)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final color in famioPalette)
              GestureDetector(
                onTap: () => onChanged(color),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Color(color),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: color == selected ? c.ink : Colors.transparent,
                      width: 3,
                    ),
                  ),
                  child: color == selected
                      ? const Icon(
                          AppIcons.check,
                          color: Colors.white,
                          size: 18,
                        )
                      : null,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Loading spinner, error with retry, or [builder] for a server request.
class ApiFutureView<T> extends StatelessWidget {
  const ApiFutureView({
    super.key,
    required this.snapshot,
    required this.builder,
    required this.onRetry,
  });

  final AsyncSnapshot<T> snapshot;
  final Widget Function(T data) builder;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (snapshot.hasData) return builder(snapshot.data as T);
    if (snapshot.hasError) {
      final error = snapshot.error;
      return EmptyHint(
        icon: AppIcons.cloudSlash,
        color: FamioColors.of(context).strong(FamioSection.settings),
        text: error is ApiError
            ? error.message
            : tr.adminServerNotReachableAdministration,
        action: TextButton(onPressed: onRetry, child: Text(tr.commonRetry)),
      );
    }
    return const Center(child: CircularProgressIndicator());
  }
}

/// "vor 5 Min." style relative time.
String agoText(DateTime t, {bool suffix = true}) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return suffix ? tr.agoJustNow : tr.agoMoment;
  if (d.inDays >= 30) return dayLabel(t);
  if (d.inDays >= 1) {
    return suffix ? tr.agoDaysAgo(d.inDays) : tr.agoDays(d.inDays);
  }
  final text = d.inHours < 1
      ? tr.agoMinutes(d.inMinutes)
      : tr.agoHours(d.inHours);
  return suffix ? tr.agoAgo(text) : text;
}
