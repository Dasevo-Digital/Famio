import 'dart:async';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/form_dialog.dart';
import '../widgets/password_reveal.dart';
import 'calendar_connect_screen.dart';
import '../widgets/section_header.dart';

/// Whether this member may connect lists in other apps.
bool canConnectLists(AppState state) =>
    !state.hiddenModules.contains(ServerSettings.listSyncModule) &&
    !(state.me?.isGuest ?? true);

/// Connects tasks and shopping lists with Bring!, Microsoft To Do and
/// reminder apps.
class ListConnectScreen extends StatefulWidget {
  const ListConnectScreen({super.key, this.section = FamioSection.shopping});

  /// Where it was opened from (colors only).
  final FamioSection section;

  @override
  State<ListConnectScreen> createState() => _ListConnectScreenState();
}

class _ListConnectScreenState extends State<ListConnectScreen> {
  late Future<List<ListAccount>> _accounts = _load();
  final _busy = <String>{};

  FamioApiClient get _api => AppScope.read(context).engine!.api;

  Future<List<ListAccount>> _load() =>
      AppScope.read(context).engine!.api.listAccounts();

  void _reload() => setState(() => _accounts = _load());

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _run(String id, Future<Object?> Function() action) async {
    setState(() => _busy.add(id));
    try {
      await action();
    } on ApiError catch (e) {
      if (mounted) _say(e.message);
    } finally {
      if (mounted) {
        setState(() => _busy.remove(id));
        _reload();
      }
    }
  }

  Future<void> _connectBring() async {
    final email = TextEditingController();
    final password = TextEditingController();
    ListAccount? added;
    await showDialog<void>(
      context: context,
      builder: (context) => FormDialog(
        title: 'Bring! verbinden',
        submitLabel: 'Anmelden',
        controllers: [email, password],
        fields: [
          const Text(
            'Bring! hat keine offizielle Schnittstelle. Famio nutzt die der '
            'Bring!-Apps (wie Home Assistant); sie kann sich jederzeit '
            'ändern, dann pausiert der Abgleich. Famio speichert nur ein '
            'Anmelde-Token, nicht dein Passwort.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: email,
            autofocus: true,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(labelText: 'E-Mail-Adresse'),
          ),
          PasswordReveal(
            builder: (_, obscure, toggle) => TextField(
              controller: password,
              obscureText: obscure,
              contextMenuBuilder: PasswordReveal.contextMenu,
              decoration: InputDecoration(
                labelText: 'Bring!-Passwort',
                suffixIcon: toggle,
              ),
            ),
          ),
        ],
        onSubmit: () async {
          added = await _api.connectBring(
            email: email.text,
            password: password.text,
          );
        },
      ),
    );
    if (added != null && mounted) {
      _reload();
      await _editLinks(added!);
    }
  }

