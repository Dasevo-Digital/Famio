import 'dart:convert';
import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/calendar_sharing.dart';
import '../widgets/form_dialog.dart';
import '../widgets/password_reveal.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/section_header.dart';

// --- calendar apps connecting to Famio (CalDAV server) ----------------------

/// Apple Calendar, DAVx5 & co. connected directly to Famio, each with its
/// own app password. Events can be edited there.
class CalDavAppsSection extends StatefulWidget {
  const CalDavAppsSection({super.key});

  @override
  State<CalDavAppsSection> createState() => _CalDavAppsSectionState();
}

class _CalDavAppsSectionState extends State<CalDavAppsSection> {
  late Future<(List<AppPassword>, Uri?)> _data = _load();

  Future<(List<AppPassword>, Uri?)> _load() async {
    final api = AppScope.read(context).engine!.api;
    final passwords = await api.appPasswords();
    final (_, publicUrl) = await api.calendarFeeds();
    return (passwords, publicUrl);
  }

  void _reload() => setState(() {
    _data = _load();
  });

  Future<void> _create() async {
    final api = AppScope.read(context).engine!.api;
    final name = TextEditingController();
    var confidential = false;
    String? secret;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => FormDialog(
          title: 'Neues App-Passwort',
          submitLabel: 'Erstellen',
          controllers: [name],
          fields: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Für welches Gerät?',
                hintText: 'z. B. iPhone von Mama',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Vertrauliche Termine zeigen'),
              subtitle: const Text(
                'Nur für eigene Geräte. Die Kalender-App speichert die '
                'Termine auf dem Gerät.',
              ),
              value: confidential,
              onChanged: (v) => setState(() => confidential = v),
            ),
          ],
          onSubmit: () async {
            final (_, s) = await api.createAppPassword(
              name: name.text,
              includeConfidential: confidential,
            );
            secret = s;
          },
        ),
      ),
    );
    if (secret == null || !mounted) return;
    _reload();
    await showDialog<void>(
      context: context,
      builder: (context) => _SecretDialog(secret: secret!),
    );
  }

  /// Creates a configuration profile for Apple Calendar and lets the user
  /// save it (Mac: opens it right away for installation).
  Future<void> _appleProfile(Uri local, Uri? publicUrl) async {
    final state = AppScope.read(context);
    final api = state.engine!.api;
    final messenger = ScaffoldMessenger.of(context);
    final name = TextEditingController(
      text: kIsWeb
          ? ''
          : Platform.isMacOS
          ? 'Mac von ${state.me!.displayName}'
          : Platform.isIOS
          ? 'iPhone von ${state.me!.displayName}'
          : '',
    );
    final address = TextEditingController(
      text: (publicUrl ?? local).toString(),
    );
    ({String fileName, String profile})? result;
    await showDialog<void>(
      context: context,
      builder: (context) => FormDialog(
        title: 'Apple-Gerät einrichten',
        submitLabel: 'Profil erstellen',
        controllers: [name, address],
        fields: [
          TextField(
            controller: name,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Für welches Gerät?',
              hintText: 'z. B. iPhone von Mama',
            ),
          ),
          TextField(
            controller: address,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: 'Serveradresse für dieses Gerät',
              helperText: local.host == 'localhost' || local.host == '127.0.0.1'
                  ? '„localhost“ gilt nur für diesen Mac – für andere Geräte '
                        'die Adresse im Heimnetz eintragen.'
                  : 'So, wie das Gerät den Server erreicht.',
              helperMaxLines: 3,
            ),
          ),
        ],
        onSubmit: () async {
          result = await api.appleProfile(
            url: FamioApiClient.normalizeUrl(address.text),
            name: name.text.trim().isEmpty ? null : name.text.trim(),
          );
        },
      ),
    );
    final profile = result;
    if (profile == null || !mounted) return;
    _reload();
    try {
      final saved = await FilePicker.saveFile(
        dialogTitle: 'Profil für Apple Kalender sichern',
        fileName: profile.fileName,
        bytes: Uint8List.fromList(utf8.encode(profile.profile)),
        mimeType: 'application/x-apple-aspen-config',
      );
      if (saved == null) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Nicht gesichert – das App-Passwort unten wieder trennen.',
            ),
          ),
        );
        return;
      }
      // The Mac shows downloaded profiles in the system settings.
      if (!kIsWeb && Platform.isMacOS) await launchUrl(saved);
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 10),
          content: Text(
            !kIsWeb && Platform.isMacOS
                ? 'Systemeinstellungen → Allgemein → Geräteverwaltung → '
                      '„Famio-Kalender“ installieren, danach die Datei löschen.'
                : 'Profil gesichert: auf dem Apple-Gerät öffnen und '
                      'installieren, danach die Datei löschen.',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Profil nicht gesichert ($e)')),
      );
    }
  }

  Future<void> _delete(AppPassword p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('„${p.name}“ trennen?'),
        content: const Text(
          'Die Kalender-App auf diesem Gerät kann sich danach nicht mehr '
          'mit Famio verbinden.',
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
    if (ok != true || !mounted) return;
    try {
      await AppScope.read(context).engine!.api.deleteAppPassword(p.id);
    } on ApiError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final c = FamioColors.of(context);
    return FutureBuilder(
      future: _data,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ListTile(
            leading: const Icon(AppIcons.cloudSlash),
            title: const Text('Nur mit Verbindung zum Server verfügbar'),
            trailing: TextButton(
              onPressed: _reload,
              child: const Text('Erneut'),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final (passwords, publicUrl) = snapshot.data!;
        final local = state.engine!.api.baseUrl;
        final user = state.me!.username;
        final dateFormat = DateFormat('d.M.yy, HH:mm', 'de');

        Widget address(String label, Uri base) => ListTile(
          dense: true,
          title: Text(label),
          subtitle: SelectableText(
            base.resolve('dav/').toString(),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          trailing: IconButton(
            icon: const Icon(AppIcons.copy),
            tooltip: 'Adresse kopieren',
            onPressed: () {
              Clipboard.setData(
                ClipboardData(text: base.resolve('dav/').toString()),
              );
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Adresse kopiert')));
            },
          ),
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: SoftCard(
                color: c.tint(FamioSection.calendar),
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (publicUrl != null)
                      address('Serveradresse (überall)', publicUrl),
                    address(
                      publicUrl == null
                          ? 'Serveradresse'
                          : 'Serveradresse (Heimnetz)',
                      local,
                    ),
                    ListTile(
                      dense: true,
                      title: const Text('Benutzername'),
                      subtitle: SelectableText(user),
                    ),
                    if (local.scheme == 'https' && state.certificatePin != null)
                      ListTile(
                        dense: true,
                        title: const Text(
                          'Zertifikat (SHA-256) zum Vergleichen',
                        ),
                        subtitle: SelectableText(
                          state.certificatePin!,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            for (final p in passwords)
              ListTile(
                leading: const Icon(AppIcons.key),
                title: Text(p.name),
                subtitle: Text(
                  [
                    p.lastUsed == null
                        ? 'noch nicht benutzt'
                        : 'zuletzt ${dateFormat.format(p.lastUsed!)}',
                    if (p.includeConfidential) 'mit vertraulichen Terminen',
                  ].join(' · '),
                ),
                trailing: IconButton(
                  icon: const Icon(AppIcons.trash),
                  tooltip: 'Trennen',
                  onPressed: () => _delete(p),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    icon: const Icon(AppIcons.devices),
                    label: const Text('Apple-Gerät einrichten'),
                    onPressed: () => _appleProfile(local, publicUrl),
                  ),
                  FilledButton.tonalIcon(
                    icon: const Icon(AppIcons.key),
                    label: const Text('App-Passwort erstellen'),
                    onPressed: _create,
                  ),
                ],
              ),
            ),
            HelpSteps('So geht’s mit Mac, iPhone und iPad', [
              '„Apple-Gerät einrichten“ erstellt ein Profil mit eigenem '
                  'App-Passwort (und dem Zertifikat des Servers). Es bringt '
                  'die Termine in Apple Kalender und Aufgaben und '
                  'Einkaufslisten in Apple Erinnerungen.',
              'Mac: Profil sichern, es öffnet sich in den '
                  'Systemeinstellungen → Allgemein → Geräteverwaltung → '
                  '„Famio-Kalender“ doppelklicken → Installieren.',
              'iPhone/iPad: Profil in „Dateien“ sichern, dort antippen, dann '
                  'Einstellungen → „Profil geladen“ → Installieren.',
              'Die Profildatei danach löschen – sie enthält das Passwort.',
              'Unterwegs klappt das nur mit der Internet-Adresse oder VPN.',
            ]),
            HelpSteps('So geht’s auf Android (DAVx⁵)', [
              'DAVx⁵ aus dem Play Store oder F-Droid installieren.',
              '„+“ → „Mit URL und Benutzername anmelden“.',
              'Basis-URL: die Adresse von oben, Benutzername „$user“, '
                  'Passwort: das App-Passwort.',
              'Kalender „Famio“ auswählen – er erscheint dann im Google- '
                  'oder Samsung-Kalender auf dem Handy.',
            ]),
            if (passwords.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Pro Gerät ein eigenes App-Passwort – so lässt sich jedes '
                  'einzeln trennen. Dein Famio-Passwort funktioniert hier '
                  'bewusst nicht.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _SecretDialog extends StatelessWidget {
  const _SecretDialog({required this.secret});

  final String secret;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Dein App-Passwort'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            secret,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontFamily: 'monospace',
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Jetzt in der Kalender-App als Passwort eingeben. Famio zeigt es '
            'nur dieses eine Mal an. Groß-/Kleinschreibung und Bindestriche '
            'sind egal.',
          ),
        ],
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(AppIcons.copy),
          label: const Text('Kopieren'),
          onPressed: () => Clipboard.setData(ClipboardData(text: secret)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fertig'),
        ),
      ],
    );
  }
}

// --- Famio syncing with other calendars (CalDAV client) ---------------------

/// Two-way sync with iCloud, Nextcloud & co., run by the Famio server.
class CalDavAccountsSection extends StatefulWidget {
  const CalDavAccountsSection({super.key});

  @override
  State<CalDavAccountsSection> createState() => _CalDavAccountsSectionState();
}

class _CalDavAccountsSectionState extends State<CalDavAccountsSection> {
  late Future<List<CalDavAccount>> _accounts = _load();
  final _busy = <String>{};

  Future<List<CalDavAccount>> _load() =>
      AppScope.read(context).engine!.api.calDavAccounts();

  void _reload() => setState(() {
    _accounts = _load();
  });

  Future<void> _run(String id, Future<Object?> Function() action) async {
    setState(() => _busy.add(id));
    try {
      await action();
    } on ApiError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) {
        setState(() => _busy.remove(id));
        _reload();
      }
    }
  }

  Future<void> _connect() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const _ConnectCalDavPage(),
      ),
    );
    if (added == true) _reload();
  }

  Future<void> _changePassword(CalDavAccount a) async {
    final api = AppScope.read(context).engine!.api;
    final password = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (context) => FormDialog(
        title: 'Neues Passwort für „${a.name}“',
        controllers: [password],
        fields: [
          PasswordReveal(
            builder: (_, obscure, toggle) => TextField(
              controller: password,
              obscureText: obscure,
              contextMenuBuilder: PasswordReveal.contextMenu,
              autofocus: true,
              decoration: InputDecoration(
                suffixIcon: toggle,
                labelText: 'Passwort',
              ),
            ),
          ),
        ],
        onSubmit: () => api.updateCalDavAccount(a.id, password: password.text),
      ),
    );
    _reload();
  }

  Future<void> _share(CalDavAccount a) async {
    final engine = AppScope.read(context).engine!;
    final sharing = await showSharingDialog(
      context,
      engine: engine,
      title: a.name,
      initial: a.sharing,
    );
    if (sharing == null || sharing == a.sharing || !mounted) return;
    await _run(
      a.id,
      () => engine.api.updateCalDavAccount(a.id, sharing: sharing),
    );
  }

  Future<void> _remove(CalDavAccount a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('„${a.name}“ trennen?'),
        content: const Text(
          'Termine, die von dort kamen, verschwinden aus Famio. Der andere '
          'Kalender behält alles, auch die Termine aus Famio.',
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
    if (ok != true || !mounted) return;
    final api = AppScope.read(context).engine!.api;
    await _run(a.id, () => api.deleteCalDavAccount(a.id));
  }

  @override
  Widget build(BuildContext context) {
    final api = AppScope.of(context).engine!.api;
    final c = FamioColors.of(context);
    final dateFormat = DateFormat('d.M., HH:mm', 'de');
    return FutureBuilder(
      future: _accounts,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ListTile(
            leading: const Icon(AppIcons.cloudSlash),
            title: const Text('Nur mit Verbindung zum Server verfügbar'),
            trailing: TextButton(
              onPressed: _reload,
              child: const Text('Erneut'),
            ),
          );
        }
        final accounts = snapshot.data ?? const <CalDavAccount>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final a in accounts)
              ListTile(
                leading: Icon(
                  a.error == null
                      ? AppIcons.arrowsLeftRight
                      : AppIcons.warningCircle,
                  color: a.error == null ? null : c.danger,
                ),
                title: Text(a.name),
                subtitle: Text(
                  a.error ??
                      [
                        '${a.username} · ${Uri.tryParse(a.serverUrl)?.host ?? a.serverUrl}',
                        '${a.linkedEvents} Termine abgeglichen'
                            '${a.lastSync == null ? '' : ', zuletzt ${dateFormat.format(a.lastSync!)}'}',
                        if (a.onlyMine) 'nur meine Termine',
                        'Sichtbar für: ${sharingLabel(AppScope.engineOf(context), a.sharing)}',
                      ].join('\n'),
                  style: a.error == null ? null : TextStyle(color: c.danger),
                ),
                isThreeLine: a.error == null,
                trailing: _busy.contains(a.id)
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(AppIcons.arrowsClockwise),
                            tooltip: 'Jetzt abgleichen',
                            onPressed: () =>
                                _run(a.id, () => api.syncCalDavAccount(a.id)),
                          ),
                          PopupMenuButton<String>(
                            onSelected: (v) => switch (v) {
                              'password' => _changePassword(a),
                              'mine' => _run(
                                a.id,
                                () => api.updateCalDavAccount(
                                  a.id,
                                  onlyMine: !a.onlyMine,
                                ),
                              ),
                              'share' => _share(a),
                              _ => _remove(a),
                            },
                            itemBuilder: (_) => [
                              if (!a.google)
                                const PopupMenuItem(
                                  value: 'password',
                                  child: Text('Passwort ändern'),
                                ),
                              CheckedPopupMenuItem(
                                value: 'mine',
                                checked: a.onlyMine,
                                child: const Text('Nur meine Termine senden'),
                              ),
                              const PopupMenuItem(
                                value: 'share',
                                child: Text('Teilen …'),
                              ),
                              const PopupMenuItem(
                                value: 'remove',
                                child: Text('Trennen'),
                              ),
                            ],
                          ),
                        ],
                      ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  icon: const Icon(AppIcons.arrowsLeftRight),
                  label: const Text('Kalender verbinden'),
                  onPressed: _connect,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

