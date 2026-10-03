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
      _snack(
        'Ohne Standortzugriff kann Famio nichts teilen. Du kannst ihn in den '
        'App-Einstellungen erlauben.',
      );
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
        title: const Text('Standort auch im Hintergrund teilen?'),
        content: const Text(
          'Damit Famio deinen Standort auch bei geschlossener App zuverlässig '
          'aktualisieren kann, braucht es den Standortzugriff „Immer '
          'zulassen“. Android öffnet dafür gleich seine Einstellungen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Später'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Freigabe aktivieren'),
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
          'Den eigenen Standort teilt man mit der Famio-App auf dem Handy '
          '(Android oder iPhone). Hier siehst du, wo die anderen sind.',
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
            Text('Meinen Standort teilen', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Deine Familie sieht auf der Karte, wo du bist, und bekommt '
              'Bescheid, wenn du an einem Ort ankommst. Positionen werden '
              'nach 7 Tagen gelöscht. Pausieren geht nur mit dem Eltern-Code.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            ColorButton(
              label: 'Standort teilen',
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
          'Standortzugriff fehlt – antippen zum Erlauben',
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
        (
          'Hintergrundortung ist nicht aktiv – der Standort wird nur bei '
              'geöffneter App zuverlässig aktualisiert',
          _askAlways,
        ),
      if (!device.locationOn)
        ('Standort ist am Handy ausgeschaltet', () async {}),
      // Approximate location is rounded to roughly 2 km: short trips
      // never show up.
      if (device.permission != LocationPermission.none && !device.precise)
        (
          'Nur „ungefährer“ Standort erlaubt – kurze Wege bleiben '
              'unsichtbar. Antippen und „Genauen Standort“ einschalten',
          LocationSharing.openAppSettings,
        ),
      if (!device.batteryUnrestricted)
        (
          'Akku-Optimierung kann die Freigabe stoppen – antippen',
          LocationSharing.openBatterySettings,
        ),
      if (!device.notifications)
        ('Benachrichtigungen sind aus', LocationSharing.openAppSettings),
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
                      ? 'Freigabe pausiert'
                      : scheduled
                      ? 'Freigabe nach Zeitplan aus'
                      : backgroundLimited
                      ? 'Standortfreigabe eingeschränkt'
                      : 'Du teilst deinen Standort',
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
            'Zeitplan: ${scheduleLabel(_schedule)}',
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
                  label: const Text('Fortsetzen'),
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
                  label: const Text('Pausieren'),
                  onPressed: _busy
                      ? null
                      : () => showPauseDialog(context, member: me),
                ),
              TextButton.icon(
                icon: const Icon(AppIcons.clock),
                label: const Text('Zeitplan'),
                onPressed: _busy ? null : _editSchedule,
              ),
              TextButton.icon(
                icon: const Icon(AppIcons.stop),
                label: const Text('Beenden'),
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
      LocationPermission.always => 'Immer erlaubt',
      LocationPermission.foreground => 'Nur bei geöffneter App',
      LocationPermission.none => 'Nicht erlaubt',
    };
    final rows = <String>[
      'Berechtigung: $permission'
          '${device.permission == LocationPermission.none
              ? ''
              : device.precise
              ? ' · genau'
              : ' · nur ungefähr'}',
      'Letzter GPS-Fix: ${_when(device.lastFixAt, now)}',
      'Letzter erfolgreicher Positions-Upload: '
          '${_when(device.lastSuccessfulUploadAt, now)}',
      'Letzte Serverantwort: ${_when(device.lastServerResponseAt, now)}'
          '${device.lastServerStatus == null ? '' : ' (${device.lastServerStatus})'}',
      if (device.lastErrorAt != null)
        'Letzter Übertragungsfehler: ${_when(device.lastErrorAt, now)}'
            '${device.lastError == null ? '' : ' (${device.lastError})'}',
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
          Text('Diagnose', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          for (final row in rows) Text(row, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  String _when(DateTime? at, DateTime now) =>
      at == null ? 'noch nie' : ago(at, now: now);
}

// --- places -------------------------------------------------------------------
