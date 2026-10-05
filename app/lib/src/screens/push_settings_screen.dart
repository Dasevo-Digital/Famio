import 'dart:math';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../push/own_push.dart';

/// Push notifications: directly from the Famio server (own push) or
/// through ntfy.
class PushSettingsScreen extends StatefulWidget {
  const PushSettingsScreen({super.key});

  @override
  State<PushSettingsScreen> createState() => _PushSettingsScreenState();
}

class _PushSettingsScreenState extends State<PushSettingsScreen> {
  late Future<List<PushTarget>> _targets = _load();

  Future<List<PushTarget>> _load() =>
      AppScope.read(context).engine!.api.pushTargets();

  void _reload() => setState(() => _targets = _load());

  Future<void> _add() async {
    final added = await showDialog<PushTarget>(
      context: context,
      builder: (_) => const _AddTargetDialog(),
    );
    if (added == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added.lastError == null
              ? 'Testnachricht gesendet – kam sie an?'
              : 'Hinzugefügt, aber: ${added.lastError}',
        ),
      ),
    );
    _reload();
  }

  Future<void> _test(PushTarget t) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final error = await AppScope.read(
        context,
      ).engine!.api.testPushTarget(t.id);
      messenger.showSnackBar(
        SnackBar(content: Text(error ?? 'Testnachricht gesendet')),
      );
    } on ApiError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
    _reload();
  }

  Future<void> _delete(PushTarget t) async {
    await AppScope.read(context).engine!.api.deletePushTarget(t.id);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final accent = c.strong(FamioSection.settings);
    return SectionPage(
      maxBodyWidth: 720,
      section: FamioSection.settings,
      title: 'Benachrichtigungen',
      subtitle: 'Nachrichten, Aufgaben, Termine & Anfragen',

      body: FutureBuilder<List<PushTarget>>(
        future: _targets,
        builder: (context, snapshot) {
          final targets = snapshot.data ?? const [];
          return ListView(
            padding: EdgeInsets.only(bottom: listBottomPadding(context)),
            children: [
              const _OwnPushCard(),
              const SizedBox(height: 12),
              const QuietHoursCard(),
              ListHeading(
                'Alternativ: über ntfy',
                color: accent,
                trailing: TextButton.icon(
                  icon: const Icon(AppIcons.plus, size: 18),
                  label: const Text('Gerät hinzufügen'),
                  onPressed: _add,
                ),
              ),
              SoftCard(
                color: c.tint(FamioSection.settings),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Für iPhones oder wenn du ntfy schon nutzt',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '1. Die kostenlose App „ntfy“ installieren (Play Store, '
                      'F-Droid oder App Store).\n'
                      '2. Hier ein Gerät hinzufügen – Famio erzeugt ein '
                      'geheimes Thema.\n'
                      '3. Dieses Thema in ntfy abonnieren.\n\n'
                      'Famio meldet dann neue Nachrichten, Aufgaben für dich, '
                      'Termin-Kommentare, Ämter-Anfragen und Ortsmeldungen. '
                      'Ohne „Details“ erfährt der Push-Server nur „Neue '
                      'Nachricht“ o. Ä. – nie Namen oder Inhalte.',
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        icon: const Icon(AppIcons.arrowSquareOut, size: 18),
                        label: const Text('ntfy.sh'),
                        onPressed: () => launchUrl(
                          Uri.parse('https://ntfy.sh'),
                          mode: LaunchMode.externalApplication,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (snapshot.hasError)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    snapshot.error is ApiError
                        ? (snapshot.error! as ApiError).message
                        : 'Laden fehlgeschlagen',
                  ),
                ),
              if (snapshot.connectionState == ConnectionState.waiting)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),

              for (final t in targets)
                ListTile(
                  leading: Icon(
                    t.lastError == null
                        ? AppIcons.bellRing
                        : AppIcons.warningCircle,
                    color: t.lastError == null ? accent : c.danger,
                  ),
                  title: Text(t.name),
                  subtitle: Text(
                    [
                      t.url,
                      t.details ? 'mit Details' : 'ohne Details',
                      ?t.lastError,
                    ].join('\n'),
                  ),
                  isThreeLine: true,
                  trailing: Wrap(
                    children: [
                      IconButton(
                        tooltip: 'Test senden',
                        icon: const Icon(AppIcons.paperPlaneRight),
                        onPressed: () => _test(t),
                      ),
                      IconButton(
                        tooltip: 'Entfernen',
                        icon: Icon(AppIcons.trash, color: c.danger),
                        onPressed: () => _delete(t),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The member's quiet time: notifications arrive silently, on every device
/// and through ntfy.
class QuietHoursCard extends StatefulWidget {
  const QuietHoursCard({super.key});

  @override
  State<QuietHoursCard> createState() => _QuietHoursCardState();
}

class _QuietHoursCardState extends State<QuietHoursCard> {
  late QuietHours _quiet = AppScope.read(context).quietHours;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    try {
      final quiet = await AppScope.read(context).engine!.api.quietHours();
      if (mounted) setState(() => _quiet = quiet);
    } on ApiError {
      // Offline: show what this device knows.
    }
  }

  Future<void> _save(QuietHours value) async {
    final previous = _quiet;
    setState(() {
      _quiet = value;
      _busy = true;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await AppScope.read(context).setQuietHours(value);
    } on ApiError catch (e) {
      if (mounted) setState(() => _quiet = previous);
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick({required bool start}) async {
    final minutes = start ? _quiet.start : _quiet.end;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
      helpText: start ? 'Ruhezeit ab' : 'Ruhezeit bis',
    );
    if (picked == null) return;
    final value = picked.hour * 60 + picked.minute;
    await _save(
      start ? _quiet.copyWith(start: value) : _quiet.copyWith(end: value),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = _quiet;
    return SoftCard(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Ruhezeit', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'In dieser Zeit kommen Nachrichten, neue Termine und Aufgaben '
            'ohne Ton an – auf allen deinen Geräten und über ntfy. '
            'Erinnerungen, die du selbst gestellt hast (Termine, '
            'Medikamente), bleiben laut.',
            style: theme.textTheme.bodySmall,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(AppIcons.moon),
            title: const Text('Ruhezeit einschalten'),
            value: q.enabled,
            onChanged: _busy ? null : (v) => _save(q.copyWith(enabled: v)),
          ),
          if (q.enabled) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(AppIcons.clock, size: 18),
                  label: Text('ab ${QuietHours.format(q.start)} Uhr'),
                  onPressed: _busy ? null : () => _pick(start: true),
                ),
                OutlinedButton.icon(
                  icon: const Icon(AppIcons.clock, size: 18),
                  label: Text('bis ${QuietHours.format(q.end)} Uhr'),
                  onPressed: _busy ? null : () => _pick(start: false),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Ortsmeldungen trotzdem laut'),
              subtitle: const Text('z. B. „Mia ist zu Hause angekommen“'),
              value: q.placesLoud,
              onChanged: _busy ? null : (v) => _save(q.copyWith(placesLoud: v)),
            ),
          ],
        ],
      ),
    );
  }
}

/// Famio's own push on this device: switch, details, test.
class _OwnPushCard extends StatefulWidget {
  const _OwnPushCard();

  @override
  State<_OwnPushCard> createState() => _OwnPushCardState();
}

class _OwnPushCardState extends State<_OwnPushCard>
    with WidgetsBindingObserver {
  OwnPushStatus? _status;
  var _busy = false;

  OwnPush? get _push => AppScope.read(context).ownPush;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from Android's settings (notifications, battery).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final status = await _push?.status();
    if (mounted) setState(() => _status = status);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
    } on ApiError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } on PlatformException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.message ?? 'Nicht möglich')),
      );
    } finally {
      await _load();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final push = _push;
    final status = _status;
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    if (push == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'Benachrichtigungen sind auf diesem Gerät nicht verfügbar.',
        ),
      );
    }
    final enabled = status?.enabled ?? push.active;
    return SoftCard(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Direkt über Famio', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            OwnPush.native
                ? 'Famio hält im Hintergrund eine Verbindung zu deinem '
                      'Server – auch wenn die App geschlossen ist. Ohne ntfy, '
                      'ohne Google; alles bleibt auf deinem Server. Android '
                      'zeigt dafür dauerhaft „Famio ist bereit“ an – gedrückt '
                      'halten, um es auszublenden.'
                : 'Solange Famio läuft, meldet es Neues, auch im '
                      'Hintergrund. Ohne ntfy – alles bleibt auf deinem '
                      'Server.',
            style: theme.textTheme.bodySmall,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              OwnPush.native ? 'Auf diesem Handy' : 'Auf diesem Gerät',
            ),
            value: enabled,
            onChanged: _busy || status == null
                ? null
                : (v) => _run(() => push.setEnabled(v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Inhalte anzeigen'),
            subtitle: Text(
              'Namen und Texte, z. B. die Chat-Nachricht. Aus: nur „Neue '
              'Nachricht“ o. Ä.'
              '${OwnPush.native ? ' Der Sperrbildschirm zeigt nie Inhalte.' : ''}',
            ),
            value: status?.details ?? true,
            onChanged: _busy || status == null
                ? null
                : (v) => _run(() => push.setDetails(v)),
          ),
          if (enabled && OwnPush.native && status != null) ...[
            if (!status.notifications)
              _Hint(
                icon: AppIcons.warningCircle,
                color: c.danger,
                text: 'Android erlaubt Famio keine Benachrichtigungen.',
                action: 'Einstellungen',
                onPressed: () => _run(
                  () => const MethodChannel(
                    'famio/location',
                  ).invokeMethod('openAppSettings'),
                ),
              ),
            if (!status.batteryUnrestricted)
              _Hint(
                icon: AppIcons.warningCircle,
                color: c.danger,
                text:
                    'Akku-Optimierung ist an – Android kann die Verbindung '
                    'dann trennen.',
                action: 'Ausnehmen',
                onPressed: () => _run(
                  () => const MethodChannel(
                    'famio/location',
                  ).invokeMethod('openBatterySettings'),
                ),
              ),
          ],
          if (enabled)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(AppIcons.paperPlaneRight, size: 18),
                label: const Text('Test senden'),
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await push.test();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Testnachricht unterwegs'),
                            ),
                          );
                        }
                      }),
              ),
            ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({
    required this.icon,
    required this.color,
    required this.text,
    required this.action,
    required this.onPressed,
  });

  final IconData icon;
  final Color color;
  final String text;
  final String action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
        TextButton(onPressed: onPressed, child: Text(action)),
      ],
    ),
  );
}