enum _Provider {
  google(
    'Google',
    '',
    '',
    'Google braucht einen eigenen, kostenlosen Zugang in der Google Cloud '
        'Console (einmalig, siehe Anleitung). Danach meldest du dich im '
        'Browser bei Google an.',
  ),
  icloud(
    'iCloud',
    'https://caldav.icloud.com',
    'Apple-ID (E-Mail)',
    'App-spezifisches Passwort: appleid.apple.com → Anmelden und Sicherheit '
        '→ App-spezifische Passwörter. Dein normales Apple-Passwort '
        'funktioniert nicht.',
  ),
  nextcloud(
    'Nextcloud',
    'https://cloud.example.org/remote.php/dav',
    'Benutzername',
    'Am besten ein App-Passwort: Nextcloud → Einstellungen → Sicherheit → '
        'Neues App-Passwort erstellen.',
  ),
  mailbox(
    'mailbox.org',
    'https://dav.mailbox.org',
    'E-Mail-Adresse',
    'Dein mailbox.org-Passwort oder ein App-Passwort.',
  ),
  posteo(
    'Posteo',
    'https://posteo.de:8443',
    'E-Mail-Adresse',
    'Dein Posteo-Passwort.',
  ),
  other(
    'Andere',
    '',
    'Benutzername',
    'Adresse des CalDAV-Servers, z. B. von Synology, Radicale oder deinem '
        'Anbieter.',
  );

