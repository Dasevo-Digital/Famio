part of '../location_screens.dart';

/// This phone's sharing switch with everything that may stop it working.
class MySharingCard extends StatefulWidget {
  const MySharingCard({super.key, this.location, this.place});

  /// The own sharing status as the family sees it (from the server).
  final MemberLocation? location;
  final Place? place;

  @override
  State<MySharingCard> createState() => _MySharingCardState();
}

class _MySharingCardState extends State<MySharingCard>
    with WidgetsBindingObserver {
  DeviceSharingStatus? _device;
  LocationSchedule? _schedule;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from the system settings: the permissions may have changed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    if (!LocationSharing.supported) return;
    final status = await LocationSharing.status();
    if (!mounted) return;
    final api = AppScope.read(context).engine?.api;
    LocationSchedule? schedule = _schedule;
    try {
      schedule = await api?.locationSchedule();
    } on ApiError {
      // The device diagnosis remains useful when the server is offline.
    }
    if (mounted) {
      setState(() {
        _device = status;
        _schedule = schedule;
      });
    }
  }

  Future<void> _editSchedule() async {
    final schedule = await showLocationScheduleDialog(
      context,
      initial: _schedule,
    );
    if (!mounted) return;
    setState(() => _schedule = schedule);
    unawaited(AppScope.read(context).engine?.sync());
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on ApiError catch (e) {
      _snack(e.message);
    } finally {
      await _refresh();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _enable() => _run(() async {
    final state = AppScope.read(context);
    var status = await LocationSharing.requestPermission();
    if (status.permission == LocationPermission.none) {
      _snack(tr.locationWithoutLocationAccessFamio);
      return;
    }
    await LocationSharing.enable(
      api: state.engine!.api,
      serverUrl: state.serverUrl!,
      certificatePin: state.certificatePin,
      device: AppState.deviceName,
      places: state.engine!.places,
    );
    status = await LocationSharing.status();
    if (!mounted) return;
    if (status.permission == LocationPermission.foreground) {
      await _askAlways();
    }
  });

  Future<void> _askAlways() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.locationShareLocationBackgroundToo),
        content: Text(tr.locationSoThatFamioCan),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr.commonLater),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr.locationTurnSharing),
          ),
        ],
      ),
    );
    if (ok == true) await LocationSharing.requestPermission(background: true);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final c = FamioColors.of(context);
    final accent = c.strong(FamioSection.location);
    if (!LocationSharing.supported) {
      return SoftCard(
        color: c.tint(FamioSection.location),
        padding: const EdgeInsets.all(16),
        child: Text(
          tr.locationYouShareOwnLocation,
          style: theme.textTheme.bodySmall,
        ),
      );
    }
    final device = _device;
    if (device == null) return const SizedBox(height: 8);
    final me = state.me!;
    final mine = widget.location;

    if (!device.enabled) {
      return SoftCard(
        color: c.tint(FamioSection.location),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr.locationShareMyLocation,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              tr.locationFamilySeesMapWhere,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            ColorButton(
              label: tr.locationShareLocation,
              icon: AppIcons.locate,
              color: accent,
              onPressed: _busy ? null : _enable,
            ),
          ],
        ),
      );
    }

    final paused = mine?.state == SharingState.paused;
    final scheduled = mine?.state == SharingState.scheduled;
    final backgroundLimited =
        device.permission == LocationPermission.foreground;
    final hints = <(String, Future<void> Function())>[
      if (device.permission == LocationPermission.none)
        (
          tr.locationLocationAccessMissingTap,
          () async {
            final s = await LocationSharing.requestPermission();
            if (s.permission == LocationPermission.none) {
              await LocationSharing.openAppSettings();
            } else {
              await _refreshService(state);
            }
          },
        ),
      if (backgroundLimited)
        (tr.locationBackgroundLocationNotActive, _askAlways),
      if (!device.locationOn) (tr.locationLocationTurnedOffPhone, () async {}),
      // Approximate location is rounded to roughly 2 km: short trips
      // never show up.
      if (device.permission != LocationPermission.none && !device.precise)
        (
          tr.locationOnlyApproximateLocationAllowed,
          LocationSharing.openAppSettings,
        ),
      if (!device.batteryUnrestricted)
        (
          tr.locationBatteryOptimizationCanStop,
          LocationSharing.openBatterySettings,
        ),
      if (!device.notifications)
        (tr.locationNotificationsOff, LocationSharing.openAppSettings),
    ];
    return SoftCard(
      color: c.tint(FamioSection.location),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                paused || scheduled ? AppIcons.pause : AppIcons.locate,
                color: accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  paused
                      ? tr.locationSharingPaused
                      : scheduled
                      ? tr.locationSharingOffSchedule
                      : backgroundLimited
                      ? tr.locationLocationSharingRestricted
                      : tr.locationYouShareLocation,
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            sharingLabel(mine, widget.place),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            tr.locationScheduleSchedule(scheduleLabel(_schedule)),
            style: theme.textTheme.bodySmall,
          ),
          for (final (text, action) in hints)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: InkWell(
                onTap: () => _run(action),
                child: Row(
                  children: [
                    Icon(AppIcons.warningCircle, size: 16, color: c.danger),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        text,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: c.danger,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          _LocationDiagnostics(location: mine, device: device),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (paused)
                FilledButton.tonalIcon(
                  icon: const Icon(AppIcons.play),
                  label: Text(tr.locationResume),
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          await state.engine!.api.resumeLocation();
                          await _refreshService(state);
                          unawaited(state.engine!.sync());
                        }),
                )
              else
                FilledButton.tonalIcon(
                  icon: const Icon(AppIcons.pause),
                  label: Text(tr.locationPause),
                  onPressed: _busy
                      ? null
                      : () => showPauseDialog(context, member: me),
                ),
              TextButton.icon(
                icon: const Icon(AppIcons.clock),
                label: Text(tr.locationSchedule),
                onPressed: _busy ? null : _editSchedule,
              ),
              TextButton.icon(
                icon: const Icon(AppIcons.stop),
                label: Text(tr.commonEnd2),
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await showPauseDialog(
                          context,
                          member: me,
                          stopOnThisDevice: true,
                        );
                      }),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LocationDiagnostics extends StatelessWidget {
  const _LocationDiagnostics({required this.location, required this.device});

  final MemberLocation? location;
  final DeviceSharingStatus device;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final permission = switch (device.permission) {
      LocationPermission.always => tr.locationAlwaysAllowed,
      LocationPermission.foreground => tr.locationOnlyWhileAppOpen,
      LocationPermission.none => tr.locationNotAllowed,
    };
    final rows = <String>[
      tr.locationPermissionPermissionPrecision(
        permission,
        device.permission == LocationPermission.none
            ? ''
            : device.precise
            ? tr.locationPrecise
            : tr.locationApproximateOnly,
      ),
      tr.locationLastGpsFixTime(_when(device.lastFixAt, now)),
      tr.locationLastSuccessfulPositionUpload(
        _when(device.lastSuccessfulUploadAt, now),
      ),
      tr.locationLastServerResponseTime(
        _when(device.lastServerResponseAt, now),
        device.lastServerStatus == null ? '' : ' (${device.lastServerStatus})',
      ),
      if (device.lastErrorAt != null)
        tr.locationLastTransferErrorTime(
          _when(device.lastErrorAt, now),
          device.lastError == null ? '' : ' (${device.lastError})',
        ),
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr.locationDiagnostics, style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          for (final row in rows) Text(row, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  String _when(DateTime? at, DateTime now) =>
      at == null ? tr.locationNever : ago(at, now: now);
}

// --- places -------------------------------------------------------------------
