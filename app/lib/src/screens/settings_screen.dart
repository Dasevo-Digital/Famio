import 'kiosk_screen.dart';
import 'push_settings_screen.dart';
import 'sos_screens.dart';
import 'wishes_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../design/app_icons.dart';

import 'package:home_widget/home_widget.dart';

import '../app_state.dart';
import '../environment.dart';
import '../home_widget/widget_sync.dart';
import '../data/family_data.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../location/location_sharing.dart';
import 'location_screens.dart';
import '../widgets/dispose_with.dart';
import '../widgets/data_builder.dart';
import '../widgets/birthday_field.dart';
import '../widgets/form_dialog.dart';
import '../widgets/member_avatar.dart';
import '../widgets/trust_certificate.dart';
import '../widgets/password_reveal.dart';
import 'admin_screens.dart';
import 'security_screens.dart';
import '../widgets/data_export.dart';
import 'waste_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final me = state.me!;
    final engine = state.engine!;
    final c = FamioColors.of(context);
    final accent = c.strong(FamioSection.settings);

    return SectionPage(
      maxBodyWidth: 960,
      section: FamioSection.settings,
      title: 'Einstellungen',
      subtitle: 'Konto, Familie & Server',
      body: ListView(
        padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
        children: [
          SoftCard(
            child: Row(
              children: [
                MemberAvatar(me, radius: 30),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        me.displayName,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(
                        '@${me.username}${me.isAdmin ? ' · Administrator' : ''}',
                        style: TextStyle(color: c.inkSoft),
                      ),
                    ],
                  ),
                ),
                BubbleButton(
                  icon: AppIcons.pencilSimple,
                  tooltip: 'Profil bearbeiten',
                  onPressed: () => showProfileEditor(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (me.isAdmin) ...[
            const SizedBox(height: 8),
            SoftCard(
              color: c.tint(FamioSection.settings),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AdminScreen()),
              ),
              child: Row(
                children: [
                  IconBlob(
                    AppIcons.shieldUser,
                    color: accent,
                    background: c.surface.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Server-Verwaltung',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          'Benutzer, Geräte & Servereinstellungen',
                          style: TextStyle(color: c.inkSoft),
                        ),
                      ],
                    ),
                  ),
                  Icon(AppIcons.caretRight, color: c.inkSoft),
                ],
              ),
            ),
          ],
          ListHeading('Konto', color: accent),
          if (state.panelMode == 'server')
            // Home Assistant signs in here; the page of the add-on sets a
            // password for the phone and computer apps.
            ListTile(
              leading: const Icon(AppIcons.password),
              title: const Text('Famio-Apps verbinden'),
              subtitle: const Text(
                'Adresse und Passwort für die Apps auf Handy und Computer',
              ),
              onTap: () => launchUrl(
                Uri.parse(state.serverUrl!).replace(query: 'info'),
                webOnlyWindowName: '_self',
              ),
            )
          else
            ListTile(
              leading: const Icon(AppIcons.password),
              title: const Text('Passwort ändern'),
              onTap: () => _changePassword(context),
            ),
          ListTile(
            leading: const Icon(AppIcons.cloudArrowDown),
            title: const Text('Meine Daten exportieren'),
            subtitle: const Text('Alles, was du siehst, als ZIP-Datei'),
            onTap: () => exportData(context),
          ),
          ListTile(
            leading: const Icon(AppIcons.shieldCheck),
            title: const Text('Anmeldung & Sicherheit'),
            subtitle: const Text('Zwei-Faktor-Anmeldung, Single Sign-On'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SecurityScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(AppIcons.devices),
            title: const Text('Meine Geräte'),
            subtitle: const Text('Wo du angemeldet bist'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const MyDevicesScreen()),
            ),
          ),
          if (HomeWidgetSync.supported)
            ListTile(
              leading: const Icon(AppIcons.smartphone),
              title: const Text('Widget auf den Startbildschirm'),
              subtitle: const Text('Termine, Essen und Einkauf von heute'),
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                if (await HomeWidget.isRequestPinWidgetSupported() == true) {
                  await HomeWidget.requestPinWidget(
                    qualifiedAndroidName:
                        'de.status403.famio.FamioWidgetProvider',
                  );
                } else {
                  messenger.showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Startbildschirm lange drücken → Widgets → Famio.',
                      ),
                    ),
                  );
                }
              },
            ),
          ListTile(
            leading: const Icon(AppIcons.gift),
            title: const Text('Wunschzettel'),
            subtitle: const Text('Deine Wünsche und die der Familie'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const WishesScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(AppIcons.recycle),
            title: const Text('Abfallkalender'),
            subtitle: const Text('Wer wann welche Tonne rausstellt'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const WasteScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(AppIcons.siren),
            title: const Text('Notfallknopf'),
            subtitle: const Text('Sirene, Anruf, Telefonnummern'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const SosSettingsScreen(),
              ),
            ),
          ),
          // The web app shows no notifications.
          if (!kIsWeb)
            ListTile(
              leading: const Icon(AppIcons.bellRing),
              title: const Text('Push-Benachrichtigungen'),
              subtitle: const Text('Direkt über Famio oder über ntfy'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const PushSettingsScreen(),
                ),
              ),
            ),
          ListHeading('Dieses Gerät', color: accent),
          ListTile(
            leading: const Icon(AppIcons.tv),
            title: const Text('Wandanzeige öffnen'),
            subtitle: const Text(
              'Großer Tagesüberblick fürs Küchen-Tablet, bleibt an',
            ),
            onTap: () => openKiosk(context),
          ),
          if (!kIsWeb)
            SwitchListTile(
              secondary: const Icon(AppIcons.monitor),
              title: const Text('Beim Start als Wandanzeige öffnen'),
              value: state.kioskAutostart,
              onChanged: state.setKioskAutostart,
            ),
          SwitchListTile(
            secondary: const Icon(AppIcons.contrast),
            title: const Text('Hoher Kontrast'),
            subtitle: const Text(
              'Kräftigere Farben und dunklere Schrift statt Pastell – '
              'leichter lesbar bei Sonne, kleiner Schrift oder schwachen '
              'Augen. Gilt nur für dieses Gerät.',
            ),
            value: state.highContrast.value,
            onChanged: state.setHighContrast,
          ),
          ListHeading('Synchronisation', color: accent),
          ListTile(
            leading: const Icon(AppIcons.hardDrives),
            title: const Text('Server'),
            subtitle: Text(
              state.panelMode == 'server'
                  ? 'Famio in Home Assistant'
                  : state.panelMode == 'client'
                  ? 'Über Home Assistant verbunden'
                  : state.serverUrl ?? '',
            ),
          ),
          if (!kIsWeb) _ConnectionSecurityTile(url: state.serverUrl),
          StreamBuilder<SyncStatus>(
            stream: engine.statusChanges,
            initialData: engine.status,
            builder: (context, snapshot) {
              final status = snapshot.data!;
              final last = status.lastSync;
              return ListTile(
                leading: const Icon(AppIcons.arrowsClockwise),
                title: const Text('Jetzt synchronisieren'),
                subtitle: Text(switch (status.state) {
                  SyncState.syncing => 'Läuft …',
                  SyncState.offline =>
                    'Offline: ${status.message ?? 'Server nicht erreichbar'}',
                  _ when last != null =>
                    'Zuletzt ${DateFormat('d. MMM, HH:mm', 'de').format(last)}',
                  _ => 'Noch nicht synchronisiert',
                }),
                onTap: engine.sync,
              );
            },
          ),
          ListHeading('Familie', color: accent),
          DataBuilder(
            collections: const {'members'},
            builder: (context, engine) => Column(
              children: [
                for (final m in engine.members)
                  ListTile(
                    leading: MemberAvatar(m),
                    title: Text(m.displayName),
                    subtitle: Text(
                      [
                        '@${m.username}',
                        if (m.role != MemberRole.adult) m.role.label,
                        if (m.isAdmin) 'Administrator',
                      ].join(' · '),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (state.canSignOut)
            ListTile(
              leading: Icon(AppIcons.signOut, color: c.danger),
              title: Text('Abmelden', style: TextStyle(color: c.danger)),
              subtitle: Text(
                state.panelMode == 'client'
                    ? 'Home Assistant vergisst deine Anmeldung'
                    : 'Lokale Daten auf diesem Gerät werden entfernt',
              ),
              onTap: () async {
                // Signing out would end location sharing: parents' code first.
                if (LocationSharing.supported &&
                    (await LocationSharing.status()).enabled) {
                  if (!context.mounted) return;
                  final stopped = await showPauseDialog(
                    context,
                    member: state.me!,
                    stopOnThisDevice: true,
                  );
                  if (!stopped) return;
                }
                await state.signOut();
              },
            ),
          ListTile(
            leading: Icon(AppIcons.userMinus, color: c.danger),
            title: Text(
              'Mein Konto löschen',
              style: TextStyle(color: c.danger),
            ),
            subtitle: const Text(
              'Zugang und persönliche Verbindungen entfernen',
            ),
            onTap: () => _deleteAccount(context),
          ),
          ListHeading('Über Famio', color: accent),
          VersionTile(api: engine.api),
        ],
      ),
    );
  }

  Future<void> _changePassword(BuildContext context) async {
    final current = TextEditingController();
    final next = TextEditingController();
    final api = AppScope.engineOf(context).api;
    await showDialog<void>(
      context: context,
      builder: (context) => FormDialog(
        title: 'Passwort ändern',
        controllers: [current, next],
        fields: [
          PasswordReveal(
            builder: (_, obscure, toggle) => TextField(
              controller: current,
              obscureText: obscure,
              contextMenuBuilder: PasswordReveal.contextMenu,
              decoration: InputDecoration(
                suffixIcon: toggle,
                labelText: 'Aktuelles Passwort',
              ),
            ),
          ),
          PasswordReveal(
            builder: (_, obscure, toggle) => TextField(
              controller: next,
              obscureText: obscure,
              contextMenuBuilder: PasswordReveal.contextMenu,
              decoration: InputDecoration(
                suffixIcon: toggle,
                labelText: 'Neues Passwort (min. 8 Zeichen)',
              ),
            ),
          ),
        ],
        onSubmit: () => api.changePassword(
          currentPassword: current.text,
          newPassword: next.text,
        ),
      ),
    );
  }

  Future<void> _deleteAccount(BuildContext context) async {
    final state = AppScope.read(context);
    final me = state.me!;
    final password = TextEditingController();
    final code = TextEditingController();
    var confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (context) => FormDialog(
        title: 'Konto wirklich löschen?',
        submitLabel: 'Konto löschen',
        controllers: [password, code],
        fields: [
          const Text(
            'Dein Konto, Sitzungen und persönlichen Verbindungen werden entfernt. '
            'Geteilte Familieneinträge bleiben für die anderen Mitglieder erhalten. '
            'Als letzter Administrator musst du zuerst die Verwaltung übergeben.',
          ),
          PasswordReveal(
            builder: (_, obscure, toggle) => TextField(
              controller: password,
              obscureText: obscure,
              contextMenuBuilder: PasswordReveal.contextMenu,
              autofocus: true,
              decoration: InputDecoration(
                suffixIcon: toggle,
                labelText: 'Passwort zur Bestätigung',
              ),
            ),
          ),
          TextField(
            controller: code,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Zwei-Faktor-Code (falls aktiviert)',
            ),
          ),
        ],
        onSubmit: () async {
          await state.engine!.api.deleteMyAccount(
            password: password.text,
            code: code.text.trim().isEmpty ? null : code.text.trim(),
          );
          confirmed = true;
        },
      ),
    );
    if (confirmed && context.mounted) {
      await state.signOut(notice: 'Konto ${me.displayName} wurde gelöscht.');
    }
  }
}