  Future<void> _connectMicrosoft() async {
    final clientId = TextEditingController();
    DeviceLogin? login;
    await showDialog<void>(
      context: context,
      builder: (context) => FormDialog(
        title: 'Microsoft To Do verbinden',
        submitLabel: 'Weiter',
        controllers: [clientId],
        fields: [
          const Text(
            'Einmalig für die Familie: Im Microsoft-Entra-Portal '
            '(entra.microsoft.com) unter „App-Registrierungen“ eine neue App '
            'anlegen – Kontotyp „Konten in einem beliebigen '
            'Organisationsverzeichnis und persönliche Microsoft-Konten“, '
            'unter „Authentifizierung“ „Öffentliche Clientflows zulassen“ '
            'einschalten. Die Anwendungs-ID (Client-ID) hier eintragen.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: clientId,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Anwendungs-ID (Client-ID)',
              hintText: '00000000-0000-0000-0000-000000000000',
            ),
          ),
        ],
        onSubmit: () async {
          login = await _api.startMicrosoftLogin(clientId.text.trim());
        },
      ),
    );
    if (login == null || !mounted) return;
    final added = await showDialog<ListAccount>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DeviceLoginDialog(login: login!, api: _api),
    );
    if (added != null && mounted) {
      _reload();
      await _editLinks(added);
    }
  }

  Future<void> _editLinks(ListAccount account) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _LinksPage(account: account),
      ),
    );
    if (saved == true) _reload();
  }

  Future<void> _remove(ListAccount a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('„${a.name}“ trennen?'),
        content: const Text(
          'Der Abgleich endet. Einträge bleiben auf beiden Seiten erhalten.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Trennen'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await _run(a.id, () => _api.disconnectListAccount(a.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final engine = state.engine!;
    final c = FamioColors.of(context);
    final enabled = canConnectLists(state);
    final date = DateFormat('d.M., HH:mm', 'de');
    String famioName(String id) => id == ListAccount.tasksList
        ? 'Aufgaben'
        : engine.shoppingLists.where((l) => l.id == id).firstOrNull?.name ??
              'gelöschte Liste';
    return SectionPage(
      section: widget.section,
      title: 'Listen verbinden',
      subtitle: 'Bring!, Microsoft To Do, Apple Erinnerungen',
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 120),
            children: [
              const SectionHeader(
                'Apple Erinnerungen, Thunderbird & Co.',
                'Aufgaben und Einkaufslisten erscheinen dort als Listen, '
                    'sobald das Gerät per CalDAV mit Famio verbunden ist – '
                    'am Mac und iPhone über „Apple-Gerät einrichten“.',
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(AppIcons.arrowsLeftRight),
                    label: const Text('Zu „Kalender verbinden“'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const CalendarConnectScreen(),
                      ),
                    ),
                  ),
                ),
              ),
              const Divider(height: 40),
              const SectionHeader(
                'Mit Bring! und Microsoft To Do abgleichen',
                'Der Famio-Server gleicht die gewählten Listen in beide '
                    'Richtungen ab, alle 5 Minuten und kurz nach jeder '
                    'Änderung. Haben beide Seiten denselben Eintrag '
                    'geändert, gewinnt die neuere Änderung.',
              ),
              if (!enabled)
                const ListTile(
                  leading: Icon(AppIcons.eyeSlash),
                  title: Text('In dieser Familie ausgeschaltet'),
                  subtitle: Text(
                    'Ein Erwachsener mit Verwaltungsrechten kann es in der '
                    'Server-Verwaltung einschalten.',
                  ),
                )
              else
                FutureBuilder(
                  future: _accounts,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return ListTile(
                        leading: const Icon(AppIcons.cloudSlash),
                        title: const Text(
                          'Nur mit Verbindung zum Server verfügbar',
                        ),
                        trailing: TextButton(
                          onPressed: _reload,
                          child: const Text('Erneut'),
                        ),
                      );
                    }
                    final accounts = snapshot.data ?? const <ListAccount>[];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final a in accounts)
                          ListTile(
                            leading: Icon(
                              a.lastError == null
                                  ? (a.isBring
                                        ? AppIcons.basket
                                        : AppIcons.listChecks)
                                  : AppIcons.warningCircle,
                              color: a.lastError == null ? null : c.danger,
                            ),
                            title: Text(a.name),
                            subtitle: Text(
                              [
                                if (a.lastError != null) a.lastError!,
                                if (a.links.isEmpty)
                                  'Noch keine Liste zugeordnet'
                                else
                                  for (final l in a.links)
                                    '${famioName(l.famioList)} ↔ '
                                        '${l.remoteName.isEmpty ? 'Liste dort' : l.remoteName}',
                                if (a.lastSync != null)
                                  'Zuletzt ${date.format(a.lastSync!)}',
                              ].join('\n'),
                              style: a.lastError == null
                                  ? null
                                  : TextStyle(color: c.danger),
                            ),
                            isThreeLine: true,
                            trailing: _busy.contains(a.id)
                                ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: const Icon(
                                          AppIcons.arrowsClockwise,
                                        ),
                                        tooltip: 'Jetzt abgleichen',
                                        onPressed: () => _run(
                                          a.id,
                                          () => _api.syncListAccount(a.id),
                                        ),
                                      ),
                                      PopupMenuButton<String>(
                                        tooltip: 'Mehr',
                                        onSelected: (v) => v == 'links'
                                            ? _editLinks(a)
                                            : _remove(a),
                                        itemBuilder: (_) => const [
                                          PopupMenuItem(
                                            value: 'links',
                                            child: Text('Listen zuordnen …'),
                                          ),
                                          PopupMenuItem(
                                            value: 'remove',
                                            child: Text('Trennen'),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                          ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton.tonalIcon(
                                icon: const Icon(AppIcons.basket),
                                label: const Text('Bring! verbinden'),
                                onPressed: _connectBring,
                              ),
                              FilledButton.tonalIcon(
                                icon: const Icon(AppIcons.listChecks),
                                label: const Text('Microsoft To Do verbinden'),
                                onPressed: _connectMicrosoft,
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows the code to enter at Microsoft and waits until the member did.
class _DeviceLoginDialog extends StatefulWidget {
  const _DeviceLoginDialog({required this.login, required this.api});

  final DeviceLogin login;
  final FamioApiClient api;

  @override
  State<_DeviceLoginDialog> createState() => _DeviceLoginDialogState();
}

class _DeviceLoginDialogState extends State<_DeviceLoginDialog> {
  Timer? _timer;
  String? _error;
  var _asking = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      Duration(seconds: widget.login.interval.clamp(2, 30)),
      (_) => _poll(),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_asking) return;
    _asking = true;
    try {
      final account = await widget.api.pollMicrosoftLogin(widget.login.flow);
      if (account != null && mounted) Navigator.pop(context, account);
    } on ApiError catch (e) {
      _timer?.cancel();
      if (mounted) setState(() => _error = e.message);
    } finally {
      _asking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Bei Microsoft anmelden'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Öffne die Seite und gib diesen Code ein:'),
          const SizedBox(height: 12),
          Row(
            children: [
              SelectableText(
                widget.login.userCode,
                style: theme.textTheme.headlineSmall,
              ),
              IconButton(
                icon: const Icon(AppIcons.copy),
                tooltip: 'Code kopieren',
                onPressed: () => Clipboard.setData(
                  ClipboardData(text: widget.login.userCode),
                ),
              ),
            ],
          ),
          TextButton.icon(
            icon: const Icon(AppIcons.arrowSquareOut),
            label: Text(widget.login.verificationUri),
            onPressed: () => launchUrl(
              Uri.parse(widget.login.verificationUri),
              mode: LaunchMode.externalApplication,
            ),
          ),
          const SizedBox(height: 8),
          if (_error == null)
            const Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 12),
                Expanded(child: Text('Warte auf die Bestätigung …')),
              ],
            )
          else
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
      ],
    );
  }
}

