part of '../admin_screens.dart';

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
          _UsernameField(controller: username, label: 'Benutzername'),
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