/// Lets members change their own name and avatar color.
Future<void> showProfileEditor(BuildContext context) async {
  final state = AppScope.read(context);
  final me = state.me!;
  final engine = state.engine!;
  final name = TextEditingController(text: me.displayName);
  var color = me.color;
  var birthday = engine.member(me.id)?.birthday ?? me.birthday;
  await showDialog<void>(
    context: context,
    builder: (context) => FormDialog(
      title: 'Mein Profil',
      controllers: [name],
      fields: [
        TextField(
          controller: name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Anzeigename'),
        ),
        StatefulBuilder(
          builder: (context, setState) => AvatarColorPicker(
            selected: color,
            onChanged: (v) => setState(() => color = v),
          ),
        ),
        StatefulBuilder(
          builder: (context, setState) => BirthdayField(
            value: birthday,
            onChanged: (v) => setState(() => birthday = v),
          ),
        ),
      ],
      onSubmit: () async {
        await engine.api.updateMe(
          displayName: name.text,
          color: color,
          birthday: birthday,
          clearBirthday: birthday == null,
        );
        await engine.refreshMembers();
      },
    ),
  );
}

/// The own signed-in devices; other devices can be signed out.
class MyDevicesScreen extends StatefulWidget {
  const MyDevicesScreen({super.key});