/// Which Famio list goes with which list there.
class _LinksPage extends StatefulWidget {
  const _LinksPage({required this.account});

  final ListAccount account;

  @override
  State<_LinksPage> createState() => _LinksPageState();
}

class _LinksPageState extends State<_LinksPage> {
  late final Future<List<RemoteListInfo>> _remote = AppScope.read(
    context,
  ).engine!.api.remoteLists(widget.account.id);
  late final Map<String, String?> _choice = {
    for (final l in widget.account.links) l.famioList: l.remoteList,
  };
  var _saving = false;
  String? _error;

  Future<void> _save(List<RemoteListInfo> remote) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await AppScope.read(context).engine!.api.setListLinks(widget.account.id, [
        for (final MapEntry(key: famio, value: id) in _choice.entries)
          if (id != null)
            ListLink(
              famioList: famio,
              remoteList: id,
              remoteName:
                  remote.where((r) => r.id == id).firstOrNull?.name ?? '',
            ),
      ]);
      if (mounted) Navigator.pop(context, true);
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.of(context).engine!;
    final famio = [
      if (!widget.account.isBring) (ListAccount.tasksList, 'Aufgaben'),
      for (final l in engine.shoppingLists) (l.id, l.name),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(widget.account.name)),
      body: FutureBuilder(
        future: _remote,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            final error = snapshot.error;
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  error is ApiError ? error.message : 'Nicht erreichbar',
                ),
              ),
            );
          }
          final remote = snapshot.data;
          if (remote == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Wähle zu jeder Famio-Liste die Liste dort. Einträge, die '
                'auf beiden Seiten gleich heißen, werden beim ersten Abgleich '
                '${widget.account.isBring ? 'zusammengeführt' : 'beide behalten'}.',
              ),
              const SizedBox(height: 16),
              for (final (id, name) in famio)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: DropdownButtonFormField<String?>(
                    initialValue: remote.any((r) => r.id == _choice[id])
                        ? _choice[id]
                        : null,
                    decoration: InputDecoration(labelText: name),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('Nicht abgleichen'),
                      ),
                      for (final r in remote)
                        DropdownMenuItem(value: r.id, child: Text(r.name)),
                    ],
                    onChanged: (v) => setState(() => _choice[id] = v),
                  ),
                ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _saving ? null : () => _save(remote),
                  child: Text(_saving ? 'Gleiche ab …' : 'Speichern'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