  const _Provider(this.label, this.url, this.userLabel, this.hint);

  final String label;
  final String url;
  final String userLabel;
  final String hint;
}

class _ConnectCalDavPage extends StatefulWidget {
  const _ConnectCalDavPage();

  @override
  State<_ConnectCalDavPage> createState() => _ConnectCalDavPageState();
}

class _ConnectCalDavPageState extends State<_ConnectCalDavPage> {
  var _provider = _Provider.icloud;
  final _clientId = TextEditingController();
  final _clientSecret = TextEditingController();

  /// One-time id of the Google access the server holds for this page.
  String? _googleGrant;
  final _url = TextEditingController(text: _Provider.icloud.url);
  final _user = TextEditingController();
  final _password = TextEditingController();
  List<CalDavCalendarInfo>? _calendars;
  CalDavCalendarInfo? _selected;
  var _onlyMine = false;
  var _sharing = const CalendarSharing.family();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _password.dispose();
    _clientId.dispose();
    _clientSecret.dispose();
    super.dispose();
  }

  Future<void> _googleLogin() async {
    final api = AppScope.read(context).engine!.api;
    setState(() {
      _busy = true;
      _error = null;
      _calendars = null;
      _selected = null;
    });
    try {
      final login = await GoogleLogin.run(
        clientId: _clientId.text,
        open: (url) async {
          if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
            throw const ApiError(
              0,
              'browser',
              'Browser ließ sich nicht öffnen',
            );
          }
        },
      );
      final (grant, email, found) = await api.connectGoogle(
        clientId: _clientId.text.trim(),
        clientSecret: _clientSecret.text.trim(),
        login: login,
      );
      setState(() {
        _googleGrant = grant;
        _user.text = email ?? '';
        _calendars = found;
        _selected = found.firstOrNull;
      });
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _search() async {
    setState(() {
      _busy = true;
      _error = null;
      _calendars = null;
      _selected = null;
    });
    try {
      final found = await AppScope.read(context).engine!.api.discoverCalDav(
        url: _url.text,
        username: _user.text,
        password: _password.text,
      );
      setState(() {
        _calendars = found;
        _selected = found.where((c) => !c.readOnly).firstOrNull;
      });
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() async {
    final calendar = _selected;
    if (calendar == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final account = await AppScope.read(context).engine!.api
          .createCalDavAccount(
            serverUrl: _url.text,
            username: _user.text,
            password: _password.text,
            calendar: calendar,
            onlyMine: _onlyMine,
            sharing: _sharing,
            googleGrant: _provider == _Provider.google ? _googleGrant : null,
          );
      if (!mounted) return;
      if (account.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Verbunden, aber: ${account.error}')),
        );
      }
      Navigator.pop(context, true);
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = FamioColors.of(context);
    final calendars = _calendars;
    return SectionPage(
      section: FamioSection.calendar,
      title: 'Kalender verbinden',
      subtitle: 'Termine in beide Richtungen abgleichen',
      bodyPadding: EdgeInsets.zero,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: EdgeInsets.fromLTRB(20, 8, 20, listBottomPadding(context)),
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in _Provider.values)
                    ChoiceChip(
                      label: Text(p.label),
                      selected: p == _provider,
                      onSelected: (_) => setState(() {
                        _provider = p;
                        _url.text = p.url;
                        _calendars = null;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(_provider.hint, style: theme.textTheme.bodySmall),
              if (_provider == _Provider.google) ...[
                const HelpSteps('So legst du den Google-Zugang an (einmalig)', [
                  'console.cloud.google.com öffnen und ein Projekt anlegen, '
                      'z. B. „Famio“.',
                  '„APIs & Dienste“ → „Bibliothek“: „Google Calendar API“ und '
                      '„CalDAV API“ aktivieren.',
                  '„OAuth-Zustimmungsbildschirm“: Typ „Extern“, App-Name '
                      'Famio, deine E-Mail; unter Zielgruppe den '
                      'Veröffentlichungsstatus auf „In Produktion“ setzen '
                      '(sonst läuft der Zugang nach 7 Tagen ab).',
                  '„Anmeldedaten“ → „Anmeldedaten erstellen“ → „OAuth-Client-ID“ '
                      '→ Anwendungstyp „Desktop-App“.',
                  'Client-ID und Clientschlüssel hier eintragen und „Bei Google '
                      'anmelden“ tippen. Google warnt, die App sei nicht '
                      'überprüft – das ist dein eigenes Projekt: „Erweitert“ → '
                      '„Weiter zu Famio“.',
                ]),
                const SizedBox(height: 12),
                TextField(
                  controller: _clientId,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Client-ID',
                    prefixIcon: Icon(AppIcons.identificationCard),
                  ),
                ),
                const SizedBox(height: 12),
                PasswordReveal(
                  builder: (_, obscure, toggle) => TextField(
                    controller: _clientSecret,
                    obscureText: obscure,
                    contextMenuBuilder: PasswordReveal.contextMenu,
                    autocorrect: false,
                    decoration: InputDecoration(
                      suffixIcon: toggle,
                      labelText: 'Clientschlüssel',
                      prefixIcon: Icon(AppIcons.key),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    icon: const Icon(AppIcons.globe),
                    label: const Text('Bei Google anmelden'),
                    onPressed: _busy ? null : _googleLogin,
                  ),
                ),
              ] else ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Serveradresse',
                    prefixIcon: Icon(AppIcons.globe),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _user,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: _provider.userLabel,
                    prefixIcon: const Icon(AppIcons.user),
                  ),
                ),
                const SizedBox(height: 12),
                PasswordReveal(
                  builder: (_, obscure, toggle) => TextField(
                    controller: _password,
                    obscureText: obscure,
                    contextMenuBuilder: PasswordReveal.contextMenu,
                    decoration: InputDecoration(
                      suffixIcon: toggle,
                      labelText: 'Passwort',
                      prefixIcon: Icon(AppIcons.key),
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    icon: const Icon(AppIcons.magnifyingGlass),
                    label: const Text('Kalender suchen'),
                    onPressed: _busy ? null : _search,
                  ),
                ),
              ],
              if (_busy) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: c.danger)),
              ],
              if (calendars != null) ...[
                const SizedBox(height: 20),
                Text('Welcher Kalender?', style: theme.textTheme.titleMedium),
                RadioGroup<String>(
                  groupValue: _selected?.url,
                  onChanged: (url) => setState(
                    () => _selected = calendars.firstWhere((c) => c.url == url),
                  ),
                  child: Column(
                    children: [
                      for (final cal in calendars)
                        RadioListTile<String>(
                          value: cal.url,
                          enabled: !cal.readOnly,
                          contentPadding: EdgeInsets.zero,
                          secondary: CircleAvatar(
                            radius: 8,
                            backgroundColor: Color(
                              cal.color ?? famioPalette.first,
                            ),
                          ),
                          title: Text(cal.name),
                          subtitle: cal.readOnly
                              ? const Text(
                                  'Nur lesbar – bitte als Abo einbinden',
                                )
                              : null,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Nur meine Termine senden'),
                  subtitle: const Text(
                    'Termine, bei denen du dabei bist, und Termine für die '
                    'ganze Familie.',
                  ),
                  value: _onlyMine,
                  onChanged: (v) => setState(() => _onlyMine = v),
                ),
                const SizedBox(height: 8),
                Text(
                  'Termine von dort sehen',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                CalendarSharingPicker(
                  engine: AppScope.engineOf(context),
                  value: _sharing,
                  onChanged: (v) => setState(() => _sharing = v),
                ),
                const SizedBox(height: 4),
                Text(
                  'Das kannst du später jederzeit ändern. Ein Admin kann '
                  'geteilte Kalender für einzelne Mitglieder ausblenden.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Vertrauliche Termine werden nie übertragen. Termine, die '
                  'Famio nicht genau abbilden kann (z. B. „jeden 2. Dienstag“), '
                  'erscheinen schreibgeschützt.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                ColorButton(
                  label: 'Verbinden',
                  color: c.strong(FamioSection.calendar),
                  onPressed: _busy || _selected == null ? null : _connect,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
