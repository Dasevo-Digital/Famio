import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/app_update.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../l10n.dart';

/// Start page: "Famio 2.1 ist da" when the family's server offers a newer
/// package for this app (Android, Windows, Linux). Asked once per app
/// start; "Später" hides it until the next.
class AppUpdateBanner extends StatefulWidget {
  const AppUpdateBanner({super.key});

  /// One request per app start (the start page rebuilds often).
  static Future<AppUpdateOffer?>? _cached;
  static var _later = false;

  @override
  State<AppUpdateBanner> createState() => _AppUpdateBannerState();
}

class _AppUpdateBannerState extends State<AppUpdateBanner> {
  Future<AppUpdateOffer?> _load() async {
    final api = AppScope.read(context).engine?.api;
    if (api == null) return null;
    try {
      return await availableUpdate(api);
    } catch (_) {
      return null; // Offline or an older server: no banner.
    }
  }

  @override
  Widget build(BuildContext context) {
    final platform = selfUpdatePlatform;
    if (platform == null || AppUpdateBanner._later) {
      return const SizedBox.shrink();
    }
    final c = FamioColors.of(context);
    return FutureBuilder<AppUpdateOffer?>(
      future: AppUpdateBanner._cached ??= _load(),
      builder: (context, snapshot) {
        final offer = snapshot.data;
        if (offer == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: SoftCard(
            color: c.tint(FamioSection.settings),
            onTap: () => showAppUpdateDialog(context, offer, platform),
            child: Row(
              children: [
                Icon(
                  AppIcons.cloudArrowDown,
                  color: c.strong(FamioSection.settings),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr.appUpdateAvailable(offer.version),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        tr.appUpdateFromServer,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: tr.commonLater,
                  icon: const Icon(AppIcons.x),
                  onPressed: () =>
                      setState(() => AppUpdateBanner._later = true),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Downloads, checks and installs [offer], with progress.
Future<void> showAppUpdateDialog(
  BuildContext context,
  AppUpdateOffer offer,
  AppPlatform platform,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _AppUpdateDialog(offer: offer, platform: platform),
);

class _AppUpdateDialog extends StatefulWidget {
  const _AppUpdateDialog({required this.offer, required this.platform});

  final AppUpdateOffer offer;
  final AppPlatform platform;

  @override
  State<_AppUpdateDialog> createState() => _AppUpdateDialogState();
}

enum _Step { ready, allow, downloading, installing, failed }

class _AppUpdateDialogState extends State<_AppUpdateDialog> {
  var _step = _Step.ready;
  double? _progress;
  String? _error;

  Future<void> _start() async {
    if (!await canInstallUpdates()) {
      setState(() => _step = _Step.allow);
      return;
    }
    if (!mounted) return;
    final api = AppScope.read(context).engine!.api;
    setState(() {
      _step = _Step.downloading;
      _progress = null;
    });
    try {
      final file = await downloadUpdate(
        api,
        widget.offer,
        widget.platform,
        onProgress: (v) {
          if (mounted) setState(() => _progress = v.clamp(0, 1));
        },
      );
      if (!mounted) return;
      setState(() => _step = _Step.installing);
      await installUpdate(file, widget.platform);
      // Android shows its own confirmation; nothing more to do here.
      if (mounted) Navigator.pop(context);
    } on AppUpdateError catch (e) {
      _fail(e.message);
    } on ApiError catch (e) {
      _fail(e.message);
    } catch (e) {
      _fail(tr.appUpdateFailed('$e'));
    }
  }

  void _fail(String message) {
    if (mounted) {
      setState(() {
        _step = _Step.failed;
        _error = message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _step == _Step.downloading || _step == _Step.installing;
    final desktop = widget.platform != AppPlatform.android;
    return AlertDialog(
      title: Text(tr.appUpdateAvailable(widget.offer.version)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(switch (_step) {
            _Step.ready =>
              desktop ? tr.appUpdateRestartHint : tr.appUpdateAndroidHint,
            _Step.allow => tr.appUpdateAllowInstall,
            _Step.downloading => tr.appUpdateDownloading,
            _Step.installing => tr.appUpdateInstalling,
            _Step.failed => _error ?? '',
          }),
          if (busy) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: _step == _Step.downloading ? _progress : null,
            ),
          ],
          if (_step == _Step.ready) ...[
            const SizedBox(height: 8),
            Text(
              tr.appUpdateSize(
                (widget.offer.size / (1024 * 1024)).toStringAsFixed(0),
              ),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
      actions: [
        if (!busy)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr.commonLater),
          ),
        if (_step == _Step.allow)
          FilledButton(
            onPressed: () async {
              await allowInstallingUpdates();
              if (mounted) setState(() => _step = _Step.ready);
            },
            child: Text(tr.appUpdateAllow),
          )
        else if (!busy)
          FilledButton(
            onPressed: _start,
            child: Text(
              _step == _Step.failed ? tr.commonRetry : tr.appUpdateNow,
            ),
          ),
      ],
    );
  }
}
