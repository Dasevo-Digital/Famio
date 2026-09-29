import 'dart:async';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../app_state.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../data/family_data.dart';
import '../format.dart';
import '../widgets/files.dart';
import '../widgets/birthday_field.dart';
import '../widgets/form_dialog.dart';
import '../widgets/member_avatar.dart';
import '../widgets/password_reveal.dart';

/// Server administration for admins: users and their devices, server
/// settings and status. Works from any connected app.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

enum _AdminTab { users, settings, status }

class _AdminScreenState extends State<AdminScreen> {
  var _tab = _AdminTab.users;
  late Future<List<AdminUser>> _users;
  late Future<ServerOverview> _overview;

  FamioApiClient get _api => AppScope.read(context).engine!.api;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _users = _api.adminUsers();
    _overview = _api.adminOverview();
  }

  void _refresh() => setState(_reload);

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final accent = c.strong(FamioSection.settings);
    final state = AppScope.of(context);
    return SectionPage(
      maxBodyWidth: 960,
      section: FamioSection.settings,
      title: 'Server-Verwaltung',
      subtitle: state.serverUrl,
      actions: [
        BubbleButton(
          icon: AppIcons.arrowsClockwise,
          tooltip: 'Aktualisieren',
          onPressed: _refresh,
        ),
      ],
      floating: _tab == _AdminTab.users
          ? AddButton(
              color: accent,
              tooltip: 'Mitglied hinzufügen',
              icon: AppIcons.userPlus,
              onPressed: _addMember,
            )
          : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PillTabs(
            values: _AdminTab.values,
            selected: _tab,
            color: accent,
            label: (t) => switch (t) {
              _AdminTab.users => 'Benutzer',
              _AdminTab.settings => 'Einstellungen',
              _AdminTab.status => 'Status',
            },
            onChanged: (t) => setState(() => _tab = t),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: switch (_tab) {
              _AdminTab.users => FutureBuilder(
                future: _users,
                builder: (context, snapshot) => ApiFutureView(
                  snapshot: snapshot,
                  onRetry: _refresh,
                  builder: (users) => _UserList(
                    users: users,
                    onOpen: (u) async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => AdminUserScreen(userId: u.member.id),
                        ),
                      );
                      _refresh();
                    },
                  ),
                ),
              ),
              _AdminTab.settings => FutureBuilder(
                future: _overview,
                builder: (context, snapshot) => ApiFutureView(
                  snapshot: snapshot,
                  onRetry: _refresh,
                  builder: (o) => _SettingsForm(
                    // Fresh fields after a reset.
                    key: ObjectKey(o),
                    overview: o,
                    onSaved: (fresh) => setState(() {
                      _overview = Future.value(fresh);
                    }),
                  ),
                ),
              ),
              _AdminTab.status => FutureBuilder(
                future: _overview,
                builder: (context, snapshot) => ApiFutureView(
                  snapshot: snapshot,
                  onRetry: _refresh,
                  builder: (o) => _StatusView(overview: o),
                ),
              ),
            },
          ),
        ],
      ),
    );
  }

  Future<void> _addMember() async {
    final name = TextEditingController();
    final username = TextEditingController();
    final password = TextEditingController();
    final engine = AppScope.engineOf(context);
    var isAdmin = false;
    var role = MemberRole.adult;
    var created = false;
    await showDialog<void>(
      context: context,
      builder: (context) => FormDialog(
        title: 'Familienmitglied hinzufügen',
        controllers: [name, username, password],
        fields: [
          TextField(
            controller: name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          TextField(
            controller: username,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Benutzername (für die Anmeldung)',
            ),
          ),
          PasswordReveal(
            builder: (_, obscure, toggle) => TextField(
              controller: password,
              obscureText: obscure,
              contextMenuBuilder: PasswordReveal.contextMenu,
              decoration: InputDecoration(
                suffixIcon: toggle,
                labelText: 'Startpasswort (min. 8 Zeichen)',
              ),
            ),
          ),
          StatefulBuilder(
            builder: (context, setState) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _RolePicker(
                  role: role,
                  onChanged: (r) => setState(() {
                    role = r;
                    if (!_canAdminister(r)) isAdmin = false;
                  }),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Administrator'),
                  subtitle: const Text('Darf den Server verwalten'),
                  value: isAdmin,
                  onChanged: !_canAdminister(role)
                      ? null
                      : (v) => setState(() => isAdmin = v),
                ),
              ],
            ),
          ),
        ],
        onSubmit: () async {
          await engine.api.createMember(
            username: username.text,
            displayName: name.text,
            password: password.text,
            isAdmin: isAdmin,
            role: role,
          );
          created = true;
          await engine.refreshMembers();
        },
      ),
    );
    if (created && mounted) _refresh();
  }
}

/// Guests and service accounts never manage the server.
bool _canAdminister(MemberRole role) =>
    role != MemberRole.guest && role != MemberRole.service;

/// Adult, child, guest or service account, with what it means.
class _RolePicker extends StatelessWidget {
  const _RolePicker({required this.role, required this.onChanged});

  final MemberRole role;
  final ValueChanged<MemberRole> onChanged;

