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
        orElse: () => throw ApiError(404, 'not_found', tr.adminMemberDeleted),
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
          title: user?.member.displayName ?? tr.commonMember,
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
                          tr.adminMemberSinceDate(
                            DateFormat.yMMMMd(appLanguage).format(u.createdAt),
                          ),
                          style: TextStyle(color: c.inkSoft),
                        ),
                      ],
                    ),
                  ),
                  BubbleButton(
                    icon: AppIcons.pencilSimple,
                    tooltip: tr.commonEdit,
                    onPressed: () => _edit(u),
                  ),
                ],
              ),
              if (u.homeAssistant) ...[
                const SizedBox(height: 12),
                Text(
                  tr.adminCreatedThroughHomeAssistant,
                  style: TextStyle(color: c.inkSoft),
                ),
              ],
            ],
          ),
        ),
        ListHeading(tr.adminRole, color: accent),
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
          ListHeading(tr.adminMayChange, color: accent),
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
                  ServiceAccess.full => tr.adminLikeAdultCreateChange,
                  ServiceAccess.everyday => tr.adminOnlyTickOffTasks,
                  ServiceAccess.readOnly => tr.adminSeesEverythingSharedFamily,
                }, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
        SwitchListTile(
          secondary: const Icon(AppIcons.shieldUser),
          title: Text(tr.settingsAdministrator),
          subtitle: Text(tr.adminMayManageMembersChange),
          value: m.isAdmin,
          onChanged: _canAdminister(m.role)
              ? (v) => _run(() => _api.updateUser(m.id, isAdmin: v))
              : null,
        ),
        ListHeading(tr.sectionCalendar, color: accent),
        _MemberCalendars(member: m, isMe: isMe),
        ListHeading(tr.adminSign, color: accent),
        ListTile(
          leading: const Icon(AppIcons.password),
          title: Text(
            u.hasPassword ? tr.adminResetPassword : tr.adminSetPassword,
          ),
          subtitle: Text(
            isMe
                ? tr.adminSetsPasswordAnewWithout
                : tr.adminEGIfName(m.displayName),
          ),
          onTap: () => _resetPassword(u, isMe: isMe),
        ),
        ListTile(
          leading: Icon(
            u.twoFactor ? AppIcons.shieldCheck : AppIcons.shield,
            color: u.twoFactor ? c.strong(FamioSection.tasks) : null,
          ),
          title: Text(u.twoFactor ? tr.adminTwoFactor : tr.adminTwoFactorOff),
          subtitle: Text(
            u.twoFactor
                ? tr.adminLostPhoneNoRecovery
                : isMe
                ? tr.adminTurnUnderSettingsSign
                : tr.adminNameCanTurnTheir(m.displayName),
          ),
          trailing: u.twoFactor
              ? TextButton(
                  onPressed: () => _confirmThen(
                    tr.adminResetTwoFactorName(m.displayName),
                    tr.adminAfterThatPasswordEnough(m.displayName),
                    tr.commonReset,
                    () => _run(
                      () => _api.resetTwoFactor(m.id),
                      done: tr.adminTwoFactorReset,
                    ),
                  ),
                  child: Text(tr.commonReset),
                )
              : null,
        ),
        if (u.singleSignOn)
          ListTile(
            leading: const Icon(AppIcons.logIn),
            title: Text(tr.adminLinkedSingleSign),
            trailing: TextButton(
              onPressed: () => _run(
                () => _api.unlinkUserSso(m.id),
                done: tr.adminLinkRemoved,
              ),
              child: Text(tr.adminUnlink),
            ),
          ),
        ListHeading(
          tr.adminDevicesCount(u.sessions.length),
          color: accent,
          trailing: u.sessions.length > (isMe ? 1 : 0)
              ? TextButton(
                  onPressed: () => _run(
                    () => _api.signOutUser(m.id),
                    done: isMe
                        ? tr.adminSignedOutAllOther
                        : tr.adminNameWasSignedOut(m.displayName),
                  ),
                  child: Text(
                    isMe ? tr.adminSignOutOthers : tr.adminSignOutEverywhere,
                  ),
                )
              : null,
        ),
        if (u.sessions.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              tr.adminNotSignedAnyDevice,
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
              tr.adminRemoveName(m.displayName),
              style: TextStyle(color: c.danger),
            ),
            subtitle: Text(tr.adminDeleteAccountSignOut),
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
            child: Text(tr.commonCancel),
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
        title: tr.adminEditMember,
        controllers: [name, username],
        fields: [
          TextField(
            controller: name,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: tr.settingsDisplayName),
          ),
          _UsernameField(controller: username, label: tr.commonUsername),
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
        title: tr.adminNewPasswordName(u.member.displayName),
        submitLabel: tr.adminSet,
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
                labelText: tr.settingsNewPassword,
              ),
            ),
          ),
          StatefulBuilder(
            builder: (context, setState) => CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                isMe ? tr.adminSignOutOtherDevices : tr.adminSignOutAllDevices,
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
          ? tr.adminPasswordChanged
          : tr.adminPasswordChangedDevicesSigned(_devices(signedOut)),
    );
  }

  Future<void> _remove(AdminUser u) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${u.member.displayName} entfernen?'),
        content: Text(tr.adminAccountDeletedSignedOut),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: FamioColors.of(context).danger,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr.commonRemove),
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
