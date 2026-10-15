part of '../admin_screens.dart';

/// Admins let the server hand out the app packages of its own version
/// (Android, Windows, Linux); the apps then offer the update themselves.
Future<void> showAppUpdatesDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _AppUpdatesDialog(),
);

class _AppUpdatesDialog extends StatefulWidget {
  const _AppUpdatesDialog();

  @override
  State<_AppUpdatesDialog> createState() => _AppUpdatesDialogState();
}

class _AppUpdatesDialogState extends State<_AppUpdatesDialog> {
  Map<String, Object?> _info = const {};
  String? _error;
  var _loading = true;
  var _busy = false;

  FamioApiClient get _api => AppScope.read(context).engine!.api;

  @override
  void initState() {
    super.initState();
    _run(_api.appUpdates, loading: true);
  }

  Future<void> _run(
    Future<Map<String, Object?>> Function() call, {
    bool loading = false,
  }) async {
    setState(() {
      _busy = !loading;
      _error = null;
    });
    try {
      final json = await call();
      if (mounted) setState(() => _info = json);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final enabled = _info['enabled'] == true;
    final lastError = _info['error'] as String?;
    return AlertDialog(
      title: Text(tr.adminAppUpdates),
      content: SizedBox(
        width: 480,
        child: _loading
            ? const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    tr.adminAppUpdatesIntro,
                    style: TextStyle(color: c.inkSoft),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr.adminAppUpdatesOn),
                    value: enabled,
                    onChanged: _busy
                        ? null
                        : (on) => _run(() => _api.saveAppUpdates(enabled: on)),
                  ),
                  if (_busy) const LinearProgressIndicator(),
                  if (enabled && !_busy) ...[
                    Text(
                      _appUpdatesReady(_info),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (lastError != null && lastError.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        localizeServerText(lastError),
                        style: TextStyle(color: c.danger),
                      ),
                    ],
                  ],
                  if (_error case final error?) ...[
                    const SizedBox(height: 8),
                    Text(error, style: TextStyle(color: c.danger)),
                  ],
                ],
              ),
      ),
      actions: [
        if (enabled)
          TextButton(
            onPressed: _busy ? null : () => _run(_api.refreshAppUpdates),
            child: Text(tr.adminAppUpdatesRefresh),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr.commonClose),
        ),
      ],
    );
  }
}

/// "Bereit für Version 2.0.1: Android, Windows, Linux" from the server's
/// state of the app updates.
String _appUpdatesReady(Map<String, Object?> info) {
  final packages = (info['packages'] as Map?)?.keys.toList() ?? const [];
  if (packages.isEmpty) return tr.adminAppUpdatesNone;
  return tr.adminAppUpdatesReady(
    '${info['version']}',
    [
      for (final p in packages)
        switch (p) {
          'android' => 'Android',
          'androidArm64' => 'Android (64 Bit)',
          'windows' => 'Windows',
          'linux' => 'Linux',
          _ => '$p',
        },
    ].join(', '),
  );
}