  static const _help = {
    MemberRole.adult: 'Sieht und verwaltet alles, was für ihn freigegeben ist.',
    MemberRole.child:
        'Sammelt Punkte und Taschengeld; erledigte Ämter bestätigen die '
        'Erwachsenen.',
    MemberRole.guest:
        'Z. B. Großeltern oder Babysitter: nur Kalender, Chat, Einkauf, '
        'Aufgaben, Essen und Kontakte – keine Dokumente, Gesundheitsdaten, '
        'Finanzen oder Standorte.',
    MemberRole.service:
        'Für Home Assistant und andere Anbindungen: sieht, was Erwachsene '
        'sehen, erscheint aber nicht in Chats, Standorten und Auswahllisten.',
  };

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 8,
        children: [
          for (final r in MemberRole.values)
            ChoiceChip(
              label: Text(r.label),
              selected: role == r,
              onSelected: (_) => onChanged(r),
            ),
        ],
      ),
      const SizedBox(height: 4),
      Text(_help[role]!, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

// --- users ------------------------------------------------------------------

class _UserList extends StatelessWidget {
  const _UserList({required this.users, required this.onOpen});

  final List<AdminUser> users;
  final ValueChanged<AdminUser> onOpen;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return ListView.separated(
      padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
      itemCount: users.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, i) {
        final u = users[i];
        final seen = u.lastSeen;
        return SoftCard(
          onTap: () => onOpen(u),
          child: Row(
            children: [
              MemberAvatar(u.member, radius: 24),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      u.member.displayName,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '@${u.member.username} · '
                      '${_devices(u.sessions.length)}'
                      '${seen == null ? '' : ' · aktiv ${_ago(seen)}'}',
                      style: TextStyle(color: c.inkSoft),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (u.member.isAdmin)
                          const _Badge('Administrator', AppIcons.shieldUser),
                        if (u.member.role != MemberRole.adult)
                          _Badge(u.member.role.label, switch (u.member.role) {
                            MemberRole.guest => AppIcons.user,
                            MemberRole.service => AppIcons.bot,
                            _ => AppIcons.baby,
                          }),
                        if (u.homeAssistant)
                          const _Badge('Home Assistant', AppIcons.house),
                        if (!u.hasPassword)
                          const _Badge('ohne Passwort', AppIcons.key),
                        if (u.twoFactor)
                          const _Badge('Zwei-Faktor', AppIcons.shieldCheck),
                        if (u.singleSignOn) const _Badge('SSO', AppIcons.logIn),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(AppIcons.caretRight, color: c.inkSoft),
            ],
          ),
        );
      },
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.label, this.icon);

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final accent = c.strong(FamioSection.settings);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: c.tint(FamioSection.settings),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: accent),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: accent),
          ),
        ],
      ),
    );
  }
}

/// Details of one member: profile, role, password and devices.
class AdminUserScreen extends StatefulWidget {
  const AdminUserScreen({super.key, required this.userId});

  final String userId;

  @override
  State<AdminUserScreen> createState() => _AdminUserScreenState();
}

class _AdminUserScreenState extends State<AdminUserScreen> {
  late Future<AdminUser> _user;