class _AddTargetDialog extends StatefulWidget {
  const _AddTargetDialog();

  @override
  State<_AddTargetDialog> createState() => _AddTargetDialogState();
}

class _AddTargetDialogState extends State<_AddTargetDialog> {
  static String _topic() {
    const chars = 'abcdefghijkmnpqrstuvwxyz23456789';
    final random = Random.secure();
    return 'famio-${List.generate(20, (_) => chars[random.nextInt(chars.length)]).join()}';
  }

  final _name = TextEditingController(text: 'Handy');
  final _url = TextEditingController(text: 'https://ntfy.sh/${_topic()}');
  final _token = TextEditingController();
  var _details = false;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final target = await AppScope.read(context).engine!.api.addPushTarget(
        name: _name.text.trim(),
        url: _url.text.trim(),
        token: _token.text.trim().isEmpty ? null : _token.text.trim(),
        details: _details,
      );
      if (mounted) Navigator.pop(context, target);
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final topic = Uri.tryParse(_url.text)?.pathSegments.lastOrNull ?? '';
    return AlertDialog(
      scrollable: true,
      title: const Text('Gerät hinzufügen'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name des Geräts'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'ntfy-Thema (Adresse)',
                helperText:
                    'Eigener ntfy-Server? Adresse anpassen. Den Namen geheim '
                    'halten – wer ihn kennt, kann mitlesen.',
                helperMaxLines: 3,
                suffixIcon: IconButton(
                  tooltip: 'Thema kopieren',
                  icon: const Icon(AppIcons.copy),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: topic));
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('„$topic“ kopiert')));
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'In der ntfy-App: + → Thema „$topic“ abonnieren'
              '${Uri.tryParse(_url.text)?.host == 'ntfy.sh' ? '' : ' (Server: ${Uri.tryParse(_url.text)?.origin ?? ''})'}.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _token,
              decoration: const InputDecoration(
                labelText: 'Zugangstoken (optional)',
                helperText: 'Nur bei geschützten ntfy-Servern (tk_…)',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Details anzeigen'),
              subtitle: const Text(
                'Namen und Texte mitsenden. Nur mit eigenem ntfy-Server '
                'empfohlen.',
              ),
              value: _details,
              onChanged: (v) => setState(() => _details = v),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('Hinzufügen & testen'),
        ),
      ],
    );
  }
}
