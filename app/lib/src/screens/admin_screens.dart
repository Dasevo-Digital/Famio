import 'dart:async';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/usernames.dart';
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
import '../widgets/data_export.dart';

part 'admin/member_calendars.dart';
part 'admin/settings_form.dart';
part 'admin/shared_widgets.dart';
part 'admin/sso_dialog.dart';
part 'admin/status_view.dart';
part 'admin/user_screen.dart';

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
    // The login name follows the name ("Jürgen" → "juergen") until it is
    // edited by hand.
    final taken = [for (final m in engine.allMembers) m.username];
    var suggested = '';
    void follow() {
      if (username.text != suggested) return;
      suggested = suggestUsername(name.text, taken);
      username.value = TextEditingValue(
        text: suggested,
        selection: TextSelection.collapsed(offset: suggested.length),
      );
    }

    name.addListener(follow);
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
          _UsernameField(
            controller: username,
            label: 'Benutzername (für die Anmeldung)',
            helper: 'Wird aus dem Namen vorgeschlagen',
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

/// A login name field that says right away what the server would refuse.
class _UsernameField extends StatelessWidget {
  const _UsernameField({
    required this.controller,
    required this.label,
    this.helper,
  });

  final TextEditingController controller;
  final String label;
  final String? helper;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller,
    builder: (context, value, _) => TextField(
      controller: controller,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        errorText: usernameProblem(value.text),
      ),
    ),
  );
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