  FamioApiClient get _api => AppScope.read(context).engine!.api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _user = _api.adminUsers().then(
      (all) => all.firstWhere(
        (u) => u.member.id == widget.userId,
        orElse: () =>
            throw const ApiError(404, 'not_found', 'Mitglied gelöscht'),
      ),
    );
  }

  void _refresh() => setState(_load);

  /// Runs [action], reports errors, reloads and syncs member changes.
  Future<void> _run(Future<void> Function() action, {String? done}) async {
    final messenger = ScaffoldMessenger.of(context);
    final engine = AppScope.read(context).engine!;
    try {
      await action();
      if (done != null) {
        messenger.showSnackBar(SnackBar(content: Text(done)));
      }
      await engine.refreshMembers();
    } on ApiError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final me = AppScope.of(context).me!;
    return FutureBuilder(
      future: _user,
      builder: (context, snapshot) {
        final user = snapshot.data;
        return SectionPage(
          maxBodyWidth: 960,
          section: FamioSection.settings,
          title: user?.member.displayName ?? 'Mitglied',
          subtitle: user == null ? null : '@${user.member.username}',
          body: ApiFutureView(
            snapshot: snapshot,
            onRetry: _refresh,
            builder: (u) => _details(context, u, isMe: u.member.id == me.id),
          ),
        );
      },
    );
  }

  Widget _details(BuildContext context, AdminUser u, {required bool isMe}) {
    final c = FamioColors.of(context);
    final accent = c.strong(FamioSection.settings);
    final m = u.member;
    return ListView(
      padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
      children: [
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  MemberAvatar(m, radius: 30),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          m.displayName,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(
                          'Mitglied seit ${DateFormat('d. MMMM y', 'de').format(u.createdAt)}',
                          style: TextStyle(color: c.inkSoft),
                        ),
                      ],
                    ),
                  ),
                  BubbleButton(
                    icon: AppIcons.pencilSimple,
                    tooltip: 'Bearbeiten',
                    onPressed: () => _edit(u),
                  ),
                ],
              ),
              if (u.homeAssistant) ...[
                const SizedBox(height: 12),
                Text(
                  'Über Home Assistant angelegt. Die Anmeldung in Home '
                  'Assistant funktioniert immer; ein Passwort ist nur für die '
                  'Apps nötig.',
                  style: TextStyle(color: c.inkSoft),
                ),
              ],
            ],
          ),
        ),
        ListHeading('Rolle', color: accent),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _RolePicker(
            role: m.role,
            onChanged: (r) => _run(
              () => _api.updateUser(
                m.id,
                role: r,
                isAdmin: _canAdminister(r) ? null : false,
              ),
            ),
          ),
        ),
        if (m.isService) ...[
          ListHeading('Darf ändern', color: accent),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    for (final a in ServiceAccess.values)
                      ChoiceChip(
                        label: Text(a.label),
                        selected: m.serviceAccess == a,
                        onSelected: (_) =>
                            _run(() => _api.updateUser(m.id, serviceAccess: a)),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(switch (m.serviceAccess) {
                  ServiceAccess.full =>
                    'Wie ein Erwachsener: Termine, Aufgaben, Listen … '
                        'anlegen, ändern und löschen.',
                  ServiceAccess.everyday =>
                    'Nur Aufgaben, Ämter und Routinen abhaken und '
                        'Einkaufslisten führen – z. B. für eine '
                        'Wandanzeige oder Sprachbefehle.',
                  ServiceAccess.readOnly =>
                    'Sieht alles für die Familie Freigegebene, ändert '
                        'nichts. Am sichersten für Home Assistant.',
                }, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
        SwitchListTile(
          secondary: const Icon(AppIcons.shieldUser),
          title: const Text('Administrator'),
          subtitle: const Text(
            'Darf Mitglieder verwalten und Servereinstellungen ändern',
          ),
          value: m.isAdmin,
          onChanged: _canAdminister(m.role)
              ? (v) => _run(() => _api.updateUser(m.id, isAdmin: v))
              : null,
        ),
        ListHeading('Kalender', color: accent),
        _MemberCalendars(member: m, isMe: isMe),
        ListHeading('Anmeldung', color: accent),
        ListTile(
          leading: const Icon(AppIcons.password),
          title: Text(
            u.hasPassword ? 'Passwort zurücksetzen' : 'Passwort festlegen',
          ),
          subtitle: Text(
            isMe
                ? 'Setzt dein Passwort neu, ohne das alte'
                : 'Z. B. wenn ${m.displayName} es vergessen hat',
          ),
          onTap: () => _resetPassword(u, isMe: isMe),
        ),
        ListTile(
          leading: Icon(
            u.twoFactor ? AppIcons.shieldCheck : AppIcons.shield,
            color: u.twoFactor ? c.strong(FamioSection.tasks) : null,
          ),
          title: Text(
            u.twoFactor ? 'Zwei-Faktor eingeschaltet' : 'Zwei-Faktor aus',
          ),
          subtitle: Text(
            u.twoFactor
                ? 'Handy verloren und keine Wiederherstellungscodes? '
                      'Zurücksetzen, dann reicht wieder das Passwort.'
                : isMe
                ? 'Einschalten unter Einstellungen → Anmeldung & Sicherheit'
                : '${m.displayName} kann sie in den eigenen Einstellungen '
                      'einschalten.',
          ),
          trailing: u.twoFactor
              ? TextButton(
                  onPressed: () => _confirmThen(
                    'Zwei-Faktor von ${m.displayName} zurücksetzen?',
                    'Danach reicht zum Anmelden wieder das Passwort, bis '
                        '${m.displayName} sie neu einrichtet.',
                    'Zurücksetzen',
                    () => _run(
                      () => _api.resetTwoFactor(m.id),
                      done: 'Zwei-Faktor zurückgesetzt',
                    ),
                  ),
                  child: const Text('Zurücksetzen'),
                )
              : null,
        ),
        if (u.singleSignOn)
          ListTile(
            leading: const Icon(AppIcons.logIn),
            title: const Text('Mit Single Sign-On verknüpft'),
            trailing: TextButton(
              onPressed: () => _run(
                () => _api.unlinkUserSso(m.id),
                done: 'Verknüpfung gelöst',
              ),
              child: const Text('Lösen'),
            ),
          ),
        ListHeading(
          'Geräte (${u.sessions.length})',
          color: accent,
          trailing: u.sessions.length > (isMe ? 1 : 0)
              ? TextButton(
                  onPressed: () => _run(
                    () => _api.signOutUser(m.id),
                    done: isMe
                        ? 'Alle anderen Geräte abgemeldet'
                        : '${m.displayName} wurde überall abgemeldet',
                  ),
                  child: Text(isMe ? 'Andere abmelden' : 'Überall abmelden'),
                )
              : null,
        ),
        if (u.sessions.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Auf keinem Gerät angemeldet.',
              style: TextStyle(color: c.inkSoft),
            ),
          ),
        for (final s in u.sessions)
          DeviceTile(
            session: s,
            onSignOut: s.current
                ? null
                : () => _run(() => _api.signOutUser(m.id, sessionId: s.id)),
          ),
        if (!isMe) ...[
          const SizedBox(height: 16),
          ListTile(
            leading: Icon(AppIcons.userMinus, color: c.danger),
            title: Text(
              '${m.displayName} entfernen',
              style: TextStyle(color: c.danger),
            ),
            subtitle: const Text(
              'Konto löschen und auf allen Geräten abmelden',
            ),
            onTap: () => _remove(u),
          ),
        ],
      ],
    );
  }

  Future<void> _confirmThen(
    String title,
    String text,
    String action,
    Future<void> Function() then,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );
    if (ok == true) await then();
  }

  Future<void> _edit(AdminUser u) async {
    final name = TextEditingController(text: u.member.displayName);
    final username = TextEditingController(text: u.member.username);
    var color = u.member.color;
    var birthday = u.member.birthday;
    var saved = false;
    await showDialog<void>(
      context: context,
      builder: (context) => FormDialog(
        title: 'Mitglied bearbeiten',
        controllers: [name, username],
        fields: [
          TextField(
            controller: name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Anzeigename'),
          ),
          TextField(
            controller: username,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Benutzername'),
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
          await _api.updateUser(
            u.member.id,
            displayName: name.text,
            username: username.text,
            color: color,
            birthday: birthday,
            clearBirthday: birthday == null,
          );
          saved = true;
        },
      ),
    );
    if (saved && mounted) await _run(() async {});
  }

  Future<void> _resetPassword(AdminUser u, {required bool isMe}) async {
    final password = TextEditingController();
    var signOut = true;
    var signedOut = -1;
    await showDialog<void>(
      context: context,
      builder: (context) => FormDialog(
        title: 'Neues Passwort für ${u.member.displayName}',
        submitLabel: 'Festlegen',
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
                labelText: 'Neues Passwort (min. 8 Zeichen)',
              ),
            ),
          ),
          StatefulBuilder(
            builder: (context, setState) => CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                isMe ? 'Andere Geräte abmelden' : 'Auf allen Geräten abmelden',
              ),
              value: signOut,
              onChanged: (v) => setState(() => signOut = v ?? true),
            ),
          ),
        ],
        onSubmit: () async {
          signedOut = await _api.resetPassword(
            u.member.id,
            password.text,
            signOut: signOut,
          );
        },
      ),
    );
    if (signedOut < 0 || !mounted) return;
    await _run(
      () async {},
      done: signedOut == 0
          ? 'Passwort geändert'
          : 'Passwort geändert, ${_devices(signedOut)} abgemeldet',
    );
  }

  Future<void> _remove(AdminUser u) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${u.member.displayName} entfernen?'),
        content: const Text(
          'Das Konto wird gelöscht und auf allen Geräten abgemeldet. '
          'Aufgaben, Termine und Listen bleiben erhalten.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: FamioColors.of(context).danger,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Entfernen'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final engine = AppScope.read(context).engine!;
    try {
      await _api.deleteMember(u.member.id);
      await engine.refreshMembers();
      navigator.pop();
    } on ApiError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

// --- settings ---------------------------------------------------------------

class _SettingsForm extends StatefulWidget {
  const _SettingsForm({
    super.key,
    required this.overview,
    required this.onSaved,
  });

  final ServerOverview overview;
  final ValueChanged<ServerOverview> onSaved;

  @override
  State<_SettingsForm> createState() => _SettingsFormState();
}

class _SettingsFormState extends State<_SettingsForm> {
  late final _publicUrl = TextEditingController(
    text: widget.overview.settings.publicUrl ?? '',
  );
  late final _upload = TextEditingController(
    text: widget.overview.settings.maxUploadMb?.toString() ?? '',
  );
  late final _tiles = TextEditingController(
    text:
        widget.overview.settings.mapTileUrl ??
        widget.overview.effective.mapTileUrl ??
        '',
  );
  late final _locationHistory = TextEditingController(
    text: widget.overview.settings.locationHistoryDays?.toString() ?? '',
  );
  late String _zone = widget.overview.settings.timeZone ?? '';
  late MapTileProvider _mapProvider =
      widget.overview.settings.mapProvider ??
      (widget.overview.effective.mapTileUrl == null
          ? MapTileProvider.openStreetMap
          : MapTileProvider.custom);
  late TwoFactorPolicy? _policy = widget.overview.settings.twoFactorRequired;
  var _busy = false;
  String? _error;

  static List<String>? _zones;

  static List<String> get zones {
    if (_zones == null) {
      tzdata.initializeTimeZones();
      _zones =
          tz.timeZoneDatabase.locations.keys
              .where((z) => z.contains('/') && !z.startsWith('Etc/'))
              .toList()
            ..sort();
    }
    return _zones!;
  }

  @override
  void dispose() {
    _publicUrl.dispose();
    _upload.dispose();
    _tiles.dispose();
    _locationHistory.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final upload = _upload.text.trim();
    try {
      final fresh = await AppScope.read(context).engine!.api
          .updateServerSettings({
            'publicUrl': _publicUrl.text.trim().isEmpty
                ? null
                : _publicUrl.text.trim(),
            'timeZone': _zone.trim().isEmpty ? null : _zone.trim(),
            'maxUploadMb': upload.isEmpty ? null : int.tryParse(upload) ?? -1,
            'mapProvider': _mapProvider.wire,
            'mapTileUrl': _mapProvider == MapTileProvider.openStreetMap
                ? null
                : _tiles.text.trim().isEmpty
                ? null
                : _tiles.text.trim(),
            'locationHistoryDays': _locationHistory.text.trim().isEmpty
                ? null
                : int.tryParse(_locationHistory.text.trim()) ?? -1,
            'twoFactorRequired': _policy?.name,
          });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Servereinstellungen gespeichert')),
      );
      widget.onSaved(fresh);
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Switches areas off for the whole family (e.g. Finanzen); their data
  /// stays on the server and comes back when switched on again.
  Future<void> _editModules() async {
    final hidden = {...?widget.overview.settings.hiddenModules};
    final optional = [
      for (final s in FamioSection.values)
        if (ServerSettings.optionalModules.contains(s.name)) s,
    ];
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          scrollable: true,
          title: const Text('Bereiche'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Was die Familie nicht nutzt, verschwindet aus Menü und '
                  'Startseite – in allen Apps. Die Daten bleiben erhalten.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                for (final s in optional)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: Icon(s.icon),
                    title: Text(s.label),
                    value: !hidden.contains(s.name),
                    onChanged: (on) => setDialog(
                      () => on ? hidden.remove(s.name) : hidden.add(s.name),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Speichern'),
            ),
          ],
        ),
      ),
    );
    if (save != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final fresh = await AppScope.read(
        context,
      ).engine!.api.updateServerSettings({'hiddenModules': hidden.toList()});
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Bereiche gespeichert')));
      widget.onSaved(fresh);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setCode() async {
    final api = AppScope.read(context).engine!.api;
    final code = TextEditingController();
    final repeat = TextEditingController();
    var saved = false;
    await showDialog<void>(
      context: context,
      builder: (context) => FormDialog(
        title: 'Eltern-Code',
        controllers: [code, repeat],
        fields: [
          const Text(
            'Mit diesem Code können Eltern die Standortfreigabe eines '
            'Familienmitglieds pausieren oder auf einem Handy beenden. '
            'Kindern nicht verraten.',
          ),
          PasswordReveal(
            builder: (_, obscure, toggle) => TextField(
              controller: code,
              obscureText: obscure,
              contextMenuBuilder: PasswordReveal.contextMenu,
              autofocus: true,
              decoration: InputDecoration(
                suffixIcon: toggle,
                labelText: 'Neuer Code (mind. 4 Zeichen)',
              ),
            ),
          ),
          PasswordReveal(
            builder: (_, obscure, toggle) => TextField(
              controller: repeat,
              obscureText: obscure,
              contextMenuBuilder: PasswordReveal.contextMenu,
              decoration: InputDecoration(
                suffixIcon: toggle,
                labelText: 'Code wiederholen',
              ),
            ),
          ),
        ],
        onSubmit: () async {
          if (code.text != repeat.text) {
            throw const ApiError(
              0,
              'mismatch',
              'Die Codes stimmen nicht überein',
            );
          }
          await api.setLocationCode(code.text);
          saved = true;
        },
      ),
    );
    if (!saved || !mounted) return;
    widget.onSaved(await api.adminOverview());
  }

  Future<void> _resetSettings() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Einstellungen zurücksetzen?'),
        content: const Text(
          'Öffentliche Adresse, Zeitzone, maximale Dateigröße und '
          'Kartenserver gelten wieder so, wie sie in der Server-Konfiguration '
          '(Umgebungsvariablen bzw. Add-on-Optionen) stehen. Daten, '
          'Mitglieder und der Eltern-Code bleiben unverändert.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Zurücksetzen'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final fresh = await AppScope.read(
        context,
      ).engine!.api.resetServerSettings();
      messenger.showSnackBar(
        const SnackBar(content: Text('Einstellungen auf Standard gesetzt')),
      );
      widget.onSaved(fresh);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _wipe() async {
    final engine = AppScope.read(context).engine!;
    final messenger = ScaffoldMessenger.of(context);
    final password = TextEditingController();
    final confirm = TextEditingController();
    var removeMembers = false;
    ({int records, int files, int members})? result;
    await showDialog<void>(
      context: context,
      builder: (context) {
        final c = FamioColors.of(context);
        return FormDialog(
          title: 'Alle Daten löschen?',
          submitLabel: 'Endgültig löschen',
          controllers: [password, confirm],
          fields: [
            Text(
              'Gelöscht werden alle Termine, Chats, Listen, Aufgaben, Ämter, '
              'Dokumente, Fotos, Kinder- und Gesundheitsdaten, Standorte, '
              'verbundene Kalender und Kalender-Links – auf dem Server und '
              'beim nächsten Abgleich auf allen Geräten. Das lässt sich nicht '
              'rückgängig machen; vorher eine Sicherung des Datenordners '
              'anlegen.\n\nErhalten bleiben die Konten, Server-Einstellungen '
              'und das HTTPS-Zertifikat.',
              style: TextStyle(color: c.inkSoft),
            ),
            StatefulBuilder(
              builder: (context, setState) => CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auch alle anderen Mitglieder entfernen'),
                subtitle: const Text('Nur dein Konto bleibt bestehen'),
                value: removeMembers,
                onChanged: (v) => setState(() => removeMembers = v ?? false),
              ),
            ),
            PasswordReveal(
              builder: (_, obscure, toggle) => TextField(
                controller: password,
                obscureText: obscure,
                contextMenuBuilder: PasswordReveal.contextMenu,
                decoration: InputDecoration(
                  suffixIcon: toggle,
                  labelText: 'Dein Passwort',
                  helperText:
                      'Leer lassen, wenn du dich nur über Home Assistant '
                      'anmeldest.',
                  helperMaxLines: 2,
                ),
              ),
            ),
            TextField(
              controller: confirm,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Zur Bestätigung LÖSCHEN eingeben',
              ),
            ),
          ],
          onSubmit: () async {
            if (confirm.text.trim().toUpperCase() != 'LÖSCHEN') {
              throw const ApiError(
                0,
                'confirmation_required',
                'Bitte zur Bestätigung LÖSCHEN eingeben',
              );
            }
            result = await engine.api.wipeServerData(
              password: password.text,
              confirm: 'LÖSCHEN',
              removeMembers: removeMembers,
            );
          },
        );
      },
    );
    final done = result;
    if (done == null) return;
    // Pull the deletions right away; other devices follow on their next sync.
    unawaited(engine.sync());
    if (done.members > 0) unawaited(engine.refreshMembers());
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Gelöscht: ${done.records} Einträge, ${done.files} Dateien'
          '${done.members > 0 ? ', ${done.members} Mitglieder' : ''}',
        ),
      ),
    );
    if (mounted) widget.onSaved(await engine.api.adminOverview());
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.overview;
    final c = FamioColors.of(context);
    final accent = c.strong(FamioSection.settings);
    String hint(String? v) => 'Standard: ${v ?? '–'}';
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
          children: [
            Text(
              'Änderungen gelten sofort für alle Geräte. Leere Felder nutzen den '
              'Standard aus der Server-Konfiguration (Umgebungsvariablen bzw. '
              'Add-on-Optionen).',
              style: TextStyle(color: c.inkSoft),
            ),
            ListHeading('Erreichbarkeit', color: accent),
            TextField(
              controller: _publicUrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Öffentliche Adresse',
                hintText: 'https://famio.example.org',
                helperText:
                    '${hint(o.defaults.publicUrl)}. Für Kalender-Abos (Google, '
                    'iCloud) über den Reverse-Proxy.',
                helperMaxLines: 3,
                prefixIcon: const Icon(AppIcons.globe),
              ),
            ),
            ListHeading('Familie', color: accent),
            Autocomplete<String>(
              initialValue: TextEditingValue(text: _zone),
              optionsBuilder: (value) {
                final q = value.text.toLowerCase();
                if (q.isEmpty) return const [];
                return zones.where((z) => z.toLowerCase().contains(q)).take(20);
              },
              onSelected: (z) => _zone = z,
              fieldViewBuilder: (context, controller, focus, onSubmit) =>
                  TextField(
                    controller: controller,
                    focusNode: focus,
                    onChanged: (v) => _zone = v,
                    decoration: InputDecoration(
                      labelText: 'Zeitzone',
                      hintText: 'Europe/Berlin',
                      helperText:
                          '${hint(o.defaults.timeZone)}. Für Kalender-Feeds und '
                          'importierte Termine.',
                      helperMaxLines: 2,
                      prefixIcon: const Icon(AppIcons.clock),
                    ),
                  ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _upload,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Maximale Dateigröße (MB)',
                helperText:
                    '${hint('${o.defaults.maxUploadMb ?? 100} MB')}. Bei NPM auch '
                    'client_max_body_size anpassen.',
                helperMaxLines: 2,
                prefixIcon: const Icon(AppIcons.upload),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Kartenanbieter',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final provider in MapTileProvider.values)
                  ChoiceChip(
                    label: Text(switch (provider) {
                      MapTileProvider.openStreetMap => 'OpenStreetMap',
                      MapTileProvider.martin => 'Eigener Martin-Server',
                      MapTileProvider.custom => 'Eigene XYZ-Adresse',
                    }),
                    selected: _mapProvider == provider,
                    onSelected: (_) => setState(() => _mapProvider = provider),
                  ),
              ],
            ),
            if (_mapProvider == MapTileProvider.openStreetMap)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Sofort nutzbar. Der öffentliche Dienst sieht den geladenen Kartenausschnitt.',
                ),
              )
            else ...[
              const SizedBox(height: 12),
              TextField(
                controller: _tiles,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: _mapProvider == MapTileProvider.martin
                      ? 'Martin-Kacheladresse'
                      : 'XYZ-Kacheladresse',
                  hintText:
                      'https://karten.example.org/tiles/basemap/{z}/{x}/{y}',
                  helperText: _mapProvider == MapTileProvider.martin
                      ? 'Martin stellt eigene PMTiles/MBTiles bereit. Docker: docker compose --profile maps up -d; danach die HTTPS-Adresse hier eintragen.'
                      : 'HTTPS-Adresse mit {z}, {x} und {y}.',
                  helperMaxLines: 3,
                  prefixIcon: const Icon(AppIcons.map),
                ),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _locationHistory,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Standortverlauf (Tage)',
                hintText: '7',
                helperText:
                    '${hint('${o.defaults.locationHistoryDays ?? 7} Tage')}. '
                    'Alte, präzise Punkte und Ortsmeldungen werden automatisch '
                    'gelöscht; der aktuelle Standort bleibt sichtbar.',
                helperMaxLines: 3,
                prefixIcon: const Icon(AppIcons.mapPin),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<TwoFactorPolicy?>(
              initialValue: _policy,
              decoration: const InputDecoration(
                labelText: 'Zwei-Faktor-Anmeldung verlangen',
                helperText:
                    'Betroffene richten beim nächsten Öffnen der App eine '
                    'Authenticator-App ein; Single Sign-On zählt auch. Für '
                    'Home Assistant ein eigenes Mitglied ohne Pflicht nutzen.',
                helperMaxLines: 3,
                prefixIcon: Icon(AppIcons.shieldCheck),
              ),
              items: [
                const DropdownMenuItem(
                  value: null,
                  child: Text('Nicht verlangt'),
                ),
                for (final p in TwoFactorPolicy.values)
                  DropdownMenuItem(value: p, child: Text('Für ${p.label}')),
              ],
              onChanged: (p) => setState(() => _policy = p),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: c.danger)),
            ],
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerLeft,
              child: ColorButton(
                label: 'Speichern',
                icon: AppIcons.check,
                color: accent,
                onPressed: _busy ? null : _save,
              ),
            ),
            ListHeading('Anmeldung', color: accent),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(AppIcons.logIn),
              title: const Text('Single Sign-On (OpenID Connect)'),
              subtitle: const Text(
                'Anmelden mit Authentik, Keycloak, Authelia, Google, Microsoft …',
              ),
              trailing: TextButton(
                onPressed: _busy ? null : () => showSsoDialog(context),
                child: const Text('Einrichten'),
              ),
            ),
            ListHeading('Bereiche', color: accent),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(AppIcons.dotsThreeCircle),
              title: const Text('Bereiche ein- und ausblenden'),
              subtitle: Text(
                (o.settings.hiddenModules ?? const []).isEmpty
                    ? 'Alle Bereiche sind sichtbar'
                    : 'Ausgeblendet: ${[for (final s in FamioSection.values)
                        if (o.settings.hiddenModules!.contains(s.name)) s.label].join(', ')}',
              ),
              trailing: TextButton(
                onPressed: _busy ? null : _editModules,
                child: const Text('Ändern'),
              ),
            ),
            ListHeading('Standort', color: accent),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(AppIcons.lockKey),
              title: const Text('Eltern-Code'),
              subtitle: Text(
                o.locationCodeSet
                    ? 'Festgelegt. Nötig, um eine Standortfreigabe zu '
                          'pausieren oder zu beenden.'
                    : 'Noch nicht festgelegt – ohne Code kann niemand die '
                          'Standortfreigabe pausieren.',
              ),
              trailing: TextButton(
                onPressed: _busy ? null : _setCode,
                child: Text(o.locationCodeSet ? 'Ändern' : 'Festlegen'),
              ),
            ),
            ListHeading('Nur auf dem Server änderbar', color: accent),
            _InfoRow(
              icon: AppIcons.shield,
              label: 'Reverse-Proxy vertrauen',
              value: o.trustProxy ? 'an' : 'aus',
              note: 'FAMIO_TRUST_PROXY – aus Sicherheitsgründen nicht per App',
            ),
            _InfoRow(
              icon: AppIcons.house,
              label: 'Home-Assistant-Anmeldung',
              value: o.ingressAuth ? 'an' : 'aus',
              note: 'Add-on-Option ingress_auth',
            ),
            ListHeading('Zurücksetzen', color: c.danger),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(AppIcons.arrowsClockwise),
              title: const Text('Einstellungen auf Standard'),
              subtitle: const Text(
                'Adresse, Zeitzone, Dateigröße und Kartenserver wieder aus der '
                'Server-Konfiguration nehmen. Daten und Eltern-Code bleiben.',
              ),
              trailing: TextButton(
                onPressed: _busy ? null : _resetSettings,
                child: const Text('Zurücksetzen'),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(AppIcons.trash, color: c.danger),
              title: Text(
                'Alle Daten löschen',
                style: TextStyle(color: c.danger),
              ),
              subtitle: const Text(
                'Termine, Chat, Listen, Dokumente, Fotos und alles Weitere '
                'endgültig löschen – auf dem Server und allen Geräten.',
              ),
              trailing: TextButton(
                style: TextButton.styleFrom(foregroundColor: c.danger),
                onPressed: _busy ? null : _wipe,
                child: const Text('Löschen …'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- status -----------------------------------------------------------------

class _StatusView extends StatelessWidget {
  const _StatusView({required this.overview});

  final ServerOverview overview;

  static const _collectionLabels = {
    Collections.tasks: 'Aufgaben',
    Collections.shoppingLists: 'Einkaufslisten',
    Collections.shoppingItems: 'Einkaufsartikel',
    Collections.events: 'Termine',
    Collections.calendarSubscriptions: 'Kalender-Abos',
    Collections.externalEvents: 'Importierte Termine',
    Collections.chatMessages: 'Chat-Nachrichten',
    Collections.documents: 'Dokumente',
    Collections.children: 'Kinder',
    Collections.childEntries: 'Kinder-Einträge',
  };

  @override
  Widget build(BuildContext context) {
    final o = overview;
    final c = FamioColors.of(context);
    final accent = c.strong(FamioSection.settings);
    return ListView(
      padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _Stat(AppIcons.hardDrives, 'Version', o.version),
            _Stat(
              AppIcons.activity,
              'Läuft seit',
              _ago(o.startedAt, suffix: false),
            ),
            _Stat(AppIcons.usersThree, 'Mitglieder', '${o.memberCount}'),
            _Stat(AppIcons.devices, 'Angemeldete Geräte', '${o.sessionCount}'),
            _Stat(
              AppIcons.arrowsClockwise,
              'Gerade verbunden',
              '${o.connectedClients}',
            ),
            _Stat(
              AppIcons.database,
              'Datenbank',
              fileSizeLabel(o.databaseBytes),
            ),
            _Stat(
              AppIcons.folderOpen,
              'Dateien',
              '${o.fileCount} · ${fileSizeLabel(o.fileBytes)}',
            ),
          ],
        ),
        ListHeading('Einträge', color: accent),
        SoftCard(
          child: Column(
            children: [
              for (final MapEntry(:key, :value) in o.recordCounts.entries)
                if (_collectionLabels[key] case final label?)
                  _InfoRow(label: label, value: '$value'),
              if (o.recordCounts.isEmpty)
                Text(
                  'Noch keine Einträge.',
                  style: TextStyle(color: c.inkSoft),
                ),
            ],
          ),
        ),
        ListHeading('Sicherheit', color: accent),
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _InfoRow(
                icon: AppIcons.database,
                label: 'Daten auf dem Server',
                value: o.encryptedAtRest ? 'verschlüsselt' : 'unverschlüsselt',
                note: o.encryptedAtRest && !o.keySeparate
                    ? 'Schlüssel liegt im Datenordner – FAMIO_KEY_FILE '
                          'woanders hin legen und getrennt sichern'
                    : o.encryptedAtRest
                    ? 'Schlüssel getrennt von den Daten'
                    : null,
              ),
              _InfoRow(
                icon: AppIcons.lock,
                label: 'HTTPS im Heimnetz',
                value: o.tlsPort == null ? 'aus' : 'Port ${o.tlsPort}',
              ),
              _InfoRow(
                icon: AppIcons.shield,
                label: 'Unverschlüsselter Zugriff',
                value: o.requireTls ? 'gesperrt' : 'erlaubt',
                note: o.requireTls
                    ? null
                    : 'FAMIO_REQUIRE_TLS=true, sobald alle Geräte HTTPS nutzen',
              ),
              if (o.tlsFingerprint case final fp?) ...[
                const SizedBox(height: 8),
                Text(
                  'Zertifikat-Fingerabdruck (zum Vergleich beim Verbinden):',
                  style: TextStyle(color: c.inkSoft),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  [
                    for (var i = 0; i < fp.split(':').length; i += 8)
                      fp.split(':').skip(i).take(8).join(':'),
                  ].join('\n'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ],
            ],
          ),
        ),
        ListHeading('Aktive Konfiguration', color: accent),
        SoftCard(
          child: Column(
            children: [
              _InfoRow(label: 'Zeitzone', value: o.effective.timeZone ?? '–'),
              _InfoRow(
                label: 'Öffentliche Adresse',
                value: o.effective.publicUrl ?? 'keine',
              ),
              _InfoRow(
                label: 'Max. Dateigröße',
                value: '${o.effective.maxUploadMb} MB',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.icon, this.label, this.value);

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return SizedBox(
      width: 200,
      child: SoftCard(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            IconBlob(
              icon,
              color: c.strong(FamioSection.settings),
              background: c.tint(FamioSection.settings),
              size: 40,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    label,
                    style: Theme.of(
                      context,
                    ).textTheme.labelMedium?.copyWith(color: c.inkSoft),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.icon,
    this.note,
  });

  final IconData? icon;
  final String label;
  final String value;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 20, color: c.inkSoft),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                if (note != null)
                  Text(
                    note!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: c.inkSoft),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        ],
      ),
    );
  }
}

// --- shared -----------------------------------------------------------------

/// A signed-in device with an optional "sign out" button.
class DeviceTile extends StatelessWidget {
  const DeviceTile({super.key, required this.session, this.onSignOut});

  final DeviceSession session;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final device = session.device ?? 'Unbekanntes Gerät';
    final mobile = RegExp('android|ios', caseSensitive: false).hasMatch(device);
    return ListTile(
      leading: Icon(mobile ? AppIcons.smartphone : AppIcons.laptop),
      title: Text(_deviceLabel(device)),
      subtitle: Text(
        session.current
            ? 'Dieses Gerät'
            : 'Zuletzt aktiv ${_ago(session.lastSeen)} · angemeldet '
                  '${DateFormat('d.M.y', 'de').format(session.createdAt)}',
      ),
      trailing: onSignOut == null
          ? null
          : IconButton(
              icon: Icon(AppIcons.signOut, color: c.danger),
              tooltip: 'Abmelden',
              onPressed: onSignOut,
            ),
    );
  }

  /// `macos (Marcos-MacBook)` → `macOS · Marcos-MacBook`.
  static String _deviceLabel(String device) {
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
        Text('Farbe', style: TextStyle(color: c.inkSoft)),
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
            : 'Server nicht erreichbar. Die Verwaltung braucht eine Verbindung.',
        action: TextButton(
          onPressed: onRetry,
          child: const Text('Erneut versuchen'),
        ),
      );
    }
    return const Center(child: CircularProgressIndicator());
  }
}