  @override
  State<MyDevicesScreen> createState() => _MyDevicesScreenState();
}

class _MyDevicesScreenState extends State<MyDevicesScreen> {
  late Future<List<DeviceSession>> _sessions;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _sessions = AppScope.read(context).engine!.api.mySessions();
  }

  @override
  Widget build(BuildContext context) {
    final api = AppScope.engineOf(context).api;
    return SectionPage(
      maxBodyWidth: 960,
      section: FamioSection.settings,
      title: 'Meine Geräte',
      subtitle: 'Angemeldete Apps mit deinem Konto',
      body: FutureBuilder(
        future: _sessions,
        builder: (context, snapshot) => ApiFutureView(
          snapshot: snapshot,
          onRetry: () => setState(_load),
          builder: (sessions) => ListView(
            padding: EdgeInsets.only(bottom: listBottomPadding(context)),
            children: [
              for (final s in sessions)
                DeviceTile(
                  session: s,
                  onSignOut: s.current
                      ? null
                      : () async {
                          await api.deleteMySession(s.id);
                          setState(_load);
                        },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows whether the connection to the server is encrypted and offers to
/// switch a plain home network connection to the server's HTTPS port.
class _ConnectionSecurityTile extends StatefulWidget {
  const _ConnectionSecurityTile({required this.url});

  final String? url;

  @override
  State<_ConnectionSecurityTile> createState() =>
      _ConnectionSecurityTileState();
}

class _ConnectionSecurityTileState extends State<_ConnectionSecurityTile> {
  var _busy = false;

  Future<void> _encrypt() async {
    final state = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await state.encryptConnection(
        trust: (fingerprint) => confirmCertificate(context, fingerprint),
      );
      messenger.showSnackBar(
        const SnackBar(content: Text('Verbindung ist jetzt verschlüsselt')),
      );
    } on ApiError catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e.isNetwork
                ? 'Der Server bietet kein HTTPS an (Port '
                      '${AppState.defaultTlsPort}). Server aktualisieren oder '
                      'den Reverse-Proxy verwenden.'
                : e.message,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _move() async {
    final state = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final address = TextEditingController(
      text: Uri.tryParse(widget.url ?? '')?.host ?? '',
    );
    final input = await showDialog<String>(
      context: context,
      builder: (context) => DisposeWith(
        controllers: [address],
        child: AlertDialog(
          title: const Text('Server-Adresse ändern'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Nur wenn euer Famio-Server umgezogen ist (z. B. auf einen '
                  'Proxmox-Container) und die Daten mitgenommen hat. Du '
                  'bleibst angemeldet.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: address,
                  autofocus: true,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Neue Server-Adresse',
                    hintText: 'famio.example.de oder 192.168.1.10',
                  ),
                  onSubmitted: (v) => Navigator.pop(context, v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, address.text),
              child: const Text('Wechseln'),
            ),
          ],
        ),
      ),
    );
    if (input == null || input.trim().isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      await state.moveServer(
        input,
        trust: (fingerprint) => confirmCertificate(context, fingerprint),
      );
      messenger.showSnackBar(
        const SnackBar(content: Text('Verbunden mit der neuen Adresse')),
      );
    } on ApiError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } on FormatException {
      messenger.showSnackBar(
        const SnackBar(content: Text('Ungültige Server-Adresse')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.url;
    if (url == null) return const SizedBox.shrink();
    final c = FamioColors.of(context);
    final state = AppScope.of(context);
    final security = FamioApiClient.transportSecurity(
      FamioApiClient.normalizeUrl(url),
    );
    final pin = state.certificatePin;
    final (icon, color, title, text) = switch (security) {
      TransportSecurity.encrypted => (
        AppIcons.lock,
        c.strong(FamioSection.tasks),
        'Verbindung verschlüsselt',
        pin == null
            ? 'HTTPS – Daten sind unterwegs geschützt.'
            : 'HTTPS mit dem bestätigten Zertifikat des Servers '
                  '(${pin.substring(0, 11)}…).',
      ),
      TransportSecurity.localNetwork => (
        AppIcons.warningCircle,
        c.strong(FamioSection.home),
        'Unverschlüsselt im Heimnetz',
        'Andere Geräte im WLAN könnten mitlesen.',
      ),
      TransportSecurity.insecure => (
        AppIcons.warningCircle,
        c.danger,
        'Unverschlüsselt über das Internet',
        'Bitte abmelden und mit der https-Adresse neu verbinden.',
      ),
    };
    return Column(
      children: [
        ListTile(
          leading: Icon(icon, color: color),
          title: Text(title),
          subtitle: Text(text),
          trailing: security == TransportSecurity.localNetwork
              ? (_busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : FilledButton(
                        onPressed: _encrypt,
                        child: const Text('Jetzt verschlüsseln'),
                      ))
              : null,
        ),
        ListTile(
          leading: const Icon(AppIcons.arrowsLeftRight),
          title: const Text('Server-Adresse ändern'),
          subtitle: Text(
            '${Uri.tryParse(url)?.authority ?? url} – z. B. nach einem '
            'Umzug des Servers',
          ),
          onTap: _busy ? null : _move,
        ),
        ListTile(
          leading: Icon(
            state.vault.secure ? AppIcons.lockKey : AppIcons.warningCircle,
            color: state.vault.secure
                ? c.strong(FamioSection.tasks)
                : c.strong(FamioSection.home),
          ),
          title: const Text('Daten auf diesem Gerät'),
          subtitle: Text(
            state.vault.secure
                ? 'Verschlüsselt; Schlüssel und Anmeldung im Schlüsselbund '
                      'des Systems.'
                : 'Verschlüsselt, aber ohne Schlüsselbund des Systems '
                      '(z. B. Linux ohne KWallet/GNOME-Schlüsselbund) – '
                      'der Schlüssel liegt ungeschützt in den Einstellungen.',
          ),
        ),
      ],
    );
  }
}

/// Versions of this app and of the server, e.g. to check an update arrived.
class VersionTile extends StatefulWidget {
  const VersionTile({super.key, required this.api});

  final FamioApiClient api;

  @override
  State<VersionTile> createState() => VersionTileState();
}

class VersionTileState extends State<VersionTile> {
  late final Future<PackageInfo?> _app = PackageInfo.fromPlatform()
      .then<PackageInfo?>((info) => info)
      .catchError((Object _) => null);
  late final Future<String?> _server = widget.api
      .health()
      .then<String?>((info) => info.version)
      .catchError((Object _) => null);

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: Future.wait([_app, _server]),
    builder: (context, snapshot) {
      final app = snapshot.data?[0] as PackageInfo?;
      final server = snapshot.data?[1] as String?;
      return ListTile(
        leading: const Icon(AppIcons.info),
        title: Text(
          app == null
              ? 'Version'
              : '${AppEnv.appName} ${app.version}'
                    '${app.buildNumber.isEmpty ? '' : ' (${app.buildNumber})'}',
        ),
        subtitle: Text(
          snapshot.connectionState != ConnectionState.done
              ? 'Server-Version wird abgefragt …'
              : 'Server ${server ?? 'nicht erreichbar'}',
        ),
      );
    },
  );
}
