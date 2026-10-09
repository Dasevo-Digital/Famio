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
import '../l10n.dart';

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
          title: tr.caldavNewAppPassword,
          submitLabel: tr.commonCreate,
          controllers: [name],
          fields: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: InputDecoration(
                labelText: tr.caldavWhichDevice,
                hintText: tr.caldavEGMomS,
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr.caldavShowPrivateEvents),
              subtitle: Text(tr.caldavOnlyOwnDevicesCalendar),
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
          ? tr.caldavNameSMac(state.me!.displayName)
          : Platform.isIOS
          ? tr.caldavNameSIphone(state.me!.displayName)
          : '',
    );
    final address = TextEditingController(
      text: (publicUrl ?? local).toString(),
    );
    ({String fileName, String profile})? result;
    await showDialog<void>(
      context: context,
      builder: (context) => FormDialog(
        title: tr.caldavSetUpAppleDevice,
        submitLabel: tr.caldavCreateProfile,
        controllers: [name, address],
        fields: [
          TextField(
            controller: name,
            autofocus: true,
            decoration: InputDecoration(
              labelText: tr.caldavWhichDevice,
              hintText: tr.caldavEGMomS,
            ),
          ),
          TextField(
            controller: address,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: tr.caldavServerAddressDevice,
              helperText: local.host == 'localhost' || local.host == '127.0.0.1'
                  ? tr.caldavLocalhostOnlyWorksMac
                  : tr.caldavWayDeviceReachesServer,
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
        dialogTitle: tr.caldavSaveProfileAppleCalendar,
        fileName: profile.fileName,
        bytes: Uint8List.fromList(utf8.encode(profile.profile)),
        mimeType: 'application/x-apple-aspen-config',
      );
      if (saved == null) {
        messenger.showSnackBar(
          SnackBar(content: Text(tr.caldavNotSavedDisconnectApp)),
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
                ? tr.caldavSystemSettingsGeneralDevice
                : tr.caldavProfileSavedOpenInstall,
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(tr.caldavProfileNotSavedError(e))),
      );
    }
  }

  Future<void> _delete(AppPassword p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.caldavDisconnectName(p.name)),
        content: Text(tr.caldavCalendarAppThatDevice),
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
            title: Text(tr.commonOnlyWithServer),
            trailing: TextButton(
              onPressed: _reload,
              child: Text(tr.commonAgain),
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
        final dateFormat = DateFormat.yMd(appLanguage).add_jm();

        Widget address(String label, Uri base) => ListTile(
          dense: true,
          title: Text(label),
          subtitle: SelectableText(
            base.resolve('dav/').toString(),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          trailing: IconButton(
            icon: const Icon(AppIcons.copy),
            tooltip: tr.caldavCopyAddress,
            onPressed: () {
              Clipboard.setData(
                ClipboardData(text: base.resolve('dav/').toString()),
              );
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(tr.caldavAddressCopied)));
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
                      address(tr.caldavServerAddressEverywhere, publicUrl),
                    address(
                      publicUrl == null
                          ? tr.commonServerAddress
                          : tr.caldavServerAddressHomeNetwork,
                      local,
                    ),
                    ListTile(
                      dense: true,
                      title: Text(tr.commonUsername),
                      subtitle: SelectableText(user),
                    ),
                    if (local.scheme == 'https' && state.certificatePin != null)
                      ListTile(
                        dense: true,
                        title: Text(tr.caldavCertificateSha256Compare),
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
                        ? tr.caldavNotUsedYet
                        : tr.caldavLastTime(dateFormat.format(p.lastUsed!)),
                    if (p.includeConfidential) tr.caldavPrivateEvents,
                  ].join(' · '),
                ),
                trailing: IconButton(
                  icon: const Icon(AppIcons.trash),
                  tooltip: tr.commonDisconnect,
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
                    label: Text(tr.caldavSetUpAppleDevice),
                    onPressed: () => _appleProfile(local, publicUrl),
                  ),
                  FilledButton.tonalIcon(
                    icon: const Icon(AppIcons.key),
                    label: Text(tr.caldavCreateAppPassword),
                    onPressed: _create,
                  ),
                ],
              ),
            ),
            HelpSteps(tr.caldavHowWorksMacIphone, [
              tr.caldavSetUpAppleDevice2,
              tr.caldavMacSaveProfileOpens,
              tr.caldavIphoneIpadSaveProfile,
              tr.caldavDeleteProfileFileAfterwards,
              tr.caldavGoOnlyWorksInternet,
            ]),
            HelpSteps(tr.caldavHowWorksAndroidDavx, [
              tr.caldavInstallDavxPlayStore,
              tr.caldavLoginUrlUserName,
              tr.caldavBaseUrlAddressAbove(user),
              tr.caldavSelectFamioCalendarThen,
            ]),
            if (passwords.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  tr.caldavOneAppPasswordPer,
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
      title: Text(tr.caldavAppPassword),
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
          Text(tr.caldavEnterNowPasswordCalendar),
        ],
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(AppIcons.copy),
          label: Text(tr.commonCopy),
          onPressed: () => Clipboard.setData(ClipboardData(text: secret)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr.commonDone),
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
        title: tr.caldavNewPasswordName(a.name),
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
                labelText: tr.commonPassword,
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
        title: Text(tr.caldavDisconnectName(a.name)),
        content: Text(tr.caldavEventsThatCameThere),
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
    if (ok != true || !mounted) return;
    final api = AppScope.read(context).engine!.api;
    await _run(a.id, () => api.deleteCalDavAccount(a.id));
  }

  @override
  Widget build(BuildContext context) {
    final api = AppScope.of(context).engine!.api;
    final c = FamioColors.of(context);
    final dateFormat = DateFormat.Md(appLanguage).add_jm();
    return FutureBuilder(
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
                  (a.error == null ? null : localizeServerText(a.error!)) ??
                      [
                        '${a.username} · ${Uri.tryParse(a.serverUrl)?.host ?? a.serverUrl}',
                        a.lastSync == null
                            ? tr.caldavEventsSynced(a.linkedEvents)
                            : tr.caldavEventsSyncedLast(
                                a.linkedEvents,
                                dateFormat.format(a.lastSync!),
                              ),
                        if (a.onlyMine) tr.caldavOnlyMyEvents,
                        tr.caldavVisibleWho(
                          sharingLabel(AppScope.engineOf(context), a.sharing),
                        ),
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
                            tooltip: tr.commonSyncNow,
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
                                PopupMenuItem(
                                  value: 'password',
                                  child: Text(tr.settingsChangePassword),
                                ),
                              CheckedPopupMenuItem(
                                value: 'mine',
                                checked: a.onlyMine,
                                child: Text(tr.caldavOnlySendMyEvents),
                              ),
                              PopupMenuItem(
                                value: 'share',
                                child: Text(tr.caldavShare),
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  icon: const Icon(AppIcons.arrowsLeftRight),
                  label: Text(tr.caldavConnectCalendar),
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
  google('Google', ''),
  icloud('iCloud', 'https://caldav.icloud.com'),
  nextcloud('Nextcloud', 'https://cloud.example.org/remote.php/dav'),
  mailbox('mailbox.org', 'https://dav.mailbox.org'),
  posteo('Posteo', 'https://posteo.de:8443'),
  other('', '');

  const _Provider(this._name, this.url);

  final String _name;
  final String url;

  String get label => this == other ? tr.commonOther : _name;

  String get userLabel => switch (this) {
    google => '',
    icloud => tr.caldavAppleIdEmail,
    mailbox || posteo => tr.commonEmailAddress,
    nextcloud || other => tr.commonUsername,
  };

  String get hint => switch (this) {
    google => tr.caldavGoogleNeedsItsOwn,
    icloud => tr.caldavAppSpecificPasswordAppleid,
    nextcloud => tr.caldavPreferablyAppPasswordNextcloud,
    mailbox => tr.caldavMailboxOrgPasswordApp,
    posteo => tr.caldavPosteoPassword,
    other => tr.caldavAddressCaldavServerE,
  };
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
            throw ApiError(0, 'browser', tr.commonBrowserFailed);
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
          SnackBar(content: Text(tr.caldavConnectedButError(account.error))),
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
      title: tr.caldavConnectCalendar,
      subtitle: tr.caldavSyncEventsBothDirections,
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
                HelpSteps(tr.caldavHowCreateGoogleAccess, [
                  tr.caldavOpenConsoleCloudGoogle,
                  tr.caldavApisServicesLibraryEnable,
                  tr.caldavOauthConsentScreenType,
                  tr.caldavCredentialsCreateCredentialsOauth,
                  tr.caldavEnterClientIdClient,
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
                      labelText: tr.caldavClientSecret,
                      prefixIcon: Icon(AppIcons.key),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    icon: const Icon(AppIcons.globe),
                    label: Text(tr.caldavSignGoogle),
                    onPressed: _busy ? null : _googleLogin,
                  ),
                ),
              ] else ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: tr.commonServerAddress,
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
                      labelText: tr.commonPassword,
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
                    label: Text(tr.caldavFindCalendars),
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
                Text(
                  tr.caldavWhichCalendar,
                  style: theme.textTheme.titleMedium,
                ),
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
                              ? Text(tr.caldavReadOnlyPleaseAdd)
                              : null,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr.caldavOnlySendMyEvents),
                  subtitle: Text(tr.caldavEventsYouTakePart),
                  value: _onlyMine,
                  onChanged: (v) => setState(() => _onlyMine = v),
                ),
                const SizedBox(height: 8),
                Text(
                  tr.caldavSeeEventsThere,
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
                  tr.caldavYouCanChangeAny,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  tr.caldavPrivateEventsNeverTransferred,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                ColorButton(
                  label: tr.commonConnect,
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