String _devices(int n) => n == 1 ? '1 Gerät' : '$n Geräte';

/// "vor 5 Min." style relative time.
String _ago(DateTime t, {bool suffix = true}) {
  final d = DateTime.now().difference(t);
  final text = switch (d) {
    _ when d.inMinutes < 1 => suffix ? 'gerade eben' : 'eben',
    _ when d.inHours < 1 => '${d.inMinutes} Min.',
    _ when d.inDays < 1 => '${d.inHours} Std.',
    _ when d.inDays < 30 => d.inDays == 1 ? '1 Tag' : '${d.inDays} Tagen',
    _ => dayLabel(t),
  };
  if (d.inMinutes < 1 || d.inDays >= 30) return text;
  return suffix ? 'vor $text' : text.replaceAll('Tagen', 'Tage');
}

/// A member's calendar profile: which calendars other members shared with
/// them appear in their Famio. Hidden ones never reach their devices.
class _MemberCalendars extends StatefulWidget {
  const _MemberCalendars({required this.member, required this.isMe});

  final FamilyMember member;
  final bool isMe;

  @override
  State<_MemberCalendars> createState() => _MemberCalendarsState();
}

class _MemberCalendarsState extends State<_MemberCalendars> {
  late Future<List<MemberCalendar>> _calendars = _api.memberCalendars(
    widget.member.id,
  );
  var _busy = false;

