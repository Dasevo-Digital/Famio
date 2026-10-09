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
import '../l10n.dart';

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
        title: tr.listsConnectBring,
        submitLabel: tr.commonSignIn,
        controllers: [email, password],
        fields: [
          Text(tr.listsBringHasNoOfficial),
          const SizedBox(height: 12),
          TextField(
            controller: email,
            autofocus: true,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: InputDecoration(labelText: tr.commonEmailAddress),
          ),
          PasswordReveal(
            builder: (_, obscure, toggle) => TextField(
              controller: password,
              obscureText: obscure,
              contextMenuBuilder: PasswordReveal.contextMenu,
              decoration: InputDecoration(
                labelText: tr.listsBringPassword,
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
        title: tr.listsConnectMsTodo,
        submitLabel: tr.commonNext,
        controllers: [clientId],
        fields: [
          Text(tr.listsOnceFamilyMicrosoftEntra),
          const SizedBox(height: 12),
          TextField(
            controller: clientId,
            autofocus: true,
            decoration: InputDecoration(
              labelText: tr.listsApplicationClientId,
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
        title: Text(tr.caldavDisconnectName(a.name)),
        content: Text(tr.listsSyncingEndsEntriesStay),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr.commonDisconnect),
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
    final date = DateFormat.Md(appLanguage).add_jm();
    String famioName(String id) => id == ListAccount.tasksList
        ? tr.sectionTasks
        : engine.shoppingLists.where((l) => l.id == id).firstOrNull?.name ??
              tr.listsDeletedList;
    return SectionPage(
      section: widget.section,
      title: tr.listsConnectLists,
      subtitle: tr.listsBringMicrosoftDoApple,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 120),
            children: [
              SectionHeader(
                tr.listsAppleRemindersThunderbirdCo,
                tr.listsTasksShoppingListsAppear,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(AppIcons.arrowsLeftRight),
                    label: Text(tr.listsConnectCalendar),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const CalendarConnectScreen(),
                      ),
                    ),
                  ),
                ),
              ),
              const Divider(height: 40),
              SectionHeader(
                tr.listsSyncBringMicrosoftDo,
                tr.listsFamioServerSyncsChosen,
              ),
              if (!enabled)
                ListTile(
                  leading: Icon(AppIcons.eyeSlash),
                  title: Text(tr.listsTurnedOffFamily),
                  subtitle: Text(tr.listsAdultAdminRightsCan),
                )
              else
                FutureBuilder(
                  future: _accounts,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return ListTile(
                        leading: const Icon(AppIcons.cloudSlash),
                        title: Text(tr.commonOnlyWithServer),
                        trailing: TextButton(
                          onPressed: _reload,
                          child: Text(tr.commonAgain),
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
                                  tr.listsNoListAssignedYet
                                else
                                  for (final l in a.links)
                                    '${famioName(l.famioList)} ↔ '
                                        '${l.remoteName.isEmpty ? tr.listsListThere : l.remoteName}',
                                if (a.lastSync != null)
                                  tr.listsLastTime(date.format(a.lastSync!)),
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
                                        tooltip: tr.commonSyncNow,
                                        onPressed: () => _run(
                                          a.id,
                                          () => _api.syncListAccount(a.id),
                                        ),
                                      ),
                                      PopupMenuButton<String>(
                                        tooltip: tr.navMore,
                                        onSelected: (v) => v == 'links'
                                            ? _editLinks(a)
                                            : _remove(a),
                                        itemBuilder: (_) => [
                                          PopupMenuItem(
                                            value: 'links',
                                            child: Text(tr.listsAssignLists),
                                          ),
                                          PopupMenuItem(
                                            value: 'remove',
                                            child: Text(tr.commonDisconnect),
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
                                label: Text(tr.listsConnectBring),
                                onPressed: _connectBring,
                              ),
                              FilledButton.tonalIcon(
                                icon: const Icon(AppIcons.listChecks),
                                label: Text(tr.listsConnectMsTodo),
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
      title: Text(tr.listsSignMicrosoft),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr.listsOpenPageEnterCode),
          const SizedBox(height: 12),
          Row(
            children: [
              SelectableText(
                widget.login.userCode,
                style: theme.textTheme.headlineSmall,
              ),
              IconButton(
                icon: const Icon(AppIcons.copy),
                tooltip: tr.listsCopyCode,
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
            Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 12),
                Expanded(child: Text(tr.listsWaitingConfirmation)),
              ],
            )
          else
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr.commonCancel),
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
      if (!widget.account.isBring) (ListAccount.tasksList, tr.sectionTasks),
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
                  error is ApiError ? error.message : tr.listsNotReachable,
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
                tr.listsEachFamioListChoose(
                  widget.account.isBring ? tr.listsMerged : tr.listsBothKept,
                ),
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
                      DropdownMenuItem(
                        value: null,
                        child: Text(tr.listsDoNotSync),
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
                  child: Text(_saving ? tr.listsSyncing : tr.commonSave),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
