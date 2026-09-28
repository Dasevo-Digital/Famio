import 'dart:math';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';

/// Push notifications through ntfy: arrive even when Famio is closed.
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
      title: 'Push-Benachrichtigungen',
      subtitle: 'Auch wenn Famio geschlossen ist',
      floating: AddButton(
        color: accent,
        tooltip: 'Gerät hinzufügen',
        onPressed: _add,
      ),
      body: FutureBuilder<List<PushTarget>>(
        future: _targets,
        builder: (context, snapshot) {
          final targets = snapshot.data ?? const [];
          return ListView(
            padding: EdgeInsets.only(bottom: listBottomPadding(context)),
            children: [
              SoftCard(
                color: c.tint(FamioSection.settings),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'So funktioniert es',
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
              if (snapshot.hasData && targets.isEmpty)
                EmptyHint(
                  icon: AppIcons.bellRing,
                  color: accent,
                  text: 'Noch kein Gerät eingerichtet.',
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