  FamioApiClient get _api => AppScope.read(context).engine!.api;

  Future<void> _toggle(List<MemberCalendar> all, MemberCalendar c) async {
    setState(() => _busy = true);
    final hidden = {
      for (final x in all)
        if (x.hidden) x.source,
    };
    c.hidden ? hidden.remove(c.source) : hidden.add(c.source);
    final engine = AppScope.read(context).engine!;
    final future = _api.setMemberCalendars(widget.member.id, hidden);
    try {
      await future;
      if (mounted) setState(() => _calendars = future);
      await engine.sync();
    } on ApiError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final engine = AppScope.of(context).engine!;
    final name = widget.member.displayName;
    return FutureBuilder(
      future: _calendars,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ListTile(
            leading: const Icon(AppIcons.cloudSlash),
            title: const Text('Nur mit Verbindung zum Server verfügbar'),
            trailing: TextButton(
              onPressed: () => setState(
                () => _calendars = _api.memberCalendars(widget.member.id),
              ),
              child: const Text('Erneut'),
            ),
          );
        }
        final all = snapshot.data;
        if (all == null) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                all.isEmpty
                    ? 'Noch hat niemand einen Kalender mit '
                          '${widget.isMe ? 'dir' : name} geteilt. Eigene '
                          'Kalender verbindet jedes Mitglied unter '
                          'Kalender → Kalender verbinden.'
                    : 'Diese Kalender haben andere mit '
                          '${widget.isMe ? 'dir' : name} geteilt. Was hier '
                          'aus ist, sieht ${widget.isMe ? 'du' : name} in '
                          'Famio nicht. Eigene Kalender sieht jeder immer.',
                style: TextStyle(color: c.inkSoft),
              ),
            ),
            for (final cal in all)
              SwitchListTile(
                secondary: Icon(switch (cal.kind) {
                  'subscription' => AppIcons.link,
                  _ => AppIcons.arrowsLeftRight,
                }),
                title: Text(cal.name),
                subtitle: Text(
                  [
                    switch (cal.kind) {
                      'google' => 'Google',
                      'caldav' => 'CalDAV',
                      _ => 'Abo',
                    },
                    cal.ownerId == null
                        ? 'für die ganze Familie'
                        : 'von ${engine.member(cal.ownerId)?.displayName ?? 'unbekannt'}',
                  ].join(' · '),
                ),
                value: !cal.hidden,
                onChanged: _busy ? null : (_) => _toggle(all, cal),
              ),
          ],
        );
      },
    );
  }
}

/// Admins set up the single sign-on provider.
Future<void> showSsoDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _SsoDialog());

class _SsoDialog extends StatefulWidget {
  const _SsoDialog();

  @override
  State<_SsoDialog> createState() => _SsoDialogState();
}

class _SsoDialogState extends State<_SsoDialog> {
  final _issuer = TextEditingController();
  final _clientId = TextEditingController();
  final _secret = TextEditingController();
  final _label = TextEditingController();
  var _match = false;
  var _configured = false;
  var _secretSet = false;
  String? _redirect;
  String? _error;
  var _loading = true;
  var _busy = false;

  FamioApiClient get _api => AppScope.read(context).engine!.api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_issuer, _clientId, _secret, _label]) {
      c.dispose();
    }
    super.dispose();
  }

  void _apply(Map<String, Object?> json) {
    _issuer.text = json['issuer'] as String? ?? '';
    _clientId.text = json['clientId'] as String? ?? '';
    _label.text = json['label'] as String? ?? '';
    _match = json['matchUsername'] as bool? ?? false;
    _configured = json['configured'] as bool? ?? false;
    _secretSet = json['secretSet'] as bool? ?? false;
    _redirect = json['redirectUri'] as String?;
  }

  Future<void> _load() async {
    try {
      final json = await _api.ssoConfig();
      if (mounted) setState(() => _apply(json));
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final json = await _api.saveSsoConfig(
        issuer: _issuer.text.trim(),
        clientId: _clientId.text.trim(),
        clientSecret: _secret.text,
        label: _label.text.trim(),
        matchUsername: _match,
      );
      if (!mounted) return;
      setState(() => _apply(json));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Single Sign-On gespeichert')),
      );
      Navigator.pop(context);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    try {
      await _api.deleteSsoConfig();
      if (mounted) Navigator.pop(context);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return AlertDialog(
      title: const Text('Single Sign-On'),
      content: SizedBox(
        width: 480,
        child: _loading
            ? const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Beim Anbieter (z. B. Authentik: „Anwendungen → OAuth2/'
                      'OpenID-Provider“) eine vertrauliche Anwendung anlegen '
                      'und diese Weiterleitungs-Adresse eintragen:',
                      style: TextStyle(color: c.inkSoft),
                    ),
                    const SizedBox(height: 6),
                    if (_redirect case final redirect?)
                      Row(
                        children: [
                          Expanded(
                            child: SelectableText(
                              redirect,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Kopieren',
                            icon: const Icon(AppIcons.copy, size: 18),
                            onPressed: () => Clipboard.setData(
                              ClipboardData(text: redirect),
                            ),
                          ),
                        ],
                      )
                    else
                      Text(
                        'Zuerst unter Einstellungen die öffentliche Adresse '
                        'eintragen und speichern.',
                        style: TextStyle(color: c.danger),
                      ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _issuer,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Anbieter-Adresse (Issuer)',
                        hintText:
                            'https://auth.example.de/application/o/famio/',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _clientId,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: 'Client-ID'),
                    ),
                    const SizedBox(height: 12),
                    PasswordReveal(
                      builder: (_, obscure, toggle) => TextField(
                        controller: _secret,
                        obscureText: obscure,
                        contextMenuBuilder: PasswordReveal.contextMenu,
                        decoration: InputDecoration(
                          labelText: 'Client-Secret',
                          helperText: _secretSet
                              ? 'Gespeichert – leer lassen, um es zu behalten'
                              : null,
                          suffixIcon: toggle,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _label,
                      decoration: const InputDecoration(
                        labelText: 'Name auf dem Knopf',
                        hintText: 'Authentik',
                        helperText:
                            '„Mit … anmelden“ auf dem Anmeldebildschirm',
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Gleiche Benutzernamen zuordnen'),
                      subtitle: const Text(
                        'Wer beim Anbieter denselben Benutzernamen hat, wird '
                        'ohne vorheriges Verknüpfen angemeldet. Nur einschalten, '
                        'wenn dort niemand Fremdes Konten anlegen kann.',
                      ),
                      value: _match,
                      onChanged: (v) => setState(() => _match = v),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(_error!, style: TextStyle(color: c.danger)),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        if (_configured)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: c.danger),
            onPressed: _busy ? null : _remove,
            child: const Text('Entfernen'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: _busy || _loading || _redirect == null ? null : _save,
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}
